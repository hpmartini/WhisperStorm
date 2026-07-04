import Foundation

/// Input for a transcription run: 16 kHz mono Float32 PCM plus language hint.
struct TranscriptionRequest {
    let samples: [Float]
    /// ISO 639-1 code ("de", "en") or nil for auto-detect.
    let languageCode: String?

    var duration: TimeInterval {
        Double(samples.count) / AudioCaptureEngine.targetSampleRate
    }
}

enum TranscriptionError: LocalizedError {
    case modelNotDownloaded(String)
    case modelLoadFailed(String)
    case recordingTooShort
    case emptyResult
    case invalidEndpointURL(String)
    case serverUnreachable(String)
    case serverError(Int, String)
    case invalidServerResponse

    var errorDescription: String? {
        switch self {
        case .modelNotDownloaded(let variant):
            "Model \"\(variant)\" is not downloaded. Open Settings > Model to download it."
        case .modelLoadFailed(let reason):
            "Failed to load the transcription model: \(reason)"
        case .recordingTooShort:
            "Recording was too short to transcribe."
        case .emptyResult:
            "No speech was recognized."
        case .invalidEndpointURL(let url):
            "Invalid server URL: \(url). Check Settings > Model."
        case .serverUnreachable(let reason):
            "Transcription server unreachable: \(reason)"
        case .serverError(let code, let message):
            "Transcription server error (HTTP \(code)): \(message)"
        case .invalidServerResponse:
            "The transcription server returned an unexpected response."
        }
    }
}

/// Pluggable speech-to-text backend: 16 kHz PCM in, text out.
protocol TranscriptionProvider {
    var displayName: String { get }
    /// Performs any expensive one-time setup (e.g. model loading) so callers
    /// can surface progress to the user before `transcribe` runs.
    func prepare() async throws
    func transcribe(_ request: TranscriptionRequest) async throws -> String
}

extension TranscriptionProvider {
    func prepare() async throws {}
}
