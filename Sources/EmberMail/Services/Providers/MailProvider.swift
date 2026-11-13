import Foundation

/// Common interface for IMAP/SMTP and Gmail accounts.
protocol MailProvider: AnyObject, Sendable {
    var accountID: UUID { get }
    func mailboxes() async throws -> [Mailbox]
    func messages(in mailbox: Mailbox, limit: Int) async throws -> [MessageSummary]
    func search(_ query: String, in mailbox: Mailbox, limit: Int) async throws -> [MessageSummary]
    /// ALL unread messages (newest first, up to `limit`), fetched from the server, not just the loaded page.
    func unreadMessages(in mailbox: Mailbox, limit: Int) async throws -> [MessageSummary]
    func body(of message: MessageSummary) async throws -> MessageBody
    /// The whole conversation containing `message`, oldest first (may span Inbox and Sent).
    func thread(for message: MessageSummary) async throws -> [MessageSummary]
    func unreadCount(_ mailbox: Mailbox) async throws -> Int
    /// Unread counts for several mailboxes at once, keyed by `Mailbox.id`. Failures are skipped.
    func unreadCounts(_ mailboxes: [Mailbox]) async -> [String: Int]
    func setRead(_ read: Bool, _ message: MessageSummary) async throws
    func setFlagged(_ flagged: Bool, _ message: MessageSummary) async throws
    func archive(_ message: MessageSummary) async throws
    func trash(_ message: MessageSummary) async throws
    func send(_ message: OutgoingMessage) async throws -> SentResult
    /// Saves (or replaces) a draft on the server.
    func saveDraft(_ message: OutgoingMessage, extraHeaders: [String], replacing: DraftRef?) async throws -> DraftRef
    func deleteDraft(_ ref: DraftRef) async throws
    /// Server reference for a message shown in the Drafts folder (to resume editing it).
    func draftRef(for message: MessageSummary) async throws -> DraftRef?
    func shutdown() async
}

extension GmailProvider {
    func unreadMessages(in mailbox: Mailbox, limit: Int) async throws -> [MessageSummary] {
        try await search("is:unread", in: mailbox, limit: limit)
    }

    func unreadCounts(_ mailboxes: [Mailbox]) async -> [String: Int] {
        await withTaskGroup(of: (String, Int?).self) { group in
            for mb in mailboxes {
                group.addTask { (mb.id, try? await self.unreadCount(mb)) }
            }
            var out: [String: Int] = [:]
            for await (id, count) in group { if let count { out[id] = count } }
            return out
        }
    }
}

extension Array where Element == Mailbox {
    func first(role: MailboxRole) -> Mailbox? { first { $0.role == role } }
}

// MARK: - IMAP

