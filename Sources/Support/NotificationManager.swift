import Foundation
import UserNotifications

/// Posts user notifications for events that must never fail silently
/// (transcription errors, microphone fallback, clipboard-only results).
@MainActor
final class NotificationManager {
    static let shared = NotificationManager()

    private var didRequestAuthorization = false

    private init() {}

    func requestAuthorizationIfNeeded() {
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                Log.app.error("Notification authorization failed: \(error.localizedDescription)")
            } else if !granted {
                Log.app.notice("Notification authorization not granted")
            }
        }
    }

    func post(title: String, body: String) {
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Log.app.error("Failed to post notification: \(error.localizedDescription)")
            }
        }
    }
}
