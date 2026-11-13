import AppKit
import Observation
import SwiftUI

/// A user-assignable key combination.
struct Shortcut: Codable, Hashable {
    /// A single lowercased character, or a special key name (see `specialKeys`).
    var key: String
    var command = false
    var shift = false
    var option = false
    var control = false

    /// No ⌘/⌥/⌃: handled by the main window's key monitor instead of the menu bar,
    /// so it never fires while you're typing.
    var isPlain: Bool { !command && !option && !control }

    static let specialKeys: [UInt16: String] = [
        51: "delete", 117: "forwarddelete", 36: "return", 76: "return", 48: "tab", 49: "space",
        123: "left", 124: "right", 125: "down", 126: "up",
    ]

    init(key: String, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) {
        self.key = key
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
    }

    /// Builds a shortcut from a key press. Returns nil for keys we don't support (e.g. Escape, F-keys).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        command = flags.contains(.command)
        option = flags.contains(.option)
        control = flags.contains(.control)
        shift = flags.contains(.shift)
        if let special = Self.specialKeys[event.keyCode] {
            key = special
            return
        }
        guard event.keyCode != 53, // escape is reserved for cancelling
              let chars = event.charactersIgnoringModifiers?.lowercased(), chars.count == 1,
              let scalar = chars.unicodeScalars.first, scalar.value >= 32, scalar.value < 0xF700 else { return nil }
        key = chars
        // Shifted symbols ("#", "?") already imply Shift: store just the symbol.
        if shift, !(chars.first?.isLetter ?? false), !(chars.first?.isNumber ?? false) { shift = false }
    }

    var keyEquivalent: KeyEquivalent? {
        switch key {
        case "delete": return .delete
        case "forwarddelete": return .deleteForward
        case "return": return .return
        case "tab": return .tab
        case "space": return .space
        case "left": return .leftArrow
        case "right": return .rightArrow
        case "down": return .downArrow
        case "up": return .upArrow
        default: return key.first.map { KeyEquivalent($0) }
        }
    }

    var keyboardShortcut: KeyboardShortcut? {
        guard let keyEquivalent else { return nil }
        var mods: EventModifiers = []
        if command { mods.insert(.command) }
        if shift { mods.insert(.shift) }
        if option { mods.insert(.option) }
        if control { mods.insert(.control) }
        return KeyboardShortcut(keyEquivalent, modifiers: mods)
    }

    var display: String {
        var s = ""
        if control { s += "⌃" }
        if option { s += "⌥" }
        if shift { s += "⇧" }
        if command { s += "⌘" }
        switch key {
        case "delete": s += "⌫"
        case "forwarddelete": s += "⌦"
        case "return": s += "↩"
        case "tab": s += "⇥"
        case "space": s += "Space"
        case "left": s += "←"
        case "right": s += "→"
        case "down": s += "↓"
        case "up": s += "↑"
        default: s += key.uppercased()
        }
        return s
    }
}

enum MailAction: String, CaseIterable, Codable, Identifiable {
    case newMessage, getMail, reply, replyAll, forward, archive, trash, toggleRead, toggleFlag, remindTomorrow
    case nextMessage, previousMessage
    case saveDraft, send
    case goAllInboxes, goScheduled, goCalendar, toggleToday

    var id: String { rawValue }

    enum Group: String, CaseIterable { case mail = "Mail", compose = "Writing", navigation = "Navigation" }

    var group: Group {
        switch self {
        case .saveDraft, .send: .compose
        case .goAllInboxes, .goScheduled, .goCalendar, .toggleToday, .nextMessage, .previousMessage: .navigation
        default: .mail
        }
    }

