import SwiftUI

/// Inspector next to the inbox: what's on today and tomorrow.
struct TodayPanel: View {
    @Environment(AppState.self) private var app
    @State private var selected: CalendarEvent?

    var body: some View {
        let store = app.calendar
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Date().formatted(.dateTime.weekday(.wide)).uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                    Text(Date().formatted(.dateTime.day().month(.wide)))
                        .font(.title2.weight(.bold))
                }

                if !store.hasGoogleAccount {
                    Text("Connect a Google account to see your schedule here.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    let upcoming = store.upcoming
                    section("Today", events: upcoming.today, empty: "Nothing else today 🎉")
                    section("Tomorrow", events: upcoming.tomorrow, empty: "Nothing scheduled")
                }

                if let next = nextMeeting {
                    NextUpCard(event: next)
                }

                Button {
                    app.selection = .calendar
                } label: {
                    Label("Open Calendar", systemImage: "calendar")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(16)
        }
        .task { await store.ensureLoaded() }
    }

    private var nextMeeting: CalendarEvent? {
        let soon = Date().addingTimeInterval(30 * 60)
        return app.calendar.visibleEvents
            .filter { !$0.isAllDay && $0.meetURL != nil && $0.end > Date() && $0.start < soon }
            .min { $0.start < $1.start }
    }

    @ViewBuilder
    private func section(_ title: String, events: [CalendarEvent], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            let visible = title == "Today" ? events.filter { $0.isAllDay || $0.end > Date() } : events
            if visible.isEmpty {
                Text(empty).font(.callout).foregroundStyle(.tertiary)
            }
            ForEach(visible) { event in
                TodayEventRow(event: event)
                    .onTapGesture { selected = event }
                    .popover(isPresented: Binding(get: { selected?.id == event.id }, set: { if !$0 { selected = nil } }),
                             arrowEdge: .leading) {
                        EventDetail(event: event)
                    }
            }
        }
    }
}

private struct TodayEventRow: View {
    let event: CalendarEvent

    var body: some View {
        let isNow = event.start <= Date() && event.end > Date() && !event.isAllDay
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(hex: event.colorHex))
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.callout.weight(.medium)).lineLimit(2)
                HStack(spacing: 4) {
                    Text(Format.timeRange(event))
                    if isNow { Text("· now").foregroundStyle(Theme.accent).fontWeight(.semibold) }
                }
                .font(.caption).foregroundStyle(.secondary)
                if let location = event.location, !location.isEmpty {
                    Text(location).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if event.meetURL != nil {
                Image(systemName: "video.fill").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(isNow ? Theme.accent.opacity(0.1) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
    }
}

private struct NextUpCard: View {
    let event: CalendarEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(event.start > Date() ? "Starting \(Format.relative(event.start))" : "Happening now",
                  systemImage: "bell.badge.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))
            Text(event.title).font(.headline).foregroundStyle(.white).lineLimit(2)
            if let meet = event.meetURL {
                Link(destination: meet) {
                    Label("Join", systemImage: "video.fill")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(.white, in: Capsule())
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [Theme.accent, Theme.oak], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 12))
    }
}
