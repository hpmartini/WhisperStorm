import AppKit
import AVFoundation
import Foundation

/// Tracks microphone and Accessibility permission status for onboarding.
@MainActor
final class PermissionsManager: ObservableObject {
    enum Status {
        case granted
        case notDetermined
        case denied
    }

    @Published private(set) var microphoneStatus: Status = .notDetermined
    @Published private(set) var accessibilityGranted = false

    private var pollTimer: Timer?

    init() {
        refresh()
    }

    func refresh() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphoneStatus = .granted
        case .notDetermined:
            microphoneStatus = .notDetermined
        default:
            microphoneStatus = .denied
        }
        accessibilityGranted = TextInserter.isAccessibilityTrusted
    }

    var allGranted: Bool {
        microphoneStatus == .granted && accessibilityGranted
    }

    func requestMicrophoneAccess() {
        Task { @MainActor in
            _ = await AudioCaptureEngine.requestMicrophoneAccess()
            refresh()
        }
    }

    func promptForAccessibility() {
        TextInserter.promptForAccessibility()
    }

    func openMicrophoneSystemSettings() {
        openSystemSettings(pane: "Privacy_Microphone")
    }

    func openAccessibilitySystemSettings() {
        openSystemSettings(pane: "Privacy_Accessibility")
    }

    private func openSystemSettings(pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Permissions are granted outside the app, so poll while onboarding is visible.
    func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
