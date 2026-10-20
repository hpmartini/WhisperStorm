import Foundation
import WhisperKit

/// Local CoreML transcription via WhisperKit. Keeps the loaded pipeline
/// cached across dictations and reloads only when the model variant changes.
actor WhisperKitProvider: TranscriptionProvider {
    nonisolated var displayName: String { "WhisperKit" }

    private var pipeline: WhisperKit?
    private var loadedVariant: String?
    private var desiredVariant = AppSettings.defaultWhisperKitModel

    func setVariant(_ variant: String) {
        desiredVariant = variant
    }

    /// Whether the pipeline for the desired variant is already in memory.
    var isReady: Bool {
        pipeline != nil && loadedVariant == desiredVariant
    }

    /// Loads the pipeline. The first load of a model triggers CoreML/ANE
    /// specialization, which can take several minutes for large models.
    func prepare() async throws {
        _ = try await loadPipelineIfNeeded()
    }

    /// Preloads the pipeline (CoreML specialization + tokenizer fetch) so the
    /// first dictation is fast. Errors are ignored; they resurface on use.
    func warmUp() async {
        _ = try? await loadPipelineIfNeeded()
    }

    func transcribe(_ request: TranscriptionRequest) async throws -> String {
        guard request.duration >= 0.35 else {
            throw TranscriptionError.recordingTooShort
        }
        let pipe = try await loadPipelineIfNeeded()

        Self.dumpRecording(request.samples)
        FileLog.write("  WHISPER in: \(Self.levelDescription(request.samples)) lang=\(request.languageCode ?? "auto")")

        let text = try await run(pipe, request: request, chunking: .vad, label: "vad")
        if !text.isEmpty {
            return text
        }

        // VAD chunking drops audio it does not consider speech — which happens
        // with quiet input (a distant built-in mic). Retry once on the raw
        // buffer before giving up, so a usable recording is not thrown away.
        let unchunked = try await run(pipe, request: request, chunking: nil, label: "no-vad")
        guard !unchunked.isEmpty else {
            throw TranscriptionError.emptyResult
        }
        return unchunked
    }

    private func run(
        _ pipe: WhisperKit,
        request: TranscriptionRequest,
        chunking: ChunkingStrategy?,
        label: String
    ) async throws -> String {
        let options = DecodingOptions(
            task: .transcribe,
            language: request.languageCode,
            detectLanguage: request.languageCode == nil,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            chunkingStrategy: chunking
        )

        let results: [TranscriptionResult]
        do {
            results = try await pipe.transcribe(audioArray: request.samples, decodeOptions: options)
        } catch {
            FileLog.write("  WHISPER \(label) threw: \(error.localizedDescription)")
            throw TranscriptionError.modelLoadFailed(error.localizedDescription)
        }

        // Noise makes auto-detection pick languages nobody dictates in (Japanese "thanks for watching"),
        // so with auto language only German and English results count.
        let accepted = results.filter { request.languageCode != nil || ["de", "en"].contains($0.language) }
        if accepted.count != results.count {
            FileLog.write("  WHISPER \(label): dropped \(results.count - accepted.count) segment(s) of language \(results.map(\.language))")
        }
        let text = accepted
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        FileLog.write("  WHISPER \(label): segments=\(results.count) chars=\(text.count)")
        return Self.isNoiseHallucination(text) ? "" : text
    }

    /// Whisper's stock output for noise: sound annotations ("*clap*", "[Music]"), bare punctuation,
    /// and its subtitle-credit phrases. Dictating exactly these is rarer than hearing them in an air conditioner.
    nonisolated private static func isNoiseHallucination(_ text: String) -> Bool {
        let stripped = text.replacingOccurrences(of: #"[\*\[\(][^\]\)\*]*[\*\]\)]"#, with: "", options: .regularExpression)
        let letters = stripped.filter { $0.isLetter || $0.isNumber }
        if letters.isEmpty { return true }
        let phrase = letters.lowercased()
        return ["you", "thankyouforwatching", "vielendankfürszuschauen", "untertitelderamaraorg"].contains(phrase)
    }

    /// Peak and RMS of the buffer actually handed to the model, in dBFS.
    nonisolated private static func levelDescription(_ samples: [Float]) -> String {
        guard !samples.isEmpty else { return "empty" }
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        let rms = (samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
        func dB(_ value: Float) -> String {
            value <= 0 ? "-inf" : String(format: "%.1f", 20 * log10(value))
        }
        return "\(samples.count) samples peak=\(dB(peak))dBFS rms=\(dB(rms))dBFS"
    }

    /// Writes the exact 16 kHz buffer sent to the model next to the log, so a
    /// failed transcription can be listened to instead of guessed about.
    nonisolated private static func dumpRecording(_ samples: [Float]) {
        let url = FileLog.url.deletingLastPathComponent()
            .appending(path: "WhisperStorm-last-recording.wav")
        try? WAVEncoder.encode(samples: samples).write(to: url)
    }

    private func loadPipelineIfNeeded() async throws -> WhisperKit {
        let variant = desiredVariant
        if let pipeline, loadedVariant == variant {
            return pipeline
        }
        guard WhisperModelManager.isDownloaded(variant) else {
            throw TranscriptionError.modelNotDownloaded(variant)
        }

        pipeline = nil
        loadedVariant = nil
        let loadStart = Date()
        Log.transcription.notice("Loading WhisperKit model \(variant)")

        let config = WhisperKitConfig(
            model: variant,
            downloadBase: WhisperModelManager.downloadBase,
            modelFolder: WhisperModelManager.modelFolderURL(for: variant).path,
            tokenizerFolder: WhisperModelManager.tokenizerFolder,
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: true,
            download: false
        )
        do {
            let pipe = try await WhisperKit(config)
            pipeline = pipe
            loadedVariant = variant
            Log.transcription.notice("WhisperKit model \(variant) loaded in \(Int(Date().timeIntervalSince(loadStart)))s")
            return pipe
        } catch {
            throw TranscriptionError.modelLoadFailed(error.localizedDescription)
        }
    }
}
