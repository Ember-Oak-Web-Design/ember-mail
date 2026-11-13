// Standalone parser tests (no XCTest in Command Line Tools). Run: ./scripts/test.sh
import Foundation

var failures = 0
var passes = 0
func expect(_ condition: @autoclosure () -> Bool, _ name: String, file: String = #file, line: Int = #line) {
    if condition() { passes += 1 } else { failures += 1; print("✗ \(name) (line \(line))") }
}
func expectEqual<T: Equatable>(_ a: T, _ b: T, _ name: String, line: Int = #line) {
    if a == b { passes += 1 } else { failures += 1; print("✗ \(name) (line \(line))\n    got: \(a)\n    expected: \(b)") }
}

// MARK: RFC 2047
expectEqual(RFC2047.decode("=?UTF-8?B?SGVsbG8gV8O2cmxk?="), "Hello Wörld", "rfc2047 base64")
expectEqual(RFC2047.decode("=?iso-8859-1?Q?Caf=E9_au_lait?="), "Café au lait", "rfc2047 Q latin1")
expectEqual(RFC2047.decode("=?UTF-8?Q?a?= =?UTF-8?Q?b?="), "ab", "rfc2047 adjacent words join")
expectEqual(RFC2047.decode("Re: =?UTF-8?B?w6k=?= done"), "Re: é done", "rfc2047 mixed")
let longSubject = String(repeating: "Ünïcødé ", count: 12)
expectEqual(RFC2047.decode(RFC2047.encodeIfNeeded(longSubject).replacingOccurrences(of: "\r\n", with: "")), longSubject, "rfc2047 roundtrip long")

// MARK: Quoted printable
expectEqual(TransferEncoding.decodeQuotedPrintable(Data("caf=C3=A9 =\r\nsoft".utf8)).lenientString, "café soft", "qp decode")
let qpSource = "Line with = sign and ünicode and a very long line " + String(repeating: "x", count: 120) + " end  "
let qp = TransferEncoding.encodeQuotedPrintable(qpSource)
expect(qp.components(separatedBy: "\r\n").allSatisfy { $0.count <= 76 }, "qp line length")
expectEqual(TransferEncoding.decodeQuotedPrintable(Data(qp.utf8)).lenientString, qpSource, "qp roundtrip")

// MARK: Base64 truncated
expectEqual(TransferEncoding.decodeBase64(Data("SGVsbG8g\r\nV29ybGQ=".utf8)).lenientString, "Hello World", "base64 with newlines")
expectEqual(TransferEncoding.decodeBase64(Data("SGVsbG8gV29y".utf8)).lenientString, "Hello Wor", "base64 truncated")

// MARK: Addresses
let addrs = AddressParser.parseList("\"Smith, Jane\" <jane@x.com>, bob@y.org, =?UTF-8?B?SsO2cmc=?= <j@z.de>")
expectEqual(addrs.count, 3, "address count")
expectEqual(addrs[0].name, "Smith, Jane", "quoted name with comma")
expectEqual(addrs[1].email, "bob@y.org", "bare address")
expectEqual(addrs[2].name, "Jörg", "encoded name")
expectEqual(AddressParser.headerValue(EmailAddress(name: "Smith, Jane", email: "j@x.com")), "\"Smith, Jane\" <j@x.com>", "header quoting")

// MARK: Dates
expect(MailDate.parse("Tue, 10 Nov 2026 14:03:22 +0200 (SAST)") != nil, "date with comment")
expect(MailDate.parse("10 Nov 2026 14:03:22 GMT") != nil, "date without weekday")
expect(MailDate.parse("10-Nov-2026 14:03:22 +0000") != nil, "imap internaldate")

// MARK: Modified UTF-7
expectEqual(ModifiedUTF7.decode("Entw&APw-rfe"), "Entwürfe", "utf7 decode")
expectEqual(ModifiedUTF7.decode("A&-B"), "A&B", "utf7 ampersand")
expectEqual(ModifiedUTF7.decode(ModifiedUTF7.encode("Gesendete Objekte – 2026 & co")), "Gesendete Objekte – 2026 & co", "utf7 roundtrip")

