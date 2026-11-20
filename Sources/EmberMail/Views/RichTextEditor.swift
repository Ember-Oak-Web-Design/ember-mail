import AppKit
import Observation
import SwiftUI

/// Drives the compose editor from the format bar and mirrors the selection's formatting for button states.
@MainActor
@Observable
final class RichTextController {
    weak var textView: NSTextView?

    // Selection state (for highlighting the format bar).
    private(set) var isBold = false
    private(set) var isItalic = false
    private(set) var isUnderlined = false
    private(set) var isStruck = false
    private(set) var list: RichTextList.Kind?
    private(set) var linkAtSelection: String?
    private(set) var selectedText = ""

    var showLinkEditor = false

    enum TextStyle: String, CaseIterable, Identifiable {
        case title, heading, body, small
        var id: String { rawValue }
        var name: String {
            switch self { case .title: "Title"; case .heading: "Heading"; case .body: "Body"; case .small: "Small" }
        }
        var size: CGFloat {
            switch self { case .title: 24; case .heading: 18; case .body: RichTextHTML.baseSize; case .small: 12 }
        }
        var bold: Bool { self == .title || self == .heading }
    }

    static let palette: [(String, NSColor?)] = [
        ("Default", nil),
        ("Ember", NSColor(red: 0.85, green: 0.33, blue: 0.12, alpha: 1)),
        ("Red", NSColor(red: 0.82, green: 0.18, blue: 0.18, alpha: 1)),
        ("Green", NSColor(red: 0.16, green: 0.56, blue: 0.29, alpha: 1)),
        ("Blue", NSColor(red: 0.13, green: 0.40, blue: 0.80, alpha: 1)),
        ("Purple", NSColor(red: 0.50, green: 0.27, blue: 0.75, alpha: 1)),
        ("Grey", NSColor(red: 0.42, green: 0.45, blue: 0.49, alpha: 1)),
    ]

    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: RichTextHTML.baseSize), .foregroundColor: NSColor.textColor]
    }

    // MARK: Selection state

    func refreshState() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = tv.selectedRange()
        let attrs: [NSAttributedString.Key: Any]
        if range.length == 0 || storage.length == 0 {
            attrs = tv.typingAttributes
        } else {
            attrs = storage.attributes(at: range.location, effectiveRange: nil)
        }
        let traits = (attrs[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
        isBold = traits.contains(.bold)
        isItalic = traits.contains(.italic)
        isUnderlined = (attrs[.underlineStyle] as? Int ?? 0) != 0
        isStruck = (attrs[.strikethroughStyle] as? Int ?? 0) != 0
        let ns = storage.string as NSString
        let line = ns.substring(with: ns.paragraphRange(for: NSRange(location: min(range.location, ns.length), length: 0)))
        list = RichTextList.marker(in: line)?.kind
        let probe = range.length > 0 ? range.location : max(0, range.location - 1)
        linkAtSelection = probe < storage.length ? RichTextHTML.linkString(storage.attribute(.link, at: probe, effectiveRange: nil)) : nil
        selectedText = range.length > 0 ? ns.substring(with: range) : ""
    }

    // MARK: Character formatting

    func toggleBold() { toggleTrait(.boldFontMask, on: !isBold) }
    func toggleItalic() { toggleTrait(.italicFontMask, on: !isItalic) }
    func toggleUnderline() { toggleAttribute(.underlineStyle, on: !isUnderlined) }
    func toggleStrikethrough() { toggleAttribute(.strikethroughStyle, on: !isStruck) }

    private func toggleTrait(_ trait: NSFontTraitMask, on: Bool) {
        mapFonts { font in
            on ? NSFontManager.shared.convert(font, toHaveTrait: trait) : NSFontManager.shared.convert(font, toNotHaveTrait: trait)
        }
    }

    private func toggleAttribute(_ key: NSAttributedString.Key, on: Bool) {
        edit { storage, range in
            if on { storage.addAttribute(key, value: NSUnderlineStyle.single.rawValue, range: range) }
            else { storage.removeAttribute(key, range: range) }
        } typing: { attrs in
            if on { attrs[key] = NSUnderlineStyle.single.rawValue } else { attrs[key] = nil }
        }
    }

    func setColor(_ color: NSColor?) {
        let value = color ?? NSColor.textColor
        edit { storage, range in storage.addAttribute(.foregroundColor, value: value, range: range) }
            typing: { $0[.foregroundColor] = value }
    }

    /// Applies a text style to the whole paragraph(s) under the selection.
    func apply(_ style: TextStyle) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = (storage.string as NSString).paragraphRange(for: tv.selectedRange())
        let make: (NSFont) -> NSFont = { font in
            var f = NSFontManager.shared.convert(font, toSize: style.size)
            f = style.bold ? NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask)
                           : NSFontManager.shared.convert(f, toNotHaveTrait: .boldFontMask)
            return f
        }
        if range.length > 0, tv.shouldChangeText(in: range, replacementString: nil) {
            storage.beginEditing()
            storage.enumerateAttribute(.font, in: range) { value, r, _ in
                storage.addAttribute(.font, value: make(value as? NSFont ?? .systemFont(ofSize: RichTextHTML.baseSize)), range: r)
            }
            storage.endEditing()
            tv.didChangeText()
        }
        tv.typingAttributes[.font] = make(tv.typingAttributes[.font] as? NSFont ?? .systemFont(ofSize: RichTextHTML.baseSize))
        refreshState()
    }

    /// Removes all formatting (and links) from the selection.
    func clearFormatting() {
        edit { storage, range in
            storage.setAttributes(Self.baseAttributes, range: range)
        } typing: { $0 = Self.baseAttributes }
    }

    private func mapFonts(_ transform: @escaping (NSFont) -> NSFont) {
        edit { storage, range in
            storage.enumerateAttribute(.font, in: range) { value, r, _ in
                storage.addAttribute(.font, value: transform(value as? NSFont ?? .systemFont(ofSize: RichTextHTML.baseSize)), range: r)
            }
        } typing: { attrs in
            attrs[.font] = transform(attrs[.font] as? NSFont ?? .systemFont(ofSize: RichTextHTML.baseSize))
        }
    }

    /// Undoable attribute edit on the selection, or a typing-attributes change when nothing is selected.
    private func edit(_ change: (NSTextStorage, NSRange) -> Void, typing: (inout [NSAttributedString.Key: Any]) -> Void) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = tv.selectedRange()
        if range.length > 0 {
            guard tv.shouldChangeText(in: range, replacementString: nil) else { return }
            storage.beginEditing()
            change(storage, range)
            storage.endEditing()
            tv.didChangeText()
        } else {
            var attrs = tv.typingAttributes
            typing(&attrs)
            tv.typingAttributes = attrs
        }
        tv.window?.makeFirstResponder(tv)
        refreshState()
    }

    // MARK: Lists

    /// Turns the selected paragraphs into a list (or back to plain paragraphs if they already are one).
    func toggleList(_ kind: RichTextList.Kind) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let ns = storage.string as NSString
        let range = ns.paragraphRange(for: tv.selectedRange())
        var paragraphs: [NSRange] = []
        var loc = range.location
        repeat {
            let p = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            paragraphs.append(p)
            loc = NSMaxRange(p)
        } while loc < NSMaxRange(range)
        let removing = paragraphs.allSatisfy { RichTextList.marker(in: ns.substring(with: $0))?.kind == kind }
        guard tv.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        // Bottom-up, so earlier ranges stay valid while markers are inserted/removed.
        for (index, p) in paragraphs.enumerated().reversed() {
            let existing = RichTextList.marker(in: ns.substring(with: p))
            let attrs = storage.length > 0 ? storage.attributes(at: min(p.location, storage.length - 1), effectiveRange: nil) : Self.baseAttributes
            if let existing { storage.deleteCharacters(in: NSRange(location: p.location, length: existing.length)) }
            if !removing {
                let marker = kind == .bullet ? RichTextList.bullet : "\(index + 1). "
                storage.insert(NSAttributedString(string: marker, attributes: attrs), at: p.location)
            }
        }
        storage.endEditing()
        tv.didChangeText()
        tv.window?.makeFirstResponder(tv)
        refreshState()
    }

    /// Return inside a list continues it; Return on an empty item ends the list. Returns true if handled.
    func handleNewline(in tv: NSTextView) -> Bool {
        guard let storage = tv.textStorage else { return false }
        let ns = storage.string as NSString
        let sel = tv.selectedRange()
        let para = ns.paragraphRange(for: NSRange(location: sel.location, length: 0))
        let line = ns.substring(with: para).trimmingCharacters(in: .newlines)
        guard let marker = RichTextList.marker(in: line) else { return false }
        if (line as NSString).length <= marker.length {
            // Empty item: remove the marker and leave the list.
            let r = NSRange(location: para.location, length: marker.length)
            if tv.shouldChangeText(in: r, replacementString: "") {
                storage.replaceCharacters(in: r, with: "")
                tv.didChangeText()
            }
            return true
        }
        let next = marker.kind == .bullet ? RichTextList.bullet : "\(marker.number + 1). "
        tv.insertText("\n" + next, replacementRange: sel)
        return true
    }

    // MARK: Links

    /// Adds or replaces a link on the selection (or the link under the cursor). Inserts `text` if nothing is selected.
    func setLink(_ urlString: String, text: String) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        var link = urlString.trimmingCharacters(in: .whitespaces)
        guard !link.isEmpty else { return }
        if !link.contains(":") { link = link.contains("@") && !link.contains("/") ? "mailto:\(link)" : "https://\(link)" }
        guard let url = URL(string: link) else { return }
        var range = tv.selectedRange()
        if range.length == 0, let existing = linkRange(at: range.location, in: storage) { range = existing }
        if range.length == 0 {
            let label = text.isEmpty ? urlString : text
            var attrs = tv.typingAttributes
            attrs[.link] = url
            let insert = NSAttributedString(string: label, attributes: attrs)
            if tv.shouldChangeText(in: range, replacementString: label) {
                storage.replaceCharacters(in: range, with: insert)
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: range.location + insert.length, length: 0))
                tv.typingAttributes[.link] = nil
            }
        } else if tv.shouldChangeText(in: range, replacementString: text.isEmpty ? nil : text) {
            if !text.isEmpty, text != (storage.string as NSString).substring(with: range) {
                let attrs = storage.attributes(at: range.location, effectiveRange: nil)
                storage.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: attrs))
                range.length = (text as NSString).length
            }
            storage.addAttribute(.link, value: url, range: range)
            tv.didChangeText()
        }
        tv.window?.makeFirstResponder(tv)
        refreshState()
    }

    func removeLink() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        var range = tv.selectedRange()
        if let existing = linkRange(at: range.length > 0 ? range.location : max(0, range.location - 1), in: storage) { range = existing }
        guard range.length > 0, tv.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.removeAttribute(.link, range: range)
        tv.didChangeText()
        refreshState()
    }

    /// Selects the whole link around the cursor so the editor can show and change it.
    func selectLink(at index: Int) {
        guard let tv = textView, let storage = tv.textStorage, let r = linkRange(at: index, in: storage) else { return }
        tv.setSelectedRange(r)
        refreshState()
    }

    private func linkRange(at index: Int, in storage: NSTextStorage) -> NSRange? {
        guard index >= 0, index < storage.length else { return nil }
        var r = NSRange()
        guard storage.attribute(.link, at: index, longestEffectiveRange: &r, in: NSRange(location: 0, length: storage.length)) != nil else { return nil }
        return r
    }

    func focus() {
        guard let tv = textView else { return }
        tv.window?.makeFirstResponder(tv)
    }
}

