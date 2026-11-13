import AppKit
import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @AppStorage(Prefs.showTodayPanel) private var showToday = false
    @State private var keyMonitor: Any?
    @State private var mainWindow = WindowBox()

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        } detail: {
            Group {
                if app.accounts.isEmpty {
                    WelcomeView()
                } else {
                    switch app.selection {
                    case .calendar:
                        CalendarView()
                    case .scheduled:
                        ScheduledView()
                    default:
                        MailBrowserView(showToday: $showToday)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .safeAreaInset(edge: .top, spacing: 0) { UpdateBar() }
        .overlay(alignment: .bottom) { BannerView() }
        // Sidebar and Today panel share the space: opening one closes the other.
        .onChange(of: showToday) {
            if showToday, columnVisibility != .detailOnly {
                withAnimation { columnVisibility = .detailOnly }
            }
        }
        .onChange(of: columnVisibility) {
            if columnVisibility != .detailOnly, showToday {
                withAnimation { showToday = false }
            }
        }
        .onAppear {
            if showToday { columnVisibility = .detailOnly }
            installKeyMonitor()
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .emberNotificationResponse)) { note in
            let info = note.userInfo?["info"] as? [AnyHashable: Any] ?? [:]
            let action = note.userInfo?["action"] as? String ?? ""
            Task {
                if let draft = await app.handleNotification(userInfo: info, action: action) {
                    openWindow(id: "compose", value: draft)
                }
            }
        }
        .onOpenURL { url in
            if url.scheme == "mailto" {
                openWindow(id: "compose", value: app.draft(fromMailto: url))
            }
        }
        .frame(minWidth: 960, minHeight: 600)
        .background(WindowAccessor { mainWindow.window = $0 })
    }
}

extension RootView {
    /// Single-key shortcuts (e.g. "e" to archive) can't be menu key equivalents, or they'd fire while typing.
    /// This monitor handles them only in the main window, and only when no text field has focus.
    fileprivate func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        let app = self.app
        let performer = MailActionPerformer(app: app, openWindow: openWindow)
        let mainWindow = self.mainWindow
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard !app.shortcuts.isRecording,
                  let window = event.window, window === mainWindow.window, window.isKeyWindow,
                  window.attachedSheet == nil,
                  !(window.firstResponder is NSText) else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard !flags.contains(.command), !flags.contains(.control), !flags.contains(.option) else { return event }
            guard let action = app.shortcuts.action(matching: event), !action.requiresModifier else { return event }
            guard performer.isAvailable(action) else { return event }
            performer.perform(action)
            return nil
        }
    }
}

final class WindowBox { weak var window: NSWindow? }

/// Reports the NSWindow hosting a SwiftUI view.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = WindowReportingView()
        view.onWindow = onWindow
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class WindowReportingView: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }
}

/// Toast-style banner for confirmations and errors.
struct BannerView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        if let banner = app.banner {
            HStack(spacing: 10) {
                Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(banner.isError ? .orange : .green)
                Text(banner.message)
                    .lineLimit(3)
                    .textSelection(.enabled)
                Button {
                    app.banner = nil
                } label: {
                    Image(systemName: "xmark").font(.caption.bold())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            .padding(.bottom, 22)
            .frame(maxWidth: 620)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(banner.id)
        }
    }
}

/// Mail list + reader, with the Today inspector.
struct MailBrowserView: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Binding var showToday: Bool

    var body: some View {
        @Bindable var app = app
        HSplitView {
            MessageListView()
                .frame(minWidth: 300, idealWidth: 370, maxWidth: 560)
            ReaderContainer()
                .frame(minWidth: 380, maxWidth: .infinity)
        }
        .searchable(text: $app.searchText, placement: .toolbar, prompt: "Search mail")
        .onSubmit(of: .search) { Task { await app.performServerSearch() } }
        .inspector(isPresented: $showToday) {
            TodayPanel()
                .inspectorColumnWidth(min: 230, ideal: 270, max: 340)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    openWindow(id: "compose", value: ComposeDraft(accountID: app.defaultAccountID()))
                } label: {
                    Label("New Message", systemImage: "square.and.pencil")
                }
                .help("New message (⌘N)")

                Button {
                    Task { await app.refreshAll() }
                } label: {
                    Label("Get Mail", systemImage: "arrow.clockwise")
                }
                .help("Check for new mail (⇧⌘N)")
                .disabled(app.isLoadingList)

                Button {
                    withAnimation { showToday.toggle() }
                } label: {
                    Label("Today", systemImage: "calendar.day.timeline.left")
                }
                .help(showToday ? "Hide today's calendar" : "Show today's calendar (hides the sidebar)")
            }
        }
    }
}


/// "Version x.y.z is available" strip above everything, with What's new / Update / Later / Skip.
struct UpdateBar: View {
    @Environment(AppState.self) private var app
    @State private var showNotes = false

    var body: some View {
        if let release = app.updates.pending {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.accent)
                Text("Ember Mail \(release.version.description) is available")
                    .font(.callout.weight(.medium))
                Text("(you have \(UpdateStore.currentVersion.description))").font(.caption).foregroundStyle(.secondary)
                Button("What's new") { showNotes = true }
                    .buttonStyle(.link)
                    .popover(isPresented: $showNotes) {
                        ScrollView {
                            Text(release.notes.isEmpty ? "No release notes." : release.notes)
                                .font(.callout).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                        }
                        .frame(width: 380, height: 240)
                    }
                Spacer()
                if case .installing(_, let status) = app.updates.state {
                    ProgressView().controlSize(.small)
                    Text(status).font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("Skip This Version") { app.updates.skip(release) }.buttonStyle(.link).foregroundStyle(.secondary)
                    Button("Later") { app.updates.dismissForNow() }
                    Button("Update Now") { Task { await app.updates.install(release) } }
                        .buttonStyle(.borderedProminent).tint(Theme.accent)
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Theme.accent.opacity(0.12))
            .overlay(alignment: .bottom) { Divider() }
        } else if case .failed(let message) = app.updates.state {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).font(.callout)
                Spacer()
                Button("Dismiss") { app.updates.dismissForNow() }.controlSize(.small)
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Color.orange.opacity(0.12))
        }
    }
}
