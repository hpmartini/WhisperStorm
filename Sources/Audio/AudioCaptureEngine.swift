import AVFoundation
import Accelerate
import Foundation

/// Captures microphone audio with AVCaptureSession, downsamples to 16 kHz mono
/// Float32 PCM and feeds smoothed RMS levels to the waveform overlay.
///
/// AVCaptureSession instead of AVAudioEngine: the engine also pulls the default
/// *output* device into a CoreAudio aggregate, and when that output stalls the
/// input fails with `kAUStartIO` / "avfaudio error 35" even though the microphone
/// is fine (reproduced with a stand-alone probe: engine failed, capture session
/// delivered samples on the same Elgato Wave:3). A capture session is input-only.
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

    /// Forwards capture callbacks without making the engine an NSObject.
    private final class SampleDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
        weak var owner: AudioCaptureEngine?

        func captureOutput(
            _ output: AVCaptureOutput,
            didOutput sampleBuffer: CMSampleBuffer,
            from connection: AVCaptureConnection
        ) {
            owner?.handle(sampleBuffer: sampleBuffer)
        }
    }

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: AudioCaptureEngine.targetSampleRate,
        channels: 1,
        interleaved: false
    )!

    private let levelStore: AudioLevelStore
    private var session: AVCaptureSession?
    private let sampleDelegate = SampleDelegate()
    /// startRunning/stopRunning block (seconds on a stalled device), so they never run on the main actor.
    private let sessionQueue = DispatchQueue(label: "whisperstorm.capture.session")
    private let sampleQueue = DispatchQueue(label: "whisperstorm.capture.samples")

    /// Only touched on `sampleQueue`.
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?

    private let bufferLock = NSLock()
    private var samples: [Float] = []
    /// Guarded by `bufferLock`; false drops late callbacks after stop().
    private var capturing = false

    private var smoothedLevel: Float = 0
    private var levelLogCounter = 0

    private(set) var isRunning = false
    private(set) var activeDeviceID: AudioDeviceID?

    /// Called on the main actor when the capture configuration changed
    /// mid-capture (e.g. the input device disappeared).
    var onConfigurationChange: (() -> Void)?

    private var observers: [NSObjectProtocol] = []

    init(levelStore: AudioLevelStore) {
        self.levelStore = levelStore
        sampleDelegate.owner = self
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
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

    /// Starts capturing without blocking the caller's thread. Pass nil to record from the system default input.
    func start(deviceID: AudioDeviceID?) async throws {
        guard !isRunning else { return }
        resetBuffers()
        let session = try makeSession(deviceID: deviceID)
        // Accept buffers from the first callback on: the await below resumes on the main actor, which may be busy, and anything dropped until then is lost audio.
        bufferLock.withLock { capturing = true }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                sessionQueue.async {
                    session.startRunning()
                    if session.isRunning {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: CaptureError.engineStartFailed("the capture session did not start"))
                    }
                }
            }
        } catch {
            bufferLock.withLock { capturing = false }
            throw error
        }
        attach(session)
        isRunning = true
    }

    /// Stops capturing and returns all 16 kHz mono samples recorded so far.
    func stop() -> [Float] {
        tearDownSession()
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
    /// Blocks while the new device starts; only used on rare device changes.
    func switchDevice(to deviceID: AudioDeviceID?) throws {
        guard isRunning else { return }
        tearDownSession()
        let session = try makeSession(deviceID: deviceID)
        bufferLock.withLock { capturing = true }
        session.startRunning()
        guard session.isRunning else {
            bufferLock.withLock { capturing = false }
            throw CaptureError.engineStartFailed("the capture session did not start")
        }
        attach(session)
    }

    var recordedDuration: TimeInterval {
        let count = bufferLock.withLock { samples.count }
        return Double(count) / Self.targetSampleRate
    }

    // MARK: - Session setup

    private func resetBuffers() {
        bufferLock.withLock { samples.removeAll(keepingCapacity: true) }
        sampleQueue.sync {
            converter = nil
            converterInputFormat = nil
        }
        smoothedLevel = 0
        levelStore.level = 0
    }

    /// Builds (but does not start) a session for the chosen device.
    private func makeSession(deviceID: AudioDeviceID?) throws -> AVCaptureSession {
        let device: AVCaptureDevice
        if let deviceID {
            guard let uid = AudioDeviceManager.allInputDevices().first(where: { $0.id == deviceID })?.uid,
                  let chosen = AVCaptureDevice(uniqueID: uid)
            else { throw CaptureError.deviceSelectionFailed }
            device = chosen
        } else {
            guard let fallback = AVCaptureDevice.default(for: .audio) else {
                throw CaptureError.deviceSelectionFailed
            }
            device = fallback
        }
        activeDeviceID = deviceID ?? AudioDeviceManager.defaultInputDeviceID()

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw CaptureError.engineStartFailed(error.localizedDescription)
        }
        let output = AVCaptureAudioDataOutput()
        // Float32 non-interleaved, so process(buffer:) can read floatChannelData directly.
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true,
        ]
        output.setSampleBufferDelegate(sampleDelegate, queue: sampleQueue)

        let session = AVCaptureSession()
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw CaptureError.deviceSelectionFailed
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        return session
    }

    private func attach(_ session: AVCaptureSession) {
        self.session = session
        let notify: (Notification) -> Void = { [weak self] _ in
            Log.audio.notice("Audio capture configuration changed")
            Task { @MainActor in
                self?.onConfigurationChange?()
            }
        }
        observers = [
            NotificationCenter.default.addObserver(
                forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil, using: notify
            ),
            NotificationCenter.default.addObserver(
                forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil, using: notify
            ),
        ]
        Log.audio.info("Capture started (device \(self.activeDeviceID ?? 0))")
    }

    private func tearDownSession() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        bufferLock.withLock { capturing = false }
        guard let session else { return }
        self.session = nil
        sessionQueue.async { session.stopRunning() }
    }

    // MARK: - Buffer processing (runs on `sampleQueue`)

    private func handle(sampleBuffer: CMSampleBuffer) {
        guard bufferLock.withLock({ capturing }) else { return }
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)
        else { return }
        var streamDescription = asbd.pointee
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0,
              let format = AVAudioFormat(streamDescription: &streamDescription),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        else { return }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList
        )
        guard status == noErr else {
            Log.audio.error("Copying capture samples failed: \(status)")
            return
        }
        process(buffer: buffer)
    }

    private func process(buffer: AVAudioPCMBuffer) {
        guard buffer.format.sampleRate > 0, buffer.format.channelCount > 0,
              let channelData = buffer.floatChannelData?[0]
        else { return }

        if converter == nil || converterInputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
            converterInputFormat = buffer.format
        }
        guard let converter else { return }

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
            guard capturing else { return }
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
