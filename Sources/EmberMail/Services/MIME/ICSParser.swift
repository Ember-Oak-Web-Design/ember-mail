import Foundation

/// A meeting invite read from an iCalendar (.ics / text/calendar) part.
struct InviteEvent: Equatable, Sendable {
    var uid: String?
    var title: String
    var start: Date
    /// For all-day events this is the last day (inclusive), not iCalendar's exclusive end.
    var end: Date
    var allDay: Bool
    var location: String
    var notes: String
    var organizer: EmailAddress?
    /// REQUEST (invite / update), CANCEL, PUBLISH, REPLY…
    var method: String
    var isCancelled: Bool { method == "CANCEL" || status == "CANCELLED" }
    var status: String = ""
}

/// Minimal RFC 5545 reader: first VEVENT, with line unfolding, text unescaping, TZID / UTC / floating
/// times, VALUE=DATE all-day events, DURATION, and VTIMEZONE offsets for non-IANA zone names (Outlook).
enum ICSParser {
    private struct Property {
        var name: String
        var params: [String: String]
        var value: String
    }

    static func parse(_ text: String) -> InviteEvent? {
        let props = unfold(text).compactMap(parseLine)
        let method = props.first { $0.name == "METHOD" }?.value.uppercased() ?? "PUBLISH"

        // Collect VTIMEZONE standard offsets (TZID → seconds), used when TZID isn't a known identifier.
        var zoneOffsets: [String: Int] = [:]
        var currentZone: String?
        var inStandard = false
        var eventProps: [Property] = []
        var depth: [String] = []
        for p in props {
            if p.name == "BEGIN" { depth.append(p.value.uppercased()); if p.value.uppercased() == "STANDARD" { inStandard = true }; continue }
            if p.name == "END" {
                if p.value.uppercased() == "STANDARD" { inStandard = false }
                if p.value.uppercased() == "VEVENT", !eventProps.isEmpty { depth.removeLast(); break }
                if !depth.isEmpty { depth.removeLast() }
                continue
            }
            if depth.last == "VTIMEZONE" || depth.contains("VTIMEZONE") {
                if p.name == "TZID" { currentZone = p.value }
                if inStandard, p.name == "TZOFFSETTO", let zone = currentZone, zoneOffsets[zone] == nil, let off = offsetSeconds(p.value) {
                    zoneOffsets[zone] = off
                }
            } else if depth.last == "VEVENT" {
                eventProps.append(p)
            }
        }
        guard !eventProps.isEmpty else { return nil }
        func prop(_ name: String) -> Property? { eventProps.first { $0.name == name } }

        guard let startProp = prop("DTSTART"), let (start, allDay) = date(startProp, zones: zoneOffsets) else { return nil }
        var end: Date
        if let endProp = prop("DTEND"), let (e, _) = date(endProp, zones: zoneOffsets) {
            end = e
        } else if let dur = prop("DURATION").flatMap({ duration($0.value) }) {
            end = start.addingTimeInterval(dur)
        } else {
            end = allDay ? Calendar.current.date(byAdding: .day, value: 1, to: start)! : start.addingTimeInterval(3600)
        }
        if allDay {
            // iCalendar all-day ends are exclusive; we store the last day.
            end = max(start, Calendar.current.date(byAdding: .day, value: -1, to: end) ?? start)
        }
        if end < start { end = start }

        var organizer: EmailAddress?
        if let org = prop("ORGANIZER") {
            let email = org.value.replacingOccurrences(of: "mailto:", with: "", options: .caseInsensitive)
            organizer = EmailAddress(name: org.params["CN"].map(unquote), email: email)
        }

        return InviteEvent(
            uid: prop("UID")?.value,
            title: unescape(prop("SUMMARY")?.value ?? "").trimmingCharacters(in: .whitespaces).nilIfEmpty ?? "Untitled event",
            start: start, end: end, allDay: allDay,
            location: unescape(prop("LOCATION")?.value ?? ""),
            notes: cleanNotes(unescape(prop("DESCRIPTION")?.value ?? "")),
            organizer: organizer,
            method: method,
            status: prop("STATUS")?.value.uppercased() ?? "")
    }

    // MARK: Lines

