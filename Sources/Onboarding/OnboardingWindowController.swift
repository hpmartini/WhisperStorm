import AppKit
import SwiftUI

/// Presents the onboarding window (the app has no regular windows otherwise).
@MainActor
final class OnboardingWindowController {
    private var window: NSWindow?
    private let permissions = PermissionsManager()

    func show() {
        if window == nil {
            let view = OnboardingView(permissions: permissions) { [weak self] in
                AppSettings.shared.hasCompletedOnboarding = true
                self?.window?.close()
            }
            let hostingController = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hostingController)
            window.title = "WhisperStorm Setup"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        permissions.refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