    var title: String {
        switch self {
        case .newMessage: "New message"
        case .getMail: "Check for new mail"
        case .reply: "Reply"
        case .replyAll: "Reply all"
        case .forward: "Forward"
        case .archive: "Archive"
        case .trash: "Move to Trash"
        case .toggleRead: "Mark read / unread"
        case .toggleFlag: "Flag / unflag"
        case .remindTomorrow: "Remind me tomorrow morning"
        case .nextMessage: "Next message"
        case .previousMessage: "Previous message"
        case .saveDraft: "Save draft"
        case .send: "Send"
        case .goAllInboxes: "Go to All Inboxes"
        case .goScheduled: "Go to Scheduled"
        case .goCalendar: "Go to Calendar"
        case .toggleToday: "Show / hide Today panel"
        }
    }

    /// Writing actions are used while typing, so they must include ⌘, ⌥ or ⌃.
    var requiresModifier: Bool { group == .compose }

    var defaultShortcut: Shortcut? {
        switch self {
        case .newMessage: Shortcut(key: "n", command: true)
        case .getMail: Shortcut(key: "n", command: true, shift: true)
        case .reply: Shortcut(key: "r", command: true)
        case .replyAll: Shortcut(key: "r", command: true, shift: true)
        case .forward: Shortcut(key: "f", command: true, shift: true)
        case .archive: Shortcut(key: "a", command: true, control: true)
        case .trash: Shortcut(key: "delete", command: true)
        case .toggleRead: Shortcut(key: "u", command: true, shift: true)
        case .toggleFlag: Shortcut(key: "l", command: true, shift: true)
        case .remindTomorrow: nil
        case .nextMessage, .previousMessage: nil
        case .saveDraft: Shortcut(key: "s", command: true)
        case .send: Shortcut(key: "return", command: true)
        case .goAllInboxes: Shortcut(key: "1", command: true)
        case .goScheduled: Shortcut(key: "2", command: true)
        case .goCalendar: Shortcut(key: "3", command: true)
        case .toggleToday: Shortcut(key: "t", command: true, option: true)
        }
    }

    /// Gmail-style single keys.
    var gmailShortcut: Shortcut? {
        switch self {
        case .newMessage: Shortcut(key: "c")
        case .reply: Shortcut(key: "r")
        case .replyAll: Shortcut(key: "a")
        case .forward: Shortcut(key: "f")
        case .archive: Shortcut(key: "e")
        case .trash: Shortcut(key: "#")
        case .toggleRead: Shortcut(key: "u", shift: true)
        case .toggleFlag: Shortcut(key: "s")
        case .remindTomorrow: Shortcut(key: "b")
        case .nextMessage: Shortcut(key: "j")
        case .previousMessage: Shortcut(key: "k")
        default: defaultShortcut
        }
    }
}

/// User shortcut assignments (UserDefaults). `nil` in the map = deliberately cleared.
@MainActor
@Observable
final class ShortcutStore {
    private var overrides: [String: Shortcut?] = [:]
    private static let defaultsKey = "customShortcuts"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: Shortcut?].self, from: data) {
            overrides = decoded
        }
    }

    func shortcut(for action: MailAction) -> Shortcut? {
        if let override = overrides[action.rawValue] { return override }
        return action.defaultShortcut
    }

    /// For menu items: only shortcuts with ⌘/⌥/⌃ (plain keys are handled by the key monitor).
    func menuShortcut(for action: MailAction) -> KeyboardShortcut? {
        guard let s = shortcut(for: action), !s.isPlain else { return nil }
        return s.keyboardShortcut
    }

    /// Assigns a shortcut. Returns the action that previously used it (now cleared), if any.
    @discardableResult
    func set(_ shortcut: Shortcut?, for action: MailAction) -> MailAction? {
        var displaced: MailAction?
        if let shortcut {
            for other in MailAction.allCases where other != action && self.shortcut(for: other) == shortcut {
                overrides[other.rawValue] = .some(nil)
                displaced = other
            }
        }
        overrides[action.rawValue] = .some(shortcut)
        save()
        return displaced
    }

    /// Staged-editing support for Settings: shortcuts apply live while editing, but only Save keeps them.
    struct Snapshot: Equatable {
        var data: Data
        static let empty = Snapshot(data: Data())
    }

    func snapshot() -> Snapshot {
        Snapshot(data: (try? JSONEncoder().encode(overrides.sorted { $0.key < $1.key }.map { [$0.key: $0.value] })) ?? Data())
    }

    func restore(_ snap: Snapshot) {
        guard !snap.data.isEmpty,
              let list = try? JSONDecoder().decode([[String: Shortcut?]].self, from: snap.data) else { return }
        var map: [String: Shortcut?] = [:]
        for item in list { for (k, v) in item { map[k] = .some(v) } }
        overrides = map
        save()
    }

    func resetToDefaults() {
        overrides = [:]
        save()
    }

    func applyGmailPreset() {
        var preset: [String: Shortcut?] = [:]
        for action in MailAction.allCases { preset[action.rawValue] = .some(action.gmailShortcut) }
        overrides = preset
        save()
    }

    func action(matching event: NSEvent) -> MailAction? {
        guard let pressed = Shortcut(event: event) else { return nil }
        return MailAction.allCases.first { shortcut(for: $0) == pressed }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(overrides) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    /// Set while the Settings recorder is listening, so the key monitor doesn't act on the keys.
    var isRecording = false
}

