import SwiftUI

/// First-run window: shows microphone and Accessibility permission status as
/// traffic lights and deep-links into the System Settings panes.
struct OnboardingView: View {
    @ObservedObject var permissions: PermissionsManager
    let onFinish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            gradient: CyberpunkPalette.waveGradient,
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to WhisperStorm")
                        .font(.title2.bold())
                    Text("System-wide dictation, transcribed entirely on this Mac.")
                        .foregroundStyle(.secondary)
                }
            }

            Text("Two permissions are needed for the full experience:")
                .font(.headline)

            PermissionRow(
                title: "Microphone",
                explanation: "Required to record your voice. Audio never leaves this Mac.",
                status: microphoneTrafficLight,
                statusText: microphoneStatusText,
                actionTitle: permissions.microphoneStatus == .notDetermined ? "Request Access" : "Open System Settings"
            ) {
                if permissions.microphoneStatus == .notDetermined {
                    permissions.requestMicrophoneAccess()
                } else {
                    permissions.openMicrophoneSystemSettings()
                }
            }

            PermissionRow(
                title: "Accessibility",
                explanation: "Required to insert the transcript into the active text field (synthesized Cmd+V). Without it, transcripts are only copied to the clipboard.",
                status: permissions.accessibilityGranted ? .green : .red,
                statusText: permissions.accessibilityGranted ? "Granted" : "Not granted",
                actionTitle: "Open System Settings"
            ) {
                permissions.promptForAccessibility()
                permissions.openAccessibilitySystemSettings()
            }

            Divider()

            HStack {
                Text(permissions.allGranted
                     ? "All set! Press ⌥ Space in any app to start dictating."
                     : "You can finish setup later — reopen via the menu bar icon.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(permissions.allGranted ? "Start Dictating" : "Done") {
                    onFinish()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear {
            permissions.refresh()
            permissions.startPolling()
        }
        .onDisappear {
            permissions.stopPolling()
        }
    }

    private var microphoneTrafficLight: Color {
        switch permissions.microphoneStatus {
        case .granted: .green
        case .notDetermined: .yellow
        case .denied: .red
        }
    }

    private var microphoneStatusText: String {
        switch permissions.microphoneStatus {
        case .granted: "Granted"
        case .notDetermined: "Not requested yet"
        case .denied: "Denied"
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let explanation: String
    let status: Color
    let statusText: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(status)
                .frame(width: 12, height: 12)
                .shadow(color: status.opacity(0.6), radius: 4)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.headline)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Button(actionTitle, action: action)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }
}
