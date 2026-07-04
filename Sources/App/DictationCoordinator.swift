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
        KeyboardShortcuts.onKeyDown(for: .dictation) { [weak self] in
            guard let self else { return }
            switch settings.dictationMode {
            case .toggle:
                toggleDictation()
            case .pushToTalk:
                pttKeyIsDown = true
                Task {
                    await self.startDictation()
                    // The key may already be released by the time the audio
                    // engine is running — stop right away in that case.
                    if !self.pttKeyIsDown, self.settings.dictationMode == .pushToTalk {
                        self.stopDictation()
                    }
                }
            }
        }
        KeyboardShortcuts.onKeyUp(for: .dictation) { [weak self] in
            guard let self else { return }
            pttKeyIsDown = false
            if settings.dictationMode == .pushToTalk {
                stopDictation()
            }
        }
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
        switch state.phase {
        case .recording, .transcribing:
            return
        case .idle, .success, .error:
            break
        }
        guard await AudioCaptureEngine.requestMicrophoneAccess() else {
            reportError("Microphone access denied. Grant it in System Settings > Privacy & Security > Microphone.")
            return
        }
        do {
            try captureEngine.start(deviceID: resolveCaptureDeviceID())
            idleResetTask?.cancel()
            state.phase = .recording
            installEscMonitors()
            Log.app.info("Recording started")
        } catch {
            reportError(error.localizedDescription)
        }
    }

    func stopDictation() {
        guard state.phase == .recording else { return }
        removeEscMonitors()
        let samples = captureEngine.stop()
        let duration = Double(samples.count) / AudioCaptureEngine.targetSampleRate
        Log.app.info("Recording stopped: \(samples.count) samples (\(duration, format: .fixed(precision: 2)) s)")

        // Accidental tap: nothing worth transcribing, bail out quietly.
        guard duration >= 0.35 else {
            state.phase = .idle
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
                state.statusDetail = "Preparing model — one-time, can take minutes…"
                modelManager.preparingVariant = settings.whisperKitModel
            }
            try await provider.prepare()
            state.statusDetail = nil

            let started = Date()
            let text = try await provider.transcribe(request)
            Log.transcription.info("Transcribed \(request.duration, format: .fixed(precision: 1)) s of audio in \(Date().timeIntervalSince(started), format: .fixed(precision: 1)) s")

            state.lastTranscript = text
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
            scheduleReturnToIdle(after: 0.8)
        } catch {
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
    private func resolveCaptureDeviceID() -> AudioDeviceID? {
        guard let uid = settings.selectedMicrophoneUID else { return nil }
        if let device = deviceManager.device(withUID: uid) {
            return device.id
        }
        NotificationManager.shared.post(
            title: "Microphone unavailable",
            body: "The selected microphone is not connected. Using the system default instead."
        )
        return nil
    }

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
