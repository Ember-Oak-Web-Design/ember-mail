import Foundation

// MARK: - Routing rules

/// One "if" line of a rule, e.g. "From domain is newsletter.com".
struct RuleCondition: Codable, Hashable, Identifiable, Sendable {
    enum Field: String, Codable, CaseIterable, Sendable {
        case sender, senderDomain, recipient, subject

        var title: String {
            switch self {
            case .sender: "From address"
            case .senderDomain: "From domain"
            case .recipient: "To or Cc"
            case .subject: "Subject"
            }
        }
    }

    enum Op: String, Codable, CaseIterable, Sendable {
        case contains, equals, matchesRegex

        var title: String {
            switch self {
            case .contains: "contains"
            case .equals: "is"
            case .matchesRegex: "matches regex"
            }
        }
    }

    var id = UUID()
    var field: Field = .sender
    var op: Op = .contains
    var value = ""

    /// Nil when the regex is valid (or the op isn't regex), otherwise a short error.
    var regexError: String? {
        guard op == .matchesRegex else { return nil }
        guard !value.isEmpty else { return "Enter a pattern" }
        return (try? NSRegularExpression(pattern: value, options: [.caseInsensitive])) == nil ? "Invalid regex" : nil
    }

    func matches(_ m: MessageSummary) -> Bool {
        let needle = value.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return false }
        let candidates: [String]
        switch field {
        case .sender: candidates = [m.from.email, m.from.name ?? ""]
        case .senderDomain: candidates = [Self.domain(of: m.from.email)]
        case .recipient: candidates = (m.to + m.cc).map(\.email)
        case .subject: candidates = [m.subject]
        }
        return candidates.contains { test($0, needle) }
    }

    private func test(_ text: String, _ needle: String) -> Bool {
        guard !text.isEmpty else { return false }
        switch op {
        case .contains:
            return text.localizedCaseInsensitiveContains(needle)
        case .equals:
            if field == .senderDomain {
                // "example.com" also matches "mail.example.com".
                let d = needle.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "@ "))
                let t = text.lowercased()
                return t == d || t.hasSuffix("." + d)
            }
            return text.compare(needle, options: [.caseInsensitive]) == .orderedSame
        case .matchesRegex:
            guard let re = try? NSRegularExpression(pattern: needle, options: [.caseInsensitive]) else { return false }
            return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
    }

    static func domain(of email: String) -> String {
        email.split(separator: "@").last.map { String($0).lowercased() } ?? ""
    }
}

enum RuleDestination: Codable, Hashable, Sendable {
    case none, archive, trash
    case folder(String)   // mailbox path in the rule's account
}

/// "When <conditions> then <actions>", applied to new mail arriving in the Inbox.
struct MailRule: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name = ""
    var enabled = true
    /// nil = every account (moving to a specific folder needs a specific account).
    var accountID: UUID?
    var matchAll = true
    var conditions: [RuleCondition] = [RuleCondition()]
    var markRead = false
    var flag = false
    var destination: RuleDestination = .none

    var hasAction: Bool { markRead || flag || destination != .none }
    var isValid: Bool {
        !conditions.isEmpty && conditions.allSatisfy { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty && $0.regexError == nil } && hasAction
    }

    func applies(to m: MessageSummary) -> Bool {
        guard enabled, isValid, accountID == nil || accountID == m.accountID else { return false }
        return matchAll ? conditions.allSatisfy { $0.matches(m) } : conditions.contains { $0.matches(m) }
    }
}

/// The combined effect of every rule matching a message (rules run top to bottom; the first move wins).
struct RuleOutcome: Equatable, Sendable {
    var markRead = false
    var flag = false
    var destination: RuleDestination = .none
    var matchedRuleIDs: [UUID] = []

    var isEmpty: Bool { matchedRuleIDs.isEmpty }

    static func evaluate(_ rules: [MailRule], for m: MessageSummary) -> RuleOutcome {
        var out = RuleOutcome()
        for rule in rules where rule.applies(to: m) {
            out.matchedRuleIDs.append(rule.id)
            out.markRead = out.markRead || rule.markRead
            out.flag = out.flag || rule.flag
            if out.destination == .none { out.destination = rule.destination }
        }
        return out
    }
}

// MARK: - Notification settings

/// Always / never notify for a person or a whole domain.
struct SenderNotifyRule: Codable, Hashable, Identifiable, Sendable {
    enum Mode: String, Codable, CaseIterable, Sendable {
        case always, never
        var title: String { self == .always ? "Always notify" : "Never notify" }
    }

    var id = UUID()
    var pattern = ""
    var mode: Mode = .always

    /// "jo@x.com" matches that address; "x.com" or "@x.com" matches anyone at x.com (and its subdomains).
    func matches(_ email: String) -> Bool {
        let p = pattern.trimmingCharacters(in: .whitespaces).lowercased()
        guard !p.isEmpty else { return false }
        let e = email.lowercased()
        if p.contains("@"), !p.hasPrefix("@") { return e == p }
        let d = p.trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        let domain = RuleCondition.domain(of: e)
        return domain == d || domain.hasSuffix("." + d)
    }
}

struct NotificationSettings: Codable, Equatable, Sendable {
    /// Explicit per-folder choices (Mailbox.id → on/off). Folders not listed use `defaultEnabled`.
    var folders: [String: Bool] = [:]
    var senders: [SenderNotifyRule] = []

    /// "All except spam", plus folders that only hold your own or duplicate mail.
    static func defaultEnabled(_ mb: Mailbox) -> Bool {
        switch mb.role {
        case .junk, .trash, .sent, .drafts, .starred, .important: return false
        case .archive: return mb.path != "__ALL__"   // Gmail "All Mail" would repeat every Inbox alert
        case .inbox, .custom: return true
        }
    }

    func isEnabled(_ mb: Mailbox) -> Bool { folders[mb.id] ?? Self.defaultEnabled(mb) }

    /// Whether a new message should produce a desktop notification.
    /// Sender rules win: "always" overrides a muted folder, "never" silences everything from that sender.
    /// `folder` is where the message ended up after routing rules (nil = archived/trashed).
    func shouldNotify(_ m: MessageSummary, folder: Mailbox?, markedRead: Bool) -> Bool {
        if let rule = senders.first(where: { $0.matches(m.from.email) }) {
            return rule.mode == .always && !m.isRead
        }
        guard !m.isRead, !markedRead, let folder else { return false }
        return isEnabled(folder)
    }
}
