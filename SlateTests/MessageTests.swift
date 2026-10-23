import Foundation
import Testing
@testable import Slate

@Suite("MIME generation")
struct MIMEBuilderTests {
    func build(subject: String = "Hello", attachments: [MIMEBuilder.Attachment] = [], bcc: [EmailAddress] = []) -> String {
        String(decoding: MIMEBuilder.build(.init(
            from: EmailAddress(name: "Lane, Jo", address: "jo@example.com"),
            to: [EmailAddress(name: "Ann", address: "ann@example.org")], cc: [], bcc: bcc, subject: subject,
            plain: "Line one\nLine two", html: "<div>Line one</div>", inReplyTo: "<a@x>", references: "<z@x> <a@x>",
            messageID: "<id@example.com>", date: Date(timeIntervalSince1970: 0), attachments: attachments), boundarySeed: "B"), as: UTF8.self)
    }

    @Test func headersAreWellFormed() {
        let s = build()
        #expect(s.contains("From: \"Lane, Jo\" <jo@example.com>\r\n"))
        #expect(s.contains("To: Ann <ann@example.org>\r\n"))
        #expect(s.contains("Message-ID: <id@example.com>\r\n"))
        #expect(s.contains("In-Reply-To: <a@x>\r\nReferences: <z@x> <a@x>"))
        #expect(s.contains("Content-Type: multipart/alternative; boundary=\"alt-B\""))
        #expect(!s.contains("Bcc:"))
        // Bodies are base64 so line endings and Unicode survive transport.
        #expect(s.contains(Data("Line one\r\nLine two".utf8).base64EncodedString()))
    }

