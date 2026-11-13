import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

extension Account {
    /// HTML signature with inline (cid:) images swapped for data URIs, for previews.
    var signaturePreviewHTML: String {
        var html = signatureHTML ?? ""
        for image in signatureImages ?? [] {
            guard let cid = image.contentID else { continue }
            html = html.replacingOccurrences(of: "cid:\(cid)", with: "data:\(image.mimeType);base64,\(image.data.base64EncodedString())")
        }
        return "<div style=\"font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:14px;\">\(html)</div>"
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            AccountsSettings()
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
            ReceiptsSettings()
                .tabItem { Label("Read Receipts", systemImage: "eye") }
            ShortcutsSettings()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 680, height: 640)
    }
}

// MARK: - Accounts

private struct AccountsSettings: View {
    @Environment(AppState.self) private var app
    @State private var selectedID: UUID?
    @State private var showAddIMAP = false
    @State private var connecting = false
    @State private var error: String?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selectedID) {
                    ForEach(app.accounts) { account in
                        HStack(spacing: 8) {
                            Circle().fill(Theme.accountColor(account.colorIndex)).frame(width: 9, height: 9)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(account.label).font(.callout.weight(.medium))
                                Text(account.email).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .tag(account.id)
                    }
                    .onMove { source, destination in
                        app.moveAccounts(from: source, to: destination)
                    }
                }
                Text("Drag to reorder the sidebar")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
                Divider()
                HStack(spacing: 0) {
                    Menu {
                        Button("Business email (IMAP)…") { showAddIMAP = true }
                        Button("Google account…") { Task { await connectGoogle() } }
                    } label: {
                        Image(systemName: "plus").frame(width: 24, height: 20)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    Button {
                        if let id = selectedID { app.removeAccount(id); selectedID = nil }
                    } label: {
                        Image(systemName: "minus").frame(width: 24, height: 20)
                    }
                    .buttonStyle(.borderless)
                    .disabled(selectedID == nil)
                    Spacer()
                    if connecting { ProgressView().controlSize(.small).padding(.trailing, 6) }
                }
                .padding(4)
            }
            .frame(width: 210)
            Divider()
            Group {
                if let id = selectedID, let account = app.account(id) {
                    AccountDetail(account: account).id(id)
                } else {
                    VStack(spacing: 10) {
                        Text("Select an account, or press + to add one.").foregroundStyle(.secondary)
                        if let error { Text(error).font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center) }
                    }
                    .padding()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $showAddIMAP) { AddIMAPAccountSheet() }
        .onAppear { selectedID = selectedID ?? app.accounts.first?.id }
    }

    private func connectGoogle() async {
        connecting = true
        error = nil
        do { try await app.addGoogleAccount() } catch { self.error = error.localizedDescription }
        connecting = false
    }
}

private struct AccountDetail: View {
    @Environment(AppState.self) private var app
    @State var account: Account
    @State private var saved: Account
    @State private var newPassword = ""
    @State private var reconnecting = false
    @State private var message: String?

    init(account: Account) {
        _account = State(initialValue: account)
        _saved = State(initialValue: account)
    }

