import Foundation

/// One node in a parsed MIME tree.
struct MIMEPart {
    /// Header names are lowercased; values are unfolded but not RFC 2047 decoded.
    var headers: [(name: String, value: String)]
    /// Raw body bytes, still transfer-encoded.
    var rawBody: Data
    var children: [MIMEPart] = []

    func header(_ name: String) -> String? {
        let lower = name.lowercased()
        return headers.first(where: { $0.name == lower })?.value
    }

    func headerValues(_ name: String) -> [String] {
        let lower = name.lowercased()
        return headers.filter { $0.name == lower }.map(\.value)
    }

    /// Decoded (RFC 2047) header value.
    func decodedHeader(_ name: String) -> String? {
        header(name).map(RFC2047.decode)
    }

    var contentType: (type: String, params: [String: String]) {
        guard let raw = header("content-type") else { return ("text/plain", [:]) }
        let parsed = MIMEParser.parseParameterized(raw)
        return (parsed.value.lowercased(), parsed.params)
    }

    var contentDisposition: (type: String, params: [String: String])? {
        guard let raw = header("content-disposition") else { return nil }
        let parsed = MIMEParser.parseParameterized(raw)
        return (parsed.value.lowercased(), parsed.params)
    }

    var isMultipart: Bool { contentType.type.hasPrefix("multipart/") }

    var filename: String? {
        if let name = contentDisposition?.params["filename"], !name.isEmpty { return RFC2047.decode(name) }
        if let name = contentType.params["name"], !name.isEmpty { return RFC2047.decode(name) }
        return nil
    }

    var isAttachment: Bool {
        if isMultipart { return false }
        if contentDisposition?.type == "attachment" { return true }
        let type = contentType.type
        if type == "text/plain" || type == "text/html" { return filename != nil && contentDisposition?.type != "inline" }
        return filename != nil || !type.hasPrefix("text/")
    }

    /// Body with transfer encoding removed.
    var decodedBody: Data {
        let encoding = header("content-transfer-encoding")?.trimmingCharacters(in: .whitespaces).lowercased() ?? "7bit"
        switch encoding {
        case "base64": return TransferEncoding.decodeBase64(rawBody)
        case "quoted-printable": return TransferEncoding.decodeQuotedPrintable(rawBody)
        default: return rawBody
        }
    }

    /// Decoded body as text using the declared charset.
    var text: String {
        let data = decodedBody
        let charset = contentType.params["charset"]
        return Charset.string(from: data, charset: charset)
    }

    /// Depth-first list of all leaf parts.
    var leaves: [MIMEPart] {
        if children.isEmpty { return [self] }
        return children.flatMap(\.leaves)
    }
}

enum MIMEParser {
    static func parse(_ data: Data) -> MIMEPart {
        let bytes = [UInt8](data)
        let (headerEnd, bodyStart) = findHeaderEnd(bytes)
        let headerData = Data(bytes[0..<headerEnd])
        let body = bodyStart < bytes.count ? Data(bytes[bodyStart...]) : Data()
        var part = MIMEPart(headers: parseHeaders(headerData), rawBody: body)
        let type = part.contentType
        if type.type.hasPrefix("multipart/"), let boundary = type.params["boundary"], !boundary.isEmpty {
            part.children = splitMultipart(body, boundary: boundary).map(parse)
        } else if type.type == "message/rfc822" {
            part.children = [parse(part.decodedBody)]
        }
        return part
    }

    /// Returns (end of header block, start of body).
    private static func findHeaderEnd(_ bytes: [UInt8]) -> (Int, Int) {
        var i = 0
        // A message that starts with a blank line has no headers.
        if bytes.starts(with: [13, 10]) { return (0, 2) }
        if bytes.starts(with: [10]) { return (0, 1) }
        while i < bytes.count {
            if bytes[i] == 10 {
                if i + 1 < bytes.count, bytes[i + 1] == 10 { return (i, i + 2) }
                if i + 2 < bytes.count, bytes[i + 1] == 13, bytes[i + 2] == 10 { return (i, i + 3) }
            }
            i += 1
        }
        return (bytes.count, bytes.count)
    }

