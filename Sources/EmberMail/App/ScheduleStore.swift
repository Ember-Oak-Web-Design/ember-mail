import Foundation
import Observation

struct ScheduledSend: Codable, Identifiable, Hashable {
    var id = UUID()
    var draft: ComposeDraft
    var sendAt: Date
    var trackOpens: Bool
    var requestMDN: Bool
    var lastError: String?
}

struct ReplyReminder: Codable, Identifiable, Hashable {
    var id = UUID()
    var message: MessageSummary
    var fireAt: Date

    var isDue: Bool { fireAt <= Date() }
    var notificationID: String { "reminder-\(id.uuidString)" }
}

/// Scheduled sends (sent by the app when due) and reply reminders (delivered by macOS, even if the app is closed).
@MainActor
@Observable
final class ScheduleStore {
    private(set) var sends: [ScheduledSend] = []
    private(set) var reminders: [ReplyReminder] = []

    private static let sendsFile = "scheduled-sends.json"
    private static let remindersFile = "reminders.json"

    init() {
        sends = DiskStore.load([ScheduledSend].self, from: Self.sendsFile) ?? []
        reminders = DiskStore.load([ReplyReminder].self, from: Self.remindersFile) ?? []
    }

    private func save() {
        DiskStore.save(sends, as: Self.sendsFile)
        DiskStore.save(reminders, as: Self.remindersFile)
    }

    // MARK: Scheduled sends

    var pendingSends: [ScheduledSend] { sends.sorted { $0.sendAt < $1.sendAt } }

    func schedule(_ item: ScheduledSend) {
        sends.append(item)
        save()
    }

    func cancelSend(_ id: UUID) {
        sends.removeAll { $0.id == id }
        save()
    }

    func dueSends(now: Date = Date()) -> [ScheduledSend] {
        sends.filter { $0.sendAt <= now }.sorted { $0.sendAt < $1.sendAt }
    }

    func markFailed(_ id: UUID, error: String) {
        guard let index = sends.firstIndex(where: { $0.id == id }) else { return }
        sends[index].lastError = error
        // Retry in 5 minutes rather than hammering the server.
        sends[index].sendAt = Date().addingTimeInterval(5 * 60)
        save()
    }

    func reschedule(_ id: UUID, to date: Date) {
        guard let index = sends.firstIndex(where: { $0.id == id }) else { return }
        sends[index].sendAt = date
        sends[index].lastError = nil
        save()
    }

    // MARK: Reply reminders

    var sortedReminders: [ReplyReminder] { reminders.sorted { $0.fireAt < $1.fireAt } }
    var dueReminderCount: Int { reminders.filter(\.isDue).count }

    func reminder(for message: MessageSummary) -> ReplyReminder? {
        reminders.first { $0.message.id == message.id || ($0.message.threadKey == message.threadKey) }
    }

    func addReminder(for message: MessageSummary, at date: Date) {
        if let existing = reminder(for: message) { cancelReminder(existing.id) }
        let reminder = ReplyReminder(message: message, fireAt: date)
        reminders.append(reminder)
        save()
        schedule(reminder)
    }

    private func schedule(_ reminder: ReplyReminder) {
        let who = reminder.message.from.displayName
        Notifier.post(title: "Reply to \(who)",
                      body: reminder.message.subject.isEmpty ? reminder.message.snippet : reminder.message.subject,
                      id: reminder.notificationID,
                      category: Notifier.reminderCategory,
                      userInfo: ["kind": "reminder", "reminderID": reminder.id.uuidString],
                      at: reminder.fireAt)
    }

    func cancelReminder(_ id: UUID) {
        if let reminder = reminders.first(where: { $0.id == id }) { Notifier.cancel(reminder.notificationID) }
        reminders.removeAll { $0.id == id }
        save()
    }

    func snooze(_ id: UUID, until date: Date) {
        guard let index = reminders.firstIndex(where: { $0.id == id }) else { return }
        Notifier.cancel(reminders[index].notificationID)
        reminders[index].fireAt = date
        save()
        schedule(reminders[index])
    }

    func reminder(id: UUID) -> ReplyReminder? { reminders.first { $0.id == id } }

    /// Replying clears the reminder for that conversation.
    func clearReminders(answeredBy draft: ComposeDraft) {
        let matches = reminders.filter { r in
            (draft.inReplyTo != nil && draft.inReplyTo == r.message.messageIDHeader) ||
                (draft.threadID != nil && draft.threadID == r.message.threadID) ||
                (draft.references.contains { $0 == r.message.messageIDHeader })
        }
        for r in matches { cancelReminder(r.id) }
    }
}

/// Preset times used by "Send later" and "Remind me".
enum QuickTimes {
    static func at(hour: Int, minute: Int = 0, daysFromNow: Int) -> Date {
        let cal = Calendar.current
        let day = cal.date(byAdding: .day, value: daysFromNow, to: Date())!
        return cal.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    static func nextWeekday(_ weekday: Int, hour: Int) -> Date {
        let cal = Calendar.current
        let next = cal.nextDate(after: Date(), matching: DateComponents(hour: hour, minute: 0, weekday: weekday),
                                matchingPolicy: .nextTime) ?? Date()
        return next
    }

    static func inHours(_ hours: Double) -> Date { Date().addingTimeInterval(hours * 3600) }

    /// "This evening" if it's still before 5 pm, otherwise nil.
    static var thisEvening: Date? {
        let date = at(hour: 18, daysFromNow: 0)
        return Calendar.current.component(.hour, from: Date()) < 17 ? date : nil
    }

    static func label(_ date: Date) -> String {
        let cal = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(date) { return "Today \(time)" }
        if cal.isDateInTomorrow(date) { return "Tomorrow \(time)" }
        if let days = cal.dateComponents([.day], from: Date(), to: date).day, days < 7 {
            return "\(date.formatted(.dateTime.weekday(.wide))) \(time)"
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
