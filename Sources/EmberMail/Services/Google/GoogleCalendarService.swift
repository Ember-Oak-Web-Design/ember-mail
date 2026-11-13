import Foundation

enum GoogleCalendarService {
    private static let base = "https://www.googleapis.com/calendar/v3"

    private static func request(_ accountID: UUID, _ path: String, method: String = "GET",
                                query: [URLQueryItem] = [], json: Any? = nil) async throws -> URLRequest {
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

    private static func encode(_ id: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id
    }

    private struct CalendarList: Decodable {
        struct Item: Decodable {
            var id: String
            var summary: String?
            var summaryOverride: String?
            var backgroundColor: String?
            var primary: Bool?
            var accessRole: String?
            var selected: Bool?
        }
        var items: [Item]?
    }

    private struct EventList: Decodable {
        struct Time: Decodable { var dateTime: String?; var date: String? }
        struct Attendee: Decodable { var email: String?; var displayName: String?; var `self`: Bool? }
        struct EntryPoint: Decodable { var entryPointType: String?; var uri: String? }
        struct Conference: Decodable { var entryPoints: [EntryPoint]? }
        struct Item: Decodable {
            var id: String
            var status: String?
            var summary: String?
            var description: String?
            var location: String?
            var start: Time?
            var end: Time?
            var hangoutLink: String?
            var htmlLink: String?
            var attendees: [Attendee]?
            var conferenceData: Conference?
        }
        var items: [Item]?
        var nextPageToken: String?
    }

    static func calendars(for accountID: UUID) async throws -> [CalendarInfo] {
        let list = try await HTTP.json(CalendarList.self, try await request(accountID, "/users/me/calendarList"))
        return (list.items ?? []).map { item in
            CalendarInfo(accountID: accountID,
                         calendarID: item.id,
                         name: item.summaryOverride ?? item.summary ?? item.id,
                         colorHex: item.backgroundColor ?? "#4285F4",
                         isPrimary: item.primary ?? false,
                         canWrite: item.accessRole == "owner" || item.accessRole == "writer")
        }.sorted { ($0.isPrimary ? 0 : 1, $0.name) < ($1.isPrimary ? 0 : 1, $1.name) }
    }

    static func events(for calendar: CalendarInfo, from: Date, to: Date) async throws -> [CalendarEvent] {
        let iso = ISO8601DateFormatter()
        var events: [CalendarEvent] = []
        var pageToken: String?
        repeat {
            var query: [URLQueryItem] = [
                .init(name: "timeMin", value: iso.string(from: from)),
                .init(name: "timeMax", value: iso.string(from: to)),
                .init(name: "singleEvents", value: "true"),
                .init(name: "orderBy", value: "startTime"),
                .init(name: "maxResults", value: "250"),
            ]
            if let pageToken { query.append(.init(name: "pageToken", value: pageToken)) }
            let path = "/calendars/\(encode(calendar.calendarID))/events"
            let list = try await HTTP.json(EventList.self, try await request(calendar.accountID, path, query: query))
            for item in list.items ?? [] where item.status != "cancelled" {
                guard let (start, allDay) = parse(item.start), let (end, _) = parse(item.end) else { continue }
                let meet = item.hangoutLink ?? item.conferenceData?.entryPoints?.first { $0.entryPointType == "video" }?.uri
                events.append(CalendarEvent(
                    id: "\(calendar.id)|\(item.id)",
                    accountID: calendar.accountID,
                    calendarKey: calendar.id,
                    title: item.summary ?? "(No title)",
                    start: start,
                    end: max(end, start),
                    isAllDay: allDay,
                    location: item.location,
                    notes: item.description.map(HTMLText.toPlainText),
                    meetURL: meet.flatMap(URL.init(string:)),
                    htmlLink: item.htmlLink.flatMap(URL.init(string:)),
                    colorHex: calendar.colorHex,
                    attendees: (item.attendees ?? []).compactMap { a in
                        a.email.map { EmailAddress(name: a.displayName, email: $0) }
                    }))
            }
            pageToken = list.nextPageToken
        } while pageToken != nil
        return events
    }

    private static func parse(_ time: EventList.Time?) -> (Date, Bool)? {
        guard let time else { return nil }
        if let dt = time.dateTime {
            let f = ISO8601DateFormatter()
            if let d = f.date(from: dt) { return (d, false) }
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: dt) { return (d, false) }
        }
        if let date = time.date {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = .current
            f.dateFormat = "yyyy-MM-dd"
            if let d = f.date(from: date) { return (d, true) }
        }
        return nil
    }

    static func createEvent(in calendar: CalendarInfo, title: String, start: Date, end: Date, allDay: Bool,
                            location: String?, notes: String?) async throws {
        var body: [String: Any] = ["summary": title]
        if allDay {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            let endDay = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: end)) ?? end
            body["start"] = ["date": f.string(from: start)]
            body["end"] = ["date": f.string(from: endDay)]
        } else {
            let iso = ISO8601DateFormatter()
            body["start"] = ["dateTime": iso.string(from: start), "timeZone": TimeZone.current.identifier]
            body["end"] = ["dateTime": iso.string(from: end), "timeZone": TimeZone.current.identifier]
        }
        if let location, !location.isEmpty { body["location"] = location }
        if let notes, !notes.isEmpty { body["description"] = notes }
        _ = try await HTTP.data(try await request(calendar.accountID, "/calendars/\(encode(calendar.calendarID))/events", method: "POST", json: body))
    }
}
