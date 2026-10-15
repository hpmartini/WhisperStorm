import Combine
import Foundation
import SwiftUI
import AppKit
import CoreAudio
import KeyboardShortcuts

/// Central orchestrator: wires hotkey, audio capture, transcription,
/// overlay and text insertion together.
@MainActor
final class DictationCoordinator: ObservableObject {
    static let shared = DictationCoordinator()

    /// How a dictation result is delivered. The hotkey path uses `.hotkey` (pastes via CGEvent + Accessibility);
    /// the Unix-socket control server uses `.socket` so the caller (pickyNotes) can read the transcript over
    /// the wire instead of pasting it twice.
    enum DeliveryMode { case hotkey, socket }
    var deliveryMode: DeliveryMode = .hotkey

    let settings = AppSettings.shared
    let state = AppState()
    let levelStore = AudioLevelStore()
    let deviceManager = AudioDeviceManager()
    let modelManager = WhisperModelManager()

    private lazy var captureEngine = AudioCaptureEngine(levelStore: levelStore)
    private let whisperProvider = WhisperKitProvider()
    private var overlayController: OverlayPanelController?
    private let onboardingController = OnboardingWindowController()

    private var escGlobalMonitor: Any?
    private var escLocalMonitor: Any?
    private var idleResetTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var pttKeyIsDown = false
    private var pttKeyDownAt = Date.distantPast
    /// Recording was started by a short tap on the push-to-talk key (with
    /// "tap to toggle" on) and keeps running until the next tap.
    private var pttLatched = false
    /// The key-down that stopped a latched recording also produces a key-up,
    /// which must not be treated as a push-to-talk release.
    private var pttIgnoreNextKeyUp = false
    /// Human-readable name of the device the current recording came from,
    /// so failures can name it instead of just saying "no speech".
    private var activeDeviceLabel = "the system default input"
    /// How long `captureEngine.start` blocked for the current recording.
    /// A stalled device (seen with an Elgato Wave:3) can hold the main actor
    /// for seconds, so the push-to-talk key-up only arrives afterwards.
    private var lastStartDuration: TimeInterval = 0
    private var settingsCancellables = Set<AnyCancellable>()

    private init() {
        overlayController = OverlayPanelController(state: state, levelStore: levelStore)
        captureEngine.onConfigurationChange = { [weak self] in
            self?.handleAudioConfigurationChange()
        }
        deviceManager.onDevicesChanged = { [weak self] in
            self?.handleDeviceListChange()
        }
        modelManager.onModelDownloaded = { [weak self] variant in
            self?.warmUpWhisperModelIfActive(variant)
        }
        KeyboardShortcuts.Name.migrateLegacyDictationMode()
        KeyboardShortcuts.Name.unbindPushToTalkIfDuplicate()
        setUpHotkey()
        setUpModelWarmUp()
    }

