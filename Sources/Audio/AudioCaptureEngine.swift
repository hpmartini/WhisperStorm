import AVFoundation
import Accelerate
import Foundation

/// Captures microphone audio with AVAudioEngine, downsamples to 16 kHz mono
/// Float32 PCM and feeds smoothed RMS levels to the waveform overlay.
final class AudioCaptureEngine {
    static let targetSampleRate: Double = 16_000

    enum CaptureError: LocalizedError {
        case microphoneAccessDenied
        case invalidInputFormat
        case converterUnavailable
        case deviceSelectionFailed
        case engineStartFailed(String)

        var errorDescription: String? {
            switch self {
            case .microphoneAccessDenied:
                "Microphone access is denied. Grant it in System Settings > Privacy & Security > Microphone."
            case .invalidInputFormat:
                "The input device reports an invalid audio format."
            case .converterUnavailable:
                "Could not create an audio converter for the input format."
            case .deviceSelectionFailed:
                "Could not select the chosen input device."
            case .engineStartFailed(let reason):
                "The audio engine failed to start: \(reason)"
            }
        }
    }

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: AudioCaptureEngine.targetSampleRate,
        channels: 1,
        interleaved: false
    )!

    private let levelStore: AudioLevelStore
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?

    private let bufferLock = NSLock()
    private var samples: [Float] = []

    private var smoothedLevel: Float = 0
    private var levelLogCounter = 0

    private(set) var isRunning = false
    private(set) var activeDeviceID: AudioDeviceID?

    /// Called on the main actor when the engine's configuration changed
    /// mid-capture (e.g. the input device disappeared).
    var onConfigurationChange: (() -> Void)?

    private var configurationObserver: NSObjectProtocol?

    init(levelStore: AudioLevelStore) {
        self.levelStore = levelStore
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    // MARK: - Capture lifecycle

    /// Starts capturing. Pass nil to record from the system default input.
    func start(deviceID: AudioDeviceID?) throws {
        guard !isRunning else { return }
        bufferLock.withLock { samples.removeAll(keepingCapacity: true) }
        smoothedLevel = 0
        levelStore.level = 0
        try setUpEngine(deviceID: deviceID)
        isRunning = true
    }

    /// Stops capturing and returns all 16 kHz mono samples recorded so far.
    func stop() -> [Float] {
        tearDownEngine()
        isRunning = false
        levelStore.level = 0
        return bufferLock.withLock { samples }
    }

    /// Discards the capture session without returning samples.
    func cancel() {
        _ = stop()
        bufferLock.withLock { samples.removeAll() }
    }

    /// Re-attaches capture to another device, keeping already-recorded samples.
    func switchDevice(to deviceID: AudioDeviceID?) throws {
        guard isRunning else { return }
        tearDownEngine()
        try setUpEngine(deviceID: deviceID)
    }

    var recordedDuration: TimeInterval {
        let count = bufferLock.withLock { samples.count }
        return Double(count) / Self.targetSampleRate
    }

    // MARK: - Engine setup

    private func setUpEngine(deviceID: AudioDeviceID?) throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        if let deviceID {
            try setInputDevice(deviceID, on: inputNode)
        }
        activeDeviceID = deviceID ?? AudioDeviceManager.defaultInputDeviceID()

        let inputFormat = inputNode.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CaptureError.invalidInputFormat
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw CaptureError.converterUnavailable
        }
        self.converter = converter

        inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer: buffer)
        }

        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            Log.audio.notice("Audio engine configuration changed")
            Task { @MainActor in
                self?.onConfigurationChange?()
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw CaptureError.engineStartFailed(error.localizedDescription)
        }
        self.engine = engine
        Log.audio.info("Capture started (device \(self.activeDeviceID ?? 0), input \(inputFormat.sampleRate) Hz / \(inputFormat.channelCount) ch)")
    }

    private func tearDownEngine() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        converter = nil
    }

    private func setInputDevice(_ deviceID: AudioDeviceID, on node: AVAudioInputNode) throws {
        guard let audioUnit = node.audioUnit else {
            throw CaptureError.deviceSelectionFailed
        }
        var device = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw CaptureError.deviceSelectionFailed
        }
    }

    // MARK: - Buffer processing (runs on the audio tap thread)

    private func process(buffer: AVAudioPCMBuffer) {
        guard let converter, let channelData = buffer.floatChannelData?[0] else { return }

        var rms: Float = 0
        vDSP_rmsqv(channelData, 1, &rms, vDSP_Length(buffer.frameLength))
        updateLevel(rms: rms)

        let ratio = Self.targetSampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return
        }

        var didProvideInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outBuffer, error: &conversionError) { _, inputStatus in
            if didProvideInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error else {
            Log.audio.error("Sample rate conversion failed: \(conversionError?.localizedDescription ?? "unknown")")
            return
        }

        let frameCount = Int(outBuffer.frameLength)
        guard frameCount > 0, let outChannel = outBuffer.floatChannelData?[0] else { return }
        bufferLock.withLock {
            samples.append(contentsOf: UnsafeBufferPointer(start: outChannel, count: frameCount))
        }
    }

    private func updateLevel(rms: Float) {
        // Map RMS to dBFS and normalize -50…0 dB to 0…1.
        let db = 20 * log10(max(rms, 1e-7))
        let normalized = max(0, min(1, (db + 50) / 50))
        // Attack/release envelope so the waveform moves organically.
        let coefficient: Float = normalized > smoothedLevel ? 0.55 : 0.12
        smoothedLevel += (normalized - smoothedLevel) * coefficient
        levelStore.level = smoothedLevel

        levelLogCounter += 1
        if levelLogCounter % 20 == 0 {
            Log.audio.debug("Mic level: rms=\(rms, format: .fixed(precision: 5)) normalized=\(self.smoothedLevel, format: .fixed(precision: 3))")
        }
    }
}
