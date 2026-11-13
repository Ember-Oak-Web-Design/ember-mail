import Foundation

/// A parsed IMAP response value.
indirect enum IMAPValue: Equatable {
    case atom(String)
    case string(Data)   // quoted string or literal
    case list([IMAPValue])
    case null

    /// Atom or string contents as text.
    var text: String? {
        switch self {
        case .atom(let s): s
        case .string(let d): d.lenientString
        default: nil
        }
    }

    var data: Data? {
        switch self {
        case .string(let d): d
        case .atom(let s): Data(s.utf8)
        default: nil
        }
    }

    var list: [IMAPValue]? {
        if case .list(let l) = self { return l }
        return nil
    }
}

/// Tokenizes an IMAP response line where literals ({n}\r\n<bytes>) are inlined.
struct IMAPTokenizer {
    private let bytes: [UInt8]
    private var i = 0

    init(_ data: Data) { bytes = [UInt8](data) }

    static func parse(_ data: Data) -> [IMAPValue] {
        var t = IMAPTokenizer(data)
        return t.parseSequence(untilClose: false)
    }

    private mutating func skipSpaces() {
        while i < bytes.count, bytes[i] == 32 { i += 1 }
    }

    private mutating func parseSequence(untilClose: Bool) -> [IMAPValue] {
        var values: [IMAPValue] = []
        while true {
            skipSpaces()
            guard i < bytes.count else { break }
            if bytes[i] == 41 { // ')'
                if untilClose { i += 1 }
                else { i += 1; continue }
                break
            }
            if bytes[i] == 13 || bytes[i] == 10 { i += 1; continue }
            if let v = parseValue() { values.append(v) } else { break }
        }
        return values
    }

    private mutating func parseValue() -> IMAPValue? {
        skipSpaces()
        guard i < bytes.count else { return nil }
        switch bytes[i] {
        case 40: // '('
            i += 1
            return .list(parseSequence(untilClose: true))
        case 34: // '"'
            i += 1
            var out = [UInt8]()
            while i < bytes.count, bytes[i] != 34 {
                if bytes[i] == 92, i + 1 < bytes.count { i += 1 } // backslash escape
                out.append(bytes[i])
                i += 1
            }
            i += 1 // closing quote
            return .string(Data(out))
        case 123: // '{'
            var j = i + 1
            var digits = ""
            while j < bytes.count, bytes[j] != 125 {
                if bytes[j] >= 48 && bytes[j] <= 57 { digits.append(Character(UnicodeScalar(bytes[j]))) }
                j += 1
            }
            j += 1 // '}'
            if j < bytes.count, bytes[j] == 13 { j += 1 }
            if j < bytes.count, bytes[j] == 10 { j += 1 }
            let count = Int(digits) ?? 0
            let end = min(bytes.count, j + count)
            i = end
            return .string(Data(bytes[j..<end]))
        default:
            var out = [UInt8]()
            var bracketDepth = 0
            while i < bytes.count {
                let b = bytes[i]
                if b == 91 { bracketDepth += 1 }
                if b == 93 { bracketDepth = max(0, bracketDepth - 1) }
                if bracketDepth == 0 && (b == 32 || b == 40 || b == 41 || b == 13 || b == 10) {
                    // "BODY[...]<0>" ends at a space; "(" after an atom only happens inside brackets.
                    break
                }
                out.append(b)
                i += 1
            }
            let s = String(decoding: out, as: UTF8.self)
            if s.uppercased() == "NIL" { return .null }
            return .atom(s)
        }
    }
}

/// Modified UTF-7 (RFC 3501 §5.1.3) used for IMAP mailbox names.
enum ModifiedUTF7 {
    static func decode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var result = ""
        var i = s.startIndex
        while i < s.endIndex {
            let ch = s[i]
            if ch == "&" {
                guard let dash = s[i...].firstIndex(of: "-") else { result += String(s[i...]); break }
                let encoded = s[s.index(after: i)..<dash]
                if encoded.isEmpty {
                    result += "&"
                } else {
                    var b64 = encoded.replacingOccurrences(of: ",", with: "/")
                    while b64.count % 4 != 0 { b64 += "=" }
                    if let data = Data(base64Encoded: b64), let decoded = String(data: data, encoding: .utf16BigEndian) {
                        result += decoded
                    } else {
                        result += String(s[i...dash])
                    }
                }
                i = s.index(after: dash)
            } else {
                result.append(ch)
                i = s.index(after: i)
            }
        }
        return result
    }

    static func encode(_ s: String) -> String {
        var result = ""
        var pending = ""
        func flush() {
            guard !pending.isEmpty else { return }
            let data = pending.data(using: .utf16BigEndian) ?? Data()
            let b64 = data.base64EncodedString().replacingOccurrences(of: "/", with: ",").replacingOccurrences(of: "=", with: "")
            result += "&\(b64)-"
            pending = ""
        }
        for scalar in s.unicodeScalars {
            if scalar.value >= 0x20 && scalar.value <= 0x7e {
                flush()
                result += scalar == "&" ? "&-" : String(scalar)
            } else {
                pending.unicodeScalars.append(scalar)
            }
        }
        flush()
        return result
    }
}
