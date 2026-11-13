import AppKit
import QuickLookUI
import SwiftUI

struct ReaderContainer: View {
    @Environment(AppState.self) private var app

    var body: some View {
        if app.hasMultiSelection {
            MultiSelectionView()
        } else if let message = app.selectedMessage {
            ReaderView(message: message)
                .id(message.id)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "envelope.open")
                    .font(.system(size: 46, weight: .ultraLight))
                    .foregroundStyle(.tertiary)
                Text("Select a message")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background)
        }
    }
}

/// Conversation view: every message in the thread as an ordered, expandable card.
/// Shown instead of the reader while several conversations are selected.
struct MultiSelectionView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let ids = app.selectedGroupIDs
        VStack(spacing: 18) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(Theme.accent)
            Text("\(ids.count) conversations selected")
                .font(.title2.weight(.semibold))
            HStack(spacing: 10) {
                Button { app.bulk(.markRead, ids: ids) } label: { Label("Mark Read", systemImage: "envelope.open") }
                Button { app.bulk(.markUnread, ids: ids) } label: { Label("Mark Unread", systemImage: "envelope.badge") }
                Button { app.bulk(.toggleFlag, ids: ids) } label: { Label("Flag", systemImage: "flag") }
            }
            HStack(spacing: 10) {
                Button { app.bulk(.archive, ids: ids) } label: { Label("Archive", systemImage: "archivebox") }
                Button(role: .destructive) { app.bulk(.trash, ids: ids) } label: { Label("Delete", systemImage: "trash") }
            }
            Button("Deselect All") { app.selectedGroupIDs = [] }
                .buttonStyle(.link)
            Text("Shift-click for a range · ⌘-click to pick individual conversations · hold Shift and drag to marquee-select")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .controlSize(.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

struct ReaderView: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow
    let message: MessageSummary

    @State private var expanded: Set<String> = []

    private var thread: [MessageSummary] { app.conversation(for: message) }
    private var latest: MessageSummary { thread.last ?? message }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        subjectHeader
                        ForEach(Array(thread.enumerated()), id: \.element.id) { index, item in
                            MessageCard(message: item,
                                        position: index + 1,
                                        total: thread.count,
                                        isExpanded: expanded.contains(item.id)) {
                                withAnimation(.snappy(duration: 0.2)) {
                                    if expanded.contains(item.id) { expanded.remove(item.id) } else { expanded.insert(item.id) }
                                }
                            }
                            .id(item.id)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
                .onAppear { resetExpansion() }
                .onChange(of: thread.map(\.id)) {
                    resetExpansion()
                    if thread.count > 2, let last = thread.last {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            withAnimation { proxy.scrollTo(last.id, anchor: .top) }
                        }
                    }
                }
            }
        }
        .background(.background)
    }

    /// Latest message open, plus any unread ones; older messages collapsed.
    private func resetExpansion() {
        var ids = Set(thread.filter { !$0.isRead }.map(\.id))
        if let last = thread.last { ids.insert(last.id) }
        ids.insert(message.id)
        expanded = ids
    }

    private var subjectHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message.subject.isEmpty ? "(No subject)" : Subject.normalize(message.subject).isEmpty ? message.subject : Subject.normalize(message.subject))
                .font(.system(size: 21, weight: .semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if thread.count > 1 {
                    Pill(text: "\(thread.count) messages", symbol: "bubble.left.and.bubble.right", color: .secondary)
                }
                if let account = app.account(message.accountID), app.accounts.count > 1 {
                    Pill(text: account.label, color: Theme.accountColor(account.colorIndex))
                }
                if let reminder = app.schedule.reminder(for: message) {
                    Pill(text: reminder.isDue ? "Reply now" : "Remind \(QuickTimes.label(reminder.fireAt))",
                         symbol: "bell.fill", color: reminder.isDue ? .red : .orange)
                }
                if app.loadingThreads.contains(message.id) {
                    ProgressView().controlSize(.mini)
                    Text("Loading conversation…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.bottom, 6)
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            if app.isDraft(message) {
                Button {
                    Task {
                        if let draft = await app.resumeDraft(message) {
                            openWindow(id: "compose", value: draft)
                        }
                    }
                } label: {
                    Label("Edit Draft", systemImage: "square.and.pencil")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .padding(.trailing, 6)
            }
            ActionButton("Reply", symbol: "arrowshape.turn.up.left") {
                openWindow(id: "compose", value: app.replyDraft(latest, all: false))
            }
            ActionButton("Reply All", symbol: "arrowshape.turn.up.left.2") {
                openWindow(id: "compose", value: app.replyDraft(latest, all: true))
            }
            ActionButton("Forward", symbol: "arrowshape.turn.up.right") {
                openWindow(id: "compose", value: app.forwardDraft(latest))
            }
            Divider().frame(height: 18).padding(.horizontal, 4)
            ActionButton("Archive", symbol: "archivebox") { app.archiveConversation(message) }
            ActionButton("Trash", symbol: "trash") { app.trashConversation(message) }
            Spacer()
            RemindMenu(message: message)
            ActionButton(message.isRead ? "Mark Unread" : "Mark Read",
                         symbol: message.isRead ? "envelope.badge" : "envelope.open") {
                app.setRead(!message.isRead, message)
            }
            ActionButton(message.isFlagged ? "Unflag" : "Flag",
                         symbol: message.isFlagged ? "flag.fill" : "flag",
                         tint: message.isFlagged ? .orange : nil) {
                app.setFlagged(!message.isFlagged, message)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

/// One message within a conversation.
struct MessageCard: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow
    @AppStorage(Prefs.loadRemoteImages) private var loadRemoteImages = true

    let message: MessageSummary
    let position: Int
    let total: Int
    let isExpanded: Bool
    let toggle: () -> Void

    @State private var bodyHeight: CGFloat = 80
    @State private var showQuoted = false
    @State private var hiddenQuotes = 0

    private var body_: MessageBody? { app.bodies[message.id] }
    private var isFromMe: Bool { app.ownAddresses.contains(message.from.email.lowercased()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                if let receipt = app.tracking.record(for: message) {
                    ReceiptBanner(receipt: receipt)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 10)
                }
                content
                if let attachments = body_?.attachments, !attachments.isEmpty {
                    AttachmentStrip(attachments: attachments)
                }
            }
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(isExpanded ? 0.10 : 0.06)))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task(id: isExpanded) {
            if isExpanded, app.bodies[message.id] == nil { await app.loadBody(message) }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(address: message.from, size: isExpanded ? 36 : 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(isFromMe ? "Me" : message.from.displayName)
                        .font(.system(size: 13, weight: message.isRead ? .semibold : .bold))
                    if isExpanded, message.from.name != nil {
                        Text(message.from.email).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if !message.isRead {
                        Circle().fill(Theme.accent).frame(width: 7, height: 7)
                    }
                }
                if isExpanded {
                    recipients
                } else {
                    Text(message.snippet.isEmpty ? " " : message.snippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 6) {
                    if message.hasAttachments || !(body_?.attachments.isEmpty ?? true) {
                        Image(systemName: "paperclip").font(.caption).foregroundStyle(.secondary)
                    }
                    if total > 1 {
                        Text("\(position)/\(total)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                    Text(isExpanded ? Format.fullDate(message.date) : Format.listDate(message.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if isExpanded {
                    HStack(spacing: 2) {
                        SmallIconButton("Reply", symbol: "arrowshape.turn.up.left") {
                            openWindow(id: "compose", value: app.replyDraft(message, all: false))
                        }
                        Menu {
                            Button("Reply All") { openWindow(id: "compose", value: app.replyDraft(message, all: true)) }
                            Button("Forward") { openWindow(id: "compose", value: app.forwardDraft(message)) }
                            Divider()
                            ReminderPresetButtons(message: message)
                        } label: {
                            Image(systemName: "ellipsis.circle").font(.system(size: 13))
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, isExpanded ? 12 : 9)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
    }

    private var recipients: some View {
        let to = body_?.to ?? message.to
        let cc = body_?.cc ?? message.cc
        return VStack(alignment: .leading, spacing: 1) {
            if !to.isEmpty {
                Text("To: ").foregroundStyle(.tertiary) + Text(to.map(\.displayName).joined(separator: ", "))
            }
            if !cc.isEmpty {
                Text("Cc: ").foregroundStyle(.tertiary) + Text(cc.map(\.displayName).joined(separator: ", "))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .textSelection(.enabled)
    }

    // MARK: Body

    @ViewBuilder
    private var content: some View {
        if let body = body_ {
            VStack(alignment: .leading, spacing: 0) {
                if let html = body.html, !html.isEmpty {
                    MessageBodyView(html: app.tracking.stripPixels(from: html), isPlainText: false,
                                    allowRemoteContent: loadRemoteImages, stripQuotes: !showQuoted,
                                    height: $bodyHeight, onQuotesHidden: { if !showQuoted { hiddenQuotes = $0 } })
                        .id(showQuoted)
                        .frame(height: bodyHeight)
                        .background(Color.white)
                } else {
                    let full = body.text ?? ""
                    let stripped = QuoteStripper.plain(full)
                    MessageBodyView(html: showQuoted ? full : stripped, isPlainText: true, allowRemoteContent: false,
                                    height: $bodyHeight)
                        .frame(height: bodyHeight)
                        .onAppear { hiddenQuotes = stripped == full ? 0 : 1 }
                }
                if hiddenQuotes > 0 || showQuoted {
                    Button {
                        showQuoted.toggle()
                    } label: {
                        Label(showQuoted ? "Hide quoted text" : "Show quoted text", systemImage: "ellipsis")
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.quaternary.opacity(0.6), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
            }
        } else if let error = app.bodyErrors[message.id] {
            VStack(alignment: .leading, spacing: 8) {
                Label("Couldn't load this message", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(error).font(.caption).foregroundStyle(.secondary)
                Button("Try Again") { Task { await app.loadBody(message) } }
            }
            .padding(14)
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(message.snippet).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            .padding(14)
        }
    }
}

private struct SmallIconButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    init(_ title: String, symbol: String, action: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.action = action
    }
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).frame(width: 22, height: 20)
        }
        .buttonStyle(.borderless)
        .help(title)
    }
}

private struct ActionButton: View {
    let title: String
    let symbol: String
    var tint: Color?
    let action: () -> Void

    init(_ title: String, symbol: String, tint: Color? = nil, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.action = action
    }

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .frame(width: 30, height: 26)
                .foregroundStyle(tint ?? .primary.opacity(0.75))
                .background(hovering ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(title)
        .accessibilityLabel(title)
    }
}

// MARK: - Read receipt banner

struct ReceiptBanner: View {
    let receipt: TrackedMessage
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: receipt.isOpened ? "eye.fill" : "eye.slash")
                        .foregroundStyle(receipt.isOpened ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(summary).font(.callout.weight(.medium))
                        if let last = receipt.lastOpen {
                            Text("Last opened \(Format.relative(last)) · \(last.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Sent \(Format.relative(receipt.sentAt)). We'll let you know when it's opened.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if !receipt.opens.isEmpty {
                        Image(systemName: "chevron.down")
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                OpenTimeline(opens: receipt.opens)
            }
        }
        .padding(12)
        .background((receipt.isOpened ? Color.green : Color.secondary).opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var summary: String {
        guard receipt.isOpened else { return "Not opened yet" }
        let n = receipt.opens.count
        if receipt.humanOpens.isEmpty { return "Possibly opened (\(n)× by Apple Mail Privacy Protection)" }
        return "Opened \(n == 1 ? "once" : "\(n) times")"
    }
}

struct OpenTimeline: View {
    let opens: [OpenEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(opens.reversed().enumerated()), id: \.offset) { _, open in
                HStack(spacing: 8) {
                    Circle().fill(open.automatic ? Color.orange : Color.green).frame(width: 6, height: 6)
                    Text(open.at.formatted(date: .abbreviated, time: .shortened)).monospacedDigit()
                    Text("·").foregroundStyle(.tertiary)
                    Text(open.client)
                    if let location = open.location {
                        Text("·").foregroundStyle(.tertiary)
                        Text(location)
                    }
                    if open.automatic {
                        Text("may be automatic").foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 28)
    }
}

// MARK: - Attachments

struct AttachmentStrip: View {
    let attachments: [AttachmentInfo]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { att in
                    AttachmentChip(attachment: att)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }
}

private struct AttachmentChip: View {
    let attachment: AttachmentInfo

    private var symbol: String {
        let t = attachment.mimeType
        if t.hasPrefix("image/") { return "photo" }
        if t == "application/pdf" { return "doc.richtext" }
        if t.contains("zip") { return "doc.zipper" }
        if t.contains("sheet") || t.contains("excel") || t.contains("csv") { return "tablecells" }
        if t.contains("presentation") || t.contains("powerpoint") { return "rectangle.on.rectangle" }
        if t.contains("word") || t.hasPrefix("text/") { return "doc.text" }
        if t == "text/calendar" { return "calendar" }
        return "doc"
    }

    var body: some View {
        Menu {
            Button("Open") { open() }
            Button("Save to Downloads") { save() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 0) {
                    Text(attachment.filename).font(.caption.weight(.medium)).lineLimit(1)
                    Text(attachment.sizeDescription).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        } primaryAction: {
            open()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func tempURL() -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("EmberMail-\(attachment.id.uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(attachment.filename.replacingOccurrences(of: "/", with: "-"))
        do { try attachment.data.write(to: url); return url } catch { return nil }
    }

    private func open() {
        if let url = tempURL() { NSWorkspace.shared.open(url) }
    }

    private func save() {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var url = downloads.appendingPathComponent(attachment.filename.replacingOccurrences(of: "/", with: "-"))
        var n = 1
        while FileManager.default.fileExists(atPath: url.path) {
            let base = (attachment.filename as NSString).deletingPathExtension
            let ext = (attachment.filename as NSString).pathExtension
            url = downloads.appendingPathComponent("\(base) \(n)\(ext.isEmpty ? "" : ".\(ext)")")
            n += 1
        }
        if (try? attachment.data.write(to: url)) != nil {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
