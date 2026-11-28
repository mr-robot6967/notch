import AppKit
import UserNotifications

/// One macOS notification per new version found by the Updater's own checks (no extra polling).
/// Clicking it opens Settings › General, where the notes and Update Now are; it never installs.
final class UpdateNotifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = UpdateNotifier()
    static let notifiedKey = "notifiedUpdateVersion"
    private static let category = "notch.update"

    /// UNUserNotificationCenter needs a real app bundle (a bare `swift run` binary would crash).
    private var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return UNUserNotificationCenter.current()
    }

    func install() {
        center?.delegate = self
    }

    func notifyIfNeeded(version: String) {
        guard let center else { return }
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: Self.notifiedKey) != version else { return }
        defaults.set(version, forKey: Self.notifiedKey)
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return } // denied: stay quiet; Settings and the menu still show it
            let content = UNMutableNotificationContent()
            content.title = "Notch \(version) is available"
            content.body = "See what's new and update in one click."
            content.sound = .default
            content.categoryIdentifier = Self.category
            let request = UNNotificationRequest(identifier: "notch.update.\(version)", content: content, trigger: nil)
            center.add(request) { _ in }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let isUpdate = response.notification.request.content.categoryIdentifier == Self.category
        if isUpdate, response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { AppActions.shared.openSettingsPage("general") }
            }
        }
        completionHandler()
    }
}
