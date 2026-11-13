import SwiftUI

// MARK: - Presets

enum TimePresets {
    static func reminders() -> [(String, Date)] {
        var items: [(String, Date)] = [("In 1 hour", QuickTimes.inHours(1)), ("In 3 hours", QuickTimes.inHours(3))]
        if let evening = QuickTimes.thisEvening { items.append(("This evening (6 pm)", evening)) }
        items.append(("Tomorrow morning (9 am)", QuickTimes.at(hour: 9, daysFromNow: 1)))
        items.append(("Tomorrow afternoon (2 pm)", QuickTimes.at(hour: 14, daysFromNow: 1)))
        items.append(("Next Monday (9 am)", QuickTimes.nextWeekday(2, hour: 9)))
        return items
    }

    static func sends() -> [(String, Date)] {
        var items: [(String, Date)] = [("In 1 hour", QuickTimes.inHours(1))]
        if let evening = QuickTimes.thisEvening { items.append(("This evening (6 pm)", evening)) }
        items.append(("Tomorrow morning (8 am)", QuickTimes.at(hour: 8, daysFromNow: 1)))
        items.append(("Tomorrow afternoon (1 pm)", QuickTimes.at(hour: 13, daysFromNow: 1)))
        items.append(("Monday morning (8 am)", QuickTimes.nextWeekday(2, hour: 8)))
        return items
    }
}

/// Reminder presets as plain buttons (usable inside menus and context menus).
struct ReminderPresetButtons: View {
    @Environment(AppState.self) private var app
    let message: MessageSummary

    var body: some View {
        if let existing = app.schedule.reminder(for: message) {
            Button("Cancel Reminder (\(QuickTimes.label(existing.fireAt)))") { app.schedule.cancelReminder(existing.id) }
        }
        Menu("Remind Me to Reply") {
            ForEach(TimePresets.reminders(), id: \.0) { label, date in
                Button(label) {
                    app.schedule.addReminder(for: message, at: date)
                    app.show("I'll remind you \(QuickTimes.label(date))")
                }
            }
        }
    }
}

/// Bell button with presets + custom time, used in the reader toolbar.
struct RemindMenu: View {
    @Environment(AppState.self) private var app
    let message: MessageSummary
    @State private var showCustom = false

    var body: some View {
        let reminder = app.schedule.reminder(for: message)
        Menu {
            if let reminder {
                Text("Reminder: \(QuickTimes.label(reminder.fireAt))")
                Button("Cancel Reminder") { app.schedule.cancelReminder(reminder.id) }
                Divider()
            }
            ForEach(TimePresets.reminders(), id: \.0) { label, date in
                Button(label) { set(date) }
            }
            Divider()
            Button("Pick a Date & Time…") { showCustom = true }
        } label: {
            Image(systemName: reminder == nil ? "bell" : "bell.badge.fill")
                .font(.system(size: 14))
                .foregroundStyle(reminder == nil ? AnyShapeStyle(.primary.opacity(0.75)) : AnyShapeStyle(Color.orange))
                .frame(width: 30, height: 26)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(reminder.map { "Reminder set for \(QuickTimes.label($0.fireAt))" } ?? "Remind me to reply")
        .sheet(isPresented: $showCustom) {
            DateTimePickerSheet(title: "Remind me to reply", subtitle: message.subject,
                                confirmTitle: "Set Reminder", initial: QuickTimes.at(hour: 9, daysFromNow: 1)) { date in
                set(date)
            }
        }
    }

    private func set(_ date: Date) {
        app.schedule.addReminder(for: message, at: date)
        app.show("I'll remind you \(QuickTimes.label(date))")
    }
}

struct DateTimePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    var subtitle: String?
    let confirmTitle: String
    let initial: Date
    let onConfirm: (Date) -> Void
    @State private var date = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.weight(.semibold))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            DatePicker("", selection: $date, in: Date()..., displayedComponents: [.date])
                .datePickerStyle(.graphical)
                .labelsHidden()
            DatePicker("Time", selection: $date, displayedComponents: [.hourAndMinute])
            HStack {
                Text(QuickTimes.label(date)).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(confirmTitle) {
                    onConfirm(date)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(date <= Date())
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear { date = initial }
    }
}

// MARK: - Scheduled & reminders page

