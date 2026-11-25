import AppKit
import Foundation
import WhisperStormTranscription

/// One live dictation. While the user speaks, Apple's SpeechTranscriber
/// confirms words and Whisper re-transcribes the audio in chunks (cut at
/// pauses, at most 30 s) whose text replaces the live words of each chunk
/// (`LiveText`). Field and clipboard follow that preview; provisional words
/// only reach the overlay.
///
/// The final transcript is always one Whisper pass over the whole recording
/// (classic-mode quality); it replaces the preview in the field. A failure
/// of the live path therefore never costs the recording.
@MainActor
final class LiveDictationSession {
    struct Outcome {
        let text: String
        /// Why the field stopped following the transcript, if it did.
        let fieldLock: FieldSync.Lock?
        let typedAnything: Bool
        /// The whole-recording pass failed or heard nothing; `text` is the live text.
        let finalPassFailed: Bool
        /// The final text differs from what the preview showed.
        let changedPreview: Bool
    }

    /// Nil when no app was in front at the start; the transcript then only
    /// goes to the clipboard.
    let typer: LiveFieldTyper?
    let feeder = LiveFeeder()
    let abort = AbortFlag()
    private let clipboard: ClipboardMirror
    private let provider: any TranscriptionProvider
    private let languageCode: String?
    private let vocabulary: Vocabulary
    private let startedAt = Date()
    private let onLiveLine: (String) -> Void

    private var text = LiveText()
    private var lastConfirmed = ""
    private var cancelled = false
    /// Recording stopped: the whole-recording pass decides the field; late
    /// chunk and live results only update the overlay.
    private var finishing = false
    private let chunkSink: AsyncStream<SpeechChunk>.Continuation
    private var worker: Task<Void, Never>?
    private var recognizer: AnyObject?
    private var recognizerStart: Task<Void, Never>?
    private var newestFinalWordEnd: TimeInterval?
    private var lags: [Double] = []

    init(
        provider: any TranscriptionProvider,
        languageCode: String?,
        vocabulary: Vocabulary,
        clipboard: ClipboardMirror? = nil,
        onLiveLine: @escaping (String) -> Void
    ) {
        self.provider = provider
        self.clipboard = clipboard ?? ClipboardMirror()
        self.languageCode = languageCode
        self.vocabulary = vocabulary
        self.onLiveLine = onLiveLine
        typer = LiveFieldTyper(abort: abort)
        let (chunks, sink) = AsyncStream<SpeechChunk>.makeStream()
        chunkSink = sink
        feeder.onChunk = { chunk in sink.yield(chunk) }
        FileLog.write("LIVE session target=\(typer?.targetName ?? "none")")
        worker = Task { [weak self] in
            for await chunk in chunks {
                guard let self, !cancelled else { return }
                let whisper = await transcribe(chunk)
                guard !cancelled, !finishing else { return }
                if let whisper {
                    text.replace(chunk.range, with: whisper)
                    refresh()
                }
            }
        }
        typer?.onTyped = { [weak self] in self?.recordLag() }
    }

    /// Starts the live recognizer for an already prepared locale; nil leaves
    /// only Whisper (text then appears chunk by chunk).
    func startRecognizer(locale: Locale?) {
        guard let locale, #available(macOS 26, *) else { return }
        recognizerStart = Task { [weak self] in
            do {
                let recognizer = try await LiveSpeechRecognizer.start(locale: locale) { isFinal, words, through in
                    DispatchQueue.main.async { self?.liveResult(isFinal: isFinal, words: words, through: through) }
                }
                guard let self, !cancelled else {
                    await recognizer.cancel()
                    return
                }
                self.recognizer = recognizer
                feeder.attach(recognizer)
            } catch {
                FileLog.write("LIVE recognizer not started: \(error.localizedDescription)")
            }
        }
    }

