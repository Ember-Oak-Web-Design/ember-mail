import SwiftUI

struct CalendarView: View {
    @Environment(AppState.self) private var app
    @State private var showNewEvent = false
    @State private var newEventStart: Date?

    private var store: CalendarStore { app.calendar }

    var body: some View {
        @Bindable var store = app.calendar
        Group {
            if !store.hasGoogleAccount {
                ContentUnavailableView {
                    Label("Connect Google Calendar", systemImage: "calendar.badge.plus")
                } description: {
                    Text("Add your Google account in Settings → Accounts to see your calendar here.")
                } actions: {
                    SettingsLink { Text("Open Settings") }
                }
            } else {
                HStack(spacing: 0) {
                    CalendarSidebar()
                        .frame(width: 220)
                    Divider()
                    VStack(spacing: 0) {
                        switch store.mode {
                        case .day, .week:
                            TimeGridView(days: store.visibleDays) { date in
                                newEventStart = date
                                showNewEvent = true
                            }
                        case .month:
                            MonthGridView()
                        }
                    }
                }
            }
        }
        .background(.background)
        .navigationTitle(store.hasGoogleAccount ? store.title : "Calendar")
        .toolbar { if store.hasGoogleAccount { calendarToolbar } }
        .overlay(alignment: .bottom) {
            if let error = store.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).lineLimit(2)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 12)
            }
        }
        .task { await store.ensureLoaded() }
        .sheet(isPresented: $showNewEvent) {
            NewEventSheet(initialStart: newEventStart ?? Self.nextHalfHour())
        }
    }

    private static func nextHalfHour() -> Date {
        let cal = Calendar.current
        let now = Date()
        let minute = cal.component(.minute, from: now)
        let add = minute < 30 ? 30 - minute : 60 - minute
        return cal.date(byAdding: .minute, value: add, to: cal.date(bySetting: .second, value: 0, of: now) ?? now) ?? now
    }

    @ToolbarContentBuilder
    private var calendarToolbar: some ToolbarContent {
        let store = app.calendar
        ToolbarItemGroup(placement: .navigation) {
            ControlGroup {
                Button { store.step(-1) } label: { Image(systemName: "chevron.left") }
                    .help("Previous")
                Button("Today") { store.goToToday() }
                Button { store.step(1) } label: { Image(systemName: "chevron.right") }
                    .help("Next")
            }
        }
        ToolbarItem(placement: .principal) {
            Picker("View", selection: Binding(get: { store.mode }, set: { newMode in
                store.mode = newMode
                Task { await store.ensureLoaded() }
            })) {
                ForEach(CalendarMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if store.isLoading { ProgressView().controlSize(.small) }
            Button {
                Task { await store.reload() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Refresh calendar")
            Button {
                newEventStart = nil
                showNewEvent = true
            } label: {
                Label("New Event", systemImage: "plus")
            }
            .help("New event")
        }
    }
}

// MARK: - Sidebar: mini month + calendar toggles

private struct CalendarSidebar: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let store = app.calendar
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                MiniMonth(selected: store.focusDate) { date in
                    store.focusDate = date
                    Task { await store.ensureLoaded() }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("CALENDARS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(store.calendars) { cal in
                        Toggle(isOn: Binding(
                            get: { !store.hiddenCalendarIDs.contains(cal.id) },
                            set: { visible in
                                if visible { store.hiddenCalendarIDs.remove(cal.id) } else { store.hiddenCalendarIDs.insert(cal.id) }
                            })) {
                            Text(cal.name).lineLimit(1).font(.callout)
                        }
                        .toggleStyle(ColorCheckboxStyle(color: Color(hex: cal.colorHex)))
                    }
                }
            }
            .padding(16)
        }
        .background(.bar.opacity(0.5))
    }
}

