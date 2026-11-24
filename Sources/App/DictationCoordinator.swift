import Combine
import Foundation
import SwiftUI
import WhisperStormTranscription
import AppKit
import CoreAudio
import KeyboardShortcuts

/// Central orchestrator: wires hotkey, audio capture, transcription,
/// overlay and text insertion together.
@MainActor
final class DictationCoordinator: ObservableObject {
    static let shared = DictationCoordinator()

    /// How a dictation result is delivered. Hotkey and menu recordings use `.hotkey` (pastes via CGEvent + Accessibility);
    /// the Unix-socket control server uses `.socket` so the caller (pickyNotes) can read the transcript over
    /// the wire instead of pasting it twice. Set by every recording that actually starts, so a socket recording
    /// that never got its stop (cancelled with Esc, client gone) cannot turn off pasting for later hotkey dictations.
    enum DeliveryMode { case hotkey, socket }
    var deliveryMode: DeliveryMode = .hotkey

    let settings = AppSettings.shared
    let state = AppState()
    let levelStore = AudioLevelStore()
    let deviceManager = AudioDeviceManager()
    let modelManager = WhisperModelManager()

    private lazy var captureEngine = AudioCaptureEngine(levelStore: levelStore)
    private let outputDucker = OutputDucker()
    private let whisperProvider = WhisperKitProvider(
        variant: AppSettings.defaultWhisperKitModel,
        diagnostics: { FileLog.write($0) },
        recordingDumpURL: FileLog.url.deletingLastPathComponent().appending(path: "WhisperStorm-last-recording.wav")
    )
    private var overlayController: OverlayPanelController?
    private let onboardingController = OnboardingWindowController()

    private lazy var keyTap = RecordingKeyTap(
        onEscape: { [weak self] in MainActor.assumeIsolated { self?.cancelDictation() } },
        onUserInput: { [liveSlot] in liveSlot.userInput() }
    )
    /// Off-main entry points (capture queue, key tap thread) of the live session.
    private let liveSlot = LiveSessionSlot()
    private var liveSession: LiveDictationSession?
    /// SpeechTranscriber locale with its model installed; nil until prepared or unsupported.
    private var liveLocale: Locale?
    private var liveLocalePreparation: Task<Void, Never>?
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
    /// `captureEngine.start` suspends (phase is still idle meanwhile), so a second
    /// start must be ignored and a stop is remembered until recording begins.
    private(set) var isStarting = false
    private var stopAfterStart = false
    private var settingsCancellables = Set<AnyCancellable>()

    private init() {
        overlayController = OverlayPanelController(state: state, levelStore: levelStore)
        captureEngine.onConfigurationChange = { [weak self] in
            self?.handleAudioConfigurationChange()
        }
        captureEngine.onSamples = { [liveSlot] samples, offset in
            liveSlot.feed(samples, at: offset)
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
        setUpOutputDucking()
        setUpLiveRecognizer()
    }

    private func setUpOutputDucking() {
        outputDucker.recoverAfterCrash()
        outputDucker.follow(state.$phase) { [weak self] in
            self?.settings.duckOutputWhileRecording ?? false
        }
        .store(in: &settingsCancellables)
    }

    func restoreOutputVolume() {
        outputDucker.restore()
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
            if pttLatched, state.phase == .recording || isStarting {
                pttLatched = false
                pttIgnoreNextKeyUp = true
                stopDictation()
                return
            }
            pttLatched = false
            pttKeyIsDown = true
            pttKeyDownAt = Date()
            Task {
                await self.startDictation(delivery: .hotkey)
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
            if isStarting {
                stopDictation()
            } else {
                Task { await startDictation(delivery: .hotkey) }
            }
        case .transcribing:
            break
        }
    }

    func startDictation(delivery: DeliveryMode) async {
        FileLog.write("START requested, phase=\(state.phase) delivery=\(delivery)")
        switch state.phase {
        case .recording, .transcribing:
            FileLog.write("  -> ignored: already \(state.phase)")
            return
        case .idle, .success, .error:
            break
        }
        guard !isStarting else {
            FileLog.write("  -> ignored: start already in progress")
            return
        }
        isStarting = true
        stopAfterStart = false
        deliveryMode = delivery
        defer { isStarting = false }
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
            // Before capture starts: the target is the app in front at the
            // hotkey, and the first audio must reach the session.
            let live = await makeLiveSession()
            let startedAt = Date()
            defer { lastStartDuration = Date().timeIntervalSince(startedAt) }
            do {
                try await captureEngine.start(deviceID: device?.id)
            } catch {
                if let live { abandonLiveSession(live) }
                throw error
            }
            idleResetTask?.cancel()
            state.phase = .recording
            startKeyTap(watchInput: live != nil)
            Log.app.info("Recording started")
            FileLog.write(
                "  -> recording from \(activeDeviceLabel) "
                + "(start took \(String(format: "%.2f", Date().timeIntervalSince(startedAt)))s)"
            )
            if stopAfterStart {
                stopAfterStart = false
                stopDictation()
            }
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
        if isStarting, state.phase != .recording {
            FileLog.write("STOP deferred until recording has started")
            stopAfterStart = true
            return
        }
        guard state.phase == .recording else {
            FileLog.write("STOP ignored, phase=\(state.phase)")
            return
        }
        keyTap.stopEscape()
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
            discardLiveSession()
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
            discardLiveSession()
            reportError("No audio from \(activeDeviceLabel). Check the microphone and its input level.")
            return
        }

        if let live = liveSession {
            state.phase = .transcribing
            state.statusDetail = "Correcting…"
            transcriptionTask = Task { await finishLiveSession(live, samples: samples) }
            return
        }

        let request = TranscriptionRequest(
            samples: samples,
            languageCode: settings.language.languageCode
        )
        state.phase = .transcribing
        transcriptionTask = Task { await runTranscription(request) }
    }

