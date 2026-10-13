import Foundation
import SwiftUI

enum TranscriptionLanguage: String, CaseIterable, Identifiable {
    case auto
    case german
    case english

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: "Auto-detect"
        case .german: "German"
        case .english: "English"
        }
    }

    /// ISO 639-1 code passed to providers; nil means auto-detect.
    var languageCode: String? {
        switch self {
        case .auto: nil
        case .german: "de"
        case .english: "en"
        }
    }
}

enum TranscriptionProviderKind: String, CaseIterable, Identifiable {
    case whisperKit
    case openAICompatible

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .whisperKit: "WhisperKit (local, CoreML)"
        case .openAICompatible: "OpenAI-compatible server"
        }
    }
}

/// UserDefaults-backed app settings shared across the whole app.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Keys {
        static let pushToTalkTapToggles = "pushToTalkTapToggles"
        static let language = "transcriptionLanguage"
        static let providerKind = "transcriptionProviderKind"
        static let whisperKitModel = "whisperKitModel"
        static let endpointBaseURL = "openAIEndpointBaseURL"
        static let endpointModelName = "openAIEndpointModelName"
        static let selectedMicrophoneUID = "selectedMicrophoneUID"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
    }

    nonisolated static let defaultWhisperKitModel = "openai_whisper-small"
    nonisolated static let recommendedWhisperKitModel = "openai_whisper-large-v3-v20240930_turbo"

    private let defaults: UserDefaults

    /// A short tap on the push-to-talk shortcut latches recording on; the
    /// next tap stops it. Holding still works as push-to-talk.
    @Published var pushToTalkTapToggles: Bool {
        didSet { defaults.set(pushToTalkTapToggles, forKey: Keys.pushToTalkTapToggles) }
    }

    @Published var language: TranscriptionLanguage {
        didSet { defaults.set(language.rawValue, forKey: Keys.language) }
    }

    @Published var providerKind: TranscriptionProviderKind {
        didSet { defaults.set(providerKind.rawValue, forKey: Keys.providerKind) }
    }

    /// WhisperKit model variant name as it appears in the HuggingFace repo.
    @Published var whisperKitModel: String {
        didSet { defaults.set(whisperKitModel, forKey: Keys.whisperKitModel) }
    }

    /// Base URL of the OpenAI-compatible server, e.g. "http://localhost:8000".
    @Published var endpointBaseURL: String {
        didSet { defaults.set(endpointBaseURL, forKey: Keys.endpointBaseURL) }
    }

    @Published var endpointModelName: String {
        didSet { defaults.set(endpointModelName, forKey: Keys.endpointModelName) }
    }

    /// CoreAudio device UID of the preferred input; nil follows the system default.
    @Published var selectedMicrophoneUID: String? {
        didSet { defaults.set(selectedMicrophoneUID, forKey: Keys.selectedMicrophoneUID) }
    }

    @Published var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.hasCompletedOnboarding) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pushToTalkTapToggles = defaults.bool(forKey: Keys.pushToTalkTapToggles)
        language = defaults.string(forKey: Keys.language)
            .flatMap(TranscriptionLanguage.init(rawValue:)) ?? .auto
        providerKind = defaults.string(forKey: Keys.providerKind)
            .flatMap(TranscriptionProviderKind.init(rawValue:)) ?? .whisperKit
        whisperKitModel = defaults.string(forKey: Keys.whisperKitModel) ?? Self.defaultWhisperKitModel
        endpointBaseURL = defaults.string(forKey: Keys.endpointBaseURL) ?? "http://localhost:8000"
        endpointModelName = defaults.string(forKey: Keys.endpointModelName) ?? "Systran/faster-whisper-small"
        selectedMicrophoneUID = defaults.string(forKey: Keys.selectedMicrophoneUID)
        hasCompletedOnboarding = defaults.bool(forKey: Keys.hasCompletedOnboarding)
    }
}
