import SwiftUI
import KeyboardShortcuts

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }

            MicrophoneSettingsView()
                .tabItem { Label("Microphone", systemImage: "mic") }

            ModelSettingsView()
                .tabItem { Label("Model", systemImage: "cpu") }
        }
        .frame(width: 520)
    }
}

struct GeneralSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var launchAtLogin = LaunchAtLoginModel()

    var body: some View {
        Form {
            KeyboardShortcuts.Recorder("Dictation shortcut:", name: .dictation)

            Picker("Dictation mode:", selection: $settings.dictationMode) {
                ForEach(DictationMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)

            Text(settings.dictationMode == .toggle
                 ? "Press once to start recording, press again to stop and transcribe."
                 : "Hold the shortcut to record, release to transcribe.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Picker("Language:", selection: $settings.language) {
                ForEach(TranscriptionLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }

            Toggle("Launch at login", isOn: Binding(
                get: { launchAtLogin.isEnabled },
                set: { launchAtLogin.setEnabled($0) }
            ))

            if let error = launchAtLogin.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(20)
    }
}

struct MicrophoneSettingsView: View {
    @EnvironmentObject private var coordinator: DictationCoordinator

    var body: some View {
        Form {
            MicrophonePicker(label: "Input device:")
                .environmentObject(coordinator.deviceManager)

            Text("If the selected device is disconnected, WhisperStorm falls back to the system default input and notifies you.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }
}

struct ModelSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var coordinator: DictationCoordinator

    var body: some View {
        Form {
            Picker("Provider:", selection: $settings.providerKind) {
                ForEach(TranscriptionProviderKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.radioGroup)

            Divider()
                .padding(.vertical, 4)

            switch settings.providerKind {
            case .whisperKit:
                WhisperKitModelListView()
                    .environmentObject(coordinator.modelManager)
            case .openAICompatible:
                OpenAIEndpointSettingsView()
            }
        }
        .padding(20)
    }
}