    /// Esc during recording: discard everything. Live text already typed is
    /// removed while the field is still ours; the clipboard gets its
    /// pre-recording content back.
    func cancelDictation() {
        guard state.phase == .recording else { return }
        keyTap.stopEscape()
        captureEngine.cancel()
        FileLog.write("CANCEL recording discarded")
        Log.app.info("Recording cancelled")
        guard let live = liveSession else {
            keyTap.stop()
            state.phase = .idle
            return
        }
        // Busy until the typed text is gone, so no new recording types into it.
        state.phase = .transcribing
        state.statusDetail = "Cancelling…"
        Task {
            await live.cancel()
            endLiveSession(live)
            state.statusDetail = nil
            state.phase = .idle
        }
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
                FileLog.write("  -> socket delivery: transcript returned to the client, not pasted")
                state.phase = .success
            }
            scheduleReturnToIdle(after: 0.8)
        } catch {
            FileLog.write("TRANSCRIPTION FAILED: \(error.localizedDescription)")
            reportError(error.localizedDescription)
        }
    }

    func currentProvider() async throws -> any TranscriptionProvider {
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

    // MARK: - Key tap (Esc swallowed and user input watched only while recording)

    private func startKeyTap(watchInput: Bool) {
        let shortcuts = [KeyboardShortcuts.Name.toggleDictation, .pushToTalk].compactMap { name in
            KeyboardShortcuts.getShortcut(for: name).map {
                UserInputClassifier.Shortcut(keyCode: Int64($0.carbonKeyCode), flags: Self.eventFlags($0.modifiers))
            }
        }
        guard !keyTap.start(watchInput: watchInput, dictationShortcuts: shortcuts) else { return }
        // Without the tap Esc neither cancels nor gets swallowed, and live
        // typing cannot notice the user typing; say so unless a microphone
        // warning already occupies the status line.
        if state.captureNotice == nil {
            state.captureNotice = "Esc cancel off — grant Accessibility"
        }
        if watchInput { liveSession?.typer?.lock(.userInput) }
    }

    private static func eventFlags(_ modifiers: NSEvent.ModifierFlags) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        return flags
    }

    // MARK: - Live dictation

    /// Keeps the SpeechTranscriber model for the dictation language installed,
    /// so a recording never waits for a download.
    private func setUpLiveRecognizer() {
        settings.$language
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                self?.liveLocale = nil
                self?.prepareLiveLocale()
            }
            .store(in: &settingsCancellables)
        settings.$dictationMode
            .removeDuplicates()
            .sink { [weak self] mode in
                if mode == .live { self?.prepareLiveLocale() }
            }
            .store(in: &settingsCancellables)
    }

    private func prepareLiveLocale() {
        guard #available(macOS 26, *), settings.dictationMode == .live, liveLocalePreparation == nil else { return }
        let wanted: Locale = switch settings.language {
        case .german: Locale(identifier: "de_DE")
        case .english: Locale(identifier: "en_US")
        case .auto: Locale.current
        }
        liveLocalePreparation = Task {
            var locale = await LiveSpeechRecognizer.prepare(locale: wanted) { FileLog.write($0) }
            if locale == nil, settings.language == .auto {
                locale = await LiveSpeechRecognizer.prepare(locale: Locale(identifier: "de_DE")) { FileLog.write($0) }
            }
            liveLocale = locale
            liveLocalePreparation = nil
            FileLog.write("LIVE recognizer locale: \(locale?.identifier ?? "unavailable, Whisper chunks only")")
        }
    }

    /// Nil when this recording runs the classic way: live mode off, a socket
    /// client records (it reads the transcript itself), or no Accessibility
    /// (typing impossible).
    private func makeLiveSession() async -> LiveDictationSession? {
        guard #available(macOS 26, *), settings.dictationMode == .live, deliveryMode == .hotkey,
              TextInserter.isAccessibilityTrusted
        else { return nil }
        let provider: any TranscriptionProvider
        do {
            provider = try await currentProvider()
        } catch {
            FileLog.write("LIVE off for this recording: \(error.localizedDescription)")
            return nil
        }
        let session = LiveDictationSession(provider: provider, languageCode: settings.language.languageCode) { [weak self] line in
            self?.state.liveLine = line
        }
        if liveLocale == nil { prepareLiveLocale() }
        session.startRecognizer(locale: liveLocale)
        session.typer?.onLock = { [weak self] _ in
            guard let self, state.phase == .recording, state.captureNotice == nil else { return }
            state.captureNotice = "Typing stopped — full text goes to the clipboard"
        }
        liveSession = session
        liveSlot.set(session)
        return session
    }

    private func finishLiveSession(_ live: LiveDictationSession, samples: [Float]) async {
        let outcome = await live.finish(samples: samples)
        endLiveSession(live)
        state.statusDetail = nil
        guard !outcome.text.isEmpty else {
            reportError(TranscriptionError.emptyResult.localizedDescription)
            return
        }
        state.lastTranscript = outcome.text
        if outcome.fieldLock == .typingFailed, !outcome.typedAnything {
            // Unicode typing did not work at all: the classic paste path.
            _ = TextInserter.insert(outcome.text)
        } else if let lock = outcome.fieldLock {
            NotificationManager.shared.post(title: "Full transcript in clipboard", body: Self.lockExplanation(lock))
        }
        state.phase = .success
        scheduleReturnToIdle(after: 0.8)
    }

    private static func lockExplanation(_ lock: FieldSync.Lock) -> String {
        switch lock {
        case .userInput:
            "You typed or clicked during dictation, so WhisperStorm stopped typing. Paste the corrected text with Cmd+V."
        case .focusChanged:
            "The window changed during dictation, so the rest was not typed. Paste the transcript with Cmd+V."
        case .secureInput:
            "Secure Keyboard Entry is active in the focused app, so nothing could be typed. Paste the transcript with Cmd+V."
        case .cursorMoved:
            "The text field changed under the cursor, so the correction was not typed. Paste the corrected text with Cmd+V."
        case .correctionTooLarge:
            "A correction reached too far back to retype safely. Paste the corrected text with Cmd+V."
        case .typingFailed:
            "Typing into the field failed. Paste the transcript with Cmd+V."
        }
    }

    /// Too short or silent: nothing worth keeping.
    private func discardLiveSession() {
        guard let live = liveSession else { return }
        Task {
            await live.cancel()
            endLiveSession(live)
        }
    }

    /// The capture broke off: keep what was typed, finalize the clipboard.
    private func abandonLiveSession(_ live: LiveDictationSession) {
        live.abandon()
        endLiveSession(live)
    }

    private func endLiveSession(_ live: LiveDictationSession) {
        guard liveSession === live else { return }
        liveSession = nil
        liveSlot.clear()
        keyTap.stopWatchingInput()
        state.liveLine = ""
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
            keyTap.stop()
            if let live = liveSession { abandonLiveSession(live) }
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
            keyTap.stop()
            if let live = liveSession { abandonLiveSession(live) }
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