// MARK: IMAP tokenizer
let fetchLine = Data("12 FETCH (UID 345 FLAGS (\\Seen \\Flagged) INTERNALDATE \"10-Nov-2026 14:03:22 +0000\" BODY[HEADER.FIELDS (FROM SUBJECT)] {28}\r\nSubject: Hi\r\nFrom: a@b.c\r\n\r\n BODY[TEXT]<0> NIL)".utf8)
let tokens = IMAPTokenizer.parse(fetchLine)
expectEqual(tokens.count, 3, "fetch token count")
expectEqual(tokens[1].text, "FETCH", "fetch keyword")
if let items = tokens[2].list {
    expectEqual(items.count, 10, "fetch item count")
    expectEqual(items[1].text, "345", "uid")
    expectEqual(items[3].list?.count, 2, "flags list")
    expectEqual(items[6].text, "BODY[HEADER.FIELDS (FROM SUBJECT)]", "bracketed atom")
    expectEqual(items[7].data?.count, 28, "literal length")
    expectEqual(items[8].text, "BODY[TEXT]<0>", "partial atom")
    expectEqual(items[9], .null, "NIL")
} else { expect(false, "fetch list") }
let listTokens = IMAPTokenizer.parse(Data("LIST (\\HasNoChildren \\Sent) \"/\" \"Sent Items\"".utf8))
expectEqual(listTokens[3].text, "Sent Items", "list quoted name")

// MARK: MIME parsing
let raw = """
From: Jane <jane@example.com>\r
To: me@emberandoak.com\r
Subject: =?UTF-8?Q?Quarterly_r=C3=A9port?=\r
Message-ID: <abc@example.com>\r
Content-Type: multipart/mixed; boundary="outer"\r
\r
--outer\r
Content-Type: multipart/alternative; boundary=inner\r
\r
--inner\r
Content-Type: text/plain; charset=utf-8\r
Content-Transfer-Encoding: quoted-printable\r
\r
Hi there, see the r=C3=A9port.\r
--inner\r
Content-Type: text/html; charset=utf-8\r
\r
<p>Hi there, see the <b>report</b>.</p><img src="cid:logo1">\r
--inner--\r
--outer\r
Content-Type: image/png; name="logo.png"\r
Content-ID: <logo1>\r
Content-Transfer-Encoding: base64\r
\r
iVBORw0KGgo=\r
--outer\r
Content-Type: application/pdf\r
Content-Disposition: attachment; filename*=utf-8''R%C3%A9sum%C3%A9.pdf\r
Content-Transfer-Encoding: base64\r
\r
JVBERi0xLjQ=\r
--outer--\r

"""
let root = MIMEParser.parse(Data(raw.utf8))
expectEqual(root.decodedHeader("subject"), "Quarterly réport", "decoded subject")
let body = MessageExtraction.body(from: root)
expectEqual(body.text?.trimmingCharacters(in: .whitespacesAndNewlines), "Hi there, see the réport.", "plain part")
expect(body.html?.contains("data:image/png;base64") == true, "cid image inlined")
expectEqual(body.attachments.map(\.filename), ["Résumé.pdf"], "attachments (inline image hidden, RFC 2231 name)")
expectEqual(body.messageIDHeader, "<abc@example.com>", "message id")
expectEqual(MessageExtraction.snippet(from: root), "Hi there, see the réport.", "snippet")

// Truncated message (as fetched for list previews) still yields a snippet.
let truncated = MIMEParser.parse(Data(raw.prefix(600).utf8))
expect(MessageExtraction.snippet(from: truncated).hasPrefix("Hi there"), "truncated snippet")

// MARK: Builder roundtrip
let outgoing = OutgoingMessage(
    from: EmailAddress(name: "Ember & Oak", email: "hello@emberandoak.com"),
    to: [EmailAddress(name: "Jörg Müller", email: "jorg@example.de")],
    cc: [], bcc: [EmailAddress(email: "secret@example.com")],
    subject: "Proposal – Q3 ✨", text: "Hello Jörg,\nHere it is.", html: "<p>Hello Jörg</p>",
    attachments: [OutgoingAttachment(filename: "quote.pdf", mimeType: "application/pdf", data: Data("PDFDATA".utf8))],
    requestMDN: true)
let built = MIMEBuilder.build(outgoing, includeBcc: false)
let reparsed = MIMEParser.parse(built.data)
expectEqual(reparsed.decodedHeader("subject"), "Proposal – Q3 ✨", "built subject")
expectEqual(AddressParser.parseList(reparsed.header("to")).first?.name, "Jörg Müller", "built recipient name")
expect(reparsed.header("bcc") == nil, "bcc omitted for SMTP")
expect(reparsed.header("disposition-notification-to") != nil, "MDN header")
let rebody = MessageExtraction.body(from: reparsed)
expectEqual(rebody.text, "Hello Jörg,\r\nHere it is.", "built text part")
expectEqual(rebody.attachments.first?.data, Data("PDFDATA".utf8), "built attachment")
expect(built.data.lenientString.unicodeScalars.allSatisfy { $0.isASCII }, "built message is 7-bit clean")
expect(MIMEBuilder.build(outgoing, includeBcc: true).data.lenientString.contains("Bcc: secret@example.com"), "bcc for Gmail")

