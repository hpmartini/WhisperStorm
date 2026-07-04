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

        let options = DecodingOptions(
            task: .transcribe,
            language: request.languageCode,
            detectLanguage: request.languageCode == nil,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            chunkingStrategy: .vad
        )

        let results: [TranscriptionResult]
        do {
            results = try await pipe.transcribe(audioArray: request.samples, decodeOptions: options)
        } catch {
            throw TranscriptionError.modelLoadFailed(error.localizedDescription)
        }

        let text = results
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw TranscriptionError.emptyResult
        }
        return text
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
