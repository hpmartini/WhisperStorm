import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        ControlSocketServer.shared.start()
        NotificationManager.shared.requestAuthorizationIfNeeded()
        if !AppSettings.shared.hasCompletedOnboarding {
            DictationCoordinator.shared.showOnboarding()
        } else if !TextInserter.isAccessibilityTrusted {
            // Rebuilds change the ad-hoc signature and silently invalidate the
            // Accessibility grant — surface that instead of failing quietly.
            Log.insertion.error("Launch check: Accessibility not trusted — text insertion disabled")
            NotificationManager.shared.post(
                title: "Text insertion disabled",
                body: "WhisperStorm has no Accessibility permission (a rebuild resets it). Re-enable it via the Setup Assistant in the menu bar — until then transcripts go to the clipboard only."
            )
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ControlSocketServer.shared.stop()
    }
}
