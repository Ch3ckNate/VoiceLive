import Foundation
import UserNotifications
import AppKit

final class NotificationManager {
    static let shared = NotificationManager()

    private init() {}

    /// Request authorization to display notifications. Returns true if
    /// granted, false if denied or an error occurred.
    func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    /// Check current authorization status without prompting.
    func isAuthorized() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
    }

    /// Show a notification. Fire-and-forget — any error (e.g. permission
    /// denied after launch) is silently ignored.
    func show(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    /// Open System Settings → Privacy & Security → Accessibility so the
    /// user can grant permission directly from the notification flow.
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
