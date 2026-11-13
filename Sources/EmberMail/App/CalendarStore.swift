import Foundation
import Observation

enum CalendarMode: String, CaseIterable, Identifiable {
    case day = "Day", week = "Week", month = "Month"
    var id: String { rawValue }
}

@MainActor
@Observable
final class CalendarStore {
    var calendars: [CalendarInfo] = []
    var events: [CalendarEvent] = []
    var mode: CalendarMode = .week
    var focusDate = Date()
    var isLoading = false
    var error: String?
    var hiddenCalendarIDs: Set<String> {
        didSet { UserDefaults.standard.set(Array(hiddenCalendarIDs), forKey: "hiddenCalendars") }
    }

    private var loadedRange: ClosedRange<Date>?
    private var accountIDs: [UUID] = []

    init() {
        hiddenCalendarIDs = Set(UserDefaults.standard.stringArray(forKey: "hiddenCalendars") ?? [])
    }

    var hasGoogleAccount: Bool { !accountIDs.isEmpty }

    var visibleEvents: [CalendarEvent] {
        events.filter { !hiddenCalendarIDs.contains($0.calendarKey) }
    }

    func calendar(for event: CalendarEvent) -> CalendarInfo? {
        calendars.first { $0.id == event.calendarKey }
    }

    func events(on day: Date) -> [CalendarEvent] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        let end = cal.date(byAdding: .day, value: 1, to: start)!
        return visibleEvents
            .filter { $0.start < end && $0.end > start || ($0.start == $0.end && $0.start >= start && $0.start < end) }
            .sorted { ($0.isAllDay ? 0 : 1, $0.start) < ($1.isAllDay ? 0 : 1, $1.start) }
    }

    /// Range shown for the current mode.
    var visibleDays: [Date] {
        let cal = Calendar.current
        switch mode {
        case .day:
            return [cal.startOfDay(for: focusDate)]
        case .week:
            let start = cal.dateInterval(of: .weekOfYear, for: focusDate)?.start ?? focusDate
            return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
        case .month:
            return monthGridDays
        }
    }

    /// Always 42 days (6 weeks) around the focus month, whatever the current mode. The month grid
    /// indexes into this, so it must not shrink when switching to Day view (that crashed).
    var monthGridDays: [Date] {
        let cal = Calendar.current
        let monthStart = cal.dateInterval(of: .month, for: focusDate)?.start ?? focusDate
        let gridStart = cal.dateInterval(of: .weekOfYear, for: monthStart)?.start ?? monthStart
        return (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: gridStart) }
    }

    var title: String {
        switch mode {
        case .day: focusDate.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
        case .week, .month: focusDate.formatted(.dateTime.month(.wide).year())
        }
    }

    func step(_ direction: Int) {
        let cal = Calendar.current
        let component: Calendar.Component = mode == .day ? .day : (mode == .week ? .weekOfYear : .month)
        focusDate = cal.date(byAdding: component, value: direction, to: focusDate) ?? focusDate
        Task { await ensureLoaded() }
    }

    func goToToday() {
        focusDate = Date()
        Task { await ensureLoaded() }
    }

    // MARK: Loading

    func configure(accounts: [Account]) {
        let ids = accounts.filter { $0.kind == .google }.map(\.id)
        if ids != accountIDs {
            accountIDs = ids
            loadedRange = nil
            calendars = []
            events = []
        }
    }

    func ensureLoaded() async {
        let days = visibleDays
        guard let first = days.first, let last = days.last else { return }
        if let loaded = loadedRange, loaded.contains(first), loaded.contains(last) { return }
        await reload()
    }

    func reload() async {
        guard !accountIDs.isEmpty else { return }
        let cal = Calendar.current
        // Load the focus month plus a week either side so all modes and the Today panel are covered.
        let monthStart = cal.dateInterval(of: .month, for: focusDate)?.start ?? focusDate
        var from = cal.date(byAdding: .day, value: -8, to: monthStart)!
        var to = cal.date(byAdding: .day, value: 45, to: monthStart)!
        let today = cal.startOfDay(for: Date())
        from = min(from, today)
        to = max(to, cal.date(byAdding: .day, value: 8, to: today)!)

        isLoading = true
        defer { isLoading = false }
        var newCalendars: [CalendarInfo] = []
        var newEvents: [CalendarEvent] = []
        var firstError: String?
        for accountID in accountIDs {
            do {
                let cals = try await GoogleCalendarService.calendars(for: accountID)
                newCalendars += cals
                try await withThrowingTaskGroup(of: [CalendarEvent].self) { group in
                    for c in cals {
                        group.addTask { (try? await GoogleCalendarService.events(for: c, from: from, to: to)) ?? [] }
                    }
                    for try await list in group { newEvents += list }
                }
            } catch {
                firstError = firstError ?? error.localizedDescription
            }
        }
        calendars = newCalendars
        events = newEvents
        error = firstError
        loadedRange = from...to
    }

    func create(title: String, start: Date, end: Date, allDay: Bool, location: String, notes: String, calendar: CalendarInfo) async throws {
        try await GoogleCalendarService.createEvent(in: calendar, title: title, start: start, end: end,
                                                    allDay: allDay, location: location, notes: notes)
        loadedRange = nil
        await reload()
    }

    /// Upcoming events for the Today panel: rest of today + tomorrow.
    var upcoming: (today: [CalendarEvent], tomorrow: [CalendarEvent]) {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Date())!
        return (events(on: Date()), events(on: tomorrow))
    }
}
