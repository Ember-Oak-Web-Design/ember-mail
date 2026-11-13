import AppKit
import Foundation
import Observation

enum SidebarItem: Hashable {
    case allInboxes
    case scheduled
    case calendar
    case mailbox(Mailbox)
}

struct Banner: Identifiable, Equatable {
    let id = UUID()
    var message: String
    var isError: Bool
}

/// Draft passed to compose windows (must be Codable + Hashable for WindowGroup(for:)).
struct ComposeDraft: Codable, Hashable, Identifiable {
    var id = UUID()
    var accountID: UUID?
    var to = ""
    var cc = ""
    var bcc = ""
    var subject = ""
    var body = ""
    var quoteHeader: String?
    var quotedText: String?
    var inReplyTo: String?
    var references: [String] = []
    var threadID: String?
    var attachments: [OutgoingAttachment] = []
    /// Set once the draft has been saved to the server.
    var draftRef: DraftRef?

    /// True when there's anything worth saving.
    var hasContent: Bool {
        ![to, cc, bcc, subject, body].allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } || !attachments.isEmpty
    }

    /// Fingerprint of the editable content, to skip autosaves when nothing changed.
    var contentFingerprint: Int {
        var hasher = Hasher()
        hasher.combine(accountID); hasher.combine(to); hasher.combine(cc); hasher.combine(bcc)
        hasher.combine(subject); hasher.combine(body); hasher.combine(quotedText)
        hasher.combine(attachments.map(\.id))
        return hasher.finalize()
    }
}

@MainActor
@Observable
final class AppState {
    // Accounts & folders
    private(set) var accounts: [Account] = []
    private(set) var mailboxes: [UUID: [Mailbox]] = [:]
    private(set) var unread: [String: Int] = [:]

    // Navigation
    var selection: SidebarItem? = .allInboxes {
        didSet { if oldValue != selection { selectionChanged() } }
    }
    /// The single message open in the reader.
    var selectedMessageID: String? {
        didSet {
            if let id = selectedMessageID, id != oldValue { openMessage(id) }
            // Keep the multi-selection in step (unless several rows are selected, where the reader is empty).
            if let id = selectedMessageID {
                if selectedGroupIDs != [id] { selectedGroupIDs = [id] }
            } else if selectedGroupIDs.count <= 1, !selectedGroupIDs.isEmpty {
                selectedGroupIDs = []
            }
        }
    }
    /// Rows selected in the list (Finder-style: click, ⌘-click, shift-click, shift-drag).
    /// Exactly one → it opens in the reader; several → bulk actions.
    var selectedGroupIDs: Set<String> = [] {
        didSet {
            guard oldValue != selectedGroupIDs else { return }
            let single = selectedGroupIDs.count == 1 ? selectedGroupIDs.first : nil
            if selectedMessageID != single { selectedMessageID = single }
        }
    }
    var hasMultiSelection: Bool { selectedGroupIDs.count > 1 }

    // Lists & bodies
    private(set) var messages: [MessageSummary] = []
    private(set) var searchResults: [MessageSummary]?
    private(set) var bodies: [String: MessageBody] = [:]
    private(set) var bodyErrors: [String: String] = [:]
    /// Conversation for a selected message id, oldest first.
    private(set) var threads: [String: [MessageSummary]] = [:]
    private(set) var loadingThreads: Set<String> = []
    private(set) var isLoadingList = false
    private(set) var isSearching = false
    var searchText = "" {
        didSet { if searchText.isEmpty { searchResults = nil } }
    }

    var banner: Banner?
    var lastSync: Date?

    // Filtering
    var filter = MailFilter() {
        didSet {
            if oldValue.unreadOnly != filter.unreadOnly {
                filterUnread = nil
                Task { await loadUnreadFilter() }
            }
        }
    }
    /// All unread messages for the current view, from the server (nil = not loaded yet).
    private(set) var filterUnread: [MessageSummary]?
    private(set) var isLoadingUnread = false
    private var unreadToken = UUID()
    private var opensLoop: Task<Void, Never>?

    let tracking = TrackingStore()
    let calendar = CalendarStore()
    let schedule = ScheduleStore()
    let shortcuts = ShortcutStore()
    let updates = UpdateStore()

    /// Folders chosen for the sidebar's Simple view, per account (accountID → mailbox paths).
    private(set) var simpleFolders: [String: [String]] = AppState.loadSimpleFolders()

    private var providers: [UUID: any MailProvider] = [:]
    private var refreshLoop: Task<Void, Never>?
    private var knownInboxIDs: [UUID: Set<String>] = [:]
    private var listToken = UUID()
    private var bootstrapped = false
    private var scheduleLoop: Task<Void, Never>?
    /// Message to select once the list for the current selection has loaded (from a notification).
    private var pendingReveal: MessageSummary?

    private static let accountsFile = "accounts.json"
    private static let listLimit = 60

    // MARK: - Lifecycle

