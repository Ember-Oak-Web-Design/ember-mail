import AppKit
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if Notifier.available { UNUserNotificationCenter.current().delegate = self }
    }

    /// Keep running when the window closes so scheduled emails still go out.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // Show banners even while Ember Mail is in front.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .emberNotificationResponse, object: nil,
                                            userInfo: ["info": info, "action": action])
        }
        completionHandler()
    }
}

@main
struct EmberMailApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var app = AppState()

    init() {
        Prefs.registerDefaults()
    }

    var body: some Scene {
        Window("Ember Mail", id: "main") {
            RootView()
                .environment(app)
                .tint(Theme.accent)
                .task { await app.bootstrap() }
        }
        .defaultSize(width: 1280, height: 820)
        .commands { MailCommands(app: app) }

        WindowGroup("New Message", id: "compose", for: ComposeDraft.self) { $draft in
            ComposeView(draft: draft ?? ComposeDraft(accountID: app.defaultAccountID()))
                .environment(app)
                .tint(Theme.accent)
        }
        .defaultSize(width: 760, height: 640)
        .windowToolbarStyle(.unified(showsTitle: false))

        Settings {
            SettingsView()
                .environment(app)
                .tint(Theme.accent)
        }
    }
}

struct MailCommands: Commands {
    let app: AppState
    @Environment(\.openWindow) private var openWindow

    private var performer: MailActionPerformer { MailActionPerformer(app: app, openWindow: openWindow) }

    /// A menu item whose shortcut comes from Settings → Shortcuts.
    private func item(_ title: String, _ action: MailAction) -> some View {
        Button(title) { performer.perform(action) }
            .keyboardShortcut(app.shortcuts.menuShortcut(for: action))
            .disabled(!performer.isAvailable(action))
    }

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                Task { if let message = await app.updates.check(manual: true) { app.show(message) } }
            }
        }
        CommandGroup(replacing: .newItem) {
            item("New Message", .newMessage)
        }
        CommandMenu("Message") {
            item("Get New Mail", .getMail)
            Divider()
            item("Reply", .reply)
            item("Reply All", .replyAll)
            item("Forward", .forward)
            Divider()
            item("Archive", .archive)
            item("Move to Trash", .trash)
            item("Mark as Read / Unread", .toggleRead)
            item("Flag / Unflag", .toggleFlag)
            item("Remind Me Tomorrow Morning", .remindTomorrow)
            Divider()
            item("Next Message", .nextMessage)
            item("Previous Message", .previousMessage)
        }
        CommandGroup(after: .sidebar) {
            item("All Inboxes", .goAllInboxes)
            item("Scheduled & Reminders", .goScheduled)
            item("Calendar", .goCalendar)
            item("Show / Hide Today Panel", .toggleToday)
            Divider()
        }
    }
}
