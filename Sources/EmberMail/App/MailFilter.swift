import Foundation

enum DateRange: String, CaseIterable, Identifiable {
    case any, today, week, month, year
    var id: String { rawValue }
    var title: String {
        switch self {
        case .any: "Any time"
        case .today: "Today"
        case .week: "Last 7 days"
        case .month: "Last 30 days"
        case .year: "Last year"
        }
    }
    var cutoff: Date? {
        let cal = Calendar.current
        switch self {
        case .any: return nil
        case .today: return cal.startOfDay(for: Date())
        case .week: return Date().addingTimeInterval(-7 * 86400)
        case .month: return Date().addingTimeInterval(-30 * 86400)
        case .year: return Date().addingTimeInterval(-365 * 86400)
        }
    }
}

enum ReceiptFilter: String, CaseIterable, Identifiable {
    case any, read, notRead
    var id: String { rawValue }
    var title: String {
        switch self {
        case .any: "Any"
        case .read: "Read by recipient"
        case .notRead: "Not read yet"
        }
    }
}

/// Filters applied on top of the current folder's message list.
struct MailFilter: Equatable {
    /// Fetches ALL unread mail from the server (not just the loaded page).
    var unreadOnly = false
    var flagged = false
    var hasAttachments = false
    var hasReminder = false
    var range: DateRange = .any
    var receipt: ReceiptFilter = .any
    /// Matches sender or recipient name/address.
    var person = ""

    var trimmedPerson: String { person.trimmingCharacters(in: .whitespaces) }

    /// Criteria that are evaluated locally on messages (everything except unreadOnly).
    var hasLocalCriteria: Bool {
        flagged || hasAttachments || hasReminder || range != .any || receipt != .any || !trimmedPerson.isEmpty
    }

    var isActive: Bool { unreadOnly || hasLocalCriteria }

    var activeCount: Int {
        [unreadOnly, flagged, hasAttachments, hasReminder, range != .any, receipt != .any, !trimmedPerson.isEmpty]
            .filter { $0 }.count
    }
}

enum BulkAction {
    case markRead, markUnread, toggleFlag, archive, trash
}
