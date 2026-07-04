import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var coordinator: DictationCoordinator
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button(state.phase == .recording ? "Stop Dictation" : "Start Dictation") {
            coordinator.toggleDictation()
        }
        .disabled(state.phase == .transcribing)

        Button("Copy Last Transcript") {
            coordinator.copyLastTranscript()
        }
        .disabled(state.lastTranscript.isEmpty)

        Divider()

        Menu("Microphone") {
            MicrophonePicker(label: "Microphone")
                .environmentObject(coordinator.deviceManager)
                .pickerStyle(.inline)
                .labelsHidden()
        }

        Divider()

        Button("Settings…") {
            // Activate first, otherwise the Settings window of this
            // LSUIElement app opens behind the frontmost app.
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",", modifiers: .command)

        Button("Setup Assistant…") {
            coordinator.showOnboarding()
        }

        Divider()

        Button("Quit WhisperStorm") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}
