import AppKit

/// Converts the compose editor's attributed text to simple, inline-styled HTML that email clients render
/// reliably (no <style> blocks or classes), and back again for resumed drafts.
///
/// Supported: bold, italic, underline, strikethrough, text colour, font size, links, and lists. Lists are
/// typed as text ("• item" / "1. item", see `RichTextList`) and become <ul>/<ol> here.
enum RichTextHTML {
    static let baseSize: CGFloat = 14

    static func html(from attr: NSAttributedString) -> String {
        let ns = attr.string as NSString
        guard ns.length > 0 else { return "" }
        var out = ""
        var openList: RichTextList.Kind?
        var location = 0
        while location < ns.length {
            let paraRange = ns.paragraphRange(for: NSRange(location: location, length: 0))
            var contentRange = paraRange
            // Drop the paragraph separator.
            while contentRange.length > 0, let scalar = Unicode.Scalar(ns.character(at: NSMaxRange(contentRange) - 1)),
                  CharacterSet.newlines.contains(scalar) {
                contentRange.length -= 1
            }
            let line = ns.substring(with: contentRange)
            let marker = RichTextList.marker(in: line)
            if openList != marker?.kind {
                if let openList { out += openList == .bullet ? "</ul>" : "</ol>" }
                if let kind = marker?.kind {
                    out += kind == .bullet ? "<ul style=\"margin:0 0 0 1.2em;padding:0;\">" : "<ol style=\"margin:0 0 0 1.2em;padding:0;\">"
                }
                openList = marker?.kind
            }
            if let marker {
                let inner = NSRange(location: contentRange.location + marker.length, length: max(0, contentRange.length - marker.length))
                out += "<li>\(runs(attr, inner))</li>"
            } else {
                let inner = runs(attr, contentRange)
                out += inner.isEmpty ? "<div><br></div>" : "<div>\(inner)</div>"
            }
            if paraRange.length == 0 { break }
            location = NSMaxRange(paraRange)
        }
        if let openList { out += openList == .bullet ? "</ul>" : "</ol>" }
        return out
    }

    private static func runs(_ attr: NSAttributedString, _ range: NSRange) -> String {
        guard range.length > 0 else { return "" }
        var out = ""
        attr.enumerateAttributes(in: range) { attrs, r, _ in
            var text = HTMLText.escape((attr.string as NSString).substring(with: r))
            text = text.replacingOccurrences(of: "\u{2028}", with: "<br>").replacingOccurrences(of: "  ", with: "&nbsp; ")
            var styles: [String] = []
            if let color = attrs[.foregroundColor] as? NSColor, let hex = hex(color) { styles.append("color:\(hex)") }
            if let font = attrs[.font] as? NSFont {
                if abs(font.pointSize - baseSize) > 0.5 { styles.append("font-size:\(Int(font.pointSize.rounded()))px") }
                let traits = font.fontDescriptor.symbolicTraits
                if traits.contains(.italic) { text = "<i>\(text)</i>" }
                if traits.contains(.bold) { text = "<b>\(text)</b>" }
            }
            if (attrs[.underlineStyle] as? Int ?? 0) != 0 { text = "<u>\(text)</u>" }
            if (attrs[.strikethroughStyle] as? Int ?? 0) != 0 { text = "<s>\(text)</s>" }
            if !styles.isEmpty { text = "<span style=\"\(styles.joined(separator: ";"))\">\(text)</span>" }
            if let link = linkString(attrs[.link]) {
                text = "<a href=\"\(HTMLText.escape(link))\" style=\"color:#d9531f;\">\(text)</a>"
            }
            out += text
        }
        return out
    }

    static func linkString(_ value: Any?) -> String? {
        if let url = value as? URL { return url.absoluteString }
        if let s = value as? String, !s.isEmpty { return s }
        return nil
    }

    /// Hex for explicit colours; nil for the editor's default (dynamic) text colours and plain black.
    static func hex(_ color: NSColor) -> String? {
        if color.type == .catalog, ["textColor", "labelColor", "controlTextColor"].contains(color.colorNameComponent) { return nil }
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        let r = Int((rgb.redComponent * 255).rounded()), g = Int((rgb.greenComponent * 255).rounded()), b = Int((rgb.blueComponent * 255).rounded())
        if r < 8 && g < 8 && b < 8 { return nil }   // black = default
        return String(format: "#%02x%02x%02x", r, g, b)
    }

    // MARK: HTML → editor

    /// Reads HTML we produced (resumed drafts) back into editor text, normalised to the system font
    /// and the default text colour so it looks like freshly typed text.
    @MainActor
    static func attributed(fromHTML html: String) -> NSAttributedString? {
        let wrapped = "<meta charset=\"utf-8\"><div style=\"font-family:-apple-system;font-size:\(Int(baseSize))px\">\(html)</div>"
        guard let data = wrapped.data(using: .utf8),
              let imported = try? NSMutableAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html,
                                                                                  .characterEncoding: String.Encoding.utf8.rawValue],
                                                            documentAttributes: nil) else { return nil }
        let full = NSRange(location: 0, length: imported.length)
        imported.enumerateAttribute(.font, in: full) { value, r, _ in
            let old = value as? NSFont
            var font = NSFont.systemFont(ofSize: old?.pointSize ?? baseSize)
            let traits = old?.fontDescriptor.symbolicTraits ?? []
            if traits.contains(.bold) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if traits.contains(.italic) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            imported.addAttribute(.font, value: font, range: r)
        }
        imported.enumerateAttribute(.foregroundColor, in: full) { value, r, _ in
            if let c = value as? NSColor, hex(c) == nil || imported.attribute(.link, at: r.location, effectiveRange: nil) != nil {
                imported.addAttribute(.foregroundColor, value: NSColor.textColor, range: r)
            }
        }
        // WebKit underlines links on import; links are styled by the editor instead.
        imported.enumerateAttribute(.link, in: full) { value, r, _ in
            if value != nil { imported.removeAttribute(.underlineStyle, range: r) }
        }
        // WebKit renders <li> with a tab-marker; turn list items back into our typed markers.
        let text = imported.string
        if text.contains("\t•\t") || text.range(of: "\t\\d+\\.\t", options: .regularExpression) != nil {
            let pattern = try? NSRegularExpression(pattern: "(?m)^\\t(•|\\d+\\.)\\t")
            for m in (pattern?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? []).reversed() {
                let markerText = (text as NSString).substring(with: m.range(at: 1))
                imported.replaceCharacters(in: m.range, with: markerText + " ")
            }
        }
        // Trim the trailing newline WebKit adds after the last block.
        while imported.length > 0, imported.string.hasSuffix("\n") { imported.deleteCharacters(in: NSRange(location: imported.length - 1, length: 1)) }
        return imported
    }
}

/// Lists are plain text markers the editor continues on Return: "• " for bullets, "1. " for numbers.
enum RichTextList {
    enum Kind: Equatable { case bullet, number }

    static let bullet = "• "

    /// The list marker at the start of a line, with its length in UTF-16 units.
    static func marker(in line: String) -> (kind: Kind, length: Int, number: Int)? {
        if line.hasPrefix(bullet) { return (.bullet, (bullet as NSString).length, 0) }
        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3, line.dropFirst(digits.count).hasPrefix(". "), let n = Int(digits) {
            return (.number, digits.count + 2, n)
        }
        return nil
    }
}