// MARK: HTML helpers
expectEqual(HTMLText.toPlainText("<style>x{}</style><p>Hello&nbsp;<b>there</b></p><p>Bye &amp; thanks</p>"), "Hello there\nBye & thanks", "html to text")
expect(HTMLText.fromPlainText("see https://example.com/a.").contains("<a href=\"https://example.com/a\">"), "linkify trims punctuation")

// MARK: Snippet fixes (truncated UTF-8, unclosed <style>, preheader padding, partial QP)
var cut = Data("Please review ͏ ­ ͏ ­ and respond é".utf8)
cut.removeLast() // split the final multi-byte character
let cutText = Charset.string(from: cut, charset: "utf-8")
expect(cutText.hasPrefix("Please review"), "truncated utf-8 stays utf-8")
expect(!cutText.contains("Ã"), "no mojibake")
expectEqual(HTMLText.snippet(from: "Please review ͏ ­ ͏ ­ ͏ and respond soon"), "Please review and respond soon", "preheader padding removed")
expectEqual(HTMLText.toPlainText("<html><head><style>/* General */ #outlook a { padding:0; } .x{color:red"), "", "unclosed style removed")
expectEqual(TransferEncoding.decodeQuotedPrintable(Data("Reply to this=\r\n email =E".utf8)).lenientString, "Reply to this email ", "partial QP at end dropped")
expectEqual(HTMLText.snippet(from: "blockquote:before { content: none !important; }\nHello there"), "Hello there", "css lines skipped in snippet")

// MARK: Subjects & threading
expectEqual(Subject.normalize("Re: RE: Fwd: Webflow Premium Partner"), "Webflow Premium Partner", "subject prefixes")
let acct = UUID()
func msg(_ id: String, _ subject: String, mid: String, refs: [String] = [], from: String = "a@x.com", date: Double) -> MessageSummary {
    MessageSummary(accountID: acct, mailboxPath: "INBOX", remoteID: id, threadID: nil, from: EmailAddress(email: from),
                   to: [EmailAddress(email: "me@example.com")], cc: [], subject: subject, snippet: "", date: Date(timeIntervalSince1970: date),
                   isRead: true, isFlagged: false, hasAttachments: false, messageIDHeader: mid, references: refs, inReplyTo: refs.last)
}
let m1 = msg("1", "Webflow Premium Partner", mid: "<a@x>", date: 1)
let m2 = msg("2", "Re: Webflow Premium Partner", mid: "<b@x>", refs: ["<a@x>"], from: "me@example.com", date: 2)
let m3 = msg("3", "Re: Webflow Premium Partner", mid: "<c@x>", refs: ["<a@x>", "<b@x>"], date: 3)
let other = msg("4", "Re: Webflow Premium Partner", mid: "<z@y>", refs: ["<y@y>"], from: "stranger@y.com", date: 2.5)
let assembled = IMAPProvider.assemble(message: m3, candidates: [m3, other, m2, m1, m2])
expectEqual(assembled.map(\.remoteID), ["1", "2", "3"], "thread assembled oldest-first, deduped, unrelated excluded")
expectEqual(m1.threadKey, m3.threadKey, "thread key shared by root and replies")
expect(m1.threadKey != msg("9", "Something else", mid: "<q@x>", date: 1).threadKey, "different threads differ")

// MARK: Quote stripping (plain text)
let replyText = """
Hi Jo - I'm free on Thursday.

Thanks,
Leigh

On Mon, Nov 9, 2026 at 9:54 AM Jo Example <jo@example.com> wrote:
> Thanks Tyrone,
> Appreciate it.
"""
expectEqual(QuoteStripper.plain(replyText), "Hi Jo - I'm free on Thursday.\n\nThanks,\nLeigh", "plain attribution cut")
let outlookText = "Sounds good.\n\nFrom: Jo Example <jo@x.com>\nSent: Monday\nTo: Leigh\nSubject: Re: X\n\nOld text"
expectEqual(QuoteStripper.plain(outlookText), "Sounds good.", "outlook header cut")
expectEqual(QuoteStripper.plain("> only quoted\n> text"), "> only quoted\n> text", "never strip everything")