    func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        Prefs.registerDefaults()
        updates.startAutomaticChecks()
        accounts = DiskStore.load([Account].self, from: Self.accountsFile) ?? []
        for account in accounts {
            buildProvider(for: account)
            mailboxes[account.id] = DiskStore.load([Mailbox].self, from: "mailboxes-\(account.id.uuidString).json") ?? []
        }
        calendar.configure(accounts: accounts)
        Notifier.requestPermission()
        loadCachedList()
        startScheduleLoop()
        startOpensLoop()
        await refreshAll()
        startRefreshLoop()
    }

    /// Sends scheduled emails when they're due (checked every 20 s while the app runs).
    private func startScheduleLoop() {
        scheduleLoop?.cancel()
        scheduleLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.processScheduledSends()
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    /// Checks the tracking server for opens every minute (cheap: one request) and notifies.
    private func startOpensLoop() {
        opensLoop?.cancel()
        opensLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkOpens()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func checkOpens() async {
        let opens = await tracking.refresh()
        guard !opens.isEmpty, UserDefaults.standard.bool(forKey: Prefs.notifyOpens) else { return }
        for (message, open) in opens.prefix(5) {
            let who = message.recipients.first?.displayName ?? "Someone"
            let title = open.automatic ? "\(who) may have opened your email" : "\(who) read your email"
            var body = "“\(message.subject.isEmpty ? "(No subject)" : message.subject)” · \(open.client)"
            if let location = open.location { body += " · \(location)" }
            if open.automatic { body += " (loaded automatically, so it may not have been read yet)" }
            Notifier.post(title: title, body: body, id: "open-\(message.id)-\(Int(open.at.timeIntervalSince1970))",
                          userInfo: ["kind": "open", "accountID": message.accountID.uuidString])
        }
        if opens.count > 5 {
            Notifier.post(title: "\(opens.count - 5) more emails were opened", body: "Check your Sent folder for details.",
                          userInfo: ["kind": "open", "accountID": opens[0].0.accountID.uuidString])
        }
    }

    private var processingSchedule = false

    func processScheduledSends() async {
        guard !processingSchedule else { return }
        processingSchedule = true
        defer { processingSchedule = false }
        for item in schedule.dueSends() {
            do {
                try await deliver(item.draft, trackOpens: item.trackOpens, requestMDN: item.requestMDN)
                schedule.cancelSend(item.id)
                let to = AddressParser.parseUserInput(item.draft.to).first?.displayName ?? "recipient"
                Notifier.post(title: "Scheduled email sent", body: "“\(item.draft.subject)” to \(to)")
            } catch {
                schedule.markFailed(item.id, error: error.localizedDescription)
                Notifier.post(title: "Scheduled email couldn't be sent",
                              body: "“\(item.draft.subject)”: \(error.localizedDescription). Retrying in 5 minutes.")
            }
        }
    }

    private func startRefreshLoop() {
        refreshLoop?.cancel()
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Prefs.refreshInterval))
                guard let self, !Task.isCancelled else { return }
                await self.refreshAll(quiet: true)
            }
        }
    }

    private func buildProvider(for account: Account) {
        switch account.kind {
        case .imap:
            let password = Keychain.get(Keychain.imapPasswordKey(account.id)) ?? ""
            providers[account.id] = IMAPProvider(account: account, password: password)
        case .google:
            providers[account.id] = GmailProvider(accountID: account.id)
        }
    }

    func provider(for accountID: UUID) -> (any MailProvider)? { providers[accountID] }
    func account(_ id: UUID) -> Account? { accounts.first { $0.id == id } }
    var ownAddresses: Set<String> { Set(accounts.map { $0.email.lowercased() }) }

    func show(_ message: String, error: Bool = false) {
        banner = Banner(message: message, isError: error)
        if !error {
            let id = banner?.id
            Task {
                try? await Task.sleep(for: .seconds(3))
                if banner?.id == id { banner = nil }
            }
        }
    }

    // MARK: - Accounts

    private func saveAccounts() {
        DiskStore.save(accounts, as: Self.accountsFile)
        calendar.configure(accounts: accounts)
    }

    func addIMAPAccount(_ account: Account, password: String) async {
        Keychain.set(password, for: Keychain.imapPasswordKey(account.id))
        var account = account
        account.colorIndex = accounts.count
        accounts.append(account)
        saveAccounts()
        buildProvider(for: account)
        await refreshMailboxes(account.id)
        if selection == .allInboxes { await reloadList() }
    }

    func addGoogleAccount() async throws {
        let result = try await GoogleAuth.shared.signIn()
        if let existing = accounts.first(where: { $0.email.lowercased() == result.email.lowercased() && $0.kind == .google }) {
            await GoogleAuth.shared.store(result.tokens, for: existing.id)
            show("Reconnected \(result.email)")
            return
        }
        let account = Account(kind: .google, email: result.email, senderName: result.name,
                              label: "Google", colorIndex: accounts.count)
        await GoogleAuth.shared.store(result.tokens, for: account.id)
        accounts.append(account)
        saveAccounts()
        buildProvider(for: account)
        await refreshMailboxes(account.id)
        await reloadList()
        await calendar.reload()
        show("Connected \(result.email)")
    }

    /// Reorders accounts (drag and drop in Settings).
    func moveAccounts(from source: IndexSet, to destination: Int) {
        let moving = source.sorted().map { accounts[$0] }
        var rest = accounts.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let insertAt = destination - source.filter { $0 < destination }.count
        rest.insert(contentsOf: moving, at: max(0, min(insertAt, rest.count)))
        accounts = rest
        saveAccounts()
    }

    /// Moves an account up (-1) or down (+1) in the sidebar.
    func moveAccount(_ id: UUID, by delta: Int) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        let target = index + delta
        guard accounts.indices.contains(target) else { return }
        accounts.swapAt(index, target)
        saveAccounts()
    }

    func updateAccount(_ account: Account) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index] = account
        saveAccounts()
    }

    func updateIMAPPassword(_ accountID: UUID, password: String) {
        Keychain.set(password, for: Keychain.imapPasswordKey(accountID))
        if let account = account(accountID) {
            let old = providers[accountID]
            Task { await old?.shutdown() }
            buildProvider(for: account)
        }
    }

    func removeAccount(_ id: UUID) {
        guard let account = account(id) else { return }
        let provider = providers.removeValue(forKey: id)
        Task { await provider?.shutdown() }
        accounts.removeAll { $0.id == id }
        mailboxes[id] = nil
        Keychain.delete(Keychain.imapPasswordKey(id))
        if account.kind == .google { Task { await GoogleAuth.shared.forget(id) } }
        DiskStore.removeAll(withPrefix: "mailboxes-\(id.uuidString)")
        DiskStore.removeAll(withPrefix: "list-\(id.uuidString)")
        saveAccounts()
        if case .mailbox(let mb) = selection, mb.accountID == id { selection = .allInboxes }
        messages.removeAll { $0.accountID == id }
    }

    // MARK: - Mailboxes

    func refreshMailboxes(_ accountID: UUID) async {
        guard let provider = providers[accountID] else { return }
        do {
            let list = try await provider.mailboxes()
            mailboxes[accountID] = list
            DiskStore.save(list, as: "mailboxes-\(accountID.uuidString).json")
        } catch {
            report(error, account: accountID)
        }
    }

    /// Inbox counts always; in Simple view also every hidden folder that can "pop up" with new mail.
    func refreshUnreadCounts() async {
        let simple = UserDefaults.standard.string(forKey: Prefs.sidebarMode) == "simple"
        for account in accounts {
            guard let provider = providers[account.id] else { continue }
            let boxes = mailboxes[account.id] ?? []
            var targets = boxes.filter { $0.role == .inbox }
            if simple { targets += boxes.filter { canPopUp($0) && !isInSimpleView($0) } }
            guard !targets.isEmpty else { continue }
            let counts = await provider.unreadCounts(targets)
            for (id, count) in counts { unread[id] = count }
        }
    }

    // MARK: - Simple sidebar view

    private static let simpleFoldersKey = "simpleFolders"

    private static func loadSimpleFolders() -> [String: [String]] {
        guard let data = UserDefaults.standard.data(forKey: simpleFoldersKey),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
        return decoded
    }

    /// Until you choose, Simple view shows Inbox, Sent and Drafts.
    func isInSimpleView(_ mailbox: Mailbox) -> Bool {
        if let chosen = simpleFolders[mailbox.accountID.uuidString] { return chosen.contains(mailbox.path) }
        return [.inbox, .sent, .drafts].contains(mailbox.role)
    }

    func setInSimpleView(_ mailbox: Mailbox, _ shown: Bool) {
        let key = mailbox.accountID.uuidString
        var chosen = simpleFolders[key] ?? (mailboxes[mailbox.accountID] ?? []).filter { isInSimpleView($0) }.map(\.path)
        chosen.removeAll { $0 == mailbox.path }
        if shown { chosen.append(mailbox.path) }
        simpleFolders[key] = chosen
        if let data = try? JSONEncoder().encode(simpleFolders) {
            UserDefaults.standard.set(data, forKey: Self.simpleFoldersKey)
        }
        if !shown { Task { await refreshUnreadCounts() } }
    }

    /// Folders where new mail "lands" (excludes Trash/Junk/Sent/Drafts and views like Starred or All Mail).
    func canPopUp(_ mailbox: Mailbox) -> Bool {
        switch mailbox.role {
        case .trash, .junk, .sent, .drafts, .starred, .important: return false
        case .archive: return mailbox.path != GmailProvider.allMailPath
        default: return true
        }
    }

    /// Unread badge to show next to a folder (nil = no badge).
    func badgeCount(for mailbox: Mailbox) -> Int? {
        guard mailbox.role == .inbox || canPopUp(mailbox), let n = unread[mailbox.id], n > 0 else { return nil }
        return n
    }

    /// Folders shown for an account in Simple view: chosen ones, plus hidden ones with unread mail,
    /// plus whatever is selected right now (so it doesn't vanish while you read it).
    func simpleMailboxes(for accountID: UUID) -> [Mailbox] {
        (mailboxes[accountID] ?? []).filter { mb in
            isInSimpleView(mb) || (canPopUp(mb) && (unread[mb.id] ?? 0) > 0) || selection == .mailbox(mb)
        }
        .sorted { ($0.role.sortOrder, $0.name) < ($1.role.sortOrder, $1.name) }
    }

    /// Moves the selection to the next (+1) or previous (-1) conversation in the list.
    func selectAdjacent(_ delta: Int) {
        let list = displayedGroups.map(\.latest.id)
        guard !list.isEmpty else { return }
        guard let current = selectedMessageID, let index = list.firstIndex(of: current) else {
            selectedMessageID = list.first
            return
        }
        let target = min(max(index + delta, 0), list.count - 1)
        selectedMessageID = list[target]
    }

    var totalUnread: Int {
        accounts.compactMap { mailboxes[$0.id]?.first(role: .inbox).flatMap { unread[$0.id] } }.reduce(0, +)
    }

    func inbox(for accountID: UUID) -> Mailbox? { mailboxes[accountID]?.first(role: .inbox) }

    // MARK: - Refresh

    func refreshAll(quiet: Bool = false) async {
        for account in accounts where (mailboxes[account.id] ?? []).isEmpty {
            await refreshMailboxes(account.id)
        }
        await reloadList(quiet: quiet)
        if filter.unreadOnly { await loadUnreadFilter() }
        await refreshUnreadCounts()
        updateDockBadge()
        await calendar.ensureLoaded()
        lastSync = Date()
    }

    private func updateDockBadge() {
        let count = totalUnread
        NSApp?.dockTile.badgeLabel = count > 0 ? String(count) : nil
    }

    private func cacheKey(for selection: SidebarItem?) -> String? {
        switch selection {
        case .allInboxes: "list-all.json"
        case .mailbox(let mb): "list-\(mb.accountID.uuidString)-\(mb.path).json"
        default: nil
        }
    }

    private func loadCachedList() {
        guard let key = cacheKey(for: selection) else { messages = []; return }
        messages = DiskStore.load([MessageSummary].self, from: key) ?? []
    }

    private func selectionChanged() {
        searchResults = nil
        searchText = ""
        selectedMessageID = nil
        loadCachedList()
        filterUnread = nil
        Task {
            await reloadList()
            if filter.unreadOnly { await loadUnreadFilter() }
        }
        if selection == .scheduled { Task { await processScheduledSends() } }
        if selection == .calendar { Task { await calendar.ensureLoaded() } }
    }

    /// Reloads the list for the current selection from the server.
    func reloadList(quiet: Bool = false) async {
        let current = selection
        let token = UUID()
        listToken = token
        let targets: [Mailbox]
        switch current {
        case .allInboxes:
            targets = accounts.compactMap { inbox(for: $0.id) }
        case .mailbox(let mb):
            targets = [mb]
        default:
            return
        }
        guard !targets.isEmpty else {
            if current == .allInboxes { messages = [] }
            return
        }
        isLoadingList = true
        defer { if listToken == token { isLoadingList = false } }

        var collected: [MessageSummary] = []
        var failed = false
        await withTaskGroup(of: (Mailbox, Result<[MessageSummary], Error>).self) { group in
            for mb in targets {
                guard let provider = providers[mb.accountID] else { continue }
                group.addTask {
                    do { return (mb, .success(try await provider.messages(in: mb, limit: Self.listLimit))) }
                    catch { return (mb, .failure(error)) }
                }
            }
            for await (mb, result) in group {
                switch result {
                case .success(let list):
                    collected += list
                    if mb.role == .inbox { notifyNewMail(list, accountID: mb.accountID) }
                case .failure(let error):
                    failed = true
                    if !quiet { report(error, account: mb.accountID) }
                    // Keep cached messages for the failed mailbox.
                    collected += messages.filter { $0.accountID == mb.accountID && $0.mailboxPath == mb.path }
                }
            }
        }
        guard listToken == token, selection == current else { return }
        collected.sort { $0.date > $1.date }
        messages = collected
        if !failed, let key = cacheKey(for: current) { DiskStore.save(collected, as: key) }
        if let selected = selectedMessageID, !messages.contains(where: { $0.id == selected }) {
            selectedMessageID = nil
        }
        applyPendingReveal()
    }

    private func applyPendingReveal() {
        guard let target = pendingReveal else { return }
        pendingReveal = nil
        if !messages.contains(where: { $0.id == target.id }) {
            messages.append(target)
            messages.sort { $0.date > $1.date }
        }
        selectedMessageID = target.id
    }

    /// Shows a message (e.g. from a notification), switching to its mailbox.
    func reveal(_ message: MessageSummary) {
        let mailbox = mailboxes[message.accountID]?.first { $0.path == message.mailboxPath }
        let target: SidebarItem = mailbox?.role == .inbox ? .allInboxes : (mailbox.map { .mailbox($0) } ?? .allInboxes)
        pendingReveal = message
        if selection == target {
            applyPendingReveal()
        } else {
            selection = target
            applyPendingReveal() // show immediately from cache; the reload keeps it selected
            pendingReveal = message
        }
    }

    private func notifyNewMail(_ list: [MessageSummary], accountID: UUID) {
        let ids = Set(list.map(\.id))
        defer { knownInboxIDs[accountID] = ids }
        guard let known = knownInboxIDs[accountID], UserDefaults.standard.bool(forKey: Prefs.notifyNewMail) else { return }
        let fresh = list.filter { !known.contains($0.id) && !$0.isRead && $0.date > Date().addingTimeInterval(-3600) }
        for message in fresh.prefix(3) {
            Notifier.post(title: message.from.displayName, body: message.subject.isEmpty ? message.snippet : message.subject,
                          id: message.id, category: Notifier.messageCategory,
                          userInfo: ["kind": "message", "messageID": message.id])
        }
    }

    // MARK: - Search

    var displayedMessages: [MessageSummary] {
        var base: [MessageSummary]
        if let searchResults {
            base = searchResults
        } else {
            // Unread filter: the server's full unread set (kept as loaded, so a message you open doesn't
            // vanish from under you). Until it arrives, fall back to unread messages already loaded.
            base = filter.unreadOnly ? (filterUnread ?? messages.filter { !$0.isRead }) : messages
            let q = searchText.trimmingCharacters(in: .whitespaces)
            if !q.isEmpty {
                base = base.filter {
                    $0.subject.localizedCaseInsensitiveContains(q) || $0.from.displayName.localizedCaseInsensitiveContains(q)
                        || $0.from.email.localizedCaseInsensitiveContains(q) || $0.snippet.localizedCaseInsensitiveContains(q)
                }
            }
        }
        guard filter.hasLocalCriteria else { return base }
        return base.filter(matchesFilter)
    }

    private func matchesFilter(_ m: MessageSummary) -> Bool {
        if filter.flagged && !m.isFlagged { return false }
        if filter.hasAttachments && !m.hasAttachments { return false }
        if let cutoff = filter.range.cutoff, m.date < cutoff { return false }
        if filter.hasReminder && schedule.reminder(for: m) == nil { return false }
        switch filter.receipt {
        case .any: break
        case .read: if tracking.record(for: m)?.isOpened != true { return false }
        case .notRead:
            guard let record = tracking.record(for: m), !record.isOpened else { return false }
        }
        let person = filter.trimmedPerson
        if !person.isEmpty {
            let people = [m.from] + m.to + m.cc
            if !people.contains(where: { $0.displayName.localizedCaseInsensitiveContains(person) || $0.email.localizedCaseInsensitiveContains(person) }) {
                return false
            }
        }
        return true
    }

    private func filterTargets() -> [Mailbox] {
        switch selection {
        case .allInboxes: return accounts.compactMap { inbox(for: $0.id) }
        case .mailbox(let mb): return [mb]
        default: return []
        }
    }

    /// Fetches every unread message in the current view from the server (up to 300 per folder).
    func loadUnreadFilter() async {
        guard filter.unreadOnly else { filterUnread = nil; return }
        let token = UUID()
        unreadToken = token
        let targets = filterTargets()
        guard !targets.isEmpty else { filterUnread = []; return }
        isLoadingUnread = true
        defer { if unreadToken == token { isLoadingUnread = false } }
        var collected: [MessageSummary] = []
        var failed = false
        await withTaskGroup(of: [MessageSummary]?.self) { group in
            for mb in targets {
                guard let provider = providers[mb.accountID] else { continue }
                group.addTask { try? await provider.unreadMessages(in: mb, limit: 300) }
            }
            for await result in group {
                if let result { collected += result } else { failed = true }
            }
        }
        guard unreadToken == token, filter.unreadOnly else { return }
        if failed && collected.isEmpty {
            show("Couldn't fetch all unread mail. Showing what's loaded.", error: true)
            return
        }
        filterUnread = collected.sorted { $0.date > $1.date }
    }

    // MARK: - Bulk actions

    /// Read/unread toggle for a selection: marks all read if any is unread, otherwise all unread.
    func bulkToggleRead(ids: Set<String>) {
        let anyUnread = displayedGroups.filter { ids.contains($0.id) }.contains { $0.hasUnread }
        bulk(anyUnread ? .markRead : .markUnread, ids: ids)
    }

    /// Applies an action to the conversations whose latest-message ids are in `ids`.
    func bulk(_ action: BulkAction, ids: Set<String>) {
        let groups = displayedGroups.filter { ids.contains($0.id) }
        guard !groups.isEmpty else { return }
        let messages = groups.flatMap(\.messages)
        switch action {
        case .markRead:
            for m in messages where !m.isRead { setRead(true, m) }
        case .markUnread:
            for m in messages where m.isRead { setRead(false, m) }
        case .toggleFlag:
            let flagAll = !groups.allSatisfy(\.isFlagged)
            for m in messages where m.isFlagged != flagAll { setFlagged(flagAll, m) }
        case .archive:
            selectedGroupIDs = []
            for m in messages { archive(m) }
        case .trash:
            selectedGroupIDs = []
            for m in messages { trash(m) }
        }
        let n = groups.count
        let noun = n == 1 ? "conversation" : "conversations"
        switch action {
        case .markRead: show("Marked \(n) \(noun) as read")
        case .markUnread: show("Marked \(n) \(noun) as unread")
        case .toggleFlag: break
        case .archive: show("Archived \(n) \(noun)")
        case .trash: show("Moved \(n) \(noun) to Trash")
        }
    }

    struct ThreadGroup: Identifiable {
        var messages: [MessageSummary]   // newest first
        var latest: MessageSummary { messages[0] }
        var id: String { latest.id }
        var hasUnread: Bool { messages.contains { !$0.isRead } }
        var hasAttachments: Bool { messages.contains { $0.hasAttachments } }
        var isFlagged: Bool { messages.contains { $0.isFlagged } }
    }

    /// List rows: one per conversation (or one per message when grouping is off).
    var displayedGroups: [ThreadGroup] {
        let list = displayedMessages
        guard UserDefaults.standard.bool(forKey: Prefs.groupThreads) else { return list.map { ThreadGroup(messages: [$0]) } }
        var order: [String] = []
        var buckets: [String: [MessageSummary]] = [:]
        for message in list {
            let key = message.threadKey
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(message)
        }
        return order.compactMap { buckets[$0].map { ThreadGroup(messages: $0.sorted { $0.date > $1.date }) } }
    }

    func group(containing message: MessageSummary) -> [MessageSummary] {
        displayedGroups.first { $0.messages.contains { $0.id == message.id } }?.messages ?? [message]
    }

    func archiveConversation(_ message: MessageSummary) {
        for m in group(containing: message) { archive(m) }
    }

    func trashConversation(_ message: MessageSummary) {
        for m in group(containing: message) { trash(m) }
    }

    func performServerSearch() async {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { searchResults = nil; return }
        let targets: [Mailbox]
        switch selection {
        case .allInboxes: targets = accounts.compactMap { inbox(for: $0.id) }
        case .mailbox(let mb): targets = [mb]
        default: return
        }
        isSearching = true
        defer { isSearching = false }
        var results: [MessageSummary] = []
        for mb in targets {
            guard let provider = providers[mb.accountID] else { continue }
            do { results += try await provider.search(q, in: mb, limit: 50) }
            catch { report(error, account: mb.accountID) }
        }
        guard searchText.trimmingCharacters(in: .whitespaces) == q else { return }
        searchResults = results.sorted { $0.date > $1.date }
    }

    // MARK: - Messages

    func summary(_ id: String) -> MessageSummary? {
        displayedMessages.first { $0.id == id } ?? messages.first { $0.id == id }
    }

    var selectedMessage: MessageSummary? { selectedMessageID.flatMap(summary) }

    private func updateSummary(_ id: String, _ change: (inout MessageSummary) -> Void) {
        if let i = messages.firstIndex(where: { $0.id == id }) { change(&messages[i]) }
        if let i = searchResults?.firstIndex(where: { $0.id == id }) { change(&searchResults![i]) }
        if let i = filterUnread?.firstIndex(where: { $0.id == id }) { change(&filterUnread![i]) }
    }

    private func openMessage(_ id: String) {
        guard let message = summary(id) else { return }
        if bodies[id] == nil { Task { await loadBody(message) } }
        if !message.isRead { setRead(true, message) }
        // Mark the rest of the conversation in the list as read too.
        for other in messages where other.threadKey == message.threadKey && !other.isRead && other.id != id {
            setRead(true, other)
        }
        if isDraft(message) {
            threads[id] = [message]
        } else if threads[id] == nil {
            Task { await loadThread(message) }
        }
    }

    func loadThread(_ message: MessageSummary) async {
        guard let provider = providers[message.accountID], !loadingThreads.contains(message.id) else { return }
        loadingThreads.insert(message.id)
        defer { loadingThreads.remove(message.id) }
        do {
            var thread = try await provider.thread(for: message)
            // Use the list's copy of each message where we have it (fresh read/flag state).
            thread = thread.map { m in messages.first { $0.id == m.id } ?? m }
            threads[message.id] = thread
            for other in thread where !other.isRead && other.id != message.id && other.mailboxPath == message.mailboxPath {
                setRead(true, other)
            }
        } catch {
            threads[message.id] = [message]
        }
    }

    /// The conversation shown in the reader for a selected message.
    func conversation(for message: MessageSummary) -> [MessageSummary] {
        threads[message.id] ?? [message]
    }

    func loadBody(_ message: MessageSummary) async {
        guard let provider = providers[message.accountID] else { return }
        bodyErrors[message.id] = nil
        do {
            bodies[message.id] = try await provider.body(of: message)
        } catch {
            bodyErrors[message.id] = error.localizedDescription
        }
    }

    func setRead(_ read: Bool, _ message: MessageSummary) {
        updateSummary(message.id) { $0.isRead = read }
        let inboxID = "\(message.accountID.uuidString)|\(message.mailboxPath)"
        if let count = unread[inboxID] { unread[inboxID] = max(0, count + (read ? -1 : 1)) }
        updateDockBadge()
        perform(message, revert: { $0.isRead = !read }) { try await $0.setRead(read, message) }
    }

    func setFlagged(_ flagged: Bool, _ message: MessageSummary) {
        updateSummary(message.id) { $0.isFlagged = flagged }
        perform(message, revert: { $0.isFlagged = !flagged }) { try await $0.setFlagged(flagged, message) }
    }

    func archive(_ message: MessageSummary) {
        removeFromList(message)
        perform(message, restore: true) { try await $0.archive(message) }
    }

    func trash(_ message: MessageSummary) {
        removeFromList(message)
        perform(message, restore: true) { try await $0.trash(message) }
    }

    private func removeFromList(_ message: MessageSummary) {
        let list = displayedGroups.map(\.latest)
        if selectedMessageID == message.id, let index = list.firstIndex(where: { $0.id == message.id }) {
            let next = index + 1 < list.count ? list[index + 1] : (index > 0 ? list[index - 1] : nil)
            selectedMessageID = next?.id
        }
        messages.removeAll { $0.id == message.id }
        searchResults?.removeAll { $0.id == message.id }
        filterUnread?.removeAll { $0.id == message.id }
    }

    private func perform(_ message: MessageSummary,
                         revert: ((inout MessageSummary) -> Void)? = nil,
                         restore: Bool = false,
                         _ action: @escaping (any MailProvider) async throws -> Void) {
        guard let provider = providers[message.accountID] else { return }
        Task {
            do {
                try await action(provider)
            } catch {
                if let revert { updateSummary(message.id, revert) }
                if restore {
                    messages.append(message)
                    messages.sort { $0.date > $1.date }
                }
                report(error, account: message.accountID)
            }
        }
    }

    private func report(_ error: Error, account: UUID) {
        let label = self.account(account)?.label ?? "Mail"
        show("\(label): \(error.localizedDescription)", error: true)
    }

    // MARK: - Compose

    func defaultAccountID() -> UUID? {
        if case .mailbox(let mb) = selection { return mb.accountID }
        return accounts.first?.id
    }

    private func quoteHeader(for message: MessageSummary) -> String {
        "On \(message.date.formatted(date: .abbreviated, time: .shortened)), \(message.from.formatted) wrote:"
    }

    func replyDraft(_ message: MessageSummary, all: Bool) -> ComposeDraft {
        let body = bodies[message.id]
        let own = ownAddresses
        var to = body?.replyTo.isEmpty == false ? body!.replyTo : [message.from]
        var cc: [EmailAddress] = []
        // Replying to something we sent: go back to the original recipients.
        if own.contains(message.from.email.lowercased()) { to = message.to }
        if all {
            let everyone = (body?.to ?? message.to) + (body?.cc ?? message.cc)
            let toSet = Set(to.map { $0.email.lowercased() })
            cc = everyone.filter { !own.contains($0.email.lowercased()) && !toSet.contains($0.email.lowercased()) }
        }
        let subject = message.subject.lowercased().hasPrefix("re:") ? message.subject : "Re: \(message.subject)"
        var refs = body?.references ?? []
        if let mid = message.messageIDHeader ?? body?.messageIDHeader { refs.append(mid) }
        return ComposeDraft(
            accountID: message.accountID,
            to: to.map(\.formatted).joined(separator: ", "),
            cc: cc.map(\.formatted).joined(separator: ", "),
            subject: subject,
            quoteHeader: quoteHeader(for: message),
            quotedText: body?.plainText ?? message.snippet,
            inReplyTo: message.messageIDHeader ?? body?.messageIDHeader,
            references: Array(refs.suffix(10)),
            threadID: message.threadID)
    }

    func forwardDraft(_ message: MessageSummary) -> ComposeDraft {
        let body = bodies[message.id]
        let subject = message.subject.lowercased().hasPrefix("fwd:") ? message.subject : "Fwd: \(message.subject)"
        let header = """
        ---------- Forwarded message ----------
        From: \(message.from.formatted)
        Date: \(Format.fullDate(message.date))
        Subject: \(message.subject)
        To: \(message.to.map(\.formatted).joined(separator: ", "))
        """
        let attachments = (body?.attachments ?? []).map {
            OutgoingAttachment(filename: $0.filename, mimeType: $0.mimeType, data: $0.data)
        }
        return ComposeDraft(
            accountID: message.accountID,
            subject: subject,
            quoteHeader: header,
            quotedText: body?.plainText ?? message.snippet,
            attachments: attachments)
    }

    func draft(fromMailto url: URL) -> ComposeDraft {
        var draft = ComposeDraft(accountID: defaultAccountID())
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        draft.to = components?.path.removingPercentEncoding ?? ""
        for item in components?.queryItems ?? [] {
            switch item.name.lowercased() {
            case "subject": draft.subject = item.value ?? ""
            case "body": draft.body = item.value ?? ""
            case "cc": draft.cc = item.value ?? ""
            case "bcc": draft.bcc = item.value ?? ""
            case "to": draft.to += (draft.to.isEmpty ? "" : ", ") + (item.value ?? "")
            default: break
            }
        }
        return draft
    }

    private func validate(_ draft: ComposeDraft) throws {
        guard let accountID = draft.accountID, account(accountID) != nil, providers[accountID] != nil else {
            throw MailError.notConfigured("Choose an account to send from.")
        }
        let all = AddressParser.parseUserInput(draft.to) + AddressParser.parseUserInput(draft.cc) + AddressParser.parseUserInput(draft.bcc)
        guard !all.isEmpty else { throw MailError.notConfigured("Add at least one recipient.") }
    }

    /// Sends now and shows a confirmation.
    func send(_ draft: ComposeDraft, trackOpens: Bool, requestMDN: Bool) async throws {
        let tracked = try await deliver(draft, trackOpens: trackOpens, requestMDN: requestMDN)
        show(tracked ? "Sent with read receipt" : "Message sent")
    }

    /// Queues a draft to be sent at `date` (the app must be running then; it catches up on next launch).
    func scheduleSend(_ draft: ComposeDraft, at date: Date, trackOpens: Bool, requestMDN: Bool) throws {
        try validate(draft)
        var queued = draft
        if let ref = draft.draftRef {
            queued.draftRef = nil
            Task { await removeDraft(ref) }
        }
        schedule.schedule(ScheduledSend(draft: queued, sendAt: date, trackOpens: trackOpens, requestMDN: requestMDN))
        show("Scheduled for \(QuickTimes.label(date))")
    }

    /// Builds and sends a draft. Returns whether a read receipt was attached.
    @discardableResult
    func deliver(_ draft: ComposeDraft, trackOpens: Bool, requestMDN: Bool) async throws -> Bool {
        try validate(draft)
        guard let accountID = draft.accountID, let account = account(accountID), let provider = providers[accountID] else { return false }
        let keys = trackOpens && tracking.isConfigured ? tracking.newTrackingKeys() : nil
        let trackingID = keys?.id
        let pixel = trackingID.flatMap { tracking.pixelURL(for: $0) }
        let message = outgoing(from: draft, account: account, pixel: pixel, requestMDN: requestMDN)
        let to = message.to, cc = message.cc, bcc = message.bcc

        let result = try await provider.send(message)
        // Sent: remove the saved draft (best effort).
        if let ref = draft.draftRef { await removeDraft(ref) }
        if let trackingID {
            tracking.add(TrackedMessage(id: trackingID, readKey: keys?.readKey, accountID: accountID, messageIDHeader: result.messageIDHeader,
                                        providerID: result.providerID, subject: draft.subject,
                                        recipients: to + cc + bcc, sentAt: Date(), mdnRequested: requestMDN))
        }
        schedule.clearReminders(answeredBy: draft)
        // Refresh open conversations so the reply shows up in the thread.
        if let inReplyTo = draft.inReplyTo {
            threads = threads.filter { _, thread in !thread.contains { $0.messageIDHeader == inReplyTo } }
        }
        if case .mailbox(let mb) = selection, mb.role == .sent, mb.accountID == accountID {
            try? await Task.sleep(for: .seconds(1))
            await reloadList(quiet: true)
        }
        return trackingID != nil
    }

    private func outgoing(from draft: ComposeDraft, account: Account, pixel: URL?, requestMDN: Bool) -> OutgoingMessage {
        let to = AddressParser.parseUserInput(draft.to)
        let cc = AddressParser.parseUserInput(draft.cc)
        let bcc = AddressParser.parseUserInput(draft.bcc)

        let signatureHTML = account.hasHTMLSignature ? account.signatureHTML : nil
        let plainSignature = signatureHTML.map(HTMLText.toPlainText) ?? account.signature
        let inlineImages = (account.signatureImages ?? []).filter { image in
            guard let cid = image.contentID, let html = signatureHTML else { return false }
            return html.contains("cid:\(cid)")
        }
        return OutgoingMessage(
            from: account.sender,
            to: to, cc: cc, bcc: bcc,
            subject: draft.subject,
            text: MIMEBuilder.plain(body: draft.body, signature: plainSignature,
                                    quoteHeader: draft.quoteHeader, quotedText: draft.quotedText),
            html: MIMEBuilder.html(body: draft.body, signature: account.signature, signatureHTML: signatureHTML,
                                   quoteHeader: draft.quoteHeader, quotedText: draft.quotedText, pixelURL: pixel),
            inReplyTo: draft.inReplyTo,
            references: draft.references,
            threadID: draft.threadID,
            attachments: draft.attachments,
            inlineImages: inlineImages,
            requestMDN: requestMDN)
    }

    // MARK: - Drafts

    /// Saves a draft to the account's Drafts folder (replacing the previous save). Returns the new reference.
    func saveDraft(_ draft: ComposeDraft) async throws -> DraftRef {
        guard let accountID = draft.accountID, let account = account(accountID), let provider = providers[accountID] else {
            throw MailError.notConfigured("Choose an account first.")
        }
        var replacing = draft.draftRef
        // Switched the From account: remove the draft from the old account.
        if let ref = replacing, ref.accountID != accountID {
            await removeDraft(ref)
            replacing = nil
        }
        let meta = DraftMeta(body: draft.body, to: draft.to, cc: draft.cc, bcc: draft.bcc,
                             quoteHeader: draft.quoteHeader, quotedText: draft.quotedText,
                             inReplyTo: draft.inReplyTo, references: draft.references, threadID: draft.threadID)
        let message = outgoing(from: draft, account: account, pixel: nil, requestMDN: false)
        let ref = try await provider.saveDraft(message, extraHeaders: MIMEBuilder.draftHeader(meta).map { [$0] } ?? [],
                                               replacing: replacing)
        if case .mailbox(let mb) = selection, mb.role == .drafts, mb.accountID == accountID {
            await reloadList(quiet: true)
        }
        return ref
    }

    func removeDraft(_ ref: DraftRef) async {
        guard let provider = providers[ref.accountID] else { return }
        try? await provider.deleteDraft(ref)
        if case .mailbox(let mb) = selection, mb.role == .drafts, mb.accountID == ref.accountID {
            messages.removeAll { $0.messageIDHeader == ref.messageID }
            await reloadList(quiet: true)
        }
    }

    func isDraft(_ message: MessageSummary) -> Bool {
        mailboxes[message.accountID]?.first { $0.path == message.mailboxPath }?.role == .drafts
    }

    /// Rebuilds an editable draft from a message in the Drafts folder.
    func resumeDraft(_ message: MessageSummary) async -> ComposeDraft? {
        if bodies[message.id] == nil { await loadBody(message) }
        guard let body = bodies[message.id] else { return nil }
        let ref = try? await providers[message.accountID]?.draftRef(for: message)
        let attachments = body.attachments.map { OutgoingAttachment(filename: $0.filename, mimeType: $0.mimeType, data: $0.data) }
        if let meta = MIMEBuilder.decodeDraftHeader(body.emberDraftMeta) {
            return ComposeDraft(accountID: message.accountID, to: meta.to, cc: meta.cc, bcc: meta.bcc,
                                subject: message.subject, body: meta.body, quoteHeader: meta.quoteHeader,
                                quotedText: meta.quotedText, inReplyTo: meta.inReplyTo, references: meta.references,
                                threadID: meta.threadID ?? message.threadID, attachments: attachments, draftRef: ref)
        }
        // A draft started in another mail app: take its text as the body.
        return ComposeDraft(accountID: message.accountID,
                            to: (body.to.isEmpty ? message.to : body.to).map(\.formatted).joined(separator: ", "),
                            cc: body.cc.map(\.formatted).joined(separator: ", "),
                            subject: message.subject, body: body.plainText,
                            threadID: message.threadID, attachments: attachments, draftRef: ref)
    }


    // MARK: - Notifications

    /// Handles a click on a notification. Returns a draft when the user chose "Reply".
    func handleNotification(userInfo: [AnyHashable: Any], action: String) async -> ComposeDraft? {
        let kind = userInfo["kind"] as? String
        if kind == "open" {
            NSApp.activate(ignoringOtherApps: true)
            if let idString = userInfo["accountID"] as? String, let id = UUID(uuidString: idString),
               let sent = mailboxes[id]?.first(role: .sent) {
                selection = .mailbox(sent)
            }
            return nil
        }
        var message: MessageSummary?
        if kind == "reminder", let idString = userInfo["reminderID"] as? String, let id = UUID(uuidString: idString),
           let reminder = schedule.reminder(id: id) {
            if action == Notifier.snoozeAction {
                schedule.snooze(id, until: QuickTimes.inHours(1))
                return nil
            }
            message = reminder.message
        } else if kind == "message", let id = userInfo["messageID"] as? String {
            message = summary(id)
        }
        guard let message else { return nil }
        NSApp.activate(ignoringOtherApps: true)
        reveal(message)
        if action == Notifier.replyAction {
            if bodies[message.id] == nil { await loadBody(message) }
            return replyDraft(message, all: false)
        }
        return nil
    }
}
