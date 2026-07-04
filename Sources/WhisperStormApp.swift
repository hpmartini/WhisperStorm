import SwiftUI

@main
struct WhisperStormApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var coordinator = DictationCoordinator.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(coordinator)
                .environmentObject(coordinator.state)
                .environmentObject(coordinator.settings)
        } label: {
            MenuBarIconView(state: coordinator.state)
        }

        Settings {
            SettingsView()
                .environmentObject(coordinator)
                .environmentObject(coordinator.settings)
        }
    }
}

private struct MenuBarIconView: View {
    @ObservedObject var state: AppState

    var body: some View {
        Image(systemName: state.menuBarSymbolName)
            .symbolRenderingMode(.hierarchical)
            .symbolEffect(
                .variableColor.iterative.dimInactiveLayers.nonReversing,
                options: .repeating,
                isActive: state.phase == .recording
            )
    }
}