private struct ColorCheckboxStyle: ToggleStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(configuration.isOn ? color : .clear)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(color, lineWidth: 1.5))
                    .overlay(Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white).opacity(configuration.isOn ? 1 : 0))
                    .frame(width: 15, height: 15)
                configuration.label
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct MiniMonth: View {
    let selected: Date
    let onSelect: (Date) -> Void
    @State private var month: Date = Date()

    private var days: [Date] {
        let cal = Calendar.current
        let start = cal.dateInterval(of: .month, for: month)?.start ?? month
        let gridStart = cal.dateInterval(of: .weekOfYear, for: start)?.start ?? start
        return (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: gridStart) }
    }

    var body: some View {
        let cal = Calendar.current
        VStack(spacing: 6) {
            HStack {
                Text(month.formatted(.dateTime.month(.wide).year())).font(.callout.weight(.semibold))
                Spacer()
                Button { month = cal.date(byAdding: .month, value: -1, to: month)! } label: { Image(systemName: "chevron.left") }
                Button { month = cal.date(byAdding: .month, value: 1, to: month)! } label: { Image(systemName: "chevron.right") }
            }
            .buttonStyle(.borderless)
            let symbols = cal.veryShortWeekdaySymbols
            let first = cal.firstWeekday - 1
            let ordered = Array(symbols[first...] + symbols[..<first])
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
                ForEach(Array(ordered.enumerated()), id: \.offset) { _, s in
                    Text(s).font(.caption2).foregroundStyle(.tertiary)
                }
                ForEach(days, id: \.self) { day in
                    let inMonth = cal.isDate(day, equalTo: month, toGranularity: .month)
                    let isToday = cal.isDateInToday(day)
                    let isSelected = cal.isDate(day, inSameDayAs: selected)
                    Button { onSelect(day) } label: {
                        Text("\(cal.component(.day, from: day))")
                            .font(.caption.monospacedDigit().weight(isToday ? .bold : .regular))
                            .frame(width: 24, height: 22)
                            .foregroundStyle(isToday ? .white : (inMonth ? Color.primary : Color.secondary.opacity(0.5)))
                            .background {
                                if isToday { Circle().fill(Theme.accent) }
                                else if isSelected { Circle().fill(Theme.accent.opacity(0.18)) }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .onAppear { month = selected }
        .onChange(of: selected) { month = selected }
    }
}

// MARK: - Day / week time grid

struct TimeGridView: View {
    @Environment(AppState.self) private var app
    let days: [Date]
    let onCreate: (Date) -> Void
    @State private var selectedEvent: CalendarEvent?

    private let hourHeight: CGFloat = 52
    private let gutter: CGFloat = 54

    var body: some View {
        let store = app.calendar
        VStack(spacing: 0) {
            // Day headers
            // Note: a bare Color.clear spacer here would stretch vertically and balloon this row.
            HStack(spacing: 0) {
                Spacer().frame(width: gutter, height: 1)
                ForEach(days, id: \.self) { day in
                    DayHeader(day: day)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 30)

            // All-day strip
            let allDay = days.map { day in store.events(on: day).filter(\.isAllDay) }
            if allDay.contains(where: { !$0.isEmpty }) {
                HStack(alignment: .top, spacing: 0) {
                    Text("all-day").font(.caption2).foregroundStyle(.secondary).frame(width: gutter)
                    ForEach(Array(days.enumerated()), id: \.offset) { index, _ in
                        VStack(spacing: 2) {
                            ForEach(allDay[index]) { event in
                                EventChip(event: event, selected: $selectedEvent)
                            }
                        }
                        .padding(.horizontal, 2)
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                }
                .padding(.bottom, 6)
            }
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    HStack(alignment: .top, spacing: 0) {
                        // Hour labels
                        VStack(spacing: 0) {
                            ForEach(0..<24, id: \.self) { hour in
                                Text(hourLabel(hour))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: gutter - 8, height: hourHeight, alignment: .topTrailing)
                                    .offset(y: -6)
                                    .id(hour)
                            }
                        }
                        .padding(.trailing, 8)

                        ForEach(days, id: \.self) { day in
                            DayColumn(day: day, events: store.events(on: day).filter { !$0.isAllDay },
                                      hourHeight: hourHeight, selectedEvent: $selectedEvent, onCreate: onCreate)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.top, 8)
                }
                .onAppear {
                    let hour = max(0, min(17, Calendar.current.component(.hour, from: Date()) - 2))
                    proxy.scrollTo(min(hour, 8), anchor: .top)
                }
            }
        }
    }

    private func hourLabel(_ hour: Int) -> String {
        guard hour > 0 else { return "" }
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(.dateTime.hour())
    }
}

private struct DayHeader: View {
    let day: Date
    var body: some View {
        let isToday = Calendar.current.isDateInToday(day)
        HStack(spacing: 5) {
            Text(day.formatted(.dateTime.weekday(.abbreviated)))
                .font(.caption.weight(.medium))
                .foregroundStyle(isToday ? Theme.accent : .secondary)
            Text(day.formatted(.dateTime.day()))
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(isToday ? .white : .primary)
                .frame(minWidth: 22, minHeight: 22)
                .background { if isToday { Circle().fill(Theme.accent) } }
        }
    }
}

private struct DayColumn: View {
    let day: Date
    let events: [CalendarEvent]
    let hourHeight: CGFloat
    @Binding var selectedEvent: CalendarEvent?
    let onCreate: (Date) -> Void

    var body: some View {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: day)
        let layout = Self.layout(events)
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // Hour lines (double-click empty space to create an event)
                VStack(spacing: 0) {
                    ForEach(0..<24, id: \.self) { hour in
                        Rectangle()
                            .fill(Color.clear)
                            .frame(height: hourHeight)
                            .overlay(alignment: .top) { Divider() }
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                onCreate(cal.date(byAdding: .hour, value: hour, to: dayStart) ?? dayStart)
                            }
                    }
                }
                Rectangle().fill(.quaternary.opacity(0.6)).frame(width: 0.5).frame(maxHeight: .infinity)

                ForEach(layout, id: \.event.id) { item in
                    let startMin = max(0, item.event.start.timeIntervalSince(dayStart) / 60)
                    let endMin = min(24 * 60, item.event.end.timeIntervalSince(dayStart) / 60)
                    let height = max(20, CGFloat(endMin - startMin) / 60 * hourHeight - 2)
                    let width = (geo.size.width - 6) / CGFloat(item.columns)
                    EventBlock(event: item.event, height: height, selected: $selectedEvent)
                        .frame(width: max(10, width - 2), height: height)
                        .offset(x: 3 + CGFloat(item.column) * width, y: CGFloat(startMin) / 60 * hourHeight + 1)
                }

                if cal.isDateInToday(day) {
                    let minutes = Date().timeIntervalSince(dayStart) / 60
                    HStack(spacing: 0) {
                        Circle().fill(.red).frame(width: 8, height: 8).offset(x: -4)
                        Rectangle().fill(.red).frame(height: 1.5)
                    }
                    .offset(y: CGFloat(minutes) / 60 * hourHeight - 4)
                    .allowsHitTesting(false)
                }
            }
        }
        .frame(height: hourHeight * 24)
    }

    struct Placed { var event: CalendarEvent; var column: Int; var columns: Int }

    /// Side-by-side layout for overlapping events.
    static func layout(_ events: [CalendarEvent]) -> [Placed] {
        let sorted = events.sorted { ($0.start, $1.end) < ($1.start, $0.end) }
        var result: [Placed] = []
        var cluster: [Placed] = []
        var clusterEnd = Date.distantPast
        var columnEnds: [Date] = []

        func flush() {
            let count = max(1, columnEnds.count)
            result += cluster.map { Placed(event: $0.event, column: $0.column, columns: count) }
            cluster = []
            columnEnds = []
        }
        for event in sorted {
            if event.start >= clusterEnd { flush() }
            if let free = columnEnds.firstIndex(where: { $0 <= event.start }) {
                columnEnds[free] = event.end
                cluster.append(Placed(event: event, column: free, columns: 1))
            } else {
                columnEnds.append(event.end)
                cluster.append(Placed(event: event, column: columnEnds.count - 1, columns: 1))
            }
            clusterEnd = max(clusterEnd, event.end)
        }
        flush()
        return result
    }
}

