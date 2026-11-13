import Foundation

/// Removes quoted history from replies so each message in a thread shows only what's new.
enum QuoteStripper {
    /// Plain-text bodies: cut at the first reply/forward header, drop trailing "> " blocks.
    static func plain(_ text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var cut = lines.count
        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if isAttributionLine(line, next: index + 1 < lines.count ? lines[index + 1] : "") ||
                line.hasPrefix("-----Original Message-----") ||
                line.hasPrefix("---------- Forwarded message") ||
                line.hasPrefix("________________________________") ||
                (line.hasPrefix("From:") && lines.dropFirst(index + 1).prefix(4).contains { $0.hasPrefix("Sent:") || $0.hasPrefix("Date:") }) {
                cut = index
                break
            }
            if line.hasPrefix(">") {
                // Only treat as history if everything after is quoted / blank.
                let rest = lines[index...].map { $0.trimmingCharacters(in: .whitespaces) }
                if rest.allSatisfy({ $0.isEmpty || $0.hasPrefix(">") }) { cut = index; break }
            }
        }
        let kept = lines[0..<cut].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return kept.isEmpty ? text : kept
    }

    private static func isAttributionLine(_ line: String, next: String) -> Bool {
        let lower = line.lowercased()
        if lower.hasPrefix("on ") && lower.hasSuffix("wrote:") { return true }
        // Attribution wrapped over two lines: "On Mon, 9 Nov 2026 at 09:54, Jo <jo@x.com>" / "wrote:"
        if lower.hasPrefix("on ") && next.trimmingCharacters(in: .whitespaces).lowercased().hasSuffix("wrote:") && line.contains("@") { return true }
        // Common translations
        for suffix in ["schrieb:", "a écrit :", "a écrit:", "escribió:", "ha scritto:", "schreef:", "skrev:"] where lower.hasSuffix(suffix) {
            return true
        }
        return false
    }

    /// JavaScript (run in an isolated world) that hides quoted history in HTML mail.
    /// Leaves the message untouched if hiding would leave nothing visible.
    static let htmlScript = """
    (function () {
      const removed = [];
      function hide(el) { if (el && el.style && !removed.includes(el)) { removed.push(el); el.setAttribute('data-ember-hidden', el.style.display || ''); el.style.display = 'none'; } }
      function hideFrom(el) { while (el) { hide(el); el = el.nextElementSibling; } }
      document.querySelectorAll('.gmail_quote, .gmail_extra, blockquote[type="cite"], .yahoo_quoted, .ember_quote, .moz-cite-prefix, #appendonsend, .protonmail_quote, div[data-marker="__QUOTED_TEXT__"]').forEach(hide);
      ['divRplyFwdMsg', 'mail-editor-reference-message-container', 'x_divRplyFwdMsg'].forEach(function (id) {
        const el = document.getElementById(id);
        if (el) { const prev = el.previousElementSibling; if (prev && prev.tagName === 'HR') hide(prev); hideFrom(el); }
      });
      // Outlook desktop: a div with a top border whose text starts with "From:"
      document.querySelectorAll('div[style*="border-top"]').forEach(function (el) {
        if (/^\\s*(From|Van|Von|De):/.test(el.innerText || '')) {
          // Outlook wraps the header in a plain <div>; the old message follows that wrapper.
          var target = el;
          while (target.parentElement && target.parentElement !== document.body && target.parentElement.children.length === 1) {
            target = target.parentElement;
          }
          hideFrom(target);
        }
      });
      // Apple Mail / generic: the "On …, X wrote:" line just before a hidden quote
      removed.slice().forEach(function (el) {
        const prev = el.previousElementSibling;
        if (prev && /wrote:\\s*$|schrieb:\\s*$|a écrit\\s*:\\s*$/i.test((prev.innerText || '').trim())) hide(prev);
      });
      const visible = (document.body.innerText || '').replace(/\\s+/g, '');
      const hasImages = Array.from(document.images).some(function (img) { return img.offsetParent !== null && img.width > 2; });
      if (visible.length === 0 && !hasImages) {
        removed.forEach(function (el) { el.style.display = el.getAttribute('data-ember-hidden') || ''; });
        return 0;
      }
      return removed.length;
    })();
    """
}
