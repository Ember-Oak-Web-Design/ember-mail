import Foundation

enum MIMEBuilder {
    /// Builds an RFC 5322 message. Bcc is only written when `includeBcc` (Gmail API strips it itself).
    static func build(_ message: OutgoingMessage, includeBcc: Bool, date: Date = Date(),
                      extraHeaders: [String] = []) -> (data: Data, messageID: String) {
        let domain = message.from.email.components(separatedBy: "@").last ?? "localhost"
        let messageID = "<\(UUID().uuidString.lowercased())@\(domain)>"

        var headers: [String] = []
        headers.append("From: \(AddressParser.headerValue(message.from))")
        if !message.to.isEmpty { headers.append("To: \(AddressParser.headerValue(message.to))") }
        if !message.cc.isEmpty { headers.append("Cc: \(AddressParser.headerValue(message.cc))") }
        if includeBcc, !message.bcc.isEmpty { headers.append("Bcc: \(AddressParser.headerValue(message.bcc))") }
        headers.append("Subject: \(RFC2047.encodeIfNeeded(message.subject))")
        headers.append("Date: \(MailDate.rfc2822(date))")
        headers.append("Message-ID: \(messageID)")
        if let inReplyTo = message.inReplyTo { headers.append("In-Reply-To: \(inReplyTo)") }
        if !message.references.isEmpty { headers.append("References: \(message.references.joined(separator: "\r\n "))") }
        if message.requestMDN {
            headers.append("Disposition-Notification-To: \(AddressParser.headerValue(message.from))")
        }
        headers.append(contentsOf: extraHeaders)
        headers.append("MIME-Version: 1.0")
        headers.append("X-Mailer: Ember Mail")

        let altBoundary = boundary("alt")
        let alternative = [
            "Content-Type: multipart/alternative; boundary=\"\(altBoundary)\"",
            "",
            "--\(altBoundary)",
            "Content-Type: text/plain; charset=utf-8",
            "Content-Transfer-Encoding: quoted-printable",
            "",
            TransferEncoding.encodeQuotedPrintable(message.text),
            "--\(altBoundary)",
            "Content-Type: text/html; charset=utf-8",
            "Content-Transfer-Encoding: quoted-printable",
            "",
            TransferEncoding.encodeQuotedPrintable(message.html),
            "--\(altBoundary)--",
            "",
        ].joined(separator: "\r\n")

        // Inline images (e.g. signature logos) wrap the alternative part in multipart/related.
        var content = alternative
        if !message.inlineImages.isEmpty {
            let relatedBoundary = boundary("rel")
            var lines = [
                "Content-Type: multipart/related; boundary=\"\(relatedBoundary)\"",
                "",
                "--\(relatedBoundary)",
                alternative,
            ]
            for image in message.inlineImages {
                let name = RFC2047.encodeIfNeeded(image.filename).replacingOccurrences(of: "\"", with: "'")
                lines.append("--\(relatedBoundary)")
                lines.append("Content-Type: \(image.mimeType); name=\"\(name)\"")
                lines.append("Content-Disposition: inline; filename=\"\(name)\"")
                lines.append("Content-ID: <\(image.contentID ?? image.id.uuidString)>")
                lines.append("Content-Transfer-Encoding: base64")
                lines.append("")
                lines.append(image.data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]))
            }
            lines.append("--\(relatedBoundary)--")
            lines.append("")
            content = lines.joined(separator: "\r\n")
        }

        var body: String
        if message.attachments.isEmpty {
            body = content
        } else {
            let mixedBoundary = boundary("mixed")
            var lines = [
                "Content-Type: multipart/mixed; boundary=\"\(mixedBoundary)\"",
                "",
                "--\(mixedBoundary)",
                content,
            ]
            for att in message.attachments {
                let encodedName = RFC2047.encodeIfNeeded(att.filename).replacingOccurrences(of: "\"", with: "'")
                lines.append("--\(mixedBoundary)")
                lines.append("Content-Type: \(att.mimeType); name=\"\(encodedName)\"")
                lines.append("Content-Disposition: attachment; filename=\"\(encodedName)\"")
                lines.append("Content-Transfer-Encoding: base64")
                lines.append("")
                lines.append(att.data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]))
            }
            lines.append("--\(mixedBoundary)--")
            lines.append("")
            body = lines.joined(separator: "\r\n")
        }

        // The top-level Content-Type line is the first line of `body`; merge it into the header block.
        var bodyLines = body.components(separatedBy: "\r\n")
        let contentTypeHeader = bodyLines.removeFirst()
        _ = bodyLines.removeFirst() // blank line
        headers.append(contentTypeHeader)
        let full = headers.joined(separator: "\r\n") + "\r\n\r\n" + bodyLines.joined(separator: "\r\n")
        return (Data(full.utf8), messageID)
    }

    private static func boundary(_ tag: String) -> String {
        "ember-\(tag)-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20))"
    }

    /// `X-Ember-Draft: <base64 JSON>` folded to 76-character lines.
    static func draftHeader(_ meta: DraftMeta) -> String? {
        guard let json = try? JSONEncoder().encode(meta) else { return nil }
        let b64 = json.base64EncodedString()
        var lines: [String] = []
        var index = b64.startIndex
        while index < b64.endIndex {
            let end = b64.index(index, offsetBy: 76, limitedBy: b64.endIndex) ?? b64.endIndex
            lines.append(String(b64[index..<end]))
            index = end
        }
        return "X-Ember-Draft: " + lines.joined(separator: "\r\n ")
    }

    static func decodeDraftHeader(_ value: String?) -> DraftMeta? {
        guard let value else { return nil }
        let data = TransferEncoding.decodeBase64(Data(value.utf8))
        return try? JSONDecoder().decode(DraftMeta.self, from: data)
    }

    // MARK: - Composing bodies

    static let bodyFont = "-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif"

    /// Builds the HTML part from the user's plain text, signature and quoted original.
    static func html(body: String, signature: String, signatureHTML: String? = nil, quoteHeader: String?, quotedText: String?, pixelURL: URL?) -> String {
        var html = """
        <!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"></head>
        <body style="font-family:\(bodyFont);font-size:14px;line-height:1.55;color:#1f2328;">
        <div>\(HTMLText.fromPlainText(body))</div>
        """
        if let signatureHTML, !signatureHTML.isEmpty {
            html += "\n<div class=\"ember_signature\" style=\"margin-top:18px;\">\(signatureHTML)</div>"
        } else if !signature.isEmpty {
            html += "\n<div class=\"ember_signature\" style=\"margin-top:18px;color:#57606a;\">\(HTMLText.fromPlainText(signature))</div>"
        }
        if let quotedText, !quotedText.isEmpty {
            html += "\n<div class=\"ember_quote\">"
            html += "<div style=\"margin-top:22px;color:#57606a;\">\(HTMLText.escape(quoteHeader ?? ""))</div>"
            html += "<blockquote type=\"cite\" style=\"margin:6px 0 0;padding:0 0 0 12px;border-left:3px solid #d0d7de;color:#57606a;\">\(HTMLText.fromPlainText(quotedText))</blockquote>"
            html += "</div>"
        }
        if let pixelURL {
            html += "\n<img src=\"\(pixelURL.absoluteString)\" width=\"1\" height=\"1\" alt=\"\" style=\"display:block;width:1px;height:1px;border:0;opacity:0;\">"
        }
        html += "\n</body></html>"
        return html
    }

    static func plain(body: String, signature: String, quoteHeader: String?, quotedText: String?) -> String {
        var text = body
        if !signature.isEmpty { text += "\n\n-- \n" + signature }
        if let quotedText, !quotedText.isEmpty {
            text += "\n\n" + (quoteHeader ?? "") + "\n"
            text += quotedText.components(separatedBy: .newlines).map { "> " + $0 }.joined(separator: "\n")
        }
        return text
    }
}