    @Test func unicodeSubjectUsesEncodedWordsThatRoundTrip() {
        let subject = "Résumé — 季度计划 ✅ with a fairly long tail to force folding across words"
        let s = build(subject: subject)
        let line = s.components(separatedBy: "\r\n").drop { !$0.hasPrefix("Subject:") }
        let header = ([line.first!.dropFirst(9)] + line.dropFirst().prefix { $0.hasPrefix(" ") }.map { $0.dropFirst() }).joined()
        #expect(MIMEBuilder.decodeEncodedWords(String(header)) == subject)
        for word in header.components(separatedBy: "?==?") { #expect(word.count < 80) }
    }

    @Test func bccIsIncludedForGmailToDeliverAndStrip() {
        #expect(build(bcc: [EmailAddress(name: nil, address: "hidden@example.org")]).contains("Bcc: hidden@example.org\r\n"))
    }

    @Test func attachmentsUseMixedMultipartAndRFC2231Names() {
        let s = build(attachments: [.init(filename: "Q3 résumé.pdf", mimeType: "application/pdf", data: Data(repeating: 7, count: 200))])
        #expect(s.contains("Content-Type: multipart/mixed; boundary=\"mixed-B\""))
        #expect(s.contains("filename*=UTF-8''Q3%20r%C3%A9sum%C3%A9.pdf"))
        #expect(s.contains("--mixed-B--"))
        for line in s.components(separatedBy: "\r\n") { #expect(line.count <= 998) }
    }

    @Test func injectedNewlinesCannotAddHeaders() {
        let s = build(subject: "Hi\r\nBcc: attacker@example.com")
        #expect(!s.contains("\r\nBcc: attacker"))
    }
}

@Suite("Reply recipients")
struct ReplyFactoryTests {
    let me = Fixtures.account
    func incoming(replyTo: [EmailAddress] = []) -> MailMessage {
        var m = Fixtures.message("m1", thread: "t1", from: "ann@example.org")
        m.from = EmailAddress(name: "Ann", address: "ann@example.org")
        m.to = [EmailAddress(name: nil, address: "me@example.com"), EmailAddress(name: "Bo", address: "bo@example.org")]
        m.cc = [EmailAddress(name: nil, address: "ME@work.example"), EmailAddress(name: "Cy", address: "cy@example.org")]
        m.bcc = [EmailAddress(name: nil, address: "secret@example.org")]
        m.replyTo = replyTo
        m.messageIDHeader = "<m1@x>"
        m.references = "<m0@x>"
        m.subject = "Plans"
        return m
    }

    @Test func replyGoesToSenderOrReplyTo() {
        #expect(ReplyFactory.draft(kind: .reply, replyingTo: incoming(), account: me, identities: []).to.map(\.address) == ["ann@example.org"])
        let list = [EmailAddress(name: nil, address: "list@example.org")]
        #expect(ReplyFactory.draft(kind: .reply, replyingTo: incoming(replyTo: list), account: me, identities: []).to == list)
    }

    @Test func replyAllRemovesEveryOwnIdentityAndNeverCopiesBcc() {
        let d = ReplyFactory.draft(kind: .replyAll, replyingTo: incoming(), account: me, identities: ["me@example.com", "me@work.example"])
        #expect(d.to.map(\.address) == ["ann@example.org", "bo@example.org"])
        #expect(d.cc.map(\.address) == ["cy@example.org"])
        #expect(d.bcc.isEmpty)
        #expect(d.subject == "Re: Plans")
        #expect(d.threadID == "t1")
        #expect(d.inReplyTo == "<m1@x>")
        #expect(d.references == "<m0@x> <m1@x>")
    }

    @Test func replyToOwnSentMessageAddressesOriginalRecipients() {
        var m = incoming()
        m.from = EmailAddress(name: nil, address: "me@example.com")
        let d = ReplyFactory.draft(kind: .reply, replyingTo: m, account: me, identities: ["me@example.com"])
        #expect(d.to.map(\.address) == ["me@example.com", "bo@example.org"])
    }

    @Test func forwardHasNoRecipientsAndKeepsOriginal() {
        let d = ReplyFactory.draft(kind: .forward, replyingTo: incoming(), account: me, identities: [])
        #expect(d.allRecipients.isEmpty)
        #expect(d.subject == "Fwd: Plans")
        #expect(d.quoted?.attribution.contains("Forwarded message") == true)
        #expect(ReplyFactory.subject("Re: Plans", kind: .reply) == "Re: Plans")
    }

    @Test func signatureSwapsWhenFromChangesButNotAfterEdits() {
        var d = ReplyFactory.newDraft(account: Account(id: "a", email: "a@x.com", displayName: "", friendlyName: "", provider: .gmail, signature: "A sig"))
        d.bodyText = "Hello" + d.bodyText
        ReplyFactory.applySignature(&d, signature: "B sig")
        #expect(d.bodyText == "Hello\n\nB sig")
        d.bodyText = "Hello\n\nB sig edited"
        ReplyFactory.applySignature(&d, signature: "C sig")
        #expect(d.bodyText.hasPrefix("Hello\n\nB sig edited"))
    }

    @Test func draftRenderingProducesListsLinksAndQuote() {
        var d = Fixtures.draft()
        d.bodyText = "Hi\n• one\n• two\nBye"
        d.quoted = QuotedContent(attribution: "On Mon, Ann wrote:", plain: "Earlier <text>", html: nil)
        let r = DraftRenderer.render(d)
        #expect(r.html.contains("<ul><li>one</li><li>two</li></ul>"))
        #expect(r.html.contains("Earlier &lt;text&gt;"))
        #expect(r.plain.contains("> Earlier <text>"))
        d.includeQuoted = false
        #expect(!DraftRenderer.render(d).plain.contains("Earlier"))
    }
}

@Suite("Addresses")
struct AddressTests {
    @Test func parsesQuotedNamesWithCommas() {
        let list = EmailAddress.parseList("\"Lane, Jo\" <jo@x.com>, b@y.com; Name <c@z.com>")
        #expect(list.map(\.address) == ["jo@x.com", "b@y.com", "c@z.com"])
        #expect(list[0].name == "Lane, Jo")
    }

    @Test func validatesAddresses() {
        #expect(EmailAddress(name: nil, address: "a@b.co").isValid)
        for bad in ["a@b", "@b.com", "a b@c.com", "a@@b.com", "a@b.com,"] { #expect(!EmailAddress(name: nil, address: bad).isValid) }
    }
}