// MARK: - Editor view

/// A growing NSTextView with the full macOS text system: spelling and grammar, autocorrect,
/// text replacements, smart quotes, inline predictions, Writing Tools, the font panel, and undo.
struct RichTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var html: String?
    let controller: RichTextController
    var autoFocus = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextView {
        let tv = EmailTextView()
        tv.delegate = context.coordinator
        tv.coordinator = context.coordinator
        tv.isRichText = true
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFontPanel = true
        tv.usesFindBar = true
        tv.drawsBackground = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainerInset = NSSize(width: 0, height: 4)
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true

        // Spelling, grammar and text input features follow the system settings
        // (System Settings → Keyboard → Text Input), and can be changed from the Edit menu / right-click.
        tv.isContinuousSpellCheckingEnabled = true
        tv.isGrammarCheckingEnabled = true
        tv.isAutomaticSpellingCorrectionEnabled = NSSpellChecker.isAutomaticSpellingCorrectionEnabled
        tv.isAutomaticTextReplacementEnabled = NSSpellChecker.isAutomaticTextReplacementEnabled
        tv.isAutomaticQuoteSubstitutionEnabled = NSSpellChecker.isAutomaticQuoteSubstitutionEnabled
        tv.isAutomaticDashSubstitutionEnabled = NSSpellChecker.isAutomaticDashSubstitutionEnabled
        tv.isAutomaticTextCompletionEnabled = NSSpellChecker.isAutomaticTextCompletionEnabled
        tv.isAutomaticLinkDetectionEnabled = true
        tv.inlinePredictionType = .yes
        tv.linkTextAttributes = [.foregroundColor: NSColor(red: 0.85, green: 0.33, blue: 0.12, alpha: 1),
                                 .underlineStyle: NSUnderlineStyle.single.rawValue,
                                 .cursor: NSCursor.pointingHand]

        let initial: NSAttributedString
        if let html, !html.isEmpty, let parsed = RichTextHTML.attributed(fromHTML: html) {
            initial = parsed
        } else {
            initial = NSAttributedString(string: text, attributes: RichTextController.baseAttributes)
        }
        tv.textStorage?.setAttributedString(initial)
        tv.typingAttributes = RichTextController.baseAttributes
        controller.textView = tv
        if autoFocus {
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }
        return tv
    }

    func updateNSView(_ nsView: NSTextView, context: Context) {
        context.coordinator.parent = self
        controller.textView = nsView
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 500
        guard let container = nsView.textContainer, let layout = nsView.layoutManager else { return nil }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let height = layout.usedRect(for: container).height + nsView.textContainerInset.height * 2
        return CGSize(width: width, height: max(180, ceil(height) + 24))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor

        init(_ parent: RichTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView, let storage = tv.textStorage else { return }
            parent.text = storage.string
            parent.html = RichTextHTML.html(from: storage)
            tv.invalidateIntrinsicContentSize()
            parent.controller.refreshState()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            parent.controller.refreshState()
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                return parent.controller.handleNewline(in: textView)
            }
            return false
        }

        /// Clicking a link while writing edits it instead of opening the browser.
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            parent.controller.selectLink(at: charIndex)
            parent.controller.showLinkEditor = true
            return true
        }
    }
}

