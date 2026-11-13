import Foundation
import UserNotifications

/// Non-secret user preferences (UserDefaults keys used with @AppStorage too).
enum Prefs {
    static let refreshMinutes = "refreshMinutes"          // Int, default 2
    static let loadRemoteImages = "loadRemoteImages"      // Bool, default true
    static let notifyNewMail = "notifyNewMail"            // Bool, default true
    static let notifyOpens = "notifyOpens"                // Bool, default true
    static let trackByDefault = "trackByDefault"          // Bool, default true
    static let trackingBaseURL = "trackingBaseURL"        // String
    static let showTodayPanel = "showTodayPanel"          // Bool
    static let groupThreads = "groupThreads"              // Bool, default true
    static let sidebarMode = "sidebarMode"                // "all" | "simple"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            refreshMinutes: 2,
            loadRemoteImages: true,
            notifyNewMail: true,
            notifyOpens: true,
            trackByDefault: true,
            showTodayPanel: false,
            groupThreads: true,
            sidebarMode: "all",
        ])
    }

    static var refreshInterval: TimeInterval {
        TimeInterval(max(1, UserDefaults.standard.integer(forKey: refreshMinutes)) * 60)
    }
}

extension Notification.Name {
    /// Posted by the app delegate when the user clicks a notification or one of its actions.
    static let emberNotificationResponse = Notification.Name("EmberNotificationResponse")
}

enum Notifier {
    static var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    static let reminderCategory = "REPLY_REMINDER"
    static let messageCategory = "MESSAGE"
    static let replyAction = "REPLY"
    static let snoozeAction = "SNOOZE_1H"

    static func requestPermission() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        let reply = UNNotificationAction(identifier: replyAction, title: "Reply", options: [.foreground])
        let snooze = UNNotificationAction(identifier: snoozeAction, title: "Remind me in 1 hour", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: reminderCategory, actions: [reply, snooze], intentIdentifiers: []),
            UNNotificationCategory(identifier: messageCategory, actions: [reply], intentIdentifiers: []),
        ])
    }

    static func post(title: String, body: String, id: String = UUID().uuidString,
                     category: String? = nil, userInfo: [String: String] = [:], at date: Date? = nil) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = userInfo
        if let category { content.categoryIdentifier = category }
        var trigger: UNNotificationTrigger?
        if let date, date > Date().addingTimeInterval(1) {
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    static func cancel(_ id: String) {
        guard available else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
    }
}
