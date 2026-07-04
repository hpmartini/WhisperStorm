import SwiftUI

/// Configuration for the OpenAI-compatible HTTP provider.
struct OpenAIEndpointSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Server base URL:", text: $settings.endpointBaseURL, prompt: Text("http://localhost:8000"))
                .textFieldStyle(.roundedBorder)

            TextField("Model name:", text: $settings.endpointModelName, prompt: Text("Systran/faster-whisper-small"))
                .textFieldStyle(.roundedBorder)

            Text("Requests go to <base URL>/v1/audio/transcriptions (multipart/form-data). Works with any OpenAI-compatible local server, e.g. a speaches (faster-whisper) Docker container. Docker Model Runner currently serves LLMs only — once it exposes audio endpoints, point the base URL at it and this provider works unchanged.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