/// ⌘K opens the link editor, like most editors.
private final class EmailTextView: NSTextView {
    weak var coordinator: RichTextEditor.Coordinator?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if window?.firstResponder === self, flags == .command, event.charactersIgnoringModifiers == "k" {
            coordinator?.parent.controller.refreshState()
            coordinator?.parent.controller.showLinkEditor = true
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateIntrinsicContentSize()
    }
}

// MARK: - Format bar

struct FormatBar: View {
    @Bindable var controller: RichTextController
    @State private var linkURL = ""
    @State private var linkText = ""

    var body: some View {
        HStack(spacing: 2) {
            Menu {
                ForEach(RichTextController.TextStyle.allCases) { style in
                    Button(style.name) { controller.apply(style) }
                }
            } label: {
                Label("Style", systemImage: "textformat.size")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Text style")

            divider
            toggle("bold", on: controller.isBold, help: "Bold (⌘B)", controller.toggleBold)
            toggle("italic", on: controller.isItalic, help: "Italic (⌘I)", controller.toggleItalic)
            toggle("underline", on: controller.isUnderlined, help: "Underline (⌘U)", controller.toggleUnderline)
            toggle("strikethrough", on: controller.isStruck, help: "Strikethrough", controller.toggleStrikethrough)

            Menu {
                ForEach(RichTextController.palette, id: \.0) { name, color in
                    Button {
                        controller.setColor(color)
                    } label: {
                        Label {
                            Text(name)
                        } icon: {
                            Image(nsImage: Self.swatch(color))
                        }
                    }
                }
            } label: {
                Image(systemName: "paintpalette")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Text colour")

            divider
            toggle("list.bullet", on: controller.list == .bullet, help: "Bulleted list") { controller.toggleList(.bullet) }
            toggle("list.number", on: controller.list == .number, help: "Numbered list") { controller.toggleList(.number) }

            divider
            toggle("link", on: controller.linkAtSelection != nil, help: "Add or edit link (⌘K)") {
                controller.showLinkEditor = true
            }
            .popover(isPresented: $controller.showLinkEditor, arrowEdge: .bottom) { linkEditor }

            toggle("textformat.characters.dottedunderline", on: false, help: "Clear formatting", controller.clearFormatting)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .controlSize(.small)
        .onChange(of: controller.showLinkEditor) {
            if controller.showLinkEditor {
                linkURL = controller.linkAtSelection ?? ""
                linkText = controller.selectedText
            }
        }
    }

    /// Menus tint SF Symbols with the accent colour, so swatches are drawn as real (non-template) images.
    /// The drawing handler runs at draw time, so "Default" follows light/dark mode.
    static func swatch(_ color: NSColor?) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            (color ?? NSColor.textColor).setFill()
            circle.fill()
            NSColor.black.withAlphaComponent(0.15).setStroke()
            circle.lineWidth = 0.5
            circle.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }

    private var divider: some View {
        Divider().frame(height: 16).padding(.horizontal, 4)
    }

    private func toggle(_ symbol: String, on: Bool, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 24, height: 20)
                .background(on ? Theme.accent.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                .foregroundStyle(on ? Theme.accent : Color.primary)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var linkEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(controller.linkAtSelection == nil ? "Add Link" : "Edit Link").font(.headline)
            TextField("Text", text: $linkText, prompt: Text("Text to show"))
            TextField("URL", text: $linkURL, prompt: Text("https://example.com"))
                .onSubmit(saveLink)
            HStack {
                if controller.linkAtSelection != nil {
                    Button("Remove Link", role: .destructive) {
                        controller.removeLink()
                        controller.showLinkEditor = false
                    }
                    if let url = URL(string: controller.linkAtSelection ?? "") {
                        Button("Open") { NSWorkspace.shared.open(url) }
                    }
                }
                Spacer()
                Button("Cancel") { controller.showLinkEditor = false }
                Button(controller.linkAtSelection == nil ? "Add" : "Update", action: saveLink)
                    .keyboardShortcut(.defaultAction)
                    .disabled(linkURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(14)
        .frame(width: 340)
    }

    private func saveLink() {
        controller.setLink(linkURL, text: linkText)
        controller.showLinkEditor = false
    }
}
