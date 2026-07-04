import Foundation
import WhisperKit

enum ModelDownloadState: Equatable {
    case notDownloaded
    case downloading(Double)
    case downloaded
    case failed(String)
}

/// Manages the curated WhisperKit CoreML models: download with progress,
/// presence checks and removal. Models live under
/// `~/Library/Application Support/WhisperStorm/models`.
@MainActor
final class WhisperModelManager: ObservableObject {
    struct ModelInfo: Identifiable {
        let variant: String
        let displayName: String
        let sizeHint: String
        let detail: String
        var id: String { variant }
    }

    static let curated: [ModelInfo] = [
        ModelInfo(
            variant: "openai_whisper-tiny",
            displayName: "Tiny",
            sizeHint: "~150 MB",
            detail: "Fastest, lowest accuracy"
        ),
        ModelInfo(
            variant: "openai_whisper-base",
            displayName: "Base",
            sizeHint: "~300 MB",
            detail: "Fast, basic accuracy"
        ),
        ModelInfo(
            variant: "openai_whisper-small",
            displayName: "Small",
            sizeHint: "~600 MB",
            detail: "Default — good speed/accuracy balance"
        ),
        ModelInfo(
            variant: "openai_whisper-large-v3-v20240930_turbo",
            displayName: "Large v3 Turbo",
            sizeHint: "~1.6 GB",
            detail: "Recommended — best accuracy, still fast"
        ),
    ]

    // MARK: - Paths
    // WhisperKit's hub layout appends "models/<repo>" to the download base,
    // so the base is the WhisperStorm folder and models end up in
    // WhisperStorm/models/argmaxinc/whisperkit-coreml/<variant>.

    nonisolated static var downloadBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "WhisperStorm")
    }

    nonisolated static var modelsRoot: URL {
        downloadBase.appending(path: "models/argmaxinc/whisperkit-coreml")
    }

    nonisolated static var tokenizerFolder: URL {
        downloadBase.appending(path: "tokenizers")
    }

    nonisolated static func modelFolderURL(for variant: String) -> URL {
        modelsRoot.appending(path: variant)
    }

    nonisolated static func isDownloaded(_ variant: String) -> Bool {
        let folder = modelFolderURL(for: variant)
        let requiredItems = ["config.json", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"]
        return requiredItems.allSatisfy {
            FileManager.default.fileExists(atPath: folder.appending(path: $0).path)
        }
    }

    // MARK: - State

    @Published private(set) var states: [String: ModelDownloadState] = [:]

    /// Variant currently being warmed up (CoreML specialization on first load).
    @Published var preparingVariant: String?

    /// Called on the main actor after a variant finished downloading.
    var onModelDownloaded: ((String) -> Void)?

    private var downloadTasks: [String: Task<Void, Never>] = [:]

    init() {
        refresh()
    }

    func state(for variant: String) -> ModelDownloadState {
        states[variant] ?? .notDownloaded
    }

    func refresh() {
        for model in Self.curated {
            if case .downloading = states[model.variant] { continue }
            states[model.variant] = Self.isDownloaded(model.variant) ? .downloaded : .notDownloaded
        }
    }

    // MARK: - Download

    func download(_ variant: String) {
        guard downloadTasks[variant] == nil else { return }
        states[variant] = .downloading(0)
        Log.transcription.info("Starting download of \(variant)")

        // The manager lives for the whole app lifetime, so strong self is fine.
        // Task inherits the main actor; only the download itself hops off.
        downloadTasks[variant] = Task {
            do {
                _ = try await WhisperKit.download(
                    variant: variant,
                    downloadBase: Self.downloadBase,
                    useBackgroundSession: false
                ) { progress in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor in
                        guard case .downloading = self.state(for: variant) else { return }
                        self.states[variant] = .downloading(fraction)
                    }
                }
                if Self.isDownloaded(variant) {
                    states[variant] = .downloaded
                    onModelDownloaded?(variant)
                } else {
                    states[variant] = .failed("Download finished but model files are incomplete.")
                }
                Log.transcription.info("Download of \(variant) finished")
            } catch is CancellationError {
                states[variant] = .notDownloaded
                Log.transcription.notice("Download of \(variant) cancelled")
            } catch {
                states[variant] = .failed(error.localizedDescription)
                Log.transcription.error("Download of \(variant) failed: \(error.localizedDescription)")
            }
            downloadTasks[variant] = nil
        }
    }

    func cancelDownload(_ variant: String) {
        downloadTasks[variant]?.cancel()
    }

    func remove(_ variant: String) {
        try? FileManager.default.removeItem(at: Self.modelFolderURL(for: variant))
        refresh()
    }
}
