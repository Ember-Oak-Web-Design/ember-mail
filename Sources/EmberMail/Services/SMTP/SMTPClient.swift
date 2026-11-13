import Foundation

/// Minimal SMTP submission client over implicit TLS (port 465).
struct SMTPClient {
    struct Config: Sendable {
        var host: String
        var port: Int
        var username: String
        var password: String
    }

    let config: Config

    private struct Reply {
        var code: Int
        var lines: [String]
        var text: String { lines.joined(separator: " ") }
    }

    private func readReply(_ conn: LineConnection) async throws -> Reply {
        var lines: [String] = []
        while true {
            let line = try await conn.readLine(timeout: 120).lenientString
            guard line.count >= 3, let code = Int(line.prefix(3)) else {
                throw MailError.protocolError(line)
            }
            lines.append(String(line.dropFirst(4)))
            // "250-..." continues, "250 ..." ends.
            if line.count == 3 || line[line.index(line.startIndex, offsetBy: 3)] != "-" {
                return Reply(code: code, lines: lines)
            }
        }
    }

    @discardableResult
    private func command(_ conn: LineConnection, _ line: String, expect: Set<Int>) async throws -> Reply {
        try await conn.send(line: line)
        let reply = try await readReply(conn)
        guard expect.contains(reply.code) else {
            throw MailError.server("SMTP \(reply.code): \(reply.text)")
        }
        return reply
    }

    private func openSession() async throws -> LineConnection {
        if config.port == 587 || config.port == 25 {
            throw MailError.notConfigured("Ember Mail sends over SSL/TLS. Please use SMTP port 465 for \(config.host).")
        }
        let conn = LineConnection(host: config.host, port: config.port, useTLS: true)
        try await conn.open()
        let greeting = try await readReply(conn)
        guard greeting.code == 220 else { throw MailError.server("SMTP greeting: \(greeting.text)") }
        let ehlo = try await command(conn, "EHLO ember-mail.local", expect: [250])
        let authLine = ehlo.lines.first { $0.uppercased().hasPrefix("AUTH") }?.uppercased() ?? "AUTH PLAIN LOGIN"

        do {
            if authLine.contains("PLAIN") {
                let token = Data("\0\(config.username)\0\(config.password)".utf8).base64EncodedString()
                try await command(conn, "AUTH PLAIN \(token)", expect: [235])
            } else {
                try await command(conn, "AUTH LOGIN", expect: [334])
                try await command(conn, Data(config.username.utf8).base64EncodedString(), expect: [334])
                try await command(conn, Data(config.password.utf8).base64EncodedString(), expect: [235])
            }
        } catch MailError.server(let message) {
            conn.close()
            throw MailError.authFailed(message)
        }
        return conn
    }

    /// Verifies the server and credentials without sending anything.
    func verify() async throws {
        let conn = try await openSession()
        _ = try? await command(conn, "QUIT", expect: [221])
        conn.close()
    }

    func send(_ message: Data, from: String, recipients: [String]) async throws {
        let conn = try await openSession()
        defer { conn.close() }
        try await command(conn, "MAIL FROM:<\(from)>", expect: [250])
        for rcpt in recipients {
            try await command(conn, "RCPT TO:<\(rcpt)>", expect: [250, 251])
        }
        try await command(conn, "DATA", expect: [354])

        // Normalise to CRLF and dot-stuff.
        let text = message.lenientString
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.hasPrefix(".") ? "." + $0 : $0 }
            .joined(separator: "\r\n")
        var payload = Data(text.utf8)
        payload.append(Data("\r\n.\r\n".utf8))
        try await conn.send(payload)
        let reply = try await readReply(conn)
        guard reply.code == 250 else { throw MailError.server("SMTP \(reply.code): \(reply.text)") }
        _ = try? await command(conn, "QUIT", expect: [221])
    }
}
