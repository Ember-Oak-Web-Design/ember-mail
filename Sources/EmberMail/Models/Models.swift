import Foundation

// MARK: - Addresses

struct EmailAddress: Codable, Hashable, Sendable {
    var name: String?
    var email: String

    init(name: String? = nil, email: String) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = (trimmed?.isEmpty ?? true) ? nil : trimmed
        self.email = email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Name if present, otherwise the email address.
    var displayName: String { name ?? email }

    /// First name-ish label for compact UI.
    var shortName: String {
        if let name { return name.components(separatedBy: " ").first ?? name }
        return email.components(separatedBy: "@").first ?? email
    }

    /// Human readable "Name <email>" (not header-encoded).
    var formatted: String {
        if let name { return "\(name) <\(email)>" }
        return email
    }
}

// MARK: - Accounts

enum AccountKind: String, Codable, Sendable {
    case imap
    case google
}

struct IMAPSettings: Codable, Hashable, Sendable {
    var imapHost: String
    var imapPort: Int = 993
    var smtpHost: String
    var smtpPort: Int = 465
    var username: String
    var saveSentCopy: Bool = true
}

struct Account: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var kind: AccountKind
    var email: String
    var senderName: String
    /// Short label shown in the sidebar, e.g. "Ember & Oak" or "Personal".
    var label: String
    var colorIndex: Int = 0
    var imap: IMAPSettings?
    /// Plain-text signature.
    var signature: String = ""
    /// HTML signature (used instead of `signature` when `useHTMLSignature` is true).
    var signatureHTML: String?
    var useHTMLSignature: Bool?
    /// Images referenced from the HTML signature as `cid:<contentID>`; sent as inline parts.
    var signatureImages: [OutgoingAttachment]?

    var sender: EmailAddress { EmailAddress(name: senderName, email: email) }

    var hasHTMLSignature: Bool { useHTMLSignature == true && !(signatureHTML ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

// MARK: - Mailboxes

enum MailboxRole: String, Codable, Sendable, CaseIterable {
    case inbox, starred, important, sent, drafts, archive, junk, trash, custom

    var sortOrder: Int {
        switch self {
        case .inbox: 0
        case .starred: 1
        case .important: 2
        case .sent: 3
        case .drafts: 4
        case .archive: 5
        case .junk: 6
        case .trash: 7
        case .custom: 8
        }
    }

    var symbol: String {
        switch self {
        case .inbox: "tray"
        case .starred: "star"
        case .important: "flag"
        case .sent: "paperplane"
        case .drafts: "doc.text"
        case .archive: "archivebox"
        case .junk: "xmark.bin"
        case .trash: "trash"
        case .custom: "folder"
        }
    }
}

struct Mailbox: Codable, Identifiable, Hashable, Sendable {
    var accountID: UUID
    /// IMAP mailbox name (raw, as returned by LIST) or Gmail label id.
    var path: String
    var name: String
    var role: MailboxRole

    var id: String { "\(accountID.uuidString)|\(path)" }
}

// MARK: - Messages

struct MessageSummary: Codable, Identifiable, Hashable, Sendable {
    var accountID: UUID
    var mailboxPath: String
    /// IMAP UID (as string) or Gmail message id.
    var remoteID: String
    var threadID: String?
    var from: EmailAddress
    var to: [EmailAddress]
    var cc: [EmailAddress]
    var subject: String
    var snippet: String
    var date: Date
    var isRead: Bool
    var isFlagged: Bool
    var hasAttachments: Bool
    /// RFC 5322 Message-ID header value (with angle brackets) if known.
    var messageIDHeader: String?
    var references: [String]?
    var inReplyTo: String?

    var id: String { "\(accountID.uuidString)|\(mailboxPath)|\(remoteID)" }

    /// Groups messages of one conversation (per account).
    var threadKey: String {
        if let threadID { return "\(accountID.uuidString)|t:\(threadID)" }
        if let root = references?.first ?? inReplyTo { return "\(accountID.uuidString)|m:\(root)" }
        let normalized = Subject.normalize(subject)
        if normalized.lowercased() != subject.lowercased().trimmingCharacters(in: .whitespaces), !normalized.isEmpty {
            return "\(accountID.uuidString)|s:\(normalized.lowercased())"
        }
        return "\(accountID.uuidString)|m:\(messageIDHeader ?? id)"
    }

    /// All Message-IDs this message refers to (itself included).
    var threadIDs: Set<String> {
        var set = Set(references ?? [])
        if let inReplyTo { set.insert(inReplyTo) }
        if let messageIDHeader { set.insert(messageIDHeader) }
        return set
    }
}

enum Subject {
    /// Strips "Re:", "Fwd:", "AW:", "[tag]" style prefixes.
    static func normalize(_ subject: String) -> String {
        var s = subject.trimmingCharacters(in: .whitespaces)
        let pattern = #"^((re|fw|fwd|aw|wg|sv|antw|tr|rif)(\[\d+\])?\s*:\s*)+"#
        while true {
            let next = s.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: .whitespaces)
            if next == s { break }
            s = next
        }
        return s
    }
}

struct AttachmentInfo: Identifiable, Hashable, Sendable {
    var id = UUID()
    var filename: String
    var mimeType: String
    var data: Data
    var contentID: String?
    var isInline: Bool = false

    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
    }
}

