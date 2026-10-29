import AudioToolbox
import Combine
import CoreAudio
import Foundation

/// Reads and writes the main volume (0…1) of output devices.
protocol OutputVolumeControl {
    func defaultOutputDevice() -> AudioDeviceID?
    /// nil when the device is gone or has no settable volume (HDMI, digital outs).
    func volume(of device: AudioDeviceID) -> Float?
    func setVolume(_ volume: Float, of device: AudioDeviceID) -> Bool
    /// Persistent identity of a device; AudioDeviceIDs are reassigned across reboots.
    func uid(of device: AudioDeviceID) -> String?
}

/// Lowers the default output while recording and restores it afterwards.
///
/// The original volume is persisted before ducking, so a crash mid-recording
/// is undone by `recoverAfterCrash()` on the next launch.
final class OutputDucker {
    /// Ducked level as a fraction of the original volume.
    static let duckFactor: Float = 0.1
    /// A volume further than this from the ducked value means the user moved it.
    static let tolerance: Float = 0.01

    private enum Keys {
        static let device = "duckedOutputDevice"
        static let uid = "duckedOutputDeviceUID"
        static let original = "duckedOutputOriginalVolume"
        static let ducked = "duckedOutputDuckedVolume"
    }

    private let control: OutputVolumeControl
    private let defaults: UserDefaults
    private let log: (String) -> Void

    init(
        control: OutputVolumeControl = CoreAudioOutputVolume(),
        defaults: UserDefaults = .standard,
        log: @escaping (String) -> Void = FileLog.write
    ) {
        self.control = control
        self.defaults = defaults
        self.log = log
    }

    var isDucked: Bool { defaults.object(forKey: Keys.device) != nil }

    func duck() {
        guard !isDucked else { return }
        guard let device = control.defaultOutputDevice() else {
            log("DUCK skipped: no default output device")
            return
        }
        guard let original = control.volume(of: device) else {
            log("DUCK skipped: output device \(device) has no settable volume")
            return
        }
        let target = original * Self.duckFactor
        // Persist first: a crash between set and save would otherwise leave the Mac quiet for good.
        defaults.set(Int(device), forKey: Keys.device)
        defaults.set(control.uid(of: device), forKey: Keys.uid)
        defaults.set(original, forKey: Keys.original)
        defaults.set(target, forKey: Keys.ducked)
        guard control.setVolume(target, of: device) else {
            log("DUCK failed: could not set volume on output device \(device)")
            clear()
            return
        }
        // Devices quantize volume steps; compare the restore check against what actually stuck.
        defaults.set(control.volume(of: device) ?? target, forKey: Keys.ducked)
        log("DUCK output \(device): \(original) -> \(target)")
    }

    func restore() {
        guard isDucked else { return }
        defer { clear() }
        let device = AudioDeviceID(defaults.integer(forKey: Keys.device))
        let original = defaults.float(forKey: Keys.original)
        let ducked = defaults.float(forKey: Keys.ducked)
        // After a reboot the same ID can name another device; never set its volume.
        guard control.uid(of: device) == defaults.string(forKey: Keys.uid),
              let current = control.volume(of: device) else {
            log("RESTORE skipped: output device \(device) is gone")
            return
        }
        guard abs(current - ducked) <= Self.tolerance else {
            log("RESTORE skipped: user changed output \(device) to \(current) while recording")
            return
        }
        if control.setVolume(original, of: device) {
            log("RESTORE output \(device): \(current) -> \(original)")
        } else {
            log("RESTORE failed: could not set volume on output device \(device)")
        }
    }

    /// Ducks while the phase is `.recording` and restores on any exit from it
    /// (stop, Esc, error, device loss), so no end path can leave the Mac quiet.
    func follow<P: Publisher>(_ phase: P, enabled: @escaping () -> Bool) -> AnyCancellable
    where P.Output == AppState.Phase, P.Failure == Never {
        phase
            .map { $0 == .recording }
            .removeDuplicates()
            .sink { [weak self] recording in
                if recording, enabled() {
                    self?.duck()
                } else if !recording {
                    self?.restore()
                }
            }
    }

    /// Undoes a duck left behind by a crash during recording.
    func recoverAfterCrash() {
        guard isDucked else { return }
        log("RESTORE after unclean exit")
        restore()
    }

    private func clear() {
        defaults.removeObject(forKey: Keys.device)
        defaults.removeObject(forKey: Keys.uid)
        defaults.removeObject(forKey: Keys.original)
        defaults.removeObject(forKey: Keys.ducked)
    }
}

/// `OutputVolumeControl` over the CoreAudio HAL (no Automation permission needed).
struct CoreAudioOutputVolume: OutputVolumeControl {
    func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    func volume(of device: AudioDeviceID) -> Float? {
        var address = Self.volumeAddress
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue
        else { return nil }
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr else { return nil }
        return volume
    }

    func setVolume(_ volume: Float, of device: AudioDeviceID) -> Bool {
        var address = Self.volumeAddress
        var value = Float32(min(max(volume, 0), 1))
        let size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectSetPropertyData(device, &address, 0, nil, size, &value) == noErr
    }

    func uid(of device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    /// The same main-volume control the menu bar slider moves.
    private static let volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
}
