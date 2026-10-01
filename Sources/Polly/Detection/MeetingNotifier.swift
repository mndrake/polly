import Foundation
import PollyCore
import UserNotifications

/// Posts "Meeting detected — Start transcribing?" notifications.
final class MeetingNotifier: NSObject, UNUserNotificationCenterDelegate {
    private static let category = "MEETING_DETECTED"
    private static let startAction = "START_TRANSCRIBING"

    /// Called on the main thread when the user taps "Start Transcribing" (or the notification).
    var onStartRequested: ((_ bundleID: String) -> Void)?

    /// UNUserNotificationCenter crashes for processes without an app bundle
    /// (e.g. a bare `swift run` binary), so notifications are only used from Polly.app.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleURL.pathExtension == "app" ? UNUserNotificationCenter.current() : nil
    }

    func setUp() {
        guard let center else { return }
        center.delegate = self
        let start = UNNotificationAction(identifier: Self.startAction, title: "Start Transcribing", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [start], intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notify(_ meeting: DetectedMeeting) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(meeting.platform.displayName) meeting detected"
        content.body = meeting.suggestedTitle.map { "“\($0)” — start transcribing with Polly?" }
            ?? "Start transcribing with Polly? Make sure everyone has agreed to being transcribed."
        content.categoryIdentifier = Self.category
        content.userInfo = ["bundleID": meeting.bundleID]
        let request = UNNotificationRequest(identifier: "meeting-\(meeting.bundleID)", content: content, trigger: nil)
        center.add(request)
    }

    func clear() {
        center?.removeAllDeliveredNotifications()
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let bundleID = response.notification.request.content.userInfo["bundleID"] as? String
        let action = response.actionIdentifier
        DispatchQueue.main.async { [weak self] in
            if let bundleID, action == Self.startAction || action == UNNotificationDefaultActionIdentifier {
                self?.onStartRequested?(bundleID)
            }
        }
        completionHandler()
    }
}