struct MessageBody: Sendable {
    var html: String?
    var text: String?
    var attachments: [AttachmentInfo]
    var replyTo: [EmailAddress]
    var to: [EmailAddress]
    var cc: [EmailAddress]
    var references: [String]
    var messageIDHeader: String?
    /// Base64 JSON `DraftMeta` from our own drafts (X-Ember-Draft header).
    var emberDraftMeta: String? = nil

    /// Best-effort plain text, used for quoting in replies.
    var plainText: String {
        if let text, !text.isEmpty { return text }
        if let html { return HTMLText.toPlainText(html) }
        return ""
    }
}

struct OutgoingAttachment: Codable, Hashable, Sendable, Identifiable {
    var id = UUID()
    var filename: String
    var mimeType: String
    var data: Data
    /// Set for inline images (referenced as cid:<contentID> in the HTML).
    var contentID: String?
}

struct OutgoingMessage: Sendable {
    var from: EmailAddress
    var to: [EmailAddress]
    var cc: [EmailAddress] = []
    var bcc: [EmailAddress] = []
    var subject: String
    var text: String
    var html: String
    var inReplyTo: String?
    var references: [String] = []
    var threadID: String?
    var attachments: [OutgoingAttachment] = []
    /// Inline images (signature logos) sent as multipart/related.
    var inlineImages: [OutgoingAttachment] = []
    var requestMDN = false

    var allRecipients: [EmailAddress] { to + cc + bcc }
}

/// Where a saved draft lives on the server, so the next save replaces it and sending deletes it.
struct DraftRef: Codable, Hashable, Sendable {
    var accountID: UUID
    /// Message-ID of the stored draft (IMAP finds it by this header).
    var messageID: String
    /// Gmail draft id.
    var gmailDraftID: String?
}

/// Ember-specific draft details stored in an `X-Ember-Draft` header, so reopening a draft restores the
/// editable body separately from the signature and quoted text.
struct DraftMeta: Codable {
    var body: String
    var to: String
    var cc: String
    var bcc: String
    var quoteHeader: String?
    var quotedText: String?
    var inReplyTo: String?
    var references: [String]
    var threadID: String?
}

struct SentResult: Sendable {
    var messageIDHeader: String
    var providerID: String?
}

// MARK: - Calendar

struct CalendarInfo: Identifiable, Hashable, Sendable {
    var accountID: UUID
    var calendarID: String
    var name: String
    var colorHex: String
    var isPrimary: Bool
    var canWrite: Bool

    var id: String { "\(accountID.uuidString)|\(calendarID)" }
}

struct CalendarEvent: Identifiable, Hashable, Sendable {
    var id: String
    var accountID: UUID
    var calendarKey: String   // CalendarInfo.id
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var location: String?
    var notes: String?
    var meetURL: URL?
    var htmlLink: URL?
    var colorHex: String
    var attendees: [EmailAddress] = []
}

// MARK: - Read receipts

struct OpenEvent: Codable, Hashable, Sendable {
    var at: Date
    var client: String      // "Gmail", "Apple Mail", "Outlook", "Browser"...
    var location: String?   // "Cape Town, ZA"
    var automatic: Bool     // e.g. Apple Mail Privacy Protection pre-fetch
}

struct TrackedMessage: Codable, Identifiable, Hashable, Sendable {
    var id: String          // tracking id used in the pixel URL (= SHA-256 of readKey, first 32 hex chars)
    var readKey: String? = nil   // secret that reads this message's opens from the Worker; nil on pre-key messages
    var accountID: UUID
    var messageIDHeader: String
    var providerID: String?
    var subject: String
    var recipients: [EmailAddress]
    var sentAt: Date
    var opens: [OpenEvent] = []
    var mdnRequested = false

    var humanOpens: [OpenEvent] { opens.filter { !$0.automatic } }
    var isOpened: Bool { !opens.isEmpty }
    var firstOpen: Date? { opens.map(\.at).min() }
    var lastOpen: Date? { opens.map(\.at).max() }
}

// MARK: - Errors

enum MailError: LocalizedError, Sendable {
    case network(String)
    case connectionClosed
    case timeout
    case authFailed(String)
    case server(String)
    case protocolError(String)
    case notConfigured(String)
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .network(let s): "Network error: \(s)"
        case .connectionClosed: "The connection was closed by the server."
        case .timeout: "The server took too long to respond."
        case .authFailed(let s): "Sign-in failed: \(s)"
        case .server(let s): s
        case .protocolError(let s): "Unexpected server response: \(s)"
        case .notConfigured(let s): s
        case .notFound(let s): s
        }
    }

    var isConnectionProblem: Bool {
        switch self {
        case .network, .connectionClosed, .timeout: true
        default: false
        }
    }
}
