import Foundation
import Observation

/// Routing rules and notification preferences (JSON in Application Support).
@MainActor
@Observable
final class RulesStore {
    private(set) var rules: [MailRule]
    private(set) var notifications: NotificationSettings

    private static let rulesFile = "rules.json"
    private static let notifyFile = "notification-settings.json"

    init() {
        rules = DiskStore.load([MailRule].self, from: Self.rulesFile) ?? []
        notifications = DiskStore.load(NotificationSettings.self, from: Self.notifyFile) ?? NotificationSettings()
    }

    func save(rules new: [MailRule]) {
        rules = new
        DiskStore.save(rules, as: Self.rulesFile)
    }

    func save(notifications new: NotificationSettings) {
        notifications = new
        DiskStore.save(notifications, as: Self.notifyFile)
    }

    var activeRules: [MailRule] { rules.filter { $0.enabled && $0.isValid } }
}
