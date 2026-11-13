import Foundation

enum AddressParser {
    /// Parses an address list header ("A <a@x>, \"B, Jr\" <b@x>, c@x").
    static func parseList(_ raw: String?) -> [EmailAddress] {
        guard let raw, !raw.isEmpty else { return [] }
        let decoded = RFC2047.decode(raw)
        var items: [String] = []
        var current = ""
        var inQuotes = false
        var angleDepth = 0
        for ch in decoded {
            switch ch {
            case "\"": inQuotes.toggle(); current.append(ch)
            case "<": angleDepth += 1; current.append(ch)
            case ">": angleDepth = max(0, angleDepth - 1); current.append(ch)
            case ",", ";":
                if inQuotes || angleDepth > 0 { current.append(ch) } else { items.append(current); current = "" }
            default: current.append(ch)
            }
        }
        items.append(current)
        return items.compactMap(parseSingle)
    }

    static func parseSingle(_ raw: String) -> EmailAddress? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        // Group syntax "Team: a@x, b@x;" — strip the group label.
        if let colon = s.firstIndex(of: ":"), !s.contains("<") || s.firstIndex(of: "<")! > colon,
           !s[..<colon].contains("@") {
            s = String(s[s.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        if let lt = s.lastIndex(of: "<"), let gt = s.lastIndex(of: ">"), lt < gt {
            let email = String(s[s.index(after: lt)..<gt]).trimmingCharacters(in: .whitespaces)
            var name = String(s[..<lt]).trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 { name = String(name.dropFirst().dropLast()) }
            name = name.replacingOccurrences(of: "\\\"", with: "\"")
            guard !email.isEmpty else { return nil }
            return EmailAddress(name: name, email: email)
        }
        // "a@x (Name)"
        if let open = s.firstIndex(of: "("), let close = s.lastIndex(of: ")"), open < close {
            let name = String(s[s.index(after: open)..<close])
            let email = String(s[..<open]).trimmingCharacters(in: .whitespaces)
            return EmailAddress(name: name, email: email)
        }
        guard s.contains("@") else { return nil }
        return EmailAddress(email: s.trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
    }

    /// Parses user-typed recipients ("a@x, Bob <b@x>").
    static func parseUserInput(_ text: String) -> [EmailAddress] {
        parseList(text).filter { $0.email.contains("@") }
    }

    /// Header-encoded single address.
    static func headerValue(_ address: EmailAddress) -> String {
        guard let name = address.name else { return address.email }
        if name.unicodeScalars.allSatisfy({ $0.isASCII }) {
            let needsQuotes = name.rangeOfCharacter(from: CharacterSet(charactersIn: "()<>[]:;@\\,.\"")) != nil
            let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return needsQuotes ? "\"\(escaped)\" <\(address.email)>" : "\(name) <\(address.email)>"
        }
        return "\(RFC2047.encodeIfNeeded(name)) <\(address.email)>"
    }

    static func headerValue(_ list: [EmailAddress]) -> String {
        list.map(headerValue).joined(separator: ",\r\n ")
    }
}

enum MailDate {
    private static let formats = [
        "EEE, d MMM yyyy HH:mm:ss Z",
        "d MMM yyyy HH:mm:ss Z",
        "EEE, d MMM yyyy HH:mm Z",
        "d MMM yyyy HH:mm Z",
        "EEE, d MMM yyyy HH:mm:ss zzz",
        "d MMM yyyy HH:mm:ss zzz",
        "EEE, d MMM yy HH:mm:ss Z",
        "dd-MMM-yyyy HH:mm:ss Z", // IMAP INTERNALDATE
    ]

    private static let formatters: [DateFormatter] = formats.map { format in
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = format
        return f
    }

    static func parse(_ raw: String?) -> Date? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        // Remove trailing comments like "(UTC)" or "(PST)".
        s = s.replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        for f in formatters {
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    static func rfc2822(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f.string(from: date)
    }
}