struct ScheduledView: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow
    @State private var rescheduling: ScheduledSend?

    var body: some View {
        let store = app.schedule
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scheduled & Reminders").font(.title2.weight(.semibold))
                    Text("Scheduled emails are sent by Ember Mail, so keep it running (closing the window is fine). Reminders arrive even when it's closed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            Divider()

            if store.sends.isEmpty && store.reminders.isEmpty {
                ContentUnavailableView {
                    Label("Nothing scheduled", systemImage: "clock")
                } description: {
                    Text("Use “Send Later” in a new message, or the bell on any email to get a reminder to reply.")
                }
            } else {
                List {
                    if !store.sends.isEmpty {
                        Section("Scheduled emails") {
                            ForEach(store.pendingSends) { item in
                                ScheduledSendRow(item: item, reschedule: { rescheduling = item })
                            }
                        }
                    }
                    if !store.reminders.isEmpty {
                        Section("Reply reminders") {
                            ForEach(store.sortedReminders) { reminder in
                                ReminderRow(reminder: reminder)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .background(.background)
        .sheet(item: $rescheduling) { item in
            DateTimePickerSheet(title: "Reschedule", subtitle: item.draft.subject, confirmTitle: "Reschedule",
                                initial: max(item.sendAt, Date().addingTimeInterval(600))) { date in
                app.schedule.reschedule(item.id, to: date)
            }
        }
    }
}

private struct ScheduledSendRow: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow
    let item: ScheduledSend
    let reschedule: () -> Void
    @State private var sending = false

    var body: some View {
        let recipients = AddressParser.parseUserInput(item.draft.to + "," + item.draft.cc)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "paperplane.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.draft.subject.isEmpty ? "(No subject)" : item.draft.subject).font(.headline).lineLimit(1)
                Text("To " + recipients.map(\.displayName).joined(separator: ", ")).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 6) {
                    if let account = item.draft.accountID.flatMap({ app.account($0) }) { Text("From \(account.label)") }
                    if item.trackOpens { Label("Read receipt", systemImage: "eye").labelStyle(.titleAndIcon) }
                    if !item.draft.attachments.isEmpty { Label("\(item.draft.attachments.count)", systemImage: "paperclip") }
                }
                .font(.caption).foregroundStyle(.tertiary)
                if let error = item.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Pill(text: QuickTimes.label(item.sendAt), symbol: "clock", color: Theme.accent)
                HStack(spacing: 6) {
                    Button("Edit") {
                        app.schedule.cancelSend(item.id)
                        openWindow(id: "compose", value: item.draft)
                    }
                    Button("Change Time", action: reschedule)
                    Button(sending ? "Sending…" : "Send Now") {
                        Task {
                            sending = true
                            do {
                                try await app.send(item.draft, trackOpens: item.trackOpens, requestMDN: item.requestMDN)
                                app.schedule.cancelSend(item.id)
                            } catch {
                                app.show(error.localizedDescription, error: true)
                            }
                            sending = false
                        }
                    }
                    .disabled(sending)
                    Button(role: .destructive) { app.schedule.cancelSend(item.id) } label: { Image(systemName: "trash") }
                        .help("Cancel this scheduled email")
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct ReminderRow: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow
    let reminder: ReplyReminder

    var body: some View {
        let m = reminder.message
        HStack(alignment: .top, spacing: 12) {
            AvatarView(address: m.from, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(m.subject.isEmpty ? "(No subject)" : m.subject).font(.headline).lineLimit(1)
                Text("From \(m.from.displayName) · received \(Format.listDate(m.date))").font(.callout).foregroundStyle(.secondary)
                Text(m.snippet).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                if reminder.isDue {
                    Pill(text: "Due · \(QuickTimes.label(reminder.fireAt))", symbol: "bell.fill", color: .red)
                } else {
                    Pill(text: QuickTimes.label(reminder.fireAt), symbol: "bell", color: .orange)
                }
                HStack(spacing: 6) {
                    Button("Open") { app.reveal(m) }
                    Button("Reply") {
                        Task {
                            if app.bodies[m.id] == nil { await app.loadBody(m) }
                            openWindow(id: "compose", value: app.replyDraft(m, all: false))
                        }
                    }
                    Menu("Snooze") {
                        ForEach(TimePresets.reminders(), id: \.0) { label, date in
                            Button(label) { app.schedule.snooze(reminder.id, until: date) }
                        }
                    }
                    .fixedSize()
                    Button("Done") { app.schedule.cancelReminder(reminder.id) }
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 6)
    }
}