// MARK: Inline signature images (multipart/related)
var withSig = outgoing
withSig.attachments = []
withSig.html = "<p>Hi</p><img src=\"cid:sig-1@embermail\">"
withSig.inlineImages = [OutgoingAttachment(filename: "logo.png", mimeType: "image/png", data: Data([0x89, 0x50, 0x4E, 0x47]), contentID: "sig-1@embermail")]
let sigParsed = MIMEParser.parse(MIMEBuilder.build(withSig, includeBcc: false).data)
expectEqual(sigParsed.contentType.type, "multipart/related", "related at top level")
let sigBody = MessageExtraction.body(from: sigParsed)
expect(sigBody.html?.contains("data:image/png;base64") == true, "inline signature image resolves")
expect(sigBody.attachments.isEmpty, "inline image not listed as attachment")
var both = withSig
both.attachments = [OutgoingAttachment(filename: "quote.pdf", mimeType: "application/pdf", data: Data("PDF".utf8))]
let bothBody = MessageExtraction.body(from: MIMEParser.parse(MIMEBuilder.build(both, includeBcc: false).data))
expectEqual(bothBody.attachments.map(\.filename), ["quote.pdf"], "mixed > related > alternative structure")
expect(MIMEBuilder.html(body: "x", signature: "", quoteHeader: "On X wrote:", quotedText: "old", pixelURL: nil).contains("class=\"ember_quote\""), "our quotes are marked for hiding")

// MARK: Drafts round-trip (X-Ember-Draft header)
let meta = DraftMeta(body: "Hi Leigh,\n\nThursday 11am works — see you then. ✨", to: "Leigh <leigh@webflow.com>", cc: "",
                     bcc: "me@x.com", quoteHeader: "On Mon, Leigh wrote:", quotedText: String(repeating: "Old quoted line\n", count: 80),
                     inReplyTo: "<c@x>", references: ["<a@x>", "<c@x>"], threadID: "18c2")
var draftMsg = outgoing
draftMsg.attachments = []
let draftBuilt = MIMEBuilder.build(draftMsg, includeBcc: true, extraHeaders: [MIMEBuilder.draftHeader(meta)!])
expect(draftBuilt.data.lenientString.components(separatedBy: "\r\n").allSatisfy { $0.count <= 998 }, "draft header lines within RFC limit")
let draftBody = MessageExtraction.body(from: draftBuilt.data)
let restored = MIMEBuilder.decodeDraftHeader(draftBody.emberDraftMeta)
expectEqual(restored?.body, meta.body, "draft body restored")
expectEqual(restored?.quotedText, meta.quotedText, "draft quote restored")
expectEqual(restored?.references ?? [], meta.references, "draft references restored")
expectEqual(restored?.bcc, "me@x.com", "draft bcc restored")
expect(MIMEBuilder.decodeDraftHeader(nil) == nil, "no header → nil")

// MARK: Updates
expect(AppVersion("1.2.0")! > AppVersion("1.1.9")!, "version compare minor")
expect(AppVersion("v2.0")! > AppVersion("1.9.9")!, "version compare major, v prefix")
expect(AppVersion("1.0")! == AppVersion("1.0.0")!, "1.0 == 1.0.0")
expect(AppVersion("1.10.0")! > AppVersion("1.9.0")!, "numeric not lexical")
expect(AppVersion("1.2.3-beta")!.description == "1.2.3", "suffix dropped")
expect(AppVersion("abc") == nil, "invalid version")
let relJSON = """
{"tag_name":"v1.3.0","body":"Notes","html_url":"https://github.com/o/r/releases/tag/v1.3.0","draft":false,"prerelease":false,
 "assets":[{"name":"Ember-Mail-1.3.0.zip","browser_download_url":"https://x/a.zip"},{"name":"Ember-Mail-1.3.0.zip.sha256","browser_download_url":"https://x/a.sha"}]}
"""
let rel = UpdateLogic.parseRelease(Data(relJSON.utf8))
expectEqual(rel?.version.description, "1.3.0", "release version")
expectEqual(rel?.zipURL.absoluteString, "https://x/a.zip", "release zip")
expectEqual(rel?.checksumURL?.absoluteString, "https://x/a.sha", "release checksum asset")
expect(UpdateLogic.parseRelease(Data(relJSON.replacingOccurrences(of: "\"prerelease\":false", with: "\"prerelease\":true").utf8)) == nil, "prerelease ignored")
expect(UpdateLogic.parseRelease(Data("{}".utf8)) == nil, "garbage ignored")
let hash = String(repeating: "ab", count: 32)
expectEqual(UpdateLogic.parseChecksum("\(hash.uppercased())  Ember-Mail-1.3.0.zip\n"), hash, "checksum parse")
expect(UpdateLogic.parseChecksum("nothex") == nil, "bad checksum")

print("\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
