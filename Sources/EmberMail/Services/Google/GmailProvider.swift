import Foundation

actor GmailProvider: MailProvider {
    nonisolated let accountID: UUID
    private let base = "https://gmail.googleapis.com/gmail/v1/users/me"
    static let allMailPath = "__ALL__"

    init(accountID: UUID) {
        self.accountID = accountID
    }

    func shutdown() async {}

    // MARK: Requests

    private func request(_ path: String, method: String = "GET", query: [URLQueryItem] = [], json: Any? = nil) async throws -> URLRequest {
        var components = URLComponents(string: base + path)!
        if !query.isEmpty { components.queryItems = query }
        var req = URLRequest(url: components.url!)
        req.httpMethod = method
        let token = try await GoogleAuth.shared.accessToken(for: accountID)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        return req
    }

    // MARK: Models

    private struct LabelList: Decodable { var labels: [Label]? }
    private struct Label: Decodable {
        var id: String
        var name: String
        var type: String?
        var messagesUnread: Int?
        var labelListVisibility: String?
    }
    private struct MessageList: Decodable {
        struct Ref: Decodable { var id: String; var threadId: String? }
        var messages: [Ref]?
    }
    private struct Message: Decodable {
        struct Header: Decodable { var name: String; var value: String }
        struct Payload: Decodable { var mimeType: String?; var headers: [Header]? }
        var id: String
        var threadId: String?
        var labelIds: [String]?
        var snippet: String?
        var internalDate: String?
        var payload: Payload?
        var raw: String?
    }
    private struct SendResponse: Decodable { var id: String; var threadId: String? }
    private struct Thread: Decodable { var id: String; var messages: [Message]? }
    private struct Draft: Decodable {
        struct Ref: Decodable { var id: String; var threadId: String? }
        var id: String
        var message: Ref?
    }
    private struct DraftList: Decodable { var drafts: [Draft]? }

    // MARK: MailProvider

    func mailboxes() async throws -> [Mailbox] {
        let list = try await HTTP.json(LabelList.self, try await request("/labels"))
        let system: [(String, String, MailboxRole)] = [
            ("INBOX", "Inbox", .inbox),
            ("STARRED", "Starred", .starred),
            ("IMPORTANT", "Important", .important),
            ("SENT", "Sent", .sent),
            ("DRAFT", "Drafts", .drafts),
            (Self.allMailPath, "All Mail", .archive),
            ("SPAM", "Spam", .junk),
            ("TRASH", "Trash", .trash),
        ]
        var result = system.map { Mailbox(accountID: accountID, path: $0.0, name: $0.1, role: $0.2) }
        let userLabels = (list.labels ?? [])
            .filter { $0.type == "user" && $0.labelListVisibility != "labelHide" }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        result += userLabels.map { Mailbox(accountID: accountID, path: $0.id, name: $0.name.replacingOccurrences(of: "/", with: " / "), role: .custom) }
        return result
    }

    private func listQuery(for mailbox: Mailbox, limit: Int, q: String? = nil) -> [URLQueryItem] {
        var items = [URLQueryItem(name: "maxResults", value: String(limit))]
        if mailbox.path != Self.allMailPath { items.append(.init(name: "labelIds", value: mailbox.path)) }
        if mailbox.path == "SPAM" || mailbox.path == "TRASH" { items.append(.init(name: "includeSpamTrash", value: "true")) }
        if let q { items.append(.init(name: "q", value: q)) }
        return items
    }

    func messages(in mailbox: Mailbox, limit: Int) async throws -> [MessageSummary] {
        let list = try await HTTP.json(MessageList.self, try await request("/messages", query: listQuery(for: mailbox, limit: limit)))
        return try await fetchMetadata(ids: (list.messages ?? []).map(\.id), mailbox: mailbox)
    }

    func search(_ query: String, in mailbox: Mailbox, limit: Int) async throws -> [MessageSummary] {
        let list = try await HTTP.json(MessageList.self, try await request("/messages", query: listQuery(for: mailbox, limit: limit, q: query)))
        return try await fetchMetadata(ids: (list.messages ?? []).map(\.id), mailbox: mailbox)
    }

    private func fetchMetadata(ids: [String], mailbox: Mailbox) async throws -> [MessageSummary] {
        var results: [MessageSummary] = []
        let headers = Self.metadataHeaders
        let query = [URLQueryItem(name: "format", value: "metadata")] + headers.map { URLQueryItem(name: "metadataHeaders", value: $0) }
        // Fetch in parallel batches of 10.
        for chunkStart in stride(from: 0, to: ids.count, by: 10) {
            let chunk = Array(ids[chunkStart..<min(ids.count, chunkStart + 10)])
            var requests: [URLRequest] = []
            for id in chunk { requests.append(try await request("/messages/\(id)", query: query)) }
            let batch = try await withThrowingTaskGroup(of: Message?.self) { group -> [Message] in
                for req in requests {
                    group.addTask { try? await HTTP.json(Message.self, req) }
                }
                var out: [Message] = []
                for try await m in group { if let m { out.append(m) } }
                return out
            }
            results += batch.map { summary(from: $0, mailbox: mailbox) }
        }
        return results.sorted { $0.date > $1.date }
    }

    private static let metadataHeaders = ["From", "To", "Cc", "Subject", "Date", "Message-ID", "References", "In-Reply-To"]

    func thread(for message: MessageSummary) async throws -> [MessageSummary] {
        guard let threadID = message.threadID else { return [message] }
        let query = [URLQueryItem(name: "format", value: "metadata")] + Self.metadataHeaders.map { URLQueryItem(name: "metadataHeaders", value: $0) }
        let thread = try await HTTP.json(Thread.self, try await request("/threads/\(threadID)", query: query))
        let mailbox = Mailbox(accountID: accountID, path: message.mailboxPath, name: "", role: .custom)
        let viewingTrash = message.mailboxPath == "TRASH"
        let items = (thread.messages ?? []).filter { m in
            let labels = Set(m.labelIds ?? [])
            return !labels.contains("DRAFT") && (viewingTrash || !labels.contains("TRASH"))
        }
        let summaries = items.map { summary(from: $0, mailbox: mailbox) }.sorted { $0.date < $1.date }
        return summaries.isEmpty ? [message] : summaries
    }

    private func summary(from m: Message, mailbox: Mailbox) -> MessageSummary {
        let headers = m.payload?.headers ?? []
        func header(_ name: String) -> String? { headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value }
        let labels = Set(m.labelIds ?? [])
        let millis = Double(m.internalDate ?? "") ?? 0
        return MessageSummary(
            accountID: accountID,
            mailboxPath: mailbox.path,
            remoteID: m.id,
            threadID: m.threadId,
            from: AddressParser.parseList(header("From")).first ?? EmailAddress(email: "unknown"),
            to: AddressParser.parseList(header("To")),
            cc: AddressParser.parseList(header("Cc")),
            subject: header("Subject").map(RFC2047.decode) ?? "",
            snippet: HTMLText.removeInvisible(HTMLText.decodeEntities(m.snippet ?? "")).trimmingCharacters(in: .whitespaces),
            date: millis > 0 ? Date(timeIntervalSince1970: millis / 1000) : (MailDate.parse(header("Date")) ?? Date.distantPast),
            isRead: !labels.contains("UNREAD"),
            isFlagged: labels.contains("STARRED"),
            hasAttachments: m.payload?.mimeType == "multipart/mixed",
            messageIDHeader: header("Message-ID"),
            references: IMAPProvider.messageIDs(header("References")),
            inReplyTo: IMAPProvider.messageIDs(header("In-Reply-To")).first)
    }

    func body(of message: MessageSummary) async throws -> MessageBody {
        let m = try await HTTP.json(Message.self, try await request("/messages/\(message.remoteID)", query: [.init(name: "format", value: "raw")]))
        guard let raw = m.raw, let data = Data(base64URLEncoded: raw) else {
            throw MailError.protocolError("Gmail returned an empty message")
        }
        return MessageExtraction.body(from: data)
    }

    func unreadCount(_ mailbox: Mailbox) async throws -> Int {
        guard mailbox.path != Self.allMailPath else { return 0 }
        let label = try await HTTP.json(Label.self, try await request("/labels/\(mailbox.path)"))
        return label.messagesUnread ?? 0
    }

    private func modify(_ id: String, add: [String] = [], remove: [String] = []) async throws {
        _ = try await HTTP.data(try await request("/messages/\(id)/modify", method: "POST",
                                                  json: ["addLabelIds": add, "removeLabelIds": remove]))
    }

    func setRead(_ read: Bool, _ message: MessageSummary) async throws {
        try await modify(message.remoteID, add: read ? [] : ["UNREAD"], remove: read ? ["UNREAD"] : [])
    }

    func setFlagged(_ flagged: Bool, _ message: MessageSummary) async throws {
        try await modify(message.remoteID, add: flagged ? ["STARRED"] : [], remove: flagged ? [] : ["STARRED"])
    }

    func archive(_ message: MessageSummary) async throws {
        try await modify(message.remoteID, remove: ["INBOX"])
    }

    func trash(_ message: MessageSummary) async throws {
        _ = try await HTTP.data(try await request("/messages/\(message.remoteID)/trash", method: "POST"))
    }

    func saveDraft(_ message: OutgoingMessage, extraHeaders: [String], replacing: DraftRef?) async throws -> DraftRef {
        let built = MIMEBuilder.build(message, includeBcc: true, extraHeaders: extraHeaders)
        var inner: [String: Any] = ["raw": built.data.base64URLEncodedString()]
        if let thread = message.threadID { inner["threadId"] = thread }
        let draft: Draft
        if let id = replacing?.gmailDraftID {
            do {
                draft = try await HTTP.json(Draft.self, try await request("/drafts/\(id)", method: "PUT", json: ["id": id, "message": inner]))
            } catch MailError.server(let msg) where msg.contains("404") {
                // Draft was deleted elsewhere (e.g. sent from Gmail web): create a new one.
                draft = try await HTTP.json(Draft.self, try await request("/drafts", method: "POST", json: ["message": inner]))
            }
        } else {
            draft = try await HTTP.json(Draft.self, try await request("/drafts", method: "POST", json: ["message": inner]))
        }
        return DraftRef(accountID: accountID, messageID: built.messageID, gmailDraftID: draft.id)
    }

    func deleteDraft(_ ref: DraftRef) async throws {
        guard let id = ref.gmailDraftID else { return }
        do {
            _ = try await HTTP.data(try await request("/drafts/\(id)", method: "DELETE"))
        } catch MailError.server(let msg) where msg.contains("404") {
            // Already gone.
        }
    }

    func draftRef(for message: MessageSummary) async throws -> DraftRef? {
        var pageToken: String?
        repeat {
            var query = [URLQueryItem(name: "maxResults", value: "100")]
            if let pageToken { query.append(.init(name: "pageToken", value: pageToken)) }
            let req = try await request("/drafts", query: query)
            let data = try await HTTP.data(req)
            let list = try JSONDecoder().decode(DraftList.self, from: data)
            if let hit = list.drafts?.first(where: { $0.message?.id == message.remoteID }) {
                return DraftRef(accountID: accountID, messageID: message.messageIDHeader ?? "", gmailDraftID: hit.id)
            }
            pageToken = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["nextPageToken"] as? String
        } while pageToken != nil
        return nil
    }

    func send(_ message: OutgoingMessage) async throws -> SentResult {
        let built = MIMEBuilder.build(message, includeBcc: true)
        var payload: [String: Any] = ["raw": built.data.base64URLEncodedString()]
        if let thread = message.threadID { payload["threadId"] = thread }
        let response = try await HTTP.json(SendResponse.self, try await request("/messages/send", method: "POST", json: payload))
        return SentResult(messageIDHeader: built.messageID, providerID: response.id)
    }
}
