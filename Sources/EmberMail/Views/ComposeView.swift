import SwiftUI
import UniformTypeIdentifiers

struct ComposeView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Prefs.trackByDefault) private var trackByDefault = true

    @State private var draft: ComposeDraft
    @State private var showCcBcc = false
    @State private var trackOpens = true
    @State private var requestMDN = false
    @State private var isSending = false
    @State private var error: String?
    @State private var showImporter = false
    @State private var showQuote = true
    @State private var showSchedulePicker = false
    @State private var signatureHeight: CGFloat = 60

    // Drafts
    private enum DraftStatus: Equatable { case idle, saving, saved(Date), failed(String) }
    @State private var draftStatus: DraftStatus = .idle
    @State private var lastSavedFingerprint: Int
    @State private var saveTask: Task<Void, Never>?
    /// Sent, scheduled or discarded: stop autosaving and don't save on close.
    @State private var finished = false
    @State private var confirmDiscard = false
    @FocusState private var focus: Field?

    private enum Field { case to, subject, body }

    init(draft: ComposeDraft) {
        _draft = State(initialValue: draft)
        // Only save once the user changes something (a reply's prefilled fields alone aren't a draft).
        _lastSavedFingerprint = State(initialValue: draft.contentFingerprint)
        _showCcBcc = State(initialValue: !draft.cc.isEmpty || !draft.bcc.isEmpty)
    }

    private var account: Account? { draft.accountID.flatMap { app.account($0) } }

    private var canSend: Bool {
        !isSending && account != nil && !AddressParser.parseUserInput(draft.to + "," + draft.cc + "," + draft.bcc).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            fields
            Divider()
            editor
            if !draft.attachments.isEmpty {
                Divider()
                attachmentsBar
            }
            Divider()
            footer
        }
        .navigationTitle(draft.subject.isEmpty ? "New Message" : draft.subject)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    confirmDiscard = draft.hasContent
                    if !draft.hasContent { discard() }
                } label: {
                    Label("Discard", systemImage: "trash")
                }
                .help("Discard this draft")

                Button {
                    Task { await saveDraft(force: true) }
                } label: {
                    Label("Save Draft", systemImage: "square.and.arrow.down")
                }
                .keyboardShortcut(app.shortcuts.menuShortcut(for: .saveDraft))
                .disabled(isSending || draftStatus == .saving || app.accounts.isEmpty)
                .help("Save to Drafts (\(app.shortcuts.shortcut(for: .saveDraft)?.display ?? "no shortcut")). Drafts also save automatically every 10 seconds.")

                Button {
                    showImporter = true
                } label: {
                    Label("Attach", systemImage: "paperclip")
                }
                .help("Attach files")

                Menu {
                    ForEach(TimePresets.sends(), id: \.0) { label, date in
                        Button(label) { scheduleSend(at: date) }
                    }
                    Divider()
                    Button("Pick a Date & Time…") { showSchedulePicker = true }
                } label: {
                    Label("Send Later", systemImage: "clock")
                }
                .disabled(!canSend)
                .help("Schedule this email")

                Button {
                    Task { await send() }
                } label: {
                    if isSending {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Send", systemImage: "paperplane.fill")
                    }
                }
                .keyboardShortcut(app.shortcuts.menuShortcut(for: .send))
                .disabled(!canSend)
                .help("Send (\(app.shortcuts.shortcut(for: .send)?.display ?? "no shortcut"))")
            }
        }
        .sheet(isPresented: $showSchedulePicker) {
            DateTimePickerSheet(title: "Schedule send", subtitle: draft.subject, confirmTitle: "Schedule",
                                initial: QuickTimes.at(hour: 8, daysFromNow: 1)) { date in
                scheduleSend(at: date)
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { attach(urls) }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { attach([url]) } }
                }
            }
            return true
        }
        .onAppear {
            trackOpens = trackByDefault
            if draft.accountID == nil { draft.accountID = app.defaultAccountID() }
            focus = draft.to.isEmpty ? .to : .body
        }
        // Autosave every 10 seconds while the message is being written.
        .task {
            while !Task.isCancelled && !finished {
                try? await Task.sleep(for: .seconds(10))
                if Task.isCancelled || finished { break }
                await saveDraft(force: false)
            }
        }
        // Closing the window keeps unsaved changes in Drafts.
        .onDisappear {
            guard !finished, draft.contentFingerprint != lastSavedFingerprint, draft.hasContent else { return }
            let snapshot = draft
            Task { _ = try? await app.saveDraft(snapshot) }
        }
        .confirmationDialog("Discard this message?", isPresented: $confirmDiscard) {
            Button("Discard", role: .destructive) { discard() }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text(draft.draftRef == nil ? "It hasn't been saved." : "It will also be removed from Drafts.")
        }
        .frame(minWidth: 560, minHeight: 420)
    }

    // MARK: Header fields

    private var fields: some View {
        VStack(spacing: 0) {
            if app.accounts.count > 1 {
                FieldRow(label: "From") {
                    Picker("", selection: $draft.accountID) {
                        ForEach(app.accounts) { account in
                            Text("\(account.senderName) <\(account.email)>").tag(Optional(account.id))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    Spacer()
                }
                Divider().padding(.leading, 16)
            }
            FieldRow(label: "To") {
                RecipientField(text: $draft.to, placeholder: "name@company.com")
                    .focused($focus, equals: .to)
                if !showCcBcc {
                    Button("Cc/Bcc") { withAnimation { showCcBcc = true } }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if showCcBcc {
                Divider().padding(.leading, 16)
                FieldRow(label: "Cc") { RecipientField(text: $draft.cc, placeholder: "") }
                Divider().padding(.leading, 16)
                FieldRow(label: "Bcc") { RecipientField(text: $draft.bcc, placeholder: "") }
            }
            Divider().padding(.leading, 16)
            FieldRow(label: "Subject") {
                TextField("", text: $draft.subject)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                    .focused($focus, equals: .subject)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: Body

    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                TextEditor(text: $draft.body)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .scrollDisabled(true)
                    .frame(minHeight: 180)
                    .focused($focus, equals: .body)

                if let account, account.hasHTMLSignature {
                    MessageBodyView(html: account.signaturePreviewHTML, isPlainText: false,
                                    allowRemoteContent: true, height: $signatureHeight)
                        .frame(height: signatureHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
                        .allowsHitTesting(false)
                        .id(account.id)
                } else if let signature = account?.signature, !signature.isEmpty {
                    Text("-- \n" + signature)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                if let quoted = draft.quotedText, !quoted.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Button {
                            withAnimation { showQuote.toggle() }
                        } label: {
                            Label(showQuote ? "Hide quoted text" : "Show quoted text", systemImage: "ellipsis.bubble")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)

                        if showQuote {
                            VStack(alignment: .leading, spacing: 4) {
                                if let header = draft.quoteHeader {
                                    Text(header).font(.caption).foregroundStyle(.secondary)
                                }
                                Text(quoted)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(40)
                                    .padding(.leading, 10)
                                    .overlay(alignment: .leading) {
                                        Rectangle().fill(.quaternary).frame(width: 3)
                                    }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .background(.background)
    }

    private var attachmentsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(draft.attachments) { att in
                    HStack(spacing: 6) {
                        Image(systemName: "doc").foregroundStyle(Theme.accent)
                        Text(att.filename).lineLimit(1)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(att.data.count), countStyle: .file))
                            .foregroundStyle(.secondary)
                        Button {
                            draft.attachments.removeAll { $0.id == att.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.quaternary.opacity(0.5), in: Capsule())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 16) {
            Toggle(isOn: $trackOpens) {
                Label("Read receipt", systemImage: "eye")
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(!app.tracking.isConfigured)
            .help(app.tracking.isConfigured
                  ? "Adds an invisible image so you can see when this email is opened"
                  : "Read receipts are unavailable")

            Toggle(isOn: $requestMDN) {
                Text("Ask recipient to confirm")
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .help("Adds a standard return-receipt request. The recipient's mail app may ask them or ignore it.")

            Spacer()

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }

            draftStatusLabel
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.bar)
    }

    @ViewBuilder
    private var draftStatusLabel: some View {
        switch draftStatus {
        case .idle:
            if !app.tracking.isConfigured {
                Text("Read receipts not set up").font(.caption).foregroundStyle(.tertiary)
            }
        case .saving:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Saving draft…")
            }
            .font(.caption).foregroundStyle(.secondary)
        case .saved(let date):
            Label("Draft saved \(date.formatted(date: .omitted, time: .shortened))", systemImage: "checkmark.circle")
                .font(.caption).foregroundStyle(.secondary)
        case .failed(let message):
            Label("Draft not saved", systemImage: "exclamationmark.circle")
                .font(.caption).foregroundStyle(.orange)
                .help(message)
        }
    }

    // MARK: Drafts

    /// Saves to the server's Drafts folder. Skips if nothing changed since the last save unless forced.
    private func saveDraft(force: Bool) async {
        guard !finished, !isSending, draft.accountID != nil else { return }
        if let running = saveTask { await running.value }
        let fingerprint = draft.contentFingerprint
        guard force || fingerprint != lastSavedFingerprint else { return }
        guard draft.hasContent || draft.draftRef != nil else { return }
        let snapshot = draft
        draftStatus = .saving
        let task = Task { @MainActor in
            do {
                let ref = try await app.saveDraft(snapshot)
                if finished {
                    // Sent or discarded while saving: don't leave this copy behind.
                    await app.removeDraft(ref)
                } else {
                    draft.draftRef = ref
                    lastSavedFingerprint = fingerprint
                    draftStatus = .saved(Date())
                }
            } catch {
                draftStatus = .failed(error.localizedDescription)
            }
        }
        saveTask = task
        await task.value
        saveTask = nil
    }

    private func discard() {
        finished = true
        let ref = draft.draftRef
        let pending = saveTask
        Task {
            await pending?.value
            if let ref { await app.removeDraft(ref) }
        }
        dismiss()
    }

    // MARK: Actions

    private func attach(_ urls: [URL]) {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            draft.attachments.append(OutgoingAttachment(filename: url.lastPathComponent, mimeType: type, data: data))
        }
    }

    private func scheduleSend(at date: Date) {
        Task {
            isSending = true
            await saveTask?.value   // let an in-flight autosave finish so its draft gets cleaned up
            do {
                var toSend = draft
                if !showQuote { toSend.quotedText = nil; toSend.quoteHeader = nil }
                try app.scheduleSend(toSend, at: date, trackOpens: trackOpens && app.tracking.isConfigured, requestMDN: requestMDN)
                finished = true
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            isSending = false
        }
    }

    private func send() async {
        guard canSend else { return }
        isSending = true
        error = nil
        await saveTask?.value   // wait for any autosave so we delete the latest draft copy after sending
        do {
            var toSend = draft
            if !showQuote { toSend.quotedText = nil; toSend.quoteHeader = nil }
            try await app.send(toSend, trackOpens: trackOpens && app.tracking.isConfigured, requestMDN: requestMDN)
            finished = true
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        isSending = false
    }
}

private struct FieldRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .trailing)
            content
        }
        .font(.system(size: 13))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

/// Recipient text field with suggestions from people you've emailed.
private struct RecipientField: View {
    @Environment(AppState.self) private var app
    @Binding var text: String
    let placeholder: String
    @State private var showSuggestions = false

    private var currentToken: String {
        (text.components(separatedBy: ",").last ?? "").trimmingCharacters(in: .whitespaces)
    }

    private var suggestions: [EmailAddress] {
        let q = currentToken.lowercased()
        guard q.count >= 2 else { return [] }
        var seen = Set<String>()
        var out: [EmailAddress] = []
        let pool = app.messages.flatMap { [$0.from] + $0.to + $0.cc }
            + app.tracking.items.flatMap(\.recipients)
        for address in pool {
            let key = address.email.lowercased()
            guard !seen.contains(key), !app.ownAddresses.contains(key) else { continue }
            if key.contains(q) || (address.name?.lowercased().contains(q) ?? false) {
                seen.insert(key)
                out.append(address)
            }
            if out.count >= 6 { break }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .onChange(of: text) { showSuggestions = !suggestions.isEmpty }
                .onSubmit {
                    if let first = suggestions.first, showSuggestions { pick(first) }
                }
            if showSuggestions && !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(suggestions, id: \.email) { address in
                        Button { pick(address) } label: {
                            HStack(spacing: 8) {
                                AvatarView(address: address, size: 20)
                                Text(address.displayName).font(.callout)
                                if address.name != nil {
                                    Text(address.email).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func pick(_ address: EmailAddress) {
        var parts = text.components(separatedBy: ",").dropLast().map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        parts.append(address.formatted)
        text = parts.joined(separator: ", ") + ", "
        showSuggestions = false
    }
}
