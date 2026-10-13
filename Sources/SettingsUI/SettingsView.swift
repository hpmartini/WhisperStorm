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
    /// Last accepted binding per shortcut, restored when a new one clashes.
    @State private var lastValidShortcut: [KeyboardShortcuts.Name: KeyboardShortcuts.Shortcut] = [:]
    @State private var shortcutConflict: String?

    var body: some View {
        Form {
            shortcutRecorder("Toggle shortcut:", .toggleDictation, other: .pushToTalk, otherTitle: "push-to-talk")
            Text("Press once to start recording, press again to stop and transcribe.")
                .font(.callout)
                .foregroundStyle(.secondary)

            shortcutRecorder("Push-to-talk shortcut:", .pushToTalk, other: .toggleDictation, otherTitle: "toggle")
            if let shortcutConflict {
                Text(shortcutConflict)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Toggle("Tap push-to-talk shortcut to toggle", isOn: $settings.pushToTalkTapToggles)
            Text(settings.pushToTalkTapToggles
                 ? "Hold to record, release to transcribe. A short tap starts recording; tap again to stop."
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

    /// KeyboardShortcuts only rejects system and menu shortcuts, not a clash
    /// between our own two — one key would then fire both handlers.
    private func shortcutRecorder(
        _ title: String,
        _ name: KeyboardShortcuts.Name,
        other: KeyboardShortcuts.Name,
        otherTitle: String
    ) -> some View {
        KeyboardShortcuts.Recorder(title, name: name) { newShortcut in
            if let newShortcut, newShortcut == KeyboardShortcuts.getShortcut(for: other) {
                KeyboardShortcuts.setShortcut(lastValidShortcut[name], for: name)
                shortcutConflict = "\(newShortcut) is already the \(otherTitle) shortcut."
            } else {
                lastValidShortcut[name] = newShortcut
                shortcutConflict = nil
            }
        }
        .onAppear { lastValidShortcut[name] = KeyboardShortcuts.getShortcut(for: name) }
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