    static func parseHeaders(_ data: Data) -> [(name: String, value: String)] {
        let text = data.lenientString
        var result: [(String, String)] = []
        var currentName: String?
        var currentValue = ""
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if line.isEmpty { continue }
            if let first = line.first, first == " " || first == "\t" {
                currentValue += " " + line.trimmingCharacters(in: .whitespaces)
                continue
            }
            if let name = currentName { result.append((name, currentValue)) }
            if let colon = line.firstIndex(of: ":") {
                currentName = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                currentValue = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            } else {
                currentName = nil
                currentValue = ""
            }
        }
        if let name = currentName { result.append((name, currentValue)) }
        return result
    }

    /// Splits a multipart body. Tolerates a missing closing boundary (truncated messages).
    static func splitMultipart(_ body: Data, boundary: String) -> [Data] {
        let bytes = [UInt8](body)
        let delimiter = [UInt8](("--" + boundary).utf8)
        var starts: [(lineStart: Int, contentStart: Int, isClose: Bool)] = []
        var i = 0
        var atLineStart = true
        while i < bytes.count {
            if atLineStart, bytes.count - i >= delimiter.count, Array(bytes[i..<(i + delimiter.count)]) == delimiter {
                var j = i + delimiter.count
                let isClose = j + 1 < bytes.count && bytes[j] == 45 && bytes[j + 1] == 45
                // skip to end of line
                while j < bytes.count, bytes[j] != 10 { j += 1 }
                starts.append((i, min(j + 1, bytes.count), isClose))
                if isClose { break }
                i = j + 1
                atLineStart = true
                continue
            }
            atLineStart = bytes[i] == 10
            i += 1
        }
        var parts: [Data] = []
        for (index, start) in starts.enumerated() where !start.isClose {
            var end = index + 1 < starts.count ? starts[index + 1].lineStart : bytes.count
            // strip the CRLF that belongs to the next delimiter line
            if end > start.contentStart, bytes[end - 1] == 10 { end -= 1 }
            if end > start.contentStart, bytes[end - 1] == 13 { end -= 1 }
            if end > start.contentStart {
                parts.append(Data(bytes[start.contentStart..<end]))
            } else {
                parts.append(Data())
            }
        }
        return parts
    }

    /// Parses `value; key=val; key2="quoted"` including RFC 2231 `key*=utf-8''...` and continuations.
    static func parseParameterized(_ raw: String) -> (value: String, params: [String: String]) {
        var segments: [String] = []
        var current = ""
        var inQuotes = false
        for ch in raw {
            if ch == "\"" { inQuotes.toggle() }
            if ch == ";" && !inQuotes {
                segments.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        segments.append(current)
        let value = segments.first?.trimmingCharacters(in: .whitespaces) ?? ""
        var params: [String: String] = [:]
        var continuations: [String: [(Int, String, Bool)]] = [:]
        for segment in segments.dropFirst() {
            guard let eq = segment.firstIndex(of: "=") else { continue }
            var key = segment[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var val = segment[segment.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if val.hasPrefix("\""), val.hasSuffix("\""), val.count >= 2 {
                val = String(val.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
            }
            var extended = false
            if key.hasSuffix("*") {
                extended = true
                key.removeLast()
            }
            if let star = key.firstIndex(of: "*"), let n = Int(key[key.index(after: star)...]) {
                let base = String(key[..<star])
                continuations[base, default: []].append((n, val, extended))
                continue
            }
            params[key] = extended ? decodeRFC2231(val, first: true) : val
        }
        for (base, pieces) in continuations {
            let joined = pieces.sorted { $0.0 < $1.0 }.enumerated().map { idx, piece in
                piece.2 ? decodeRFC2231(piece.1, first: idx == 0) : piece.1
            }.joined()
            params[base] = joined
        }
        return (value, params)
    }

    private static func decodeRFC2231(_ value: String, first: Bool) -> String {
        var charset = "utf-8"
        var encoded = value
        if first {
            let parts = value.components(separatedBy: "'")
            if parts.count >= 3 {
                charset = parts[0].isEmpty ? "utf-8" : parts[0]
                encoded = parts[2...].joined(separator: "'")
            }
        }
        var bytes: [UInt8] = []
        var iterator = Array(encoded.utf8).makeIterator()
        while let b = iterator.next() {
            if b == 37, let h1 = iterator.next(), let h2 = iterator.next(),
               let v = UInt8(String(bytes: [h1, h2], encoding: .ascii) ?? "", radix: 16) {
                bytes.append(v)
            } else {
                bytes.append(b)
            }
        }
        return Charset.string(from: Data(bytes), charset: charset)
    }
}

// MARK: - Transfer encodings

enum TransferEncoding {
    static func decodeBase64(_ data: Data) -> Data {
        // Keep only base64 alphabet, then trim to a multiple of 4 so truncated input still decodes.
        var filtered = [UInt8]()
        filtered.reserveCapacity(data.count)
        for b in data {
            if (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || (b >= 48 && b <= 57) || b == 43 || b == 47 || b == 61 {
                filtered.append(b)
            }
        }
        if let firstPad = filtered.firstIndex(of: 61) {
            // Drop anything after padding of the first block that ends with '='.
            let end = min(filtered.count, ((firstPad / 4) + 1) * 4)
            filtered = Array(filtered[0..<end])
            while filtered.count % 4 != 0 { filtered.append(61) }
        } else {
            filtered = Array(filtered[0..<(filtered.count - filtered.count % 4)])
        }
        return Data(base64Encoded: Data(filtered)) ?? Data()
    }

    static func decodeQuotedPrintable(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var out = [UInt8]()
        out.reserveCapacity(bytes.count)
        var i = 0
        func hex(_ b: UInt8) -> UInt8? {
            switch b {
            case 48...57: return b - 48
            case 65...70: return b - 55
            case 97...102: return b - 87
            default: return nil
            }
        }
        while i < bytes.count {
            let b = bytes[i]
            if b == 61 { // '='
                if i + 1 < bytes.count, bytes[i + 1] == 10 { i += 2; continue }
                if i + 2 < bytes.count, bytes[i + 1] == 13, bytes[i + 2] == 10 { i += 3; continue }
                if i + 2 < bytes.count, let h = hex(bytes[i + 1]), let l = hex(bytes[i + 2]) {
                    out.append(h << 4 | l)
                    i += 3
                    continue
                }
                if i + 2 >= bytes.count { break } // truncated "=" or "=X" at the end of partial data
            }
            out.append(b)
            i += 1
        }
        return Data(out)
    }

    /// Quoted-printable encoder producing CRLF line endings and lines ≤ 76 chars.
    static func encodeQuotedPrintable(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var outLines: [String] = []
        for line in normalized.components(separatedBy: "\n") {
            let bytes = Array(line.utf8)
            var encoded = ""
            var lineLength = 0
            for (index, b) in bytes.enumerated() {
                let isLast = index == bytes.count - 1
                var token: String
                if (b == 32 || b == 9) && isLast {
                    token = String(format: "=%02X", b)
                } else if (b >= 33 && b <= 126 && b != 61) || b == 32 || b == 9 {
                    token = String(UnicodeScalar(b))
                } else {
                    token = String(format: "=%02X", b)
                }
                if lineLength + token.count > 75 {
                    encoded += "=\r\n"
                    lineLength = 0
                }
                encoded += token
                lineLength += token.count
            }
            outLines.append(encoded)
        }
        return outLines.joined(separator: "\r\n")
    }
}

// MARK: - Charsets

enum Charset {
    static func encoding(for charset: String?) -> String.Encoding? {
        guard var name = charset?.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).lowercased(), !name.isEmpty else { return nil }
        if name == "utf8" { name = "utf-8" }
        if name == "ks_c_5601-1987" { name = "euc-kr" }
        let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    static func string(from data: Data, charset: String?) -> String {
        let enc = encoding(for: charset)
        if enc == nil || enc == .utf8 {
            if let s = String(data: data, encoding: .utf8) { return s }
            // Truncated previews often cut a multi-byte character in half: drop the partial tail.
            let trimmed = trimIncompleteUTF8(data)
            if let s = String(data: trimmed, encoding: .utf8) { return s }
            // Mostly-valid UTF-8 (declared or not): decode leniently rather than producing mojibake.
            if enc == .utf8 || isMostlyUTF8(data) { return String(decoding: trimmed, as: UTF8.self) }
        } else if let enc, let s = String(data: data, encoding: enc) {
            return s
        }
        if let s = String(data: data, encoding: .windowsCP1252) { return s }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    private static func trimIncompleteUTF8(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { return data }
        var i = bytes.count - 1
        var continuation = 0
        while i >= 0 && bytes[i] & 0xC0 == 0x80 && continuation < 3 { i -= 1; continuation += 1 }
        guard i >= 0 else { return data }
        let lead = bytes[i]
        let needed = lead >= 0xF0 ? 3 : lead >= 0xE0 ? 2 : lead >= 0xC0 ? 1 : 0
        return needed > continuation ? Data(bytes[0..<i]) : data
    }

    private static func isMostlyUTF8(_ data: Data) -> Bool {
        let decoded = String(decoding: data, as: UTF8.self)
        let replacements = decoded.unicodeScalars.filter { $0 == "\u{FFFD}" }.count
        return replacements <= max(2, decoded.unicodeScalars.count / 200)
    }
}

// MARK: - RFC 2047 encoded words

enum RFC2047 {
    static func decode(_ input: String) -> String {
        guard input.contains("=?") else { return input }
        let pattern = #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
        let ns = input as NSString
        var result = ""
        var lastEnd = 0
        var lastWasEncoded = false
        for match in regex.matches(in: input, range: NSRange(location: 0, length: ns.length)) {
            let between = ns.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
            // Whitespace between adjacent encoded words is dropped.
            if !(lastWasEncoded && between.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                result += between
            }
            var charset = ns.substring(with: match.range(at: 1))
            if let star = charset.firstIndex(of: "*") { charset = String(charset[..<star]) } // RFC 2231 language
            let mode = ns.substring(with: match.range(at: 2)).uppercased()
            let payload = ns.substring(with: match.range(at: 3))
            let data: Data
            if mode == "B" {
                data = TransferEncoding.decodeBase64(Data(payload.utf8))
            } else {
                data = TransferEncoding.decodeQuotedPrintable(Data(payload.replacingOccurrences(of: "_", with: " ").utf8))
            }
            result += Charset.string(from: data, charset: charset)
            lastEnd = match.range.location + match.range.length
            lastWasEncoded = true
        }
        result += ns.substring(from: lastEnd)
        return result
    }

    /// Encodes a header value if it contains non-ASCII, splitting into multiple encoded words.
    static func encodeIfNeeded(_ value: String) -> String {
        if value.unicodeScalars.allSatisfy({ $0.isASCII }) { return value }
        var words: [String] = []
        var chunk = ""
        for ch in value {
            if (chunk + String(ch)).utf8.count > 45 {
                words.append(chunk)
                chunk = ""
            }
            chunk.append(ch)
        }
        if !chunk.isEmpty { words.append(chunk) }
        return words.map { "=?UTF-8?B?\(Data($0.utf8).base64EncodedString())?=" }.joined(separator: "\r\n ")
    }
}

// MARK: - HTML helpers

enum HTMLText {
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        let named = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'",
                     "&apos;": "'", "&rsquo;": "\u{2019}", "&lsquo;": "\u{2018}", "&rdquo;": "\u{201D}",
                     "&ldquo;": "\u{201C}", "&ndash;": "\u{2013}", "&mdash;": "\u{2014}", "&hellip;": "\u{2026}",
                     "&zwnj;": "", "&copy;": "\u{00A9}", "&reg;": "\u{00AE}", "&trade;": "\u{2122}", "&euro;": "\u{20AC}"]
        for (k, v) in named { out = out.replacingOccurrences(of: k, with: v) }
        if let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") {
            let ns = out as NSString
            var result = ""
            var last = 0
            for m in regex.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let isHex = m.range(at: 1).length > 0
                let digits = ns.substring(with: m.range(at: 2))
                if let code = UInt32(digits, radix: isHex ? 16 : 10), let scalar = UnicodeScalar(code) {
                    result.unicodeScalars.append(scalar)
                }
                last = m.range.location + m.range.length
            }
            result += ns.substring(from: last)
            out = result
        }
        return out
    }

    static func toPlainText(_ html: String) -> String {
        var s = html
        let replacements: [(String, String)] = [
            ("(?s)<!--.*?(-->|$)", ""),
            ("(?is)<(script|style|head|title)[^>]*>.*?(</\\1>|$)", ""),
            ("(?i)<br\\s*/?>", "\n"),
            ("(?i)</(p|div|tr|h[1-6]|li|blockquote)>", "\n"),
            ("(?s)<[^>]+>", ""),
        ]
        for (pattern, template) in replacements {
            s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        s = decodeEntities(s)
        s = s.replacingOccurrences(of: "[ \\t\\u{00A0}]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\n\\s*\\n\\s*\\n+", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func looksLikeCSS(_ line: String) -> Bool {
        line.range(of: #"^[^{}]{0,120}\{[^}]*:[^}]*\}?\s*$"#, options: .regularExpression) != nil
            || line.hasPrefix("/*") || line.hasPrefix("@media") || line.hasPrefix("@import")
    }

    /// Converts plain text to simple HTML with links and line breaks.
    static func fromPlainText(_ text: String) -> String {
        let escaped = escape(text)
        let linked = escaped.replacingOccurrences(
            of: #"(https?://[^\s<]+[^\s<.,;:!?)\]'"])"#,
            with: "<a href=\"$1\">$1</a>",
            options: .regularExpression)
        return linked.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "<br>\n")
    }

    /// Zero-width / preheader padding characters that marketing emails stuff into previews.
    static func removeInvisible(_ s: String) -> String {
        let invisible: Set<UInt32> = [0x034F, 0x00AD, 0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF, 0x180E, 0x2007, 0x2028, 0x2029]
        var out = String.UnicodeScalarView()
        for scalar in s.unicodeScalars where !invisible.contains(scalar.value) {
            out.append(scalar.value == 0x00A0 ? " " : scalar)
        }
        return String(out)
    }

    /// Short one-line preview text.
    static func snippet(from text: String, limit: Int = 180) -> String {
        let lines = removeInvisible(text).components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix(">") && !Self.looksLikeCSS($0) }
        let joined = lines.joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return String(joined.prefix(limit))
    }
}
