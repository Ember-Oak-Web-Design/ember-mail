import SwiftUI

// MARK: - Notifications tab

struct NotificationsSettings: View {
    @Environment(AppState.self) private var app
    @State private var draft = NotificationSettings()
    @State private var saved = NotificationSettings()
    @State private var enabled = true
    @State private var savedEnabled = true
    @State private var loaded = false
    @State private var newSender = ""
    @State private var newMode: SenderNotifyRule.Mode = .always

    private var isDirty: Bool { draft != saved || enabled != savedEnabled }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Toggle("Show notifications for new mail", isOn: $enabled)
                } footer: {
                    Text("Ember Mail checks for new mail in the background, even when its window is closed or another app is in front.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                ForEach(app.accounts) { account in
                    Section {
                        let boxes = folders(for: account)
                        if boxes.isEmpty {
                            Text("Folders appear once the account has loaded.").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(boxes) { mb in
                            Toggle(isOn: folderBinding(mb)) {
                                Label(mb.name, systemImage: mb.role.symbol)
                            }
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Circle().fill(Theme.accountColors[account.colorIndex % Theme.accountColors.count]).frame(width: 8, height: 8)
                            Text(account.label)
                            Spacer()
                            Button("All On") { setAll(account, true) }
                            Button("All Off") { setAll(account, false) }
                            Button("Defaults") { resetDefaults(account) }
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                    .disabled(!enabled)
                }

                Section {
                    ForEach($draft.senders) { $rule in
                        HStack {
                            Image(systemName: rule.pattern.contains("@") && !rule.pattern.hasPrefix("@") ? "person.crop.circle" : "building.2")
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            Text(rule.pattern)
                            Spacer()
                            Picker("", selection: $rule.mode) {
                                ForEach(SenderNotifyRule.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: 150)
                            Button { draft.senders.removeAll { $0.id == rule.id } } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Remove")
                        }
                    }
                    HStack {
                        TextField("Address or domain", text: $newSender, prompt: Text("boss@client.com or client.com"))
                            .onSubmit(addSender)
                        Picker("", selection: $newMode) {
                            ForEach(SenderNotifyRule.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                        Button("Add", action: addSender).disabled(newSender.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("People")
                } footer: {
                    Text("“Always notify” works even in folders you've turned off. “Never notify” silences that sender everywhere. A domain like client.com covers everyone there.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .disabled(!enabled)
            }
            .formStyle(.grouped)
            SaveBar(isDirty: isDirty, save: save, revert: { draft = saved; enabled = savedEnabled })
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            draft = app.rules.notifications
            saved = draft
            enabled = UserDefaults.standard.bool(forKey: Prefs.notifyNewMail)
            savedEnabled = enabled
        }
    }

    private func folders(for account: Account) -> [Mailbox] {
        (app.mailboxes[account.id] ?? []).sorted { ($0.role.sortOrder, $0.name) < ($1.role.sortOrder, $1.name) }
    }

    private func folderBinding(_ mb: Mailbox) -> Binding<Bool> {
        Binding(
            get: { draft.isEnabled(mb) },
            set: { on in
                if on == NotificationSettings.defaultEnabled(mb) { draft.folders[mb.id] = nil } else { draft.folders[mb.id] = on }
            })
    }

    private func setAll(_ account: Account, _ on: Bool) {
        for mb in folders(for: account) { folderBinding(mb).wrappedValue = on }
    }

    private func resetDefaults(_ account: Account) {
        for mb in folders(for: account) { draft.folders[mb.id] = nil }
    }

    private func addSender() {
        let p = newSender.trimmingCharacters(in: .whitespaces).lowercased()
        guard !p.isEmpty else { return }
        draft.senders.removeAll { $0.pattern.lowercased() == p }
        draft.senders.append(SenderNotifyRule(pattern: p, mode: newMode))
        newSender = ""
    }

    private func save() {
        app.rules.save(notifications: draft)
        UserDefaults.standard.set(enabled, forKey: Prefs.notifyNewMail)
        saved = draft
        savedEnabled = enabled
    }
}

// MARK: - Rules tab

struct RulesSettings: View {
    @Environment(AppState.self) private var app
    @State private var draft: [MailRule] = []
    @State private var saved: [MailRule] = []
    @State private var loaded = false
    @State private var editing: MailRule?
    @State private var running: UUID?
    @State private var note: String?

    var body: some View {
        VStack(spacing: 0) {
            if draft.isEmpty {
                emptyState
            } else {
                List {
                    ForEach($draft) { $rule in
                        RuleRow(rule: $rule, summary: summary(rule), isRunning: running == rule.id,
                                edit: { editing = rule },
                                run: { run(rule) },
                                duplicate: { duplicate(rule) },
                                delete: { draft.removeAll { $0.id == rule.id } })
                    }
                    .onMove { draft.move(fromOffsets: $0, toOffset: $1) }
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))
                HStack {
                    Button { editing = MailRule() } label: { Label("New Rule", systemImage: "plus") }
                    if let note { Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    Spacer()
                    Text("Rules run top to bottom on new Inbox mail. Drag to reorder.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            }
            SaveBar(isDirty: draft != saved, save: { app.rules.save(rules: draft); saved = draft }, revert: { draft = saved })
        }
        .sheet(item: $editing) { rule in
            RuleEditor(rule: rule) { updated in
                if let i = draft.firstIndex(where: { $0.id == updated.id }) { draft[i] = updated } else { draft.append(updated) }
            }
            .environment(app)
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            draft = app.rules.rules
            saved = draft
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.accent)
            Text("No rules yet").font(.title3.weight(.semibold))
            Text("Sort mail automatically as it arrives: move newsletters to a folder, mark receipts as read, flag messages from important clients. Rules run in the background.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            Button { editing = MailRule() } label: { Label("New Rule", systemImage: "plus") }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func summary(_ rule: MailRule) -> String {
        let join = rule.matchAll ? " and " : " or "
        let when = rule.conditions.map { "\($0.field.title) \($0.op.title) “\($0.value)”" }.joined(separator: join)
        var then: [String] = []
        switch rule.destination {
        case .none: break
        case .archive: then.append("archive")
        case .trash: then.append("move to Trash")
        case .folder(let path):
            let name = rule.accountID.flatMap { app.mailboxes[$0]?.first { $0.path == path }?.name } ?? path
            then.append("move to \(name)")
        }
        if rule.markRead { then.append("mark as read") }
        if rule.flag { then.append("flag") }
        let scope = rule.accountID.flatMap { app.account($0)?.label }.map { " (\($0))" } ?? ""
        return "If \(when.isEmpty ? "…" : when) → \(then.isEmpty ? "do nothing" : then.joined(separator: ", "))\(scope)"
    }

    private func run(_ rule: MailRule) {
        running = rule.id
        note = nil
        Task {
            let n = await app.runRuleNow(rule)
            running = nil
            note = n == 0 ? "No Inbox messages matched “\(rule.name)”." : "“\(rule.name)” applied to \(n) message\(n == 1 ? "" : "s")."
        }
    }

    private func duplicate(_ rule: MailRule) {
        var copy = rule
        copy.id = UUID()
        copy.name = rule.name + " copy"
        copy.conditions = rule.conditions.map { var c = $0; c.id = UUID(); return c }
        if let i = draft.firstIndex(where: { $0.id == rule.id }) { draft.insert(copy, at: i + 1) } else { draft.append(copy) }
    }
}

private struct RuleRow: View {
    @Binding var rule: MailRule
    let summary: String
    let isRunning: Bool
    let edit: () -> Void
    let run: () -> Void
    let duplicate: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: $rule.enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name.isEmpty ? "Untitled rule" : rule.name).font(.body.weight(.medium))
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            .opacity(rule.enabled ? 1 : 0.5)
            Spacer()
            if isRunning { ProgressView().controlSize(.small) }
            Button("Edit", action: edit)
            Menu {
                Button("Run on Inbox Now", action: run)
                Button("Duplicate", action: duplicate)
                Divider()
                Button("Delete", role: .destructive, action: delete)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: edit)
    }
}

// MARK: - Rule editor sheet

private struct RuleEditor: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State var rule: MailRule
    let onSave: (MailRule) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $rule.name, prompt: Text("e.g. Newsletters"))
                    Picker("Account", selection: $rule.accountID) {
                        Text("All accounts").tag(UUID?.none)
                        ForEach(app.accounts) { Text($0.label).tag(UUID?.some($0.id)) }
                    }
                }

                Section {
                    Picker("", selection: $rule.matchAll) {
                        Text("All conditions match").tag(true)
                        Text("Any condition matches").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    ForEach($rule.conditions) { $condition in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Picker("", selection: $condition.field) {
                                    ForEach(RuleCondition.Field.allCases, id: \.self) { Text($0.title).tag($0) }
                                }
                                .labelsHidden().frame(width: 130)
                                Picker("", selection: $condition.op) {
                                    ForEach(RuleCondition.Op.allCases, id: \.self) { Text($0.title).tag($0) }
                                }
                                .labelsHidden().frame(width: 130)
                                TextField("", text: $condition.value, prompt: Text(prompt(for: condition)))
                                    .textFieldStyle(.roundedBorder)
                                    .font(condition.op == .matchesRegex ? .system(.body, design: .monospaced) : .body)
                                Button {
                                    rule.conditions.removeAll { $0.id == condition.id }
                                } label: {
                                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .disabled(rule.conditions.count == 1)
                            }
                            if let error = condition.regexError, !condition.value.isEmpty {
                                Text(error).font(.caption).foregroundStyle(.red)
                            }
                        }
                    }
                    Button { rule.conditions.append(RuleCondition()) } label: { Label("Add Condition", systemImage: "plus") }
                        .buttonStyle(.link)
                } header: {
                    Text("When a new email arrives in the Inbox")
                }

                Section {
                    Picker("Move to", selection: $rule.destination) {
                        Text("Leave in Inbox").tag(RuleDestination.none)
                        Text("Archive").tag(RuleDestination.archive)
                        Text("Trash").tag(RuleDestination.trash)
                        if !folders.isEmpty {
                            Divider()
                            ForEach(folders) { Label($0.name, systemImage: $0.role.symbol).tag(RuleDestination.folder($0.path)) }
                        }
                    }
                    Toggle("Mark as read", isOn: $rule.markRead)
                    Toggle("Flag", isOn: $rule.flag)
                } header: {
                    Text("Then")
                } footer: {
                    if rule.accountID == nil {
                        Text("Choose an account above to move mail into one of its folders.").font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section {
                    Label(preview, systemImage: "eye").font(.callout).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                if let problem { Text(problem).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Done") {
                    if rule.name.trimmingCharacters(in: .whitespaces).isEmpty { rule.name = defaultName }
                    onSave(rule)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent).tint(Theme.accent)
                .disabled(!rule.isValid)
            }
            .padding(16)
        }
        .frame(width: 600, height: 560)
        .onChange(of: rule.accountID) {
            if case .folder = rule.destination { rule.destination = .none }
        }
    }

    private var folders: [Mailbox] {
        guard let id = rule.accountID else { return [] }
        return (app.mailboxes[id] ?? [])
            .filter { $0.role != .inbox && $0.role != .drafts && $0.role != .sent && $0.path != "__ALL__" }
            .sorted { ($0.role.sortOrder, $0.name) < ($1.role.sortOrder, $1.name) }
    }

    private func prompt(for c: RuleCondition) -> String {
        if c.op == .matchesRegex { return c.field == .subject ? "^Invoice #\\d+" : ".*@client\\.com$" }
        switch c.field {
        case .sender: return "name@example.com"
        case .senderDomain: return "example.com"
        case .recipient: return "team@yourdomain.com"
        case .subject: return "Weekly digest"
        }
    }

    private var problem: String? {
        if rule.conditions.contains(where: { $0.value.trimmingCharacters(in: .whitespaces).isEmpty }) { return "Fill in every condition." }
        if rule.conditions.contains(where: { $0.regexError != nil }) { return "Fix the regex." }
        if !rule.hasAction { return "Choose at least one action." }
        return nil
    }

    private var defaultName: String {
        rule.conditions.first.map { $0.value.trimmingCharacters(in: .whitespaces) } ?? "Rule"
    }

    /// Live test against the messages currently loaded in the list.
    private var preview: String {
        var test = rule
        test.enabled = true
        test.markRead = true // so the preview works before an action is chosen
        guard test.isValid else { return "Matches will show here once the conditions are filled in." }
        let pool = app.displayedMessages
        let n = pool.filter { test.applies(to: $0) }.count
        return "Matches \(n) of the \(pool.count) messages in your current list."
    }
}