actor IMAPProvider: MailProvider {
    nonisolated let accountID: UUID
    private let account: Account
    private let settings: IMAPSettings
    private let password: String
    private let client: IMAPClient
    private var cachedMailboxes: [Mailbox] = []

    init(account: Account, password: String) {
        self.accountID = account.id
        self.account = account
        self.settings = account.imap ?? IMAPSettings(imapHost: "", smtpHost: "", username: account.email)
        self.password = password
        self.client = IMAPClient(config: .init(host: settings.imapHost, port: settings.imapPort,
                                              username: settings.username, password: password))
    }

    /// Quick credential check used when adding an account.
    static func verify(settings: IMAPSettings, password: String) async throws {
        let client = IMAPClient(config: .init(host: settings.imapHost, port: settings.imapPort,
                                              username: settings.username, password: password))
        try await client.connect()
        await client.logout()
        try await SMTPClient(config: .init(host: settings.smtpHost, port: settings.smtpPort,
                                           username: settings.username, password: password)).verify()
    }

    func shutdown() async {
        await client.logout()
    }

    func mailboxes() async throws -> [Mailbox] {
        let listed = try await client.listMailboxes()
        var result: [Mailbox] = []
        var usedRoles = Set<MailboxRole>()
        // Special-use flags first, then name heuristics.
        let sorted = listed.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        for item in sorted where !item.flags.contains("\\noselect") && !item.flags.contains("\\nonexistent") {
            var role = Self.role(fromFlags: item.flags)
            if role == .custom, let guess = Self.role(fromName: item.name), !usedRoles.contains(guess) {
                role = guess
            }
            if role != .custom {
                if usedRoles.contains(role) { role = .custom } else { usedRoles.insert(role) }
            }
            var display = ModifiedUTF7.decode(item.name)
            if let delimiter = item.delimiter, !delimiter.isEmpty, role == .custom {
                display = display.components(separatedBy: delimiter).joined(separator: " / ")
                if display.uppercased().hasPrefix("INBOX / ") { display = String(display.dropFirst(8)) }
            }
            if role != .custom { display = Self.displayName(for: role) }
            result.append(Mailbox(accountID: accountID, path: item.name, name: display, role: role))
        }
        cachedMailboxes = result
        return result
    }

    private static func role(fromFlags flags: Set<String>) -> MailboxRole {
        if flags.contains("\\sent") { return .sent }
        if flags.contains("\\trash") { return .trash }
        if flags.contains("\\drafts") { return .drafts }
        if flags.contains("\\junk") { return .junk }
        if flags.contains("\\archive") { return .archive }
        if flags.contains("\\flagged") { return .starred }
        return .custom
    }

    private static func role(fromName name: String) -> MailboxRole? {
        let leaf = (name.components(separatedBy: CharacterSet(charactersIn: "/.")).last ?? name).lowercased()
        if name.uppercased() == "INBOX" { return .inbox }
        switch leaf {
        case "sent", "sent items", "sent messages", "sent mail": return .sent
        case "trash", "deleted", "deleted items", "deleted messages", "bin": return .trash
        case "drafts", "draft": return .drafts
        case "junk", "spam", "junk e-mail", "junk email", "bulk mail": return .junk
        case "archive", "archives", "all mail": return .archive
        default: return nil
        }
    }

    static func displayName(for role: MailboxRole) -> String {
        switch role {
        case .inbox: "Inbox"
        case .starred: "Flagged"
        case .important: "Important"
        case .sent: "Sent"
        case .drafts: "Drafts"
        case .archive: "Archive"
        case .junk: "Junk"
        case .trash: "Trash"
        case .custom: "Folder"
        }
    }

    private func summary(from fetched: IMAPClient.FetchedMessage, mailbox: Mailbox) -> MessageSummary {
        var raw = fetched.header ?? Data()
        if let preview = fetched.textPreview { raw.append(preview) }
        let part = MIMEParser.parse(raw)
        let from = AddressParser.parseList(part.header("from")).first ?? EmailAddress(email: "unknown")
        return MessageSummary(
            accountID: accountID,
            mailboxPath: mailbox.path,
            remoteID: String(fetched.uid),
            threadID: nil,
            from: from,
            to: AddressParser.parseList(part.header("to")),
            cc: AddressParser.parseList(part.header("cc")),
            subject: part.decodedHeader("subject") ?? "",
            snippet: MessageExtraction.snippet(from: part),
            date: MailDate.parse(part.header("date")) ?? fetched.internalDate ?? Date.distantPast,
            isRead: fetched.flags.contains("\\seen"),
            isFlagged: fetched.flags.contains("\\flagged"),
            hasAttachments: part.contentType.type == "multipart/mixed",
            messageIDHeader: part.header("message-id")?.trimmingCharacters(in: .whitespaces),
            references: Self.messageIDs(part.header("references")),
            inReplyTo: Self.messageIDs(part.header("in-reply-to")).first)
    }

    static func messageIDs(_ header: String?) -> [String] {
        guard let header else { return [] }
        guard let regex = try? NSRegularExpression(pattern: "<[^<>\\s]+>") else { return [] }
        let ns = header as NSString
        return regex.matches(in: header, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    func thread(for message: MessageSummary) async throws -> [MessageSummary] {
        let subject = Subject.normalize(message.subject)
        guard !subject.isEmpty else { return [message] }
        if cachedMailboxes.isEmpty { _ = try await mailboxes() }
        var folders = cachedMailboxes.filter { $0.role == .inbox || $0.role == .sent }
        if let current = cachedMailboxes.first(where: { $0.path == message.mailboxPath }), !folders.contains(current) {
            folders.append(current)
        }
        // IMAP SUBJECT search is a substring match; keep the query reasonably short.
        let query = String(subject.prefix(120))
        var candidates: [MessageSummary] = []
        for folder in folders {
            if let found = try? await client.searchSubject(folder.path, subject: query, limit: 40) {
                candidates += found.filter { $0.uid > 0 }.map { summary(from: $0, mailbox: folder) }
            }
        }
        return Self.assemble(message: message, candidates: candidates)
    }

    /// Picks the candidates that belong to `message`'s conversation using References/In-Reply-To,
    /// falling back to identical subjects with overlapping participants.
    static func assemble(message: MessageSummary, candidates: [MessageSummary]) -> [MessageSummary] {
        var keys = message.threadIDs
        var chosen: [MessageSummary] = []
        var remaining = candidates
        var changed = true
        while changed {
            changed = false
            for candidate in remaining where !candidate.threadIDs.isDisjoint(with: keys) {
                chosen.append(candidate)
                keys.formUnion(candidate.threadIDs)
                changed = true
            }
            remaining.removeAll { c in chosen.contains { $0.id == c.id } }
        }
        if chosen.count <= 1 {
            let normalized = Subject.normalize(message.subject).lowercased()
            let people = Set(([message.from] + message.to + message.cc).map { $0.email.lowercased() })
            chosen += remaining.filter { c in
                Subject.normalize(c.subject).lowercased() == normalized &&
                    !people.isDisjoint(with: ([c.from] + c.to + c.cc).map { $0.email.lowercased() })
            }
        }
        if !chosen.contains(where: { $0.id == message.id }) { chosen.append(message) }
        // De-duplicate (a message to yourself appears in Inbox and Sent).
        var seen = Set<String>()
        let unique = chosen.sorted { $0.date < $1.date }.filter { m in
            let key = m.messageIDHeader ?? m.id
            return seen.insert(key).inserted
        }
        return unique
    }

    func messages(in mailbox: Mailbox, limit: Int) async throws -> [MessageSummary] {
        let fetched = try await client.fetchLatest(mailbox.path, limit: limit)
        return fetched.filter { $0.uid > 0 }.map { summary(from: $0, mailbox: mailbox) }.sorted { $0.date > $1.date }
    }

    func search(_ query: String, in mailbox: Mailbox, limit: Int) async throws -> [MessageSummary] {
        let fetched = try await client.search(mailbox.path, query: query, limit: limit)
        return fetched.filter { $0.uid > 0 }.map { summary(from: $0, mailbox: mailbox) }.sorted { $0.date > $1.date }
    }

    func body(of message: MessageSummary) async throws -> MessageBody {
        guard let uid = Int(message.remoteID) else { throw MailError.notFound("Invalid message id") }
        let raw = try await client.fetchFull(message.mailboxPath, uid: uid)
        return MessageExtraction.body(from: raw)
    }

    func unreadCount(_ mailbox: Mailbox) async throws -> Int {
        try await client.unseenCount(mailbox.path)
    }

    func unreadMessages(in mailbox: Mailbox, limit: Int) async throws -> [MessageSummary] {
        let fetched = try await client.searchUnseen(mailbox.path, limit: limit)
        return fetched.filter { $0.uid > 0 }.map { summary(from: $0, mailbox: mailbox) }.sorted { $0.date > $1.date }
    }

    func unreadCounts(_ mailboxes: [Mailbox]) async -> [String: Int] {
        let byPath = Dictionary(mailboxes.map { ($0.path, $0.id) }, uniquingKeysWith: { a, _ in a })
        let counts = (try? await client.unseenCounts(Array(byPath.keys))) ?? [:]
        var out: [String: Int] = [:]
        for (path, count) in counts { if let id = byPath[path] { out[id] = count } }
        return out
    }

    func setRead(_ read: Bool, _ message: MessageSummary) async throws {
        guard let uid = Int(message.remoteID) else { return }
        try await client.store(message.mailboxPath, uid: uid, flag: "\\Seen", add: read)
    }

    func setFlagged(_ flagged: Bool, _ message: MessageSummary) async throws {
        guard let uid = Int(message.remoteID) else { return }
        try await client.store(message.mailboxPath, uid: uid, flag: "\\Flagged", add: flagged)
    }

    private func mailbox(role: MailboxRole) async throws -> Mailbox? {
        if cachedMailboxes.isEmpty { _ = try await mailboxes() }
        return cachedMailboxes.first(role: role)
    }

    func archive(_ message: MessageSummary) async throws {
        guard let uid = Int(message.remoteID) else { return }
        var destination = try await mailbox(role: .archive)?.path
        if destination == nil {
            try await client.create("Archive")
            _ = try await mailboxes()
            destination = "Archive"
        }
        try await client.move(message.mailboxPath, uid: uid, to: destination!)
    }

    func trash(_ message: MessageSummary) async throws {
        guard let uid = Int(message.remoteID) else { return }
        guard let trash = try await mailbox(role: .trash) else {
            throw MailError.notFound("No Trash folder was found on the server.")
        }
        if trash.path == message.mailboxPath {
            try await client.store(message.mailboxPath, uid: uid, flag: "\\Deleted", add: true)
        } else {
            try await client.move(message.mailboxPath, uid: uid, to: trash.path)
        }
    }

    func saveDraft(_ message: OutgoingMessage, extraHeaders: [String], replacing: DraftRef?) async throws -> DraftRef {
        var drafts = try await mailbox(role: .drafts)?.path
        if drafts == nil {
            try await client.create("Drafts")
            _ = try await mailboxes()
            drafts = "Drafts"
        }
        // Each save gets a new Message-ID: append the new copy first, then remove the old one,
        // so a failed save never loses the previous draft.
        let built = MIMEBuilder.build(message, includeBcc: true, extraHeaders: extraHeaders)
        try await client.append(drafts!, message: built.data, flags: "(\\Draft \\Seen)")
        if let old = replacing?.messageID {
            try? await client.deleteMessages(drafts!, messageID: old)
        }
        return DraftRef(accountID: accountID, messageID: built.messageID)
    }

    func deleteDraft(_ ref: DraftRef) async throws {
        guard let drafts = try await mailbox(role: .drafts) else { return }
        try await client.deleteMessages(drafts.path, messageID: ref.messageID)
    }

    func draftRef(for message: MessageSummary) async throws -> DraftRef? {
        message.messageIDHeader.map { DraftRef(accountID: accountID, messageID: $0) }
    }

    func send(_ message: OutgoingMessage) async throws -> SentResult {
        let built = MIMEBuilder.build(message, includeBcc: false)
        let smtp = SMTPClient(config: .init(host: settings.smtpHost, port: settings.smtpPort,
                                            username: settings.username, password: password))
        try await smtp.send(built.data, from: message.from.email, recipients: message.allRecipients.map(\.email))
        if settings.saveSentCopy, let sent = try? await mailbox(role: .sent) {
            try? await client.append(sent.path, message: built.data)
        }
        return SentResult(messageIDHeader: built.messageID, providerID: nil)
    }
}