/// Runs a mail action from the menu bar or the key monitor.
@MainActor
struct MailActionPerformer {
    let app: AppState
    let openWindow: OpenWindowAction

    func perform(_ action: MailAction) {
        let message = app.selectedMessage
        switch action {
        case .newMessage:
            openWindow(id: "compose", value: ComposeDraft(accountID: app.defaultAccountID()))
        case .getMail:
            Task { await app.refreshAll() }
        case .reply:
            if let m = message { openWindow(id: "compose", value: app.replyDraft(app.conversation(for: m).last ?? m, all: false)) }
        case .replyAll:
            if let m = message { openWindow(id: "compose", value: app.replyDraft(app.conversation(for: m).last ?? m, all: true)) }
        case .forward:
            if let m = message { openWindow(id: "compose", value: app.forwardDraft(app.conversation(for: m).last ?? m)) }
        case .archive:
            if app.hasMultiSelection { app.bulk(.archive, ids: app.selectedGroupIDs) }
            else if let m = message { app.archiveConversation(m) }
        case .trash:
            if app.hasMultiSelection { app.bulk(.trash, ids: app.selectedGroupIDs) }
            else if let m = message { app.trashConversation(m) }
        case .toggleRead:
            if app.hasMultiSelection { app.bulkToggleRead(ids: app.selectedGroupIDs) }
            else if let m = message { app.setRead(!m.isRead, m) }
        case .toggleFlag:
            if app.hasMultiSelection { app.bulk(.toggleFlag, ids: app.selectedGroupIDs) }
            else if let m = message { app.setFlagged(!m.isFlagged, m) }
        case .remindTomorrow:
            if let m = message {
                let date = QuickTimes.at(hour: 9, daysFromNow: 1)
                app.schedule.addReminder(for: m, at: date)
                app.show("I'll remind you \(QuickTimes.label(date))")
            }
        case .nextMessage:
            app.selectAdjacent(1)
        case .previousMessage:
            app.selectAdjacent(-1)
        case .saveDraft, .send:
            break // handled by the compose window's own buttons
        case .goAllInboxes:
            app.selection = .allInboxes
        case .goScheduled:
            app.selection = .scheduled
        case .goCalendar:
            app.selection = .calendar
        case .toggleToday:
            let key = Prefs.showTodayPanel
            UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
        }
    }

    /// Whether the action can run right now (for menu enabling).
    func isAvailable(_ action: MailAction) -> Bool {
        switch action {
        case .archive, .trash, .toggleRead, .toggleFlag:
            app.selectedMessage != nil || app.hasMultiSelection
        case .reply, .replyAll, .forward, .remindTomorrow:
            app.selectedMessage != nil
        default:
            true
        }
    }
}
