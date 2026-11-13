import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var app
    @Environment(\.openSettings) private var openSettings
    @State private var expandedFolders: Set<UUID> = []
    @AppStorage(Prefs.sidebarMode) private var mode = "all"
    @State private var choosingFoldersFor: Account?

    private var isSimple: Bool { mode == "simple" }

    var body: some View {
        @Bindable var app = app
        List(selection: $app.selection) {
            Section {
                Label {
                    HStack {
                        Text("All Inboxes")
                        Spacer()
                        if app.totalUnread > 0 { UnreadBadge(count: app.totalUnread) }
                    }
                } icon: {
                    Image(systemName: "tray.2.fill").foregroundStyle(Theme.accent)
                }
                .tag(SidebarItem.allInboxes)

                Label {
                    HStack {
                        Text("Scheduled")
                        Spacer()
                        let pending = app.schedule.sends.count
                        let due = app.schedule.dueReminderCount
                        if due > 0 {
                            Text("\(due)")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6).padding(.vertical, 1.5)
                                .background(Color.red, in: Capsule())
                                .foregroundStyle(.white)
                        } else if pending + app.schedule.reminders.count > 0 {
                            Text("\(pending + app.schedule.reminders.count)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: "clock.fill").foregroundStyle(.orange)
                }
                .tag(SidebarItem.scheduled)

                Label {
                    Text("Calendar")
                } icon: {
                    Image(systemName: "calendar").foregroundStyle(.red)
                }
                .tag(SidebarItem.calendar)
            }

            ForEach(app.accounts) { account in
                Section {
                    let boxes = app.mailboxes[account.id] ?? []
                    let primary = boxes.filter { $0.role != .custom }.sorted { $0.role.sortOrder < $1.role.sortOrder }
                    let custom = boxes.filter { $0.role == .custom }

                    if boxes.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Loading folders…").foregroundStyle(.secondary)
                        }
                    }

                    if isSimple {
                        let shown = app.simpleMailboxes(for: account.id)
                        ForEach(shown) { mailbox in
                            MailboxRow(mailbox: mailbox, unread: app.badgeCount(for: mailbox),
                                       isPoppedUp: !app.isInSimpleView(mailbox))
                                .tag(SidebarItem.mailbox(mailbox))
                                .contextMenu { simpleToggle(mailbox) }
                        }
                        if shown.isEmpty && !boxes.isEmpty {
                            Button("Choose folders…") { choosingFoldersFor = account }
                                .buttonStyle(.link)
                                .font(.caption)
                        }
                    } else {
                        ForEach(primary) { mailbox in
                            MailboxRow(mailbox: mailbox, unread: mailbox.role == .inbox ? app.unread[mailbox.id] : app.badgeCount(for: mailbox))
                                .tag(SidebarItem.mailbox(mailbox))
                                .contextMenu { simpleToggle(mailbox) }
                        }

                        if !custom.isEmpty {
                            DisclosureGroup(isExpanded: Binding(
                                get: { expandedFolders.contains(account.id) },
                                set: { if $0 { expandedFolders.insert(account.id) } else { expandedFolders.remove(account.id) } }
                            )) {
                                ForEach(custom) { mailbox in
                                    MailboxRow(mailbox: mailbox, unread: app.badgeCount(for: mailbox))
                                        .tag(SidebarItem.mailbox(mailbox))
                                        .contextMenu { simpleToggle(mailbox) }
                                }
                            } label: {
                                Label(account.kind == .google ? "Labels" : "Folders", systemImage: "folder")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    HStack(spacing: 6) {
                        Circle().fill(Theme.accountColor(account.colorIndex)).frame(width: 7, height: 7)
                        Text(account.label)
                        Spacer()
                    }
                    .help(account.email)
                    .contextMenu {
                        Button("Move Up") { withAnimation { app.moveAccount(account.id, by: -1) } }
                            .disabled(app.accounts.first?.id == account.id)
                        Button("Move Down") { withAnimation { app.moveAccount(account.id, by: 1) } }
                            .disabled(app.accounts.last?.id == account.id)
                        Divider()
                        Button("Choose Simple View Folders…") { choosingFoldersFor = account }
                        Button("Refresh Folders") { Task { await app.refreshMailboxes(account.id) } }
                        Button("Account Settings…") { openSettings() }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) {
            Picker("Sidebar", selection: $mode) {
                Text("All").tag("all")
                Text("Simple").tag("simple")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.top, 2)
            .padding(.bottom, 6)
            .help("Simple shows only the folders you choose, plus any folder with unread mail")
        }
        .safeAreaInset(edge: .bottom) { SyncFooter() }
        .onChange(of: mode) { Task { await app.refreshUnreadCounts() } }
        .sheet(item: $choosingFoldersFor) { account in
            SimpleFoldersSheet(account: account)
        }
    }

    @ViewBuilder
    private func simpleToggle(_ mailbox: Mailbox) -> some View {
        Toggle("Show in Simple View", isOn: Binding(
            get: { app.isInSimpleView(mailbox) },
            set: { app.setInSimpleView(mailbox, $0) }))
        if let account = app.account(mailbox.accountID) {
            Button("Choose Simple View Folders…") { choosingFoldersFor = account }
        }
    }
}

/// Checklist of an account's folders for the Simple view.
private struct SimpleFoldersSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let account: Account

    var body: some View {
        let boxes = (app.mailboxes[account.id] ?? []).sorted { ($0.role.sortOrder, $0.name) < ($1.role.sortOrder, $1.name) }
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Simple view: \(account.label)").font(.title3.weight(.semibold))
                Text("Choose the folders to always show. Other folders appear only while they have unread mail.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
            List {
                ForEach(boxes) { mailbox in
                    Toggle(isOn: Binding(get: { app.isInSimpleView(mailbox) }, set: { app.setInSimpleView(mailbox, $0) })) {
                        Label(mailbox.name, systemImage: mailbox.role.symbol)
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .listStyle(.inset)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 380, height: 480)
    }
}

private struct MailboxRow: View {
    let mailbox: Mailbox
    let unread: Int?
    /// A folder hidden in Simple view that's showing because it has unread mail.
    var isPoppedUp = false

    var body: some View {
        Label {
            HStack {
                Text(mailbox.name).lineLimit(1)
                Spacer()
                if let unread, unread > 0 { UnreadBadge(count: unread, highlighted: isPoppedUp) }
            }
        } icon: {
            Image(systemName: mailbox.role.symbol)
        }
        .help(isPoppedUp ? "Shown because it has unread mail. It hides again once everything is read." : "")
    }
}

struct UnreadBadge: View {
    let count: Int
    var highlighted = false
    var body: some View {
        Text(count > 999 ? "999+" : "\(count)")
            .font(.caption2.weight(.semibold).monospacedDigit())
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(highlighted ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.quaternary), in: Capsule())
            .foregroundStyle(highlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
    }
}

private struct SyncFooter: View {
    @Environment(AppState.self) private var app

    var body: some View {
        HStack(spacing: 6) {
            if app.isLoadingList {
                ProgressView().controlSize(.mini)
                Text("Checking mail…")
            } else if let last = app.lastSync {
                Image(systemName: "checkmark.circle")
                Text("Updated \(last.formatted(date: .omitted, time: .shortened))")
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
