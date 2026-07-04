import Foundation

/// Transcribes via any OpenAI-compatible HTTP server:
/// POST <baseURL>/v1/audio/transcriptions (multipart/form-data).
///
/// This works with local Docker servers such as a speaches (faster-whisper)
/// container. Note: Docker Model Runner currently serves LLMs and does not
/// expose STT endpoints — use the mentioned whisper container for
/// Docker-based transcription. As soon as Docker Model Runner offers audio
/// endpoints, this same provider class works unchanged against its URL.
struct OpenAICompatibleProvider: TranscriptionProvider {
    let baseURL: String
    let model: String

    var displayName: String { "OpenAI-compatible server" }

    func transcribe(_ request: TranscriptionRequest) async throws -> String {
        guard request.duration >= 0.35 else {
            throw TranscriptionError.recordingTooShort
        }
        let endpoint = try endpointURL()
        let wavData = WAVEncoder.encode(samples: request.samples)

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 180

        let boundary = "WhisperStorm-\(UUID().uuidString)"
        urlRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = multipartBody(
            boundary: boundary,
            wavData: wavData,
            languageCode: request.languageCode
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: urlRequest)
        } catch {
            throw TranscriptionError.serverUnreachable(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidServerResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data.prefix(500), encoding: .utf8) ?? ""
            throw TranscriptionError.serverError(http.statusCode, message)
        }

        struct TranscriptionResponse: Decodable {
            let text: String
        }
        guard let decoded = try? JSONDecoder().decode(TranscriptionResponse.self, from: data) else {
            throw TranscriptionError.invalidServerResponse
        }
        let text = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw TranscriptionError.emptyResult
        }
        return text
    }

    private func endpointURL() throws -> URL {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") {
            base.removeLast()
        }
        // Accept both "http://host:port" and "http://host:port/v1" as base.
        if base.lowercased().hasSuffix("/v1") {
            base.removeLast(3)
            while base.hasSuffix("/") {
                base.removeLast()
            }
        }
        guard !base.isEmpty, let url = URL(string: base + "/v1/audio/transcriptions"),
              let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased())
        else {
            throw TranscriptionError.invalidEndpointURL(baseURL)
        }
        return url
    }

    private func multipartBody(boundary: String, wavData: Data, languageCode: String?) -> Data {
        var body = Data()

        func appendField(name: String, value: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }

        appendField(name: "model", value: model)
        appendField(name: "response_format", value: "json")
        if let languageCode {
            appendField(name: "language", value: languageCode)
        }

        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".utf8))
        body.append(Data("Content-Type: audio/wav\r\n\r\n".utf8))
        body.append(wavData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }
}
