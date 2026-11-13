import SwiftUI

struct MessageListView: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow

    private var title: String {
        switch app.selection {
        case .mailbox(let mb):
            let label = app.account(mb.accountID)?.label ?? ""
            return mb.role == .custom ? mb.name : "\(mb.name)\(label.isEmpty ? "" : " · \(label)")"
        default:
            return "All Inboxes"
        }
    }

    private var isUnified: Bool { app.selection == .allInboxes }

    @State private var showFilter = false

    var body: some View {
        @Bindable var app = app
        let groups = app.displayedGroups
        VStack(spacing: 0) {
            header(count: groups.count)
            filterBar
            if app.filter.isActive { activeFilterChips }
            Divider()
            if groups.isEmpty {
                emptyState
            } else {
                // Finder-style selection: click, ⌘-click (toggle), shift-click (range), shift-drag (marquee).
                List(selection: $app.selectedGroupIDs) {
                    ForEach(groups) { group in
                        row(for: group)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .contextMenu(forSelectionType: String.self) { ids in
                    contextMenuItems(for: ids)
                }
                .overlay {
                    MarqueeSelection(orderedIDs: { app.displayedGroups.map(\.id) },
                                     currentSelection: { app.selectedGroupIDs },
                                     onChange: { app.selectedGroupIDs = $0 })
                        .allowsHitTesting(false)
                }
                .onDeleteCommand {
                    if app.hasMultiSelection { app.bulk(.trash, ids: app.selectedGroupIDs) }
                    else if let m = app.selectedMessage { app.trashConversation(m) }
                }
                .safeAreaInset(edge: .bottom) {
                    if app.hasMultiSelection { bulkBar(groups: groups) }
                }
            }
        }
        .background(.background)
        .onChange(of: groups.map(\.id)) {
            // Drop multi-selected rows that are no longer in the list (archived, filtered out, …).
            if app.hasMultiSelection {
                app.selectedGroupIDs.formIntersection(Set(groups.map(\.id)))
            }
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func row(for group: AppState.ThreadGroup) -> some View {
        let message = group.latest
        let accountColor: Color? = isUnified ? app.account(message.accountID).map { Theme.accountColor($0.colorIndex) } : nil
        MessageRow(message: message,
                   count: group.messages.count,
                   isUnread: group.hasUnread,
                   isFlagged: group.isFlagged,
                   hasAttachments: group.hasAttachments,
                   accountColor: accountColor,
                   receipt: app.tracking.record(for: message),
                   reminder: app.schedule.reminder(for: message))
            .tag(message.id)
            .swipeActions(edge: .leading) { leadingSwipe(message) }
            .swipeActions(edge: .trailing) { trailingSwipe(message) }
    }

    @ViewBuilder
    private func leadingSwipe(_ message: MessageSummary) -> some View {
        Button {
            app.setRead(!message.isRead, message)
        } label: {
            Label(message.isRead ? "Unread" : "Read", systemImage: message.isRead ? "envelope.badge" : "envelope.open")
        }
        .tint(.blue)
    }

    @ViewBuilder
    private func trailingSwipe(_ message: MessageSummary) -> some View {
        Button(role: .destructive) {
            app.trashConversation(message)
        } label: {
            Label("Trash", systemImage: "trash")
        }
        Button {
            app.archiveConversation(message)
        } label: {
            Label("Archive", systemImage: "archivebox")
        }
        .tint(.purple)
    }

    // MARK: Filter bar

    private var filterBar: some View {
        HStack(spacing: 8) {
            Button {
                showFilter.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: app.filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    Text("Filter")
                    if app.filter.activeCount > 0 {
                        Text("\(app.filter.activeCount)")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 5)
                            .background(Theme.accent, in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
                .font(.callout.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(app.filter.isActive ? Theme.accent.opacity(0.14) : Color.primary.opacity(0.07), in: Capsule())
                .foregroundStyle(app.filter.isActive ? Theme.accent : .primary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showFilter, arrowEdge: .bottom) { FilterPopover() }
            .help("Filter this view")

            // One-click "all unread".
            Button {
                app.filter.unreadOnly.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: app.filter.unreadOnly ? "envelope.badge.fill" : "envelope.badge")
                    Text("Unread")
                    if app.isLoadingUnread { ProgressView().controlSize(.mini) }
                }
                .font(.callout.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(app.filter.unreadOnly ? Theme.accent : Color.primary.opacity(0.07), in: Capsule())
                .foregroundStyle(app.filter.unreadOnly ? Color.white : Color.primary)
            }
            .buttonStyle(.plain)
            .help("Show all unread mail in this view (fetched from the server, not just what's loaded)")

            Spacer()

        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private var activeFilterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                let f = app.filter
                if f.unreadOnly { chip("Unread") { app.filter.unreadOnly = false } }
                if f.flagged { chip("Flagged") { app.filter.flagged = false } }
                if f.hasAttachments { chip("Attachments") { app.filter.hasAttachments = false } }
                if f.hasReminder { chip("Has reminder") { app.filter.hasReminder = false } }
                if f.range != .any { chip(f.range.title) { app.filter.range = .any } }
                if f.receipt != .any { chip(f.receipt.title) { app.filter.receipt = .any } }
                if !f.trimmedPerson.isEmpty { chip("“\(f.trimmedPerson)”") { app.filter.person = "" } }
                Button("Clear all") { app.filter = MailFilter() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 8)
    }

    private func chip(_ text: String, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(text)
            Button(action: remove) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Theme.accent.opacity(0.14), in: Capsule())
    }

    // MARK: Bulk actions (several rows selected)

    private func runBulk(_ action: BulkAction) {
        app.bulk(action, ids: app.selectedGroupIDs)
    }

    private func bulkBar(groups: [AppState.ThreadGroup]) -> some View {
        let allPicked = !groups.isEmpty && app.selectedGroupIDs.count == groups.count
        return VStack(spacing: 0) {
            Divider()
            HStack(spacing: 4) {
                Button(allPicked ? "Select None" : "Select All") {
                    app.selectedGroupIDs = allPicked ? [] : Set(groups.map(\.id))
                }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(Theme.accent)
                Text("\(app.selectedGroupIDs.count) selected")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.leading, 6)
                Spacer()
                bulkButton("Read", "envelope.open", .markRead)
                bulkButton("Unread", "envelope.badge", .markUnread)
                bulkButton("Flag", "flag", .toggleFlag)
                bulkButton("Archive", "archivebox", .archive)
                bulkButton("Delete", "trash", .trash, destructive: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private func bulkButton(_ title: String, _ symbol: String, _ action: BulkAction, destructive: Bool = false) -> some View {
        Button { runBulk(action) } label: {
            VStack(spacing: 1) {
                Image(systemName: symbol).font(.system(size: 14))
                Text(title).font(.system(size: 9.5))
            }
            .frame(width: 46)
            .foregroundStyle(destructive ? AnyShapeStyle(Color.red) : AnyShapeStyle(Color.primary))
        }
        .buttonStyle(.plain)
        .help(title)
    }

    private func header(count: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Group {
                    if app.isSearching {
                        Text("Searching the server…")
                    } else if app.searchResults != nil {
                        Text("\(count) results on server")
                    } else if app.filter.unreadOnly && app.isLoadingUnread {
                        Text("Fetching all unread mail…")
                    } else if app.filter.isActive {
                        Text("\(count) \(count == 1 ? "conversation matches" : "conversations match") your filters")
                    } else if !app.searchText.isEmpty {
                        Text("\(count) matches · press Return to search the server")
                    } else {
                        let unread = app.displayedGroups.filter(\.hasUnread).count
                        Text(unread > 0 ? "\(unread) unread" : "All caught up")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if app.isLoadingList || app.isSearching {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            if app.isLoadingList || app.isLoadingUnread {
                ProgressView()
                Text(app.filter.unreadOnly ? "Fetching unread mail…" : "Loading messages…").foregroundStyle(.secondary)
            } else if app.filter.isActive {
                Image(systemName: app.filter.unreadOnly && !app.filter.hasLocalCriteria ? "checkmark.circle" : "line.3.horizontal.decrease.circle")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(app.filter.unreadOnly && !app.filter.hasLocalCriteria ? "No unread mail" : "Nothing matches these filters")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Button("Clear Filters") { app.filter = MailFilter() }
            } else {
                Image(systemName: app.searchText.isEmpty ? "tray" : "magnifyingglass")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(app.searchText.isEmpty ? "No messages" : "No matches")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// Right-click menu: acts on the whole selection when the clicked row is part of a multi-selection.
    @ViewBuilder
    private func contextMenuItems(for ids: Set<String>) -> some View {
        if ids.count > 1 {
            Button("Mark as Read") { app.bulk(.markRead, ids: ids) }
            Button("Mark as Unread") { app.bulk(.markUnread, ids: ids) }
            Button("Flag / Unflag") { app.bulk(.toggleFlag, ids: ids) }
            Divider()
            Button("Archive \(ids.count) Conversations") { app.bulk(.archive, ids: ids) }
            Button("Move \(ids.count) to Trash", role: .destructive) { app.bulk(.trash, ids: ids) }
        } else if let id = ids.first, let message = app.displayedGroups.first(where: { $0.id == id })?.latest {
            contextMenu(for: message)
        }
    }

    @ViewBuilder
    private func contextMenu(for message: MessageSummary) -> some View {
        Button("Reply") { openWindow(id: "compose", value: app.replyDraft(message, all: false)) }
        Button("Reply All") { openWindow(id: "compose", value: app.replyDraft(message, all: true)) }
        Button("Forward") { openWindow(id: "compose", value: app.forwardDraft(message)) }
        Divider()
        Button(message.isRead ? "Mark as Unread" : "Mark as Read") { app.setRead(!message.isRead, message) }
        Button(message.isFlagged ? "Unflag" : "Flag") { app.setFlagged(!message.isFlagged, message) }
        ReminderPresetButtons(message: message)
        Divider()
        Button("Archive") { app.archiveConversation(message) }
        Button("Move to Trash", role: .destructive) { app.trashConversation(message) }
    }
}

struct MessageRow: View {
    let message: MessageSummary
    var count: Int = 1
    var isUnread: Bool
    var isFlagged: Bool
    var hasAttachments: Bool
    var accountColor: Color?
    var receipt: TrackedMessage?
    var reminder: ReplyReminder?

    private var isSentByMe: Bool { receipt != nil }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack(alignment: .topLeading) {
                AvatarView(address: isSentByMe ? (message.to.first ?? message.from) : message.from, size: 36)
                if isUnread {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                        .offset(x: -3, y: -3)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let accountColor {
                        RoundedRectangle(cornerRadius: 1.5).fill(accountColor).frame(width: 3, height: 12)
                    }
                    Text(isSentByMe ? "To: \(message.to.first?.displayName ?? "")" : message.from.displayName)
                        .font(.system(size: 13, weight: isUnread ? .bold : .medium))
                        .lineLimit(1)
                    if count > 1 {
                        Text("\(count)")
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if let reminder {
                        Image(systemName: reminder.isDue ? "bell.badge.fill" : "bell.fill")
                            .font(.caption)
                            .foregroundStyle(reminder.isDue ? .red : .orange)
                            .help("Reminder: \(QuickTimes.label(reminder.fireAt))")
                    }
                    if hasAttachments {
                        Image(systemName: "paperclip").font(.caption).foregroundStyle(.secondary)
                    }
                    if isFlagged {
                        Image(systemName: "flag.fill").font(.caption).foregroundStyle(.orange)
                    }
                    Text(Format.listDate(message.date))
                        .font(.caption)
                        .foregroundStyle(isUnread ? Theme.accent : .secondary)
                        .monospacedDigit()
                }
                HStack(spacing: 6) {
                    Text(message.subject.isEmpty ? "(No subject)" : message.subject)
                        .font(.system(size: 12.5, weight: isUnread ? .semibold : .regular))
                        .lineLimit(1)
                    if let receipt { ReceiptLabel(receipt: receipt).layoutPriority(1) }
                    Spacer(minLength: 0)
                }
                Text(message.snippet)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

/// Read-receipt status shown next to a sent email's subject.
/// Green "Read" = the recipient opened it · orange "Maybe read" = only an automatic image load
/// (Apple Mail Privacy Protection) · small grey tick = delivered, not opened yet.
struct ReceiptLabel: View {
    let receipt: TrackedMessage

    var body: some View {
        if !receipt.isOpened {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)
                .help("Sent with a read receipt · not read yet")
        } else if receipt.humanOpens.isEmpty {
            label("Maybe read", symbol: "questionmark.circle.fill", color: .orange)
                .help("Loaded automatically by Apple Mail's privacy protection, so it may not have been read yet.")
        } else {
            let n = receipt.humanOpens.count
            label(n > 1 ? "Read ×\(n)" : "Read", symbol: "checkmark.circle.fill", color: .green)
                .help("Read \(Format.relative(receipt.humanOpens.map(\.at).max() ?? Date())) · \(Format.fullDate(receipt.humanOpens.map(\.at).max() ?? Date()))")
        }
    }

    private func label(_ text: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            Text(text)
        }
        .font(.system(size: 10.5, weight: .semibold))
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .foregroundStyle(color)
        .background(color.opacity(0.16), in: Capsule())
        .fixedSize()
    }
}

// MARK: - Filter popover

struct FilterPopover: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Filter").font(.headline)
                Spacer()
                if app.filter.isActive {
                    Button("Reset") { app.filter = MailFilter() }.buttonStyle(.link)
                }
            }

            Toggle(isOn: $app.filter.unreadOnly) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("All unread").font(.system(size: 13, weight: .semibold))
                    Text("Every unread message in this view, straight from the server")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .padding(10)
            .background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Flagged", isOn: $app.filter.flagged)
                Toggle("Has attachments", isOn: $app.filter.hasAttachments)
                Toggle("Has a reply reminder", isOn: $app.filter.hasReminder)
            }
            .toggleStyle(.checkbox)

            Divider()

            LabeledContent("Date") {
                Picker("", selection: $app.filter.range) {
                    ForEach(DateRange.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 150)
            }
            LabeledContent("Read receipt") {
                Picker("", selection: $app.filter.receipt) {
                    ForEach(ReceiptFilter.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 150)
            }
            LabeledContent("Person") {
                TextField("Name or email", text: $app.filter.person)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}