    var body: some View {
        VStack(spacing: 0) {
        Form {
            Section {
                LabeledContent("Email", value: account.email)
                LabeledContent("Type", value: account.kind == .google ? "Google (Gmail API)" : "IMAP / SMTP")
                TextField("Sidebar label", text: $account.label)
                TextField("Your name", text: $account.senderName)
                Picker("Colour", selection: $account.colorIndex) {
                    ForEach(0..<Theme.accountColors.count, id: \.self) { i in
                        Label { Text(" ") } icon: { Image(systemName: "circle.fill").foregroundStyle(Theme.accountColors[i]) }
                            .tag(i)
                    }
                }
            }
            SignatureEditor(account: $account)
            if account.kind == .imap, let imap = account.imap {
                Section("Server") {
                    LabeledContent("Incoming", value: "\(imap.imapHost):\(imap.imapPort)")
                    LabeledContent("Outgoing", value: "\(imap.smtpHost):\(imap.smtpPort)")
                    Toggle("Save sent messages to Sent folder", isOn: Binding(
                        get: { account.imap?.saveSentCopy ?? true },
                        set: { account.imap?.saveSentCopy = $0 }))
                    HStack {
                        SecureField("New password", text: $newPassword)
                        Button("Update") {
                            app.updateIMAPPassword(account.id, password: newPassword)
                            newPassword = ""
                            message = "Password updated."
                        }
                        .disabled(newPassword.isEmpty)
                    }
                }
            } else {
                Section("Connection") {
                    Button {
                        Task {
                            reconnecting = true
                            do { try await app.addGoogleAccount(); message = "Reconnected." }
                            catch { message = error.localizedDescription }
                            reconnecting = false
                        }
                    } label: {
                        HStack { Text("Reconnect Google account"); if reconnecting { ProgressView().controlSize(.small) } }
                    }
                }
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .formStyle(.grouped)
        SaveBar(isDirty: account != saved,
                save: { app.updateAccount(account); saved = account },
                revert: { account = saved })
        }
    }
}

struct AddIMAPAccountSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var email = ""
    @State private var label = "Ember & Oak"
    @State private var password = ""
    @State private var imapHost = ""
    @State private var imapPort = 993
    @State private var smtpHost = ""
    @State private var smtpPort = 465
    @State private var username = ""
    @State private var verifying = false
    @State private var error: String?

    private var domain: String { email.components(separatedBy: "@").last ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add business email").font(.title3.weight(.semibold))
                Text("Use the IMAP/SMTP details from your email host (cPanel, Zoho, Fastmail, etc.).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], 20)

            Form {
                Section {
                    TextField("Your name", text: $name, prompt: Text("Jane Smith"))
                    TextField("Email", text: $email, prompt: Text("you@emberandoak.com"))
                        .onChange(of: email) { old, new in
                            if username.isEmpty || username == old { username = new }
                            let d = new.components(separatedBy: "@").last ?? ""
                            if !d.isEmpty, d.contains(".") {
                                if imapHost.isEmpty || imapHost.hasPrefix("mail.") { imapHost = "mail.\(d)" }
                                if smtpHost.isEmpty || smtpHost.hasPrefix("mail.") { smtpHost = "mail.\(d)" }
                            }
                        }
                    SecureField("Password", text: $password)
                    TextField("Sidebar label", text: $label)
                }
                Section("Incoming (IMAP, SSL)") {
                    TextField("Server", text: $imapHost)
                    TextField("Port", value: $imapPort, format: .number.grouping(.never))
                }
                Section("Outgoing (SMTP, SSL)") {
                    TextField("Server", text: $smtpHost)
                    TextField("Port", value: $smtpPort, format: .number.grouping(.never))
                    TextField("Username", text: $username)
                }
            }
            .formStyle(.grouped)

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .padding(.horizontal, 20)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button {
                    Task { await add() }
                } label: {
                    if verifying { HStack { ProgressView().controlSize(.small); Text("Checking…") } } else { Text("Sign In") }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(verifying || !email.contains("@") || password.isEmpty || imapHost.isEmpty || smtpHost.isEmpty)
            }
            .padding(20)
        }
        .frame(width: 480, height: 600)
    }

    private func add() async {
        verifying = true
        error = nil
        let settings = IMAPSettings(imapHost: imapHost.trimmingCharacters(in: .whitespaces), imapPort: imapPort,
                                    smtpHost: smtpHost.trimmingCharacters(in: .whitespaces), smtpPort: smtpPort,
                                    username: username.isEmpty ? email : username)
        do {
            try await IMAPProvider.verify(settings: settings, password: password)
            let account = Account(kind: .imap, email: email.trimmingCharacters(in: .whitespaces),
                                  senderName: name, label: label.isEmpty ? domain : label, imap: settings)
            await app.addIMAPAccount(account, password: password)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        verifying = false
    }
}

// MARK: - Save bar

/// Footer shared by every settings page: nothing is applied until Save (⌘S) is pressed.
private struct SaveBar: View {
    let isDirty: Bool
    let save: () -> Void
    let revert: () -> Void
    @State private var justSaved = false

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                if isDirty {
                    Label("Unsaved changes", systemImage: "circle.fill")
                        .font(.caption).foregroundStyle(.orange)
                } else if justSaved {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                }
                Spacer()
                Button("Revert", action: revert).disabled(!isDirty)
                Button("Save") {
                    save()
                    justSaved = true
                    Task { try? await Task.sleep(for: .seconds(2.5)); justSaved = false }
                }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(!isDirty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }
}

// MARK: - Read receipts

private struct ReceiptsSettings: View {
    @State private var trackByDefault = UserDefaults.standard.object(forKey: Prefs.trackByDefault) as? Bool ?? true
    @State private var notifyOpens = UserDefaults.standard.object(forKey: Prefs.notifyOpens) as? Bool ?? true
    @State private var saved = ReceiptsSettings.current()

    private struct Values: Equatable { var track: Bool; var notify: Bool }

    private static func current() -> Values {
        Values(track: UserDefaults.standard.object(forKey: Prefs.trackByDefault) as? Bool ?? true,
               notify: UserDefaults.standard.object(forKey: Prefs.notifyOpens) as? Bool ?? true)
    }

    private var draft: Values { Values(track: trackByDefault, notify: notifyOpens) }

    var body: some View {
        VStack(spacing: 0) {
        Form {
            Section {
                Toggle("Turn on read receipts for new emails", isOn: $trackByDefault)
                Toggle("Notify me when an email is opened", isOn: $notifyOpens)
            } footer: {
                Text("Nothing to set up: Ember Mail adds an invisible image to emails you send, and only this app can see who opened them. Apple Mail's Privacy Protection loads images automatically, so opens from Apple Mail are marked “may be automatic”. Gmail loads images only when the email is opened, so those are reliable.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        SaveBar(isDirty: draft != saved, save: save, revert: revert)
        }
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(trackByDefault, forKey: Prefs.trackByDefault)
        d.set(notifyOpens, forKey: Prefs.notifyOpens)
        saved = draft
    }

    private func revert() { trackByDefault = saved.track; notifyOpens = saved.notify }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(AppState.self) private var app
    @State private var updateNote: String?
    @State private var refreshMinutes = Self.int(Prefs.refreshMinutes, 2)
    @State private var loadRemoteImages = Self.bool(Prefs.loadRemoteImages, true)
    @State private var notifyNewMail = Self.bool(Prefs.notifyNewMail, true)
    @State private var groupThreads = Self.bool(Prefs.groupThreads, true)
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var saved = GeneralSettings.current()
    @State private var loginError: String?

    private struct Values: Equatable { var minutes: Int; var images: Bool; var notify: Bool; var group: Bool; var login: Bool }

    private static func int(_ key: String, _ fallback: Int) -> Int {
        UserDefaults.standard.object(forKey: key) as? Int ?? fallback
    }
    private static func bool(_ key: String, _ fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? fallback
    }
    private static func current() -> Values {
        Values(minutes: int(Prefs.refreshMinutes, 2), images: bool(Prefs.loadRemoteImages, true),
               notify: bool(Prefs.notifyNewMail, true), group: bool(Prefs.groupThreads, true),
               login: SMAppService.mainApp.status == .enabled)
    }
    private var draft: Values {
        Values(minutes: refreshMinutes, images: loadRemoteImages, notify: notifyNewMail, group: groupThreads, login: openAtLogin)
    }

    var body: some View {
        VStack(spacing: 0) {
        Form {
            Toggle("Group messages by conversation", isOn: $groupThreads)
            Toggle("Open Ember Mail at login", isOn: $openAtLogin)
            Text("Scheduled emails are sent by Ember Mail itself, so keep it open (closing the window is fine). Opening at login makes sure nothing is missed.")
                .font(.caption).foregroundStyle(.secondary)
            if let loginError { Text(loginError).font(.caption).foregroundStyle(.orange) }
            Picker("Check for new mail", selection: $refreshMinutes) {
                Text("Every minute").tag(1)
                Text("Every 2 minutes").tag(2)
                Text("Every 5 minutes").tag(5)
                Text("Every 15 minutes").tag(15)
            }
            Toggle("Notify me about new mail", isOn: $notifyNewMail)
            Toggle("Load remote images in emails", isOn: $loadRemoteImages)
            Text("Turning remote images off stops senders from seeing when you open their emails.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Make default mail app") {
                Text("In Apple Mail: Settings → General → Default email reader → Ember Mail")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("About") {
                LabeledContent("Version", value: UpdateStore.currentVersion.description)
                HStack {
                    Button("Check for Updates…") {
                        Task { if let m = await app.updates.check(manual: true) { updateNote = m } }
                    }
                    if let updateNote { Text(updateNote).font(.caption).foregroundStyle(.secondary) }
                }
                Link("Privacy Policy", destination: LegalLinks.privacy)
                Link("Terms of Service", destination: LegalLinks.terms)
            }
        }
        .formStyle(.grouped)
        SaveBar(isDirty: draft != saved, save: save, revert: revert)
        }
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(refreshMinutes, forKey: Prefs.refreshMinutes)
        d.set(loadRemoteImages, forKey: Prefs.loadRemoteImages)
        d.set(notifyNewMail, forKey: Prefs.notifyNewMail)
        d.set(groupThreads, forKey: Prefs.groupThreads)
        if openAtLogin != (SMAppService.mainApp.status == .enabled) {
            do {
                if openAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                loginError = nil
            } catch {
                loginError = error.localizedDescription
                openAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
        saved = draft
    }

    private func revert() {
        refreshMinutes = saved.minutes; loadRemoteImages = saved.images; notifyNewMail = saved.notify
        groupThreads = saved.group; openAtLogin = saved.login
    }
}

enum LegalLinks {
    static let privacy = URL(string: "https://emberandoakdesign.com/legal/ember-mail/privacy")!
    static let terms = URL(string: "https://emberandoakdesign.com/legal/ember-mail/terms")!
}

// MARK: - Signature editor

private struct SignatureEditor: View {
    @Binding var account: Account
    @State private var previewHeight: CGFloat = 60
    @State private var showImagePicker = false
    @State private var showHTMLPicker = false
    @State private var note: String?

    private var useHTML: Binding<Bool> {
        Binding(get: { account.useHTMLSignature == true }, set: { account.useHTMLSignature = $0 })
    }
    private var html: Binding<String> {
        Binding(get: { account.signatureHTML ?? "" }, set: { account.signatureHTML = $0 })
    }

    var body: some View {
        Section {
            Picker("Style", selection: useHTML) {
                Text("Plain text").tag(false)
                Text("HTML & images").tag(true)
            }
            .pickerStyle(.segmented)

            if account.useHTMLSignature == true {
                TextEditor(text: html)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 120)
                    .overlay(alignment: .topLeading) {
                        if html.wrappedValue.isEmpty {
                            Text("Paste your signature HTML here, or insert an image below.")
                                .font(.caption).foregroundStyle(.tertiary).padding(6).allowsHitTesting(false)
                        }
                    }
                HStack {
                    Button("Insert Image…") { showImagePicker = true }
                        .fileImporter(isPresented: $showImagePicker, allowedContentTypes: [.png, .jpeg, .gif]) { result in
                            if case .success(let url) = result { insertImage(url) }
                        }
                    Button("Import HTML File…") { showHTMLPicker = true }
                        .fileImporter(isPresented: $showHTMLPicker, allowedContentTypes: [.html, .plainText]) { result in
                            if case .success(let url) = result { importHTML(url) }
                        }
                    Spacer()
                    if !html.wrappedValue.isEmpty {
                        Button("Clear", role: .destructive) {
                            account.signatureHTML = ""
                            account.signatureImages = []
                        }
                    }
                }
                ForEach(account.signatureImages ?? []) { image in
                    HStack(spacing: 8) {
                        if let ns = NSImage(data: image.data) {
                            Image(nsImage: ns).resizable().scaledToFit().frame(width: 40, height: 24)
                        }
                        Text(image.filename).font(.caption).lineLimit(1)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(image.data.count), countStyle: .file))
                            .font(.caption).foregroundStyle(image.data.count > 200_000 ? .orange : .secondary)
                        Spacer()
                        Button {
                            account.signatureImages?.removeAll { $0.id == image.id }
                            if let cid = image.contentID {
                                account.signatureHTML = account.signatureHTML?.replacingOccurrences(
                                    of: "<img[^>]*cid:\(NSRegularExpression.escapedPattern(for: cid))[^>]*>", with: "",
                                    options: .regularExpression)
                            }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
                if !html.wrappedValue.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Preview").font(.caption).foregroundStyle(.secondary)
                        MessageBodyView(html: account.signaturePreviewHTML, isPlainText: false,
                                        allowRemoteContent: true, height: $previewHeight)
                            .frame(height: min(previewHeight, 320))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
                    }
                }
                if let note { Text(note).font(.caption).foregroundStyle(.orange) }
            } else {
                TextEditor(text: $account.signature)
                    .font(.callout)
                    .frame(height: 80)
            }
        } header: {
            Text("Signature")
        } footer: {
            if account.useHTMLSignature == true {
                Text("Images hosted on your website (https://…) are the most reliable across mail apps. Inserted images are embedded in every email, so keep them small (under ~100 KB).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func insertImage(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/png"
        let cid = "sig-\(UUID().uuidString.prefix(8).lowercased())@embermail"
        var width = 240
        if let image = NSImage(data: data), let rep = image.representations.first {
            // Retina images (e.g. logo@2x.png) are shown at half their pixel width.
            let pixels = rep.pixelsWide > 0 ? rep.pixelsWide : Int(image.size.width)
            width = min(url.lastPathComponent.contains("@2x") ? pixels / 2 : pixels, 320)
        }
        account.signatureImages = (account.signatureImages ?? []) + [
            OutgoingAttachment(filename: url.lastPathComponent, mimeType: mime, data: data, contentID: cid)
        ]
        let tag = "<img src=\"cid:\(cid)\" width=\"\(width)\" alt=\"\(HTMLText.escape(account.label))\" style=\"display:block;border:0;max-width:100%;height:auto;\">"
        account.signatureHTML = (account.signatureHTML ?? "") + (account.signatureHTML?.isEmpty == false ? "\n" : "") + tag
        note = data.count > 200_000 ? "That image is \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)). Large images make every email heavier and can trip spam filters." : nil
    }

    private func importHTML(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        var text = Charset.string(from: data, charset: nil)
        // Keep just the <body> contents of a full HTML document.
        if let range = text.range(of: "(?is)<body[^>]*>(.*)</body>", options: .regularExpression) {
            text = String(text[range])
                .replacingOccurrences(of: "(?is)^<body[^>]*>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "(?is)</body>$", with: "", options: .regularExpression)
        }
        account.signatureHTML = text.trimmingCharacters(in: .whitespacesAndNewlines)
        account.useHTMLSignature = true
    }
}


// MARK: - Shortcuts

private struct ShortcutsSettings: View {
    @Environment(AppState.self) private var app
    @State private var note: String?
    @State private var baseline = ShortcutStore.Snapshot.empty

    var body: some View {
        VStack(spacing: 0) {
            Form {
                ForEach(MailAction.Group.allCases, id: \.self) { group in
                    Section(group.rawValue) {
                        ForEach(MailAction.allCases.filter { $0.group == group }) { action in
                            LabeledContent(action.title) {
                                ShortcutRecorder(action: action, note: $note)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            VStack(alignment: .leading, spacing: 8) {
                if let note {
                    Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Text("Click a shortcut, then press the new keys. Esc cancels. Single keys (like E) only work in the main window when you're not typing.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Gmail-style Keys") {
                        app.shortcuts.applyGmailPreset()
                        note = "Gmail-style keys on: C new, R reply, A reply all, F forward, E archive, # trash, S flag, ⇧U read/unread, B remind, J/K next/previous."
                    }
                    Button("Restore Defaults") {
                        app.shortcuts.resetToDefaults()
                        note = nil
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            SaveBar(isDirty: app.shortcuts.snapshot() != baseline,
                    save: { baseline = app.shortcuts.snapshot() },
                    revert: { app.shortcuts.restore(baseline); note = nil })
        }
        .onAppear { baseline = app.shortcuts.snapshot() }
        // Closing without saving discards the changes.
        .onDisappear { app.shortcuts.restore(baseline) }
    }
}

/// Click to record a new key combination for an action.
private struct ShortcutRecorder: View {
    @Environment(AppState.self) private var app
    let action: MailAction
    @Binding var note: String?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        let current = app.shortcuts.shortcut(for: action)
        HStack(spacing: 6) {
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? "Press keys…" : (current?.display ?? "None"))
                    .font(.system(size: 12, weight: .medium, design: current == nil && !recording ? .default : .rounded))
                    .foregroundStyle(recording ? Theme.accent : (current == nil ? .secondary : .primary))
                    .frame(minWidth: 90)
            }
            .buttonStyle(.bordered)
            Button {
                app.shortcuts.set(nil, for: action)
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.borderless)
            .opacity(current == nil ? 0 : 1)
            .disabled(current == nil)
            .help("Remove shortcut")
        }
        .onDisappear { stop() }
    }

    private func start() {
        stop()
        recording = true
        app.shortcuts.isRecording = true
        let store = app.shortcuts
        let action = self.action
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Esc
                stop()
                return nil
            }
            guard let shortcut = Shortcut(event: event) else {
                NSSound.beep()
                return nil
            }
            if action.requiresModifier && shortcut.isPlain {
                note = "“\(action.title)” is used while typing, so it needs ⌘, ⌥ or ⌃."
                NSSound.beep()
                return nil
            }
            if let displaced = store.set(shortcut, for: action) {
                note = "\(shortcut.display) was used by “\(displaced.title)”, which now has no shortcut."
            } else {
                note = nil
            }
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        app.shortcuts.isRecording = false
    }
}
