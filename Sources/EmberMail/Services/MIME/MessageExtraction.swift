import Foundation

/// Turns parsed MIME trees into the app's message models.
enum MessageExtraction {
    static func body(from raw: Data) -> MessageBody {
        let root = MIMEParser.parse(raw)
        return body(from: root)
    }

    static func body(from root: MIMEPart) -> MessageBody {
        var html: String?
        var text: String?
        var attachments: [AttachmentInfo] = []
        collect(root, html: &html, text: &text, attachments: &attachments)

        // Inline cid: images → data URIs so they render without network access.
        var embeddedCIDs = Set<String>()
        if var h = html {
            for att in attachments {
                guard let cid = att.contentID, h.contains("cid:\(cid)") else { continue }
                let uri = "data:\(att.mimeType);base64,\(att.data.base64EncodedString())"
                h = h.replacingOccurrences(of: "cid:\(cid)", with: uri)
                embeddedCIDs.insert(cid)
            }
            html = h
        }
        // Images shown inside the body don't need to be listed as attachments too.
        let visibleAttachments = attachments.filter { att in
            guard let cid = att.contentID else { return true }
            return !embeddedCIDs.contains(cid)
        }

        let references = (root.header("references") ?? "")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.hasPrefix("<") }
        return MessageBody(
            html: html,
            text: text,
            attachments: visibleAttachments,
            replyTo: AddressParser.parseList(root.header("reply-to")),
            to: AddressParser.parseList(root.header("to")),
            cc: AddressParser.parseList(root.header("cc")),
            references: references,
            messageIDHeader: root.header("message-id")?.trimmingCharacters(in: .whitespaces),
            emberDraftMeta: root.header("x-ember-draft")
        )
    }

    private static func collect(_ part: MIMEPart, html: inout String?, text: inout String?, attachments: inout [AttachmentInfo]) {
        let type = part.contentType.type
        if type == "multipart/alternative" {
            // Prefer the richest alternative we understand (last one), but keep a text version too.
            for child in part.children {
                collect(child, html: &html, text: &text, attachments: &attachments)
            }
            return
        }
        if part.isMultipart {
            for child in part.children {
                collect(child, html: &html, text: &text, attachments: &attachments)
            }
            return
        }
        if type == "message/rfc822", let inner = part.children.first {
            // Forwarded message: surface as attachment and keep its text if we have none.
            attachments.append(AttachmentInfo(filename: inner.decodedHeader("subject").map { "\($0).eml" } ?? "message.eml",
                                              mimeType: "message/rfc822", data: part.decodedBody))
            return
        }
        if part.isAttachment {
            let cid = part.header("content-id")?.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
            let inline = part.contentDisposition?.type == "inline" || (cid != nil && part.contentDisposition == nil)
            attachments.append(AttachmentInfo(
                filename: part.filename ?? defaultName(for: type),
                mimeType: type,
                data: part.decodedBody,
                contentID: cid,
                isInline: inline))
            return
        }
        if type == "text/html" {
            let value = part.text
            html = (html.map { $0 + "<hr>" } ?? "") + value
        } else if type == "text/plain" || type.hasPrefix("text/") {
            let value = part.text
            text = (text.map { $0 + "\n\n" } ?? "") + value
        }
    }

    private static func defaultName(for type: String) -> String {
        let ext = type.components(separatedBy: "/").last ?? "bin"
        return "attachment.\(ext)"
    }

    /// Snippet from a (possibly truncated) message.
    static func snippet(from part: MIMEPart) -> String {
        let leaves = part.leaves.filter { !$0.isAttachment }
        if let plain = leaves.first(where: { $0.contentType.type == "text/plain" }) {
            return HTMLText.snippet(from: plain.text)
        }
        if let html = leaves.first(where: { $0.contentType.type == "text/html" }) {
            return HTMLText.snippet(from: HTMLText.toPlainText(html.text))
        }
        return ""
    }

    static func hasAttachments(_ part: MIMEPart) -> Bool {
        part.contentType.type == "multipart/mixed" || part.leaves.contains { $0.isAttachment && !($0.contentDisposition?.type == "inline") }
    }
}