    /// First load of a model triggers CoreML/ANE specialization (minutes for
    /// large models). Warm up whenever the active model could have changed —
    /// at launch, on model activation and on provider switch — so dictation
    /// never pays that cost.
    private func setUpModelWarmUp() {
        settings.$whisperKitModel
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] variant in
                self?.warmUpWhisperModelIfActive(variant)
            }
            .store(in: &settingsCancellables)

        settings.$providerKind
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] kind in
                guard let self, kind == .whisperKit else { return }
                warmUpWhisperModelIfActive(settings.whisperKitModel)
            }
            .store(in: &settingsCancellables)

        warmUpWhisperModelIfActive(settings.whisperKitModel)
    }

    // MARK: - Hotkey

    private func setUpHotkey() {
        KeyboardShortcuts.onKeyDown(for: .toggleDictation) { [weak self] in
            guard let self, Self.accepts(.toggleDictation, event: "TOGGLE down") else { return }
            toggleDictation()
        }
        KeyboardShortcuts.onKeyDown(for: .pushToTalk) { [weak self] in
            guard let self, Self.accepts(.pushToTalk, event: "PTT down") else { return }
            if pttLatched, state.phase == .recording {
                pttLatched = false
                pttIgnoreNextKeyUp = true
                stopDictation()
                return
            }
            pttLatched = false
            pttKeyIsDown = true
            pttKeyDownAt = Date()
            Task {
                await self.startDictation()
                // The key may already be released by the time the audio
                // engine is running — stop right away unless a tap latched it.
                if !self.pttKeyIsDown, !self.pttLatched {
                    self.stopDictation()
                }
            }
        }
        KeyboardShortcuts.onKeyUp(for: .pushToTalk) { [weak self] in
            FileLog.write("PTT up")
            guard let self else { return }
            // Note: no modifier check on key-up — releasing the trigger key
            // means at least one registered modifier is already lifting, so
            // the held flags no longer match. We must still stop, otherwise
            // recording would run forever.
            pttKeyIsDown = false
            if pttIgnoreNextKeyUp {
                pttIgnoreNextKeyUp = false
                return
            }
            // This handler can run late (capture start blocks the main actor
            // for ~0.5 s), so take the release time from the HID event clock.
            let releasedAt = Date().addingTimeInterval(
                -CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyUp)
            )
            if settings.pushToTalkTapToggles,
               releasedAt.timeIntervalSince(pttKeyDownAt) < Self.tapThreshold {
                pttLatched = true
                FileLog.write("  -> tap: recording latched")
                return
            }
            stopDictation()
        }
    }

    /// Key-down shorter than this counts as a tap, not a hold.
    private static let tapThreshold: TimeInterval = 0.3

    /// Logs the key-down and checks its modifiers. Carbon's
    /// `RegisterEventHotKey` (used by KeyboardShortcuts) matches when the
    /// registered modifiers are *present*, not when they are the *only*
    /// modifiers held — so ⌥Space also fires under ⌃⌥Space. Reject that by
    /// requiring the held modifiers to equal the shortcut's exactly.
    /// Restricted to the four command modifiers so Caps Lock, Fn, etc. don't
    /// spuriously block the hotkey. (The unified log is unreadable for this
    /// app, see TASK.md, hence the file log.)
    private static func accepts(_ name: KeyboardShortcuts.Name, event: String) -> Bool {
        let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let held = NSEvent.modifierFlags.intersection(relevant)
        let expected = KeyboardShortcuts.getShortcut(for: name)?.modifiers.intersection(relevant)
        FileLog.write("\(event) held=\(held.rawValue) expected=\(expected.map { String($0.rawValue) } ?? "nil")")
        guard expected == nil || held == expected else {
            FileLog.write("  -> ignored: held modifiers differ from shortcut")
            return false
        }
        return true
    }

    // MARK: - Dictation flow

    func toggleDictation() {
        switch state.phase {
        case .recording:
            stopDictation()
        case .idle, .success, .error:
            Task { await startDictation() }
        case .transcribing:
            break
        }
    }

    func startDictation() async {
        FileLog.write("START requested, phase=\(state.phase)")
        switch state.phase {
        case .recording, .transcribing:
            FileLog.write("  -> ignored: already \(state.phase)")
            return
        case .idle, .success, .error:
            break
        }
        guard await AudioCaptureEngine.requestMicrophoneAccess() else {
            FileLog.write("  -> microphone access denied")
            reportError("Microphone access denied. Grant it in System Settings > Privacy & Security > Microphone.")
            return
        }
        do {
            let device = resolveCaptureDevice()
            activeDeviceLabel = device?.name
                ?? deviceManager.defaultInputDevice?.name
                ?? "the system default input"
            let startedAt = Date()
            defer { lastStartDuration = Date().timeIntervalSince(startedAt) }
            try await captureEngine.start(deviceID: device?.id)
            idleResetTask?.cancel()
            state.phase = .recording
            installEscMonitors()
            Log.app.info("Recording started")
            FileLog.write(
                "  -> recording from \(activeDeviceLabel) "
                + "(start took \(String(format: "%.2f", Date().timeIntervalSince(startedAt)))s)"
            )
        } catch {
            FileLog.write(
                "  -> capture start FAILED after \(String(format: "%.2f", lastStartDuration))s: "
                + error.localizedDescription
            )
            if case AudioCaptureEngine.CaptureError.engineStartFailed = error {
                // The raw CoreAudio text ("avfaudio error 35") tells the user
                // nothing. This is a device/HAL stall, not an app fault.
                reportError(
                    "\(activeDeviceLabel) did not start (\(String(format: "%.0f", lastStartDuration)) s). "
                    + "Replug it or pick another microphone in Settings."
                )
            } else {
                reportError(error.localizedDescription)
            }
        }
    }

    func stopDictation() {
        guard state.phase == .recording else {
            FileLog.write("STOP ignored, phase=\(state.phase)")
            return
        }
        removeEscMonitors()
        let samples = captureEngine.stop()
        let duration = Double(samples.count) / AudioCaptureEngine.targetSampleRate
        Log.app.info("Recording stopped: \(samples.count) samples (\(duration, format: .fixed(precision: 2)) s)")

        // Accidental tap: nothing worth transcribing, bail out quietly.
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        FileLog.write(
            "STOP samples=\(samples.count) duration=\(String(format: "%.2f", duration))s "
            + "peak=\(String(format: "%.4f", peak)) device=\(activeDeviceLabel)"
        )
        guard duration >= 0.35 else {
            FileLog.write("  -> discarded: shorter than 0.35 s")
            // If the device took seconds to start, the key was held long
            // enough — the stall ate the recording. Don't discard silently.
            if lastStartDuration >= Self.slowStartThreshold {
                reportError(
                    "\(activeDeviceLabel) took \(String(format: "%.0f", lastStartDuration)) s to start, "
                    + "nothing was recorded. Replug it or pick another microphone."
                )
            } else {
                state.phase = .idle
            }
            return
        }

        // A silent buffer would reach the model and come back as the useless
        // "No speech was recognized" — name the device that produced it instead.
        guard peak >= Self.silenceThreshold else {
            FileLog.write("  -> silent recording, not transcribing")
            reportError("No audio from \(activeDeviceLabel). Check the microphone and its input level.")
            return
        }

        let request = TranscriptionRequest(
            samples: samples,
            languageCode: settings.language.languageCode
        )
        state.phase = .transcribing
        transcriptionTask = Task { await runTranscription(request) }
    }

    /// Esc during recording: discard everything — no insert, no clipboard write.
    func cancelDictation() {
        guard state.phase == .recording else { return }
        removeEscMonitors()
        captureEngine.cancel()
        state.phase = .idle
        Log.app.info("Recording cancelled")
    }

    private func runTranscription(_ request: TranscriptionRequest) async {
        defer {
            state.statusDetail = nil
            if modelManager.preparingVariant == settings.whisperKitModel {
                modelManager.preparingVariant = nil
            }
        }
        do {
            let provider = try await currentProvider()

            // Surface expensive one-time model loading instead of letting the
            // overlay claim "Transcribing…" for minutes.
            if settings.providerKind == .whisperKit, await !whisperProvider.isReady {
                state.statusDetail = "Loading model…"
                modelManager.preparingVariant = settings.whisperKitModel
            }
            try await provider.prepare()
            state.statusDetail = nil

            let started = Date()
            let text = try await provider.transcribe(request)
            Log.transcription.info("Transcribed \(request.duration, format: .fixed(precision: 1)) s of audio in \(Date().timeIntervalSince(started), format: .fixed(precision: 1)) s")

            FileLog.write("TRANSCRIBED chars=\(text.count)")
            state.lastTranscript = text
            if deliveryMode == .hotkey {
                let outcome = TextInserter.insert(text)
                state.phase = .success
                if case .clipboardOnly(let reason, let accessibilityMissing) = outcome {
                    if accessibilityMissing {
                        NotificationManager.shared.post(
                            title: "Copied to clipboard — insertion disabled",
                            body: "WhisperStorm has no Accessibility permission (rebuilds reset it). System Settings > Privacy & Security > Accessibility: remove WhisperStorm with \u{2212}, then re-add and enable it. The transcript is in your clipboard."
                        )
                    } else {
                        NotificationManager.shared.post(
                            title: "Copied to clipboard",
                            body: "The transcript could not be inserted (\(reason.lowercased())). It is in your clipboard — paste it with Cmd+V."
                        )
                    }
                }
            } else {
                // Socket delivery: the caller reads the transcript over the wire.
                state.phase = .success
            }
            scheduleReturnToIdle(after: 0.8)
        } catch {
            FileLog.write("TRANSCRIPTION FAILED: \(error.localizedDescription)")
            reportError(error.localizedDescription)
        }
    }

    private func currentProvider() async throws -> any TranscriptionProvider {
        switch settings.providerKind {
        case .whisperKit:
            await whisperProvider.setVariant(settings.whisperKitModel)
            return whisperProvider
        case .openAICompatible:
            return OpenAICompatibleProvider(
                baseURL: settings.endpointBaseURL,
                model: settings.endpointModelName
            )
        }
    }

    func showOnboarding() {
        onboardingController.show()
    }

    private func warmUpWhisperModelIfActive(_ variant: String) {
        guard settings.providerKind == .whisperKit,
              settings.whisperKitModel == variant,
              WhisperModelManager.isDownloaded(variant)
        else { return }
        Task {
            await whisperProvider.setVariant(variant)
            guard await !whisperProvider.isReady else { return }
            modelManager.preparingVariant = variant
            await whisperProvider.warmUp()
            if modelManager.preparingVariant == variant {
                modelManager.preparingVariant = nil
            }
        }
    }

    func copyLastTranscript() {
        guard !state.lastTranscript.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(state.lastTranscript, forType: .string)
    }

    // MARK: - Esc monitoring (only active while recording)

    private func installEscMonitors() {
        removeEscMonitors()
        escGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor in self?.cancelDictation() }
        }
        escLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.cancelDictation()
            return nil
        }
    }

    private func removeEscMonitors() {
        if let escGlobalMonitor {
            NSEvent.removeMonitor(escGlobalMonitor)
            self.escGlobalMonitor = nil
        }
        if let escLocalMonitor {
            NSEvent.removeMonitor(escLocalMonitor)
            self.escLocalMonitor = nil
        }
    }

    // MARK: - Microphone handling

    /// Resolves the persisted microphone selection to a live device, falling
    /// back to the system default (with a notification) when it is gone.
    /// Resolves the microphone to record from. Falls back to the system
    /// default when the selected device is gone — which happens silently
    /// whenever a USB mic's CoreAudio UID changes (a different port, or
    /// vendor software such as Elgato Wave Link claiming the raw device and
    /// replacing it with its own virtual inputs). The fallback is surfaced in
    /// the overlay as well, because recording from an unexpected device looks
    /// exactly like a broken app.
    private func resolveCaptureDevice() -> AudioInputDevice? {
        state.captureNotice = nil
        guard let uid = settings.selectedMicrophoneUID else { return nil }
        if let device = deviceManager.device(withUID: uid) {
            return device
        }
        let fallback = deviceManager.defaultInputDevice?.name ?? "the system default input"
        state.captureNotice = "Selected mic unavailable — using \(fallback)"
        FileLog.write("  -> selected mic (uid=\(uid)) not present, falling back")
        NotificationManager.shared.post(
            title: "Microphone unavailable",
            body: "The microphone selected in WhisperStorm is not available. Recording from \(fallback) instead — pick another device in Settings."
        )
        return nil
    }

    /// Peak amplitude below which a recording is treated as silence
    /// (≈ −54 dBFS): far under any live microphone's room noise.
    private static let silenceThreshold: Float = 0.002

    /// Capture start normally takes well under a second; beyond this the
    /// device is stalling and the start itself becomes the problem.
    private static let slowStartThreshold: TimeInterval = 2

    private func handleDeviceListChange() {
        guard state.phase == .recording,
              let activeID = captureEngine.activeDeviceID,
              !deviceManager.isDevicePresent(id: activeID)
        else { return }

        Log.audio.notice("Active input device disappeared, falling back to system default")
        NotificationManager.shared.post(
            title: "Microphone disconnected",
            body: "The active microphone was disconnected. Switched to the system default input."
        )
        do {
            try captureEngine.switchDevice(to: nil)
        } catch {
            captureEngine.cancel()
            removeEscMonitors()
            reportError("Recording stopped: \(error.localizedDescription)")
        }
    }

    private func handleAudioConfigurationChange() {
        guard state.phase == .recording else { return }
        // The engine stops delivering buffers after a configuration change;
        // re-attach to whatever device is still valid.
        let deviceID: AudioDeviceID? = captureEngine.activeDeviceID.flatMap {
            deviceManager.isDevicePresent(id: $0) ? $0 : nil
        }
        do {
            try captureEngine.switchDevice(to: deviceID)
        } catch {
            captureEngine.cancel()
            removeEscMonitors()
            reportError("Recording stopped: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private func scheduleReturnToIdle(after delay: TimeInterval) {
        idleResetTask?.cancel()
        idleResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            switch self.state.phase {
            case .success, .error:
                self.state.phase = .idle
            default:
                break
            }
        }
    }

    /// Errors surface in the overlay AND as a user notification — never silently.
    private func reportError(_ message: String) {
        Log.app.error("\(message)")
        state.phase = .error(message)
        NotificationManager.shared.post(title: "WhisperStorm", body: message)
        scheduleReturnToIdle(after: 3.5)
    }
}