    private static func unfold(_ text: String) -> [String] {
        var lines: [String] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n") {
            if let first = raw.first, first == " " || first == "\t", !lines.isEmpty {
                lines[lines.count - 1] += raw.dropFirst()
            } else if !raw.isEmpty {
                lines.append(raw)
            }
        }
        return lines
    }

    /// NAME;PARAM=a;PARAM2="b:c":value. Colons inside quoted params don't end the name part.
    private static func parseLine(_ line: String) -> Property? {
        var inQuotes = false
        var splitIndex: String.Index?
        for i in line.indices {
            let c = line[i]
            if c == "\"" { inQuotes.toggle() }
            if c == ":" && !inQuotes { splitIndex = i; break }
        }
        guard let colon = splitIndex else { return nil }
        let head = String(line[..<colon])
        let value = String(line[line.index(after: colon)...])
        var parts = head.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty else { return nil }
        let name = parts.removeFirst().uppercased()
        var params: [String: String] = [:]
        for p in parts {
            let kv = p.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { params[kv[0].uppercased()] = kv[1] }
        }
        return Property(name: name, params: params, value: value)
    }

    private static func unquote(_ s: String) -> String { s.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }

    static func unescape(_ s: String) -> String {
        var out = ""
        var it = s.makeIterator()
        while let c = it.next() {
            guard c == "\\" else { out.append(c); continue }
            switch it.next() {
            case "n", "N": out.append("\n")
            case let next?: out.append(next)   // \\ \, \;
            case nil: out.append("\\")
            }
        }
        return out
    }

    /// Drops Google's "-::~:~::~" invitation boilerplate and trims.
    private static func cleanNotes(_ s: String) -> String {
        var text = s
        if let r = text.range(of: "-::~") { text = String(text[..<r.lowerBound]) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Dates

    private static func date(_ p: Property, zones: [String: Int]) -> (Date, Bool)? {
        let v = p.value.trimmingCharacters(in: .whitespaces)
        if p.params["VALUE"]?.uppercased() == "DATE" || (v.count == 8 && !v.contains("T")) {
            let f = formatter("yyyyMMdd", TimeZone.current)
            return f.date(from: String(v.prefix(8))).map { ($0, true) }
        }
        if v.hasSuffix("Z") {
            return formatter("yyyyMMdd'T'HHmmss", TimeZone(identifier: "UTC")!).date(from: String(v.dropLast())).map { ($0, false) }
        }
        var zone = TimeZone.current
        if let tzid = p.params["TZID"].map(unquote) {
            if let tz = TimeZone(identifier: tzid) { zone = tz }
            else if let off = zones[tzid], let tz = TimeZone(secondsFromGMT: off) { zone = tz }
            else if let tz = windowsZones[tzid].flatMap(TimeZone.init(identifier:)) { zone = tz }
        }
        return formatter("yyyyMMdd'T'HHmmss", zone).date(from: String(v.prefix(15))).map { ($0, false) }
    }

    private static func formatter(_ format: String, _ zone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = zone
        f.dateFormat = format
        return f
    }

    /// "+0200" / "-0530" → seconds.
    private static func offsetSeconds(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count >= 5, let sign = t.first, sign == "+" || sign == "-",
              let h = Int(t.dropFirst().prefix(2)), let m = Int(t.dropFirst(3).prefix(2)) else { return nil }
        return (sign == "-" ? -1 : 1) * (h * 3600 + m * 60)
    }

    /// "PT1H30M", "P1D", "-PT15M" → seconds.
    private static func duration(_ s: String) -> TimeInterval? {
        var total = 0.0, num = "", inTime = false
        let negative = s.hasPrefix("-")
        for c in s.uppercased() {
            switch c {
            case "P", "+", "-": continue
            case "T": inTime = true
            case "W": total += (Double(num) ?? 0) * 604800; num = ""
            case "D": total += (Double(num) ?? 0) * 86400; num = ""
            case "H": total += (Double(num) ?? 0) * 3600; num = ""
            case "M": total += (Double(num) ?? 0) * (inTime ? 60 : 2_592_000); num = ""
            case "S": total += Double(num) ?? 0; num = ""
            default: num.append(c)
            }
        }
        return total > 0 ? (negative ? -total : total) : nil
    }

    /// Common Outlook (Windows) zone names that arrive without a VTIMEZONE block.
    private static let windowsZones: [String: String] = [
        "South Africa Standard Time": "Africa/Johannesburg",
        "GMT Standard Time": "Europe/London",
        "W. Europe Standard Time": "Europe/Berlin",
        "Romance Standard Time": "Europe/Paris",
        "Central Europe Standard Time": "Europe/Budapest",
        "E. Europe Standard Time": "Europe/Bucharest",
        "Eastern Standard Time": "America/New_York",
        "Central Standard Time": "America/Chicago",
        "Mountain Standard Time": "America/Denver",
        "Pacific Standard Time": "America/Los_Angeles",
        "AUS Eastern Standard Time": "Australia/Sydney",
        "India Standard Time": "Asia/Kolkata",
        "Singapore Standard Time": "Asia/Singapore",
        "Tokyo Standard Time": "Asia/Tokyo",
        "UTC": "UTC",
    ]
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