private struct EventBlock: View {
    let event: CalendarEvent
    let height: CGFloat
    @Binding var selected: CalendarEvent?

    var body: some View {
        let color = Color(hex: event.colorHex)
        let isPast = event.end < Date()
        VStack(alignment: .leading, spacing: 1) {
            Text(event.title)
                .font(.system(size: 11.5, weight: .semibold))
                .lineLimit(height > 40 ? 2 : 1)
            if height > 34 {
                Text(Format.timeRange(event)).font(.system(size: 10.5)).opacity(0.8)
            }
            if height > 60, let location = event.location {
                Text(location).font(.system(size: 10.5)).opacity(0.7).lineLimit(1)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(.primary)
        .background(color.opacity(isPast ? 0.18 : 0.28), in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 6).fill(color).frame(width: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { selected = event }
        .popover(isPresented: Binding(get: { selected?.id == event.id }, set: { if !$0 { selected = nil } }),
                 arrowEdge: .trailing) {
            EventDetail(event: event)
        }
    }
}

private struct EventChip: View {
    let event: CalendarEvent
    @Binding var selected: CalendarEvent?

    var body: some View {
        let color = Color(hex: event.colorHex)
        Text(event.title)
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(.white)
            .background(color, in: RoundedRectangle(cornerRadius: 4))
            .onTapGesture { selected = event }
            .popover(isPresented: Binding(get: { selected?.id == event.id }, set: { if !$0 { selected = nil } })) {
                EventDetail(event: event)
            }
    }
}

struct EventDetail: View {
    @Environment(AppState.self) private var app
    let event: CalendarEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(Color(hex: event.colorHex)).frame(width: 4, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title).font(.headline)
                    Text(event.isAllDay
                         ? event.start.formatted(date: .complete, time: .omitted)
                         : "\(event.start.formatted(date: .abbreviated, time: .omitted)) · \(Format.timeRange(event))")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if let cal = app.calendar.calendar(for: event) {
                Label(cal.name, systemImage: "calendar").font(.caption).foregroundStyle(.secondary)
            }
            if let location = event.location, !location.isEmpty {
                Label(location, systemImage: "mappin.and.ellipse").font(.callout).textSelection(.enabled)
            }
            if !event.attendees.isEmpty {
                Label("\(event.attendees.count) guests: " + event.attendees.prefix(4).map(\.shortName).joined(separator: ", ")
                      + (event.attendees.count > 4 ? "…" : ""), systemImage: "person.2")
                    .font(.callout).lineLimit(2)
            }
            if let notes = event.notes, !notes.isEmpty {
                ScrollView {
                    Text(notes).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
            }
            HStack {
                if let meet = event.meetURL {
                    Link(destination: meet) { Label("Join video call", systemImage: "video.fill") }
                        .buttonStyle(.borderedProminent)
                }
                Spacer()
                if let link = event.htmlLink {
                    Link("Open in Google Calendar", destination: link).font(.caption)
                }
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}

// MARK: - Month grid

struct MonthGridView: View {
    @Environment(AppState.self) private var app
    @State private var selectedEvent: CalendarEvent?

    var body: some View {
        let store = app.calendar
        let cal = Calendar.current
        let days = store.monthGridDays
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { i in
                    Text(days[i].formatted(.dateTime.weekday(.abbreviated)))
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 4)
            Divider()
            GeometryReader { geo in
                let rowHeight = geo.size.height / 6
                VStack(spacing: 0) {
                    ForEach(0..<6, id: \.self) { row in
                        HStack(spacing: 0) {
                            ForEach(0..<7, id: \.self) { col in
                                let day = days[row * 7 + col]
                                let events = store.events(on: day)
                                let maxShown = max(1, Int((rowHeight - 28) / 19))
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Spacer()
                                        let isToday = cal.isDateInToday(day)
                                        Text("\(cal.component(.day, from: day))")
                                            .font(.callout.monospacedDigit().weight(isToday ? .bold : .regular))
                                            .foregroundStyle(isToday ? .white : (cal.isDate(day, equalTo: store.focusDate, toGranularity: .month) ? Color.primary : Color.secondary.opacity(0.5)))
                                            .frame(minWidth: 24, minHeight: 22)
                                            .background { if isToday { Capsule().fill(Theme.accent) } }
                                    }
                                    ForEach(events.prefix(maxShown)) { event in
                                        MonthEventRow(event: event, selected: $selectedEvent)
                                    }
                                    if events.count > maxShown {
                                        Text("+\(events.count - maxShown) more").font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(4)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                .background(cal.isDateInWeekend(day) ? Color.primary.opacity(0.025) : .clear)
                                .overlay(alignment: .trailing) { Rectangle().fill(.quaternary).frame(width: 0.5) }
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) {
                                    store.focusDate = day
                                    store.mode = .day
                                }
                            }
                        }
                        .frame(height: rowHeight)
                        .overlay(alignment: .bottom) { Rectangle().fill(.quaternary).frame(height: 0.5) }
                    }
                }
            }
        }
    }
}

private struct MonthEventRow: View {
    let event: CalendarEvent
    @Binding var selected: CalendarEvent?

    var body: some View {
        let color = Color(hex: event.colorHex)
        HStack(spacing: 4) {
            if event.isAllDay {
                Text(event.title).foregroundStyle(.white)
            } else {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(event.start.formatted(date: .omitted, time: .shortened)).foregroundStyle(.secondary).monospacedDigit()
                Text(event.title)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .lineLimit(1)
        .padding(.horizontal, 4)
        .padding(.vertical, 1.5)
        .background(event.isAllDay ? color : .clear, in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture { selected = event }
        .popover(isPresented: Binding(get: { selected?.id == event.id }, set: { if !$0 { selected = nil } })) {
            EventDetail(event: event)
        }
    }
}

// MARK: - New event

struct NewEventSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let initialStart: Date

    @State private var title = ""
    @State private var start = Date()
    @State private var end = Date()
    @State private var allDay = false
    @State private var location = ""
    @State private var notes = ""
    @State private var calendarID: String?
    @State private var saving = false
    @State private var error: String?

    private var writable: [CalendarInfo] { app.calendar.calendars.filter(\.canWrite) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New Event").font(.title3.weight(.semibold)).padding([.horizontal, .top], 20)
            Form {
                TextField("Title", text: $title)
                Toggle("All day", isOn: $allDay)
                DatePicker("Starts", selection: $start, displayedComponents: allDay ? [.date] : [.date, .hourAndMinute])
                    .onChange(of: start) { old, new in end = end.addingTimeInterval(new.timeIntervalSince(old)) }
                DatePicker("Ends", selection: $end, in: start..., displayedComponents: allDay ? [.date] : [.date, .hourAndMinute])
                Picker("Calendar", selection: $calendarID) {
                    ForEach(writable) { cal in
                        Label {
                            Text(cal.name)
                        } icon: {
                            Image(systemName: "circle.fill").foregroundStyle(Color(hex: cal.colorHex))
                        }
                        .tag(Optional(cal.id))
                    }
                }
                TextField("Location", text: $location)
                TextField("Notes", text: $notes, axis: .vertical).lineLimit(3...6)
            }
            .formStyle(.grouped)
            if let error {
                Text(error).font(.caption).foregroundStyle(.orange).padding(.horizontal, 20)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button {
                    Task { await save() }
                } label: {
                    if saving { ProgressView().controlSize(.small) } else { Text("Add Event") }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || calendarID == nil || saving)
            }
            .padding(20)
        }
        .frame(width: 440)
        .onAppear {
            start = initialStart
            end = initialStart.addingTimeInterval(3600)
            calendarID = writable.first(where: \.isPrimary)?.id ?? writable.first?.id
        }
    }

    private func save() async {
        guard let cal = writable.first(where: { $0.id == calendarID }) else { return }
        saving = true
        do {
            try await app.calendar.create(title: title, start: start, end: end, allDay: allDay,
                                          location: location, notes: notes, calendar: cal)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        saving = false
    }
}
