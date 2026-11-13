import Foundation

/// A small IMAP4rev1 client over implicit TLS. One instance = one connection.
actor IMAPClient {
    struct Config: Sendable {
        var host: String
        var port: Int
        var username: String
        var password: String
        /// Always true in the app; false only for tests against a local fake server.
        var useTLS = true
    }

    struct ListedMailbox {
        var name: String
        var delimiter: String?
        var flags: Set<String>
    }

    struct FetchedMessage {
        var sequence: Int
        var uid: Int
        var flags: Set<String>
        var internalDate: Date?
        var header: Data?
        var textPreview: Data?
        var full: Data?
    }

    private let config: Config
    private var connection: LineConnection?
    private var tagCounter = 0
    private(set) var capabilities: Set<String> = []
    private var selected: String?

    /// One IMAP connection can only run one command at a time, but actor methods interleave while they
    /// await network I/O. Every operation therefore takes this FIFO lock for its whole duration.
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(config: Config) {
        self.config = config
    }

    private func lock() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func unlock() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume() // hand ownership straight to the next waiter
        }
    }

    // MARK: Connection

    func connect() async throws {
        if connection != nil { return }
        let conn = LineConnection(host: config.host, port: config.port, useTLS: config.useTLS)
        try await conn.open()
        connection = conn
        selected = nil
        let greeting = try await conn.readLine().lenientString
        guard greeting.hasPrefix("* OK") || greeting.hasPrefix("* PREAUTH") else {
            disconnect()
            throw MailError.protocolError(greeting)
        }
        if !greeting.hasPrefix("* PREAUTH") {
            do {
                _ = try await execute("LOGIN \(quote(config.username)) \(quote(config.password))")
            } catch MailError.server(let message) {
                disconnect()
                throw MailError.authFailed(message)
            }
        }
        let caps = try await execute("CAPABILITY")
        for line in caps where line.first?.text?.uppercased() == "CAPABILITY" {
            capabilities = Set(line.dropFirst().compactMap { $0.text?.uppercased() })
        }
    }

    func disconnect() {
        connection?.close()
        connection = nil
        selected = nil
    }

    func logout() async {
        await lock()
        defer { unlock() }
        if connection != nil { _ = try? await execute("LOGOUT") }
        disconnect()
    }

    /// Runs `body`, reconnecting and retrying once if the connection dropped.
    @discardableResult
    private func withRetry<T>(_ body: () async throws -> T) async throws -> T {
        await lock()
        defer { unlock() }
        do {
            try await connect()
            return try await body()
        } catch let error as MailError where error.isConnectionProblem {
            disconnect()
            try await connect()
            return try await body()
        }
    }

    // MARK: Low level

    private func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private func nextTag() -> String {
        tagCounter += 1
        return "E\(tagCounter)"
    }

    /// Reads one logical response line, inlining any literals.
    private func readResponse(_ conn: LineConnection) async throws -> Data {
        var raw = Data()
        var line = try await conn.readLine()
        while let count = literalLength(line) {
            raw.append(line)
            raw.append(contentsOf: [13, 10])
            raw.append(try await conn.readBytes(count))
            line = try await conn.readLine()
        }
        raw.append(line)
        return raw
    }

    private func literalLength(_ line: Data) -> Int? {
        guard line.last == 125 /* } */, let open = line.lastIndex(of: 123 /* { */) else { return nil }
        var digits = line[(open + 1)..<(line.endIndex - 1)]
        if digits.last == 43 /* + */ { digits = digits.dropLast() }
        return Int(String(decoding: digits, as: UTF8.self))
    }

    /// Sends a command, returns tokenized untagged responses. Throws on NO/BAD.
    @discardableResult
    private func execute(_ command: String, literal: Data? = nil) async throws -> [[IMAPValue]] {
        guard let conn = connection else { throw MailError.connectionClosed }
        let tag = nextTag()
        if let literal {
            try await conn.send(line: "\(tag) \(command) {\(literal.count)}")
            // Wait for continuation.
            while true {
                let response = try await readResponse(conn)
                if response.first == 43 /* + */ { break }
                let text = response.lenientString
                if text.hasPrefix(tag + " ") { throw MailError.server(String(text.dropFirst(tag.count + 1))) }
            }
            var payload = literal
            payload.append(contentsOf: [13, 10])
            try await conn.send(payload)
        } else {
            try await conn.send(line: "\(tag) \(command)")
        }
        var untagged: [[IMAPValue]] = []
        while true {
            let response = try await readResponse(conn)
            if response.starts(with: Data("* ".utf8)) {
                untagged.append(IMAPTokenizer.parse(response.dropFirst(2)))
            } else if response.starts(with: Data((tag + " ").utf8)) {
                let rest = response.dropFirst(tag.count + 1).lenientString
                let status = rest.prefix(3).uppercased()
                if status.hasPrefix("OK") { return untagged }
                let message = rest.drop(while: { $0 != " " }).trimmingCharacters(in: .whitespaces)
                throw MailError.server(message.isEmpty ? rest : message)
            }
            // "+" continuations and stray lines are ignored.
        }
    }

    // MARK: Mailboxes

    func listMailboxes() async throws -> [ListedMailbox] {
        try await withRetry {
            let lines = try await execute("LIST \"\" \"*\"")
            return lines.compactMap { tokens -> ListedMailbox? in
                guard tokens.count >= 4, tokens[0].text?.uppercased() == "LIST" else { return nil }
                let flags = Set((tokens[1].list ?? []).compactMap { $0.text?.lowercased() })
                guard let name = tokens[3].text else { return nil }
                return ListedMailbox(name: name, delimiter: tokens[2].text, flags: flags)
            }
        }
    }

    /// SELECTs a mailbox (always re-issued so EXISTS is fresh). Returns message count.
    @discardableResult
    func select(_ mailbox: String) async throws -> Int {
        let lines = try await execute("SELECT \(quote(mailbox))")
        selected = mailbox
        for tokens in lines where tokens.count >= 2 && tokens[1].text?.uppercased() == "EXISTS" {
            return Int(tokens[0].text ?? "") ?? 0
        }
        return 0
    }

    private func ensureSelected(_ mailbox: String) async throws {
        if selected != mailbox { try await select(mailbox) }
    }

    func unseenCount(_ mailbox: String) async throws -> Int {
        try await withRetry {
            let lines = try await execute("STATUS \(quote(mailbox)) (UNSEEN)")
            for tokens in lines where tokens.first?.text?.uppercased() == "STATUS" {
                if let items = tokens.last?.list, let idx = items.firstIndex(where: { $0.text?.uppercased() == "UNSEEN" }), idx + 1 < items.count {
                    return Int(items[idx + 1].text ?? "") ?? 0
                }
            }
            return 0
        }
    }

    /// UNSEEN counts for several mailboxes. Uses one `LIST … RETURN (STATUS (UNSEEN))` when the server
    /// supports LIST-STATUS, otherwise one STATUS per mailbox (all inside a single lock).
    func unseenCounts(_ mailboxes: [String]) async throws -> [String: Int] {
        try await withRetry {
            var result: [String: Int] = [:]
            func parseStatus(_ lines: [[IMAPValue]]) {
                for tokens in lines where tokens.first?.text?.uppercased() == "STATUS" && tokens.count >= 3 {
                    guard let name = tokens[1].text, let items = tokens.last?.list,
                          let idx = items.firstIndex(where: { $0.text?.uppercased() == "UNSEEN" }), idx + 1 < items.count,
                          let n = Int(items[idx + 1].text ?? "") else { continue }
                    result[name] = n
                }
            }
            if capabilities.contains("LIST-STATUS") {
                parseStatus(try await execute("LIST \"\" \"*\" RETURN (STATUS (UNSEEN))"))
                return result.filter { mailboxes.contains($0.key) }
            }
            for name in mailboxes {
                if let lines = try? await execute("STATUS \(quote(name)) (UNSEEN)") { parseStatus(lines) }
            }
            return result
        }
    }

    // MARK: Messages

    private static let headerFields = "FROM TO CC SUBJECT DATE MESSAGE-ID IN-REPLY-TO REFERENCES CONTENT-TYPE CONTENT-TRANSFER-ENCODING"
    private static let summaryItems = "(UID FLAGS INTERNALDATE BODY.PEEK[HEADER.FIELDS (\(headerFields))] BODY.PEEK[TEXT]<0.2048>)"

    /// Latest `limit` messages (by sequence number).
    func fetchLatest(_ mailbox: String, limit: Int) async throws -> [FetchedMessage] {
        try await withRetry {
            let exists = try await select(mailbox)
            guard exists > 0 else { return [] }
            let low = max(1, exists - limit + 1)
            let lines = try await execute("FETCH \(low):\(exists) \(Self.summaryItems)")
            return lines.compactMap(parseFetch)
        }
    }

    func search(_ mailbox: String, query: String, limit: Int) async throws -> [FetchedMessage] {
        try await withRetry {
            try await select(mailbox)
            let lines: [[IMAPValue]]
            if query.unicodeScalars.allSatisfy({ $0.isASCII }) {
                lines = try await execute("UID SEARCH TEXT \(quote(query))")
            } else {
                lines = try await execute("UID SEARCH CHARSET UTF-8 TEXT", literal: Data(query.utf8))
            }
            var uids: [Int] = []
            for tokens in lines where tokens.first?.text?.uppercased() == "SEARCH" {
                uids += tokens.dropFirst().compactMap { Int($0.text ?? "") }
            }
            let wanted = uids.sorted().suffix(limit)
            guard !wanted.isEmpty else { return [] }
            let set = wanted.map(String.init).joined(separator: ",")
            let fetched = try await execute("UID FETCH \(set) \(Self.summaryItems)")
            return fetched.compactMap(parseFetch)
        }
    }

    /// The newest `limit` unread messages in a mailbox (server-side UNSEEN search).
    func searchUnseen(_ mailbox: String, limit: Int) async throws -> [FetchedMessage] {
        try await withRetry {
            try await select(mailbox)
            let lines = try await execute("UID SEARCH UNSEEN")
            var uids: [Int] = []
            for tokens in lines where tokens.first?.text?.uppercased() == "SEARCH" {
                uids += tokens.dropFirst().compactMap { Int($0.text ?? "") }
            }
            let wanted = uids.sorted().suffix(limit)
            guard !wanted.isEmpty else { return [] }
            let fetched = try await execute("UID FETCH \(wanted.map(String.init).joined(separator: ",")) \(Self.summaryItems)")
            return fetched.compactMap(parseFetch)
        }
    }

    /// Messages whose subject contains `subject` (used to assemble conversations).
    func searchSubject(_ mailbox: String, subject: String, limit: Int) async throws -> [FetchedMessage] {
        try await withRetry {
            try await select(mailbox)
            let lines: [[IMAPValue]]
            if subject.unicodeScalars.allSatisfy({ $0.isASCII }) {
                lines = try await execute("UID SEARCH SUBJECT \(quote(subject))")
            } else {
                lines = try await execute("UID SEARCH CHARSET UTF-8 SUBJECT", literal: Data(subject.utf8))
            }
            var uids: [Int] = []
            for tokens in lines where tokens.first?.text?.uppercased() == "SEARCH" {
                uids += tokens.dropFirst().compactMap { Int($0.text ?? "") }
            }
            let wanted = uids.sorted().suffix(limit)
            guard !wanted.isEmpty else { return [] }
            let fetched = try await execute("UID FETCH \(wanted.map(String.init).joined(separator: ",")) \(Self.summaryItems)")
            return fetched.compactMap(parseFetch)
        }
    }

    func fetchFull(_ mailbox: String, uid: Int) async throws -> Data {
        try await withRetry {
            try await ensureSelected(mailbox)
            let lines = try await execute("UID FETCH \(uid) (UID BODY.PEEK[])")
            for line in lines {
                if let msg = parseFetch(line), msg.uid == uid, let full = msg.full { return full }
            }
            throw MailError.notFound("That message is no longer on the server.")
        }
    }

    func store(_ mailbox: String, uid: Int, flag: String, add: Bool) async throws {
        try await withRetry {
            try await ensureSelected(mailbox)
            try await execute("UID STORE \(uid) \(add ? "+" : "-")FLAGS.SILENT (\(flag))")
        }
    }

    func move(_ mailbox: String, uid: Int, to destination: String) async throws {
        try await withRetry {
            try await ensureSelected(mailbox)
            if capabilities.contains("MOVE") {
                try await execute("UID MOVE \(uid) \(quote(destination))")
            } else {
                try await execute("UID COPY \(uid) \(quote(destination))")
                try await execute("UID STORE \(uid) +FLAGS.SILENT (\\Deleted)")
                if capabilities.contains("UIDPLUS") {
                    try await execute("UID EXPUNGE \(uid)")
                } else {
                    try await execute("EXPUNGE")
                }
            }
        }
    }

    /// Permanently removes messages with the given Message-ID header from a mailbox (used for drafts).
    func deleteMessages(_ mailbox: String, messageID: String) async throws {
        try await withRetry {
            try await select(mailbox)
            let lines = try await execute("UID SEARCH HEADER Message-ID \(quote(messageID))")
            var uids: [Int] = []
            for tokens in lines where tokens.first?.text?.uppercased() == "SEARCH" {
                uids += tokens.dropFirst().compactMap { Int($0.text ?? "") }
            }
            guard !uids.isEmpty else { return }
            let set = uids.map(String.init).joined(separator: ",")
            try await execute("UID STORE \(set) +FLAGS.SILENT (\\Deleted)")
            if capabilities.contains("UIDPLUS") {
                try await execute("UID EXPUNGE \(set)")
            } else {
                try await execute("EXPUNGE")
            }
        }
    }

    func create(_ mailbox: String) async throws {
        try await withRetry {
            try await execute("CREATE \(quote(mailbox))")
        }
    }

    func append(_ mailbox: String, message: Data, flags: String = "(\\Seen)") async throws {
        try await withRetry {
            try await execute("APPEND \(quote(mailbox)) \(flags)", literal: message)
        }
    }

    // MARK: Parsing

    private func parseFetch(_ tokens: [IMAPValue]) -> FetchedMessage? {
        guard tokens.count >= 3, tokens[1].text?.uppercased() == "FETCH",
              let seq = Int(tokens[0].text ?? ""), let items = tokens[2].list else { return nil }
        var msg = FetchedMessage(sequence: seq, uid: 0, flags: [])
        var index = 0
        while index + 1 < items.count {
            let key = (items[index].text ?? "").uppercased()
            let value = items[index + 1]
            switch key {
            case "UID":
                msg.uid = Int(value.text ?? "") ?? 0
            case "FLAGS":
                msg.flags = Set((value.list ?? []).compactMap { $0.text?.lowercased() })
            case "INTERNALDATE":
                msg.internalDate = MailDate.parse(value.text)
            default:
                if key.hasPrefix("BODY[HEADER") {
                    msg.header = value.data
                } else if key.hasPrefix("BODY[TEXT]") {
                    msg.textPreview = value.data
                } else if key.hasPrefix("BODY[]") {
                    msg.full = value.data
                }
            }
            index += 2
        }
        return msg
    }
}