    /// Stops the live preview and returns the final transcript: one Whisper
    /// pass over the whole recording, exactly what the classic mode produces
    /// (chunks give Whisper too little context, and words at a cut can come
    /// out twice). The live text is the fallback when that pass yields
    /// nothing or misses `passDeadline` (2026-11-25: the model was still
    /// loading and the app stayed "transcribing" for good). Field and
    /// clipboard show the result by then; every wait here is bounded.
    func finish(samples: [Float], passDeadline: TimeInterval) async -> Outcome {
        _ = feeder.flush()
        finishing = true
        chunkSink.finish()
        worker?.cancel()
        let provider = provider
        let request = TranscriptionRequest(samples: samples, languageCode: languageCode, prompt: vocabulary.prompt)
        let vocabulary = vocabulary
        async let whole = withDeadline(seconds: passDeadline) {
            await Self.transcribeWhole(request, provider: provider, vocabulary: vocabulary)
        }
        // The live text is only the fallback: never wait long for the recognizer.
        _ = await withDeadline(seconds: 3) { @MainActor [self] in
            await recognizerStart?.value
            if #available(macOS 26, *), let recognizer = recognizer as? LiveSpeechRecognizer {
                await recognizer.finish()
                // Results hop to the main queue; let those already queued land.
                await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            }
        }
        let live = Self.joined(text.confirmedText, text.provisionalText)
        let final: String
        let finalPassFailed: Bool
        let passResult = await whole
        if passResult == nil { FileLog.write("LIVE final pass missed its \(Int(passDeadline)) s deadline") }
        if let whole = passResult ?? nil, !whole.isEmpty {
            final = whole
            finalPassFailed = false
        } else {
            FileLog.write("LIVE final pass gave no text: keeping the live text")
            final = live
            finalPassFailed = true
        }
        // What the user saw: the field's preview, else the overlay's.
        let preview = typer.map(\.sync.delivered).flatMap { $0.isEmpty ? nil : $0 } ?? live
        FileLog.write("LIVE final pass chars=\(final.count) (live preview chars=\(live.count), changed=\(final != preview))")
        onLiveLine("")
        if let typer {
            typer.update(to: final, isFinal: true)
            await typer.settle()
        }
        if !final.isEmpty { clipboard.writeFinal(final) }
        FileLog.write("LIVE finished chars=\(final.count) field=\(typer?.sync.lock.map { "locked(\($0))" } ?? (typer == nil ? "none" : "in sync")) \(lagSummary)")
        return Outcome(
            text: final,
            fieldLock: typer == nil ? .focusChanged : typer?.sync.lock,
            typedAnything: !(typer?.sync.delivered.isEmpty ?? true),
            finalPassFailed: finalPassFailed,
            changedPreview: final != preview
        )
    }

    /// Esc: drops everything, removes the typed text while the field is
    /// still ours and puts the previous clipboard back.
    func cancel() async {
        cancelled = true
        feeder.stop()
        chunkSink.finish()
        worker?.cancel()
        await recognizerStart?.value
        if #available(macOS 26, *), let recognizer = recognizer as? LiveSpeechRecognizer {
            await recognizer.cancel()
        }
        onLiveLine("")
        await typer?.removeTyped()
        clipboard.restore()
        FileLog.write("LIVE cancelled, field=\(typer?.sync.lock.map { "locked(\($0)), text kept" } ?? "cleared")")
    }

    /// The recording broke off (device error): keep what was typed and make
    /// the clipboard's last state a normal entry.
    func abandon() {
        cancelled = true
        feeder.stop()
        chunkSink.finish()
        worker?.cancel()
        onLiveLine("")
        if !lastConfirmed.isEmpty { clipboard.writeFinal(lastConfirmed) }
        if #available(macOS 26, *), let recognizer = recognizer as? LiveSpeechRecognizer {
            Task { await recognizer.cancel() }
        }
    }

    // MARK: - Results

    private func liveResult(isFinal: Bool, words: [LiveWord], through: TimeInterval) {
        guard !cancelled else { return }
        if isFinal {
            text.confirm(words, through: through)
            if let end = words.last?.end { newestFinalWordEnd = max(newestFinalWordEnd ?? end, end) }
        } else {
            text.setProvisional(words)
        }
        refresh()
    }

    private func refresh() {
        let confirmed = text.confirmedText
        if confirmed != lastConfirmed, !finishing {
            lastConfirmed = confirmed
            if !confirmed.isEmpty { clipboard.writeTransient(confirmed) }
            typer?.update(to: confirmed)
        }
        onLiveLine(Self.joined(confirmed, text.provisionalText))
    }

    private func transcribe(_ chunk: SpeechChunk) async -> String? {
        do {
            try await provider.prepare()
            let request = TranscriptionRequest(samples: chunk.samples, languageCode: languageCode, prompt: vocabulary.prompt)
            let result = vocabulary.apply(to: try await provider.transcribe(request))
            FileLog.write("LIVE whisper chunk \(String(format: "%.1f", chunk.start))+\(String(format: "%.1f", chunk.duration))s chars=\(result.count)")
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch TranscriptionError.emptyResult {
            return ""
        } catch TranscriptionError.recordingTooShort {
            return nil
        } catch {
            FileLog.write("LIVE whisper chunk at \(String(format: "%.1f", chunk.start))s failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Off the main actor, so a stalled model load never holds it.
    private nonisolated static func transcribeWhole(
        _ request: TranscriptionRequest, provider: any TranscriptionProvider, vocabulary: Vocabulary
    ) async -> String? {
        do {
            try await provider.prepare()
            let whole = vocabulary.apply(to: try await provider.transcribe(request))
            return whole.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        } catch {
            FileLog.write("LIVE final pass failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Latency

    /// Word end (audio clock) → typed into the field.
    private func recordLag() {
        guard let end = newestFinalWordEnd else { return }
        lags.append(Date().timeIntervalSince(startedAt) - end)
        newestFinalWordEnd = nil
    }

    private var lagSummary: String {
        let sorted = lags.sorted()
        guard !sorted.isEmpty else { return "lag n=0" }
        return String(
            format: "lag word→field n=%d p50 %.2f s p90 %.2f s max %.2f s",
            sorted.count, sorted[sorted.count / 2], sorted[min(sorted.count - 1, sorted.count * 9 / 10)], sorted.last!
        )
    }

    private static func joined(_ a: String, _ b: String) -> String {
        [a, b].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// Runs on its own serial queue: cuts the capture stream into Whisper chunks
/// and feeds the live recognizer. Audio that arrives before the recognizer
/// is ready is kept and fed once it is, so the first words are not lost.
final class LiveFeeder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "whisperstorm.live.feed", qos: .userInitiated)
    private var chunker = SpeechChunker()
    private var recognizer: AnyObject?
    private var backlog: [Float] = []
    private var backlogOffset: Int?
    private var stopped = false
    /// Set once before feeding starts; called on the feed queue.
    var onChunk: ((SpeechChunk) -> Void)?

    /// At most this much audio waits for the recognizer (60 s at 16 kHz).
    private static let maxBacklog = 960_000

    func feed(_ samples: [Float], at offset: Int) {
        queue.async { [self] in
            guard !stopped else { return }
            for chunk in chunker.append(samples) { onChunk?(chunk) }
            if #available(macOS 26, *), let recognizer = recognizer as? LiveSpeechRecognizer {
                recognizer.feed(samples, at: offset)
            } else if backlog.count < Self.maxBacklog {
                if backlogOffset == nil { backlogOffset = offset }
                backlog += samples
            }
        }
    }

    @available(macOS 26, *)
    func attach(_ recognizer: LiveSpeechRecognizer) {
        queue.async { [self] in
            guard !stopped else { return }
            if let backlogOffset, !backlog.isEmpty { recognizer.feed(backlog, at: backlogOffset) }
            backlog = []
            self.recognizer = recognizer
        }
    }

    /// The rest of the audio as a last chunk; nil when it holds no speech.
    func flush() -> SpeechChunk? {
        queue.sync {
            stopped = true
            return chunker.flush()
        }
    }

    func stop() {
        queue.sync { stopped = true }
    }
}

/// Hands the running live session's off-main entry points to the capture
/// queue and the key tap thread.
final class LiveSessionSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var feeder: LiveFeeder?
    private var abort: AbortFlag?
    private var reportInput: (@MainActor (String) -> Void)?

    @MainActor
    func set(_ session: LiveDictationSession) {
        lock.withLock {
            feeder = session.feeder
            abort = session.abort
            reportInput = { [weak session] event in session?.typer?.userInput(event) }
        }
    }

    func clear() {
        lock.withLock {
            feeder = nil
            abort = nil
            reportInput = nil
        }
    }

    func feed(_ samples: [Float], at offset: Int) {
        lock.withLock { feeder }?.feed(samples, at: offset)
    }

    /// The user typed or clicked: stop a running burst now; the typer then
    /// decides on the main actor whether the field must lock.
    func userInput(_ event: String) {
        let (abort, reportInput) = lock.withLock { (abort, reportInput) }
        abort?.set()
        if let reportInput {
            DispatchQueue.main.async { MainActor.assumeIsolated { reportInput(event) } }
        }
    }
}
