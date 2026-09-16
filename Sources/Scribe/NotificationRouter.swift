import Foundation
import UserNotifications

/// Notifications, including the "meeting detected" prompt with its Record button.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {

    var onRecord: (@MainActor () -> Void)?
    var onDismiss: (@MainActor () -> Void)?

    private static let meetingCategory = "MEETING_DETECTED"
    private static let recordAction = "RECORD"
    private static let dismissAction = "DISMISS"
    private static let meetingIdentifier = "meeting-detected"

    private var available: Bool { Bundle.main.bundleIdentifier != nil }

    func install() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let record = UNNotificationAction(identifier: Self.recordAction, title: "Record", options: [])
        let dismiss = UNNotificationAction(identifier: Self.dismissAction, title: "Not now", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.meetingCategory,
                                   actions: [record, dismiss],
                                   intentIdentifiers: [],
                                   options: [.customDismissAction]),
        ])
    }

    func postMeetingDetected(name: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = "Meeting in \(name)"
        content.body = "Click to record and take notes."
        content.categoryIdentifier = Self.meetingCategory
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: Self.meetingIdentifier, content: content, trigger: nil))
    }

    func removeMeetingDetected() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.meetingIdentifier])
        center.removePendingNotificationRequests(withIdentifiers: [Self.meetingIdentifier])
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Show the banner even though Scribe counts as the active app.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        defer { completionHandler() }
        guard response.notification.request.content.categoryIdentifier == Self.meetingCategory else { return }
        let action = response.actionIdentifier
        Task { @MainActor in
            switch action {
            case Self.recordAction, UNNotificationDefaultActionIdentifier:
                self.onRecord?()
            case Self.dismissAction, UNNotificationDismissActionIdentifier:
                self.onDismiss?()
            default:
                break
            }
        }
    }
}
