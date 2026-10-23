import Foundation
import Testing
import UIKit
@testable import Slate

@Suite("Local store")
struct MailStoreTests {
    @Test func threadsAggregateMessagesAndLabels() async throws {
        let store = try Fixtures.store()
        let t0 = Date(timeIntervalSince1970: 1_000)
        try await store.upsertMessages([
            Fixtures.message("a", thread: "t", labels: [SystemLabel.inbox, SystemLabel.unread], date: t0),
            Fixtures.message("b", thread: "t", from: "me@example.com", labels: [SystemLabel.sent, "Label_x"], date: t0.addingTimeInterval(60), body: "Latest"),
        ], accountEmail: "me@example.com")
        let t = try #require(try await store.thread(ThreadRef(accountID: Fixtures.account.id, threadID: "t")))
        #expect(t.messageCount == 2 && t.isUnread && t.snippet == "Latest")
        #expect(t.labelIDs == [SystemLabel.inbox, SystemLabel.unread, SystemLabel.sent, "Label_x"])
        // Archiving removes Inbox only; it never marks the conversation read.
        try await store.applyLabelChange(t.ref, add: [], remove: [SystemLabel.inbox], accountEmail: "me@example.com")
        let archived = try #require(try await store.thread(t.ref))
        #expect(!archived.inInbox && archived.isUnread)
        #expect(try await store.threads(mailbox: .inbox, accountIDs: [Fixtures.account.id], before: nil, limit: 10).isEmpty)
        #expect(try await store.threads(mailbox: .allMail, accountIDs: [Fixtures.account.id], before: nil, limit: 10).count == 1)
    }

    @Test func unifiedPaginationIsStableAcrossAccounts() async throws {
        let store = try Fixtures.store()
        let base = Date(timeIntervalSince1970: 10_000)
        var a: [MailMessage] = [], b: [MailMessage] = []
        for i in 0..<25 {
            a.append(Fixtures.message("a\(i)", thread: "ta\(i)", account: "acct-1", date: base.addingTimeInterval(Double(i * 10))))
            // Same timestamps in the other account exercise the tie-breaker.
            b.append(Fixtures.message("b\(i)", thread: "tb\(i)", account: "acct-2", date: base.addingTimeInterval(Double(i * 10))))
        }
        try await store.upsertMessages(a, accountEmail: "me@example.com")
        try await store.upsertMessages(b, accountEmail: "me@work.example")
        var seen: [ThreadRef] = []
        var cursor: MailStore.ListCursor?
        repeat {
            let page = try await store.threads(mailbox: .inbox, accountIDs: ["acct-1", "acct-2"], before: cursor, limit: 7)
            seen += page.map(\.ref)
            cursor = page.last.map { .init(date: $0.lastDate, key: $0.ref.accountID + "/" + $0.ref.threadID) }
            if page.isEmpty { break }
        } while true
        #expect(seen.count == 50)
        #expect(Set(seen).count == 50)
    }

    @Test func laterHidesFromInboxUntilDue() async throws {
        let store = try Fixtures.store()
        try await store.upsertMessages([Fixtures.message("a", thread: "t")], accountEmail: "me@example.com")
        let ref = ThreadRef(accountID: Fixtures.account.id, threadID: "t")
        try await store.setLater(ref, until: .now.addingTimeInterval(3600))
        #expect(try await store.threads(mailbox: .inbox, accountIDs: [ref.accountID], before: nil, limit: 10).isEmpty)
        #expect(try await store.threads(mailbox: .later, accountIDs: [ref.accountID], before: nil, limit: 10).count == 1)
        #expect(try await store.threads(mailbox: .inbox, accountIDs: [ref.accountID], before: nil, limit: 10, now: .now.addingTimeInterval(7200)).count == 1)
    }

    @Test func removingAnAccountLeavesOthersIntact() async throws {
        let store = try Fixtures.store()
        try await store.saveAccount(Fixtures.account)
        try await store.saveAccount(Fixtures.work)
        try await store.upsertMessages([Fixtures.message("a", thread: "t", account: "acct-1")], accountEmail: "me@example.com")
        try await store.upsertMessages([Fixtures.message("b", thread: "t", account: "acct-2")], accountEmail: "me@work.example")
        try await store.saveDraft(Fixtures.draft())
        try await store.replaceLabels(accountID: "acct-1", [MailLabel(accountID: "acct-1", labelID: "L1", name: "Clients", kind: .user)])
        try await store.replaceLabels(accountID: "acct-2", [MailLabel(accountID: "acct-2", labelID: "L1", name: "Clients", kind: .user)])
        #expect(try await store.labels(accountIDs: ["acct-1", "acct-2"]).count == 2) // same name, distinct per account

        try await store.removeAccount("acct-1")
        #expect(try await store.accounts().map(\.id) == ["acct-2"])
        #expect(try await store.threads(mailbox: .allMail, accountIDs: ["acct-1"], before: nil, limit: 10).isEmpty)
        #expect(try await store.drafts(accountIDs: ["acct-1"]).isEmpty)
        #expect(try await store.threads(mailbox: .allMail, accountIDs: ["acct-2"], before: nil, limit: 10).count == 1)
        #expect(try await store.search(SearchQuery.parse("Body"), accountIDs: ["acct-1", "acct-2"], mailbox: nil).map(\.ref.accountID) == ["acct-2"])
    }

    @Test func metadataRefreshKeepsDownloadedBody() async throws {
        let store = try Fixtures.store()
        try await store.upsertMessages([Fixtures.message("a", thread: "t", body: "Full text")], accountEmail: "me@example.com")
        var meta = Fixtures.message("a", thread: "t", labels: [SystemLabel.inbox, SystemLabel.starred], body: "")
        meta.bodyPlain = nil
        meta.hasFullBody = false
        try await store.upsertMessages([meta], accountEmail: "me@example.com")
        let m = try #require(try await store.message(accountID: Fixtures.account.id, id: "a"))
        #expect(m.bodyPlain == "Full text" && m.labelIDs.contains(SystemLabel.starred))
    }
}

@Suite("Search")
struct SearchQueryTests {
    let cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/Los_Angeles")!; return c }()

    @Test func parsesOperatorsPhrasesOrAndExclusion() {
        let q = SearchQuery.parse("from:ann subject:\"q3 plan\" has:attachment is:unread \"exact words\" -label:promos invoice OR receipt", calendar: cal)
        #expect(q.clauses.count == 7)
        #expect(q.clauses[0].alternatives == [.from("ann")])
        #expect(q.clauses[1].alternatives == [.subject("q3 plan")])
        #expect(q.clauses[4].alternatives == [.phrase("exact words")])
        #expect(q.clauses[5].negated && q.clauses[5].alternatives == [.label("promos")])
        #expect(q.clauses[6].alternatives == [.text("invoice"), .text("receipt")])
        #expect(!q.includesSpamTrash)
        #expect(SearchQuery.parse("in:anywhere x").includesSpamTrash)
    }

    @Test func providerDatesUseLocalMidnightAsEpochSeconds() {
        let q = SearchQuery.parse("after:2026/03/08 before:2026-03-09", calendar: cal)
        // 2026-03-08 00:00 PST = 08:00 UTC; DST begins later that day.
        #expect(q.providerQuery == "after:1772956800 before:1773039600")
    }

    @Test func localSearchMatchesFieldsAndRespectsSpamScope() async throws {
        let store = try Fixtures.store()
        var invoice = Fixtures.message("a", thread: "t1", from: "billing@cobalt.example", subject: "Invoice INV-2207", body: "Amount due")
        invoice.attachments = [AttachmentInfo(attachmentID: "x", partID: "1", filename: "INV-2207.pdf", mimeType: "application/pdf", size: 1, contentID: nil, isInline: false)]
        let spam = Fixtures.message("b", thread: "t2", labels: [SystemLabel.spam], subject: "Invoice prize")
        try await store.upsertMessages([invoice, spam], accountEmail: "me@example.com")
        let ids = [Fixtures.account.id]
        func run(_ s: String) async throws -> [String] { try await store.search(.parse(s), accountIDs: ids, mailbox: nil).map(\.ref.threadID) }
        #expect(try await run("invoice") == ["t1"])
        #expect(Set(try await run("invoice in:anywhere")) == ["t1", "t2"])
        #expect(try await run("from:cobalt") == ["t1"])
        #expect(try await run("filename:INV-2207") == ["t1"])
        #expect(try await run("has:attachment") == ["t1"])
        #expect(try await run("invoice -from:cobalt").isEmpty)
        #expect(try await run("\"amount due\"") == ["t1"])
        #expect(try await run("nothinglikethis").isEmpty)
    }
}

@Suite("Gmail payload mapping")
struct GmailMapperTests {
    @Test func parsesAlternativeCharsetAttachmentsAndInlineImages() throws {
        let latin1 = Data("Café".data(using: .isoLatin1)!).base64URLEncodedString()
        let html = Data("<p>Hi <img src=\"cid:logo\"></p>".utf8).base64URLEncodedString()
        let json = """
        {"id":"m1","threadId":"t1","labelIds":["INBOX","UNREAD"],"snippet":"Caf&eacute; &amp; more","internalDate":"1700000000000",
         "payload":{"mimeType":"multipart/mixed","headers":[{"name":"From","value":"\\"Lane, Jo\\" <jo@x.com>"},{"name":"Subject","value":"Hi"},
           {"name":"To","value":"a@x.com, b@y.com"},{"name":"Message-ID","value":"<abc@x.com>"},{"name":"List-Unsubscribe","value":"<https://u.example>"}],
          "parts":[{"partId":"0","mimeType":"multipart/related","parts":[
              {"partId":"0.0","mimeType":"multipart/alternative","parts":[
                {"partId":"0.0.0","mimeType":"text/plain","headers":[{"name":"Content-Type","value":"text/plain; charset=ISO-8859-1"}],"body":{"data":"\(latin1)"}},
                {"partId":"0.0.1","mimeType":"text/html","headers":[{"name":"Content-Type","value":"text/html; charset=utf-8"}],"body":{"data":"\(html)"}}]},
              {"partId":"0.1","mimeType":"image/png","filename":"","headers":[{"name":"Content-ID","value":"<logo>"},{"name":"Content-Disposition","value":"inline"}],
               "body":{"attachmentId":"att-logo","size":10}}]},
            {"partId":"1","mimeType":"application/pdf","filename":"report.pdf","headers":[{"name":"Content-Disposition","value":"attachment; filename=report.pdf"}],
             "body":{"attachmentId":"att-1","size":2048}}]}}
        """
        let dto = try JSONDecoder().decode(GmailDTO.Message.self, from: Data(json.utf8))
        let m = GmailMapper.message(dto, accountID: "a", full: true)
        #expect(m.bodyPlain == "Café")
        #expect(m.bodyHTML?.contains("cid:logo") == true)
        #expect(m.from?.name == "Lane, Jo" && m.to.count == 2)
        #expect(m.isUnread && m.messageIDHeader == "<abc@x.com>" && m.listUnsubscribe != nil)
        #expect(m.snippet == "Café & more")
        #expect(m.attachments.count == 2)
        #expect(m.visibleAttachments.map(\.filename) == ["report.pdf"])
        #expect(m.date == Date(timeIntervalSince1970: 1_700_000_000))
    }
}

@Suite("Scheduling and focus")
struct LaterAndFocusTests {
    let cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/London")!; c.firstWeekday = 2; return c }()

    @Test func presets() {
        let thursday9pm = cal.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 21, minute: 10))!
        let morning = DateComponents(hour: 8, minute: 30)
        #expect(LaterPreset.laterToday.date(from: thursday9pm, morning: morning, calendar: cal) == nil)
        #expect(LaterPreset.tomorrowMorning.date(from: thursday9pm, morning: morning, calendar: cal) == cal.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 8, minute: 30)))
        // Next week across the end of British Summer Time (25 Oct) still lands at 08:30 local on Monday.
        #expect(LaterPreset.nextWeek.date(from: thursday9pm, morning: morning, calendar: cal) == cal.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 8, minute: 30)))
        let thursday10am = cal.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 10, minute: 20))!
        #expect(LaterPreset.laterToday.date(from: thursday10am, morning: morning, calendar: cal) == cal.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 14)))
    }

    @Test func focusIsExplainableAndCorrectable() {
        func t(_ from: String, labels: Set<String> = [SystemLabel.inbox], list: Bool = false, toMe: Bool = true) -> ThreadSummary {
            ThreadSummary(ref: .init(accountID: "a", threadID: from), subject: "", snippet: "", lastDate: .now, participants: [], messageCount: 1,
                          hasAttachment: false, isUnread: true, isStarred: false, isImportant: labels.contains(SystemLabel.important),
                          labelIDs: labels, latestFrom: EmailAddress(name: nil, address: from), isMailingList: list, toMe: toMe, laterUntil: nil)
        }
        var f = FocusClassifier(senderRules: [:], correspondents: ["a|friend@x.com"], identities: ["me@x.com"])
        #expect(f.reason(for: t("friend@x.com")) == .repliedBefore)
        #expect(f.reason(for: t("person@x.com")) == .directCorrespondent)
        #expect(f.reason(for: t("news@x.com", list: true)) == nil)
        #expect(f.reason(for: t("noreply@shop.com")) == nil)
        #expect(f.reason(for: t("deals@shop.com", labels: [SystemLabel.inbox, SystemLabel.important, "CATEGORY_PROMOTIONS"])) == nil)
        f.senderRules = ["news@x.com": "always", "person@x.com": "never"]
        #expect(f.reason(for: t("news@x.com", list: true)) == .vip)
        #expect(f.reason(for: t("person@x.com")) == nil)
    }

    @Test func deepLinksRoundTripAndRejectUnknownHosts() {
        let ref = ThreadRef(accountID: "acct 1", threadID: "abc")
        #expect(DeepLink.parse(DeepLink.thread(ref)) == .thread(ref))
        #expect(DeepLink.parse(URL(string: "slate://unknown/x")!) == nil)
        if case .compose(let to, let subject, _) = DeepLink.parse(URL(string: "mailto:ann@x.com?subject=Hi%20there")!) {
            #expect(to.map(\.address) == ["ann@x.com"] && subject == "Hi there")
        } else { Issue.record("mailto not parsed") }
    }
}

@Suite("Color contrast (WCAG relative luminance)")
struct ContrastTests {
    func ratio(_ a: String, _ b: String, _ traits: UITraitCollection) throws -> Double {
        func lum(_ name: String) throws -> Double {
            let c = try #require(UIColor(named: name, in: Bundle(for: AppModel.self), compatibleWith: traits)).resolvedColor(with: traits)
            var r: CGFloat = 0, g: CGFloat = 0, bl: CGFloat = 0, al: CGFloat = 0
            c.getRed(&r, green: &g, blue: &bl, alpha: &al)
            func ch(_ v: CGFloat) -> Double { let v = Double(v); return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * ch(r) + 0.7152 * ch(g) + 0.0722 * ch(bl)
        }
        let (l1, l2) = (try lum(a), try lum(b))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    static let modes: [UITraitCollection] = [
        UITraitCollection(userInterfaceStyle: .light),
        UITraitCollection(userInterfaceStyle: .dark),
        UITraitCollection(traitsFrom: [.init(userInterfaceStyle: .light), .init(accessibilityContrast: .high)]),
        UITraitCollection(traitsFrom: [.init(userInterfaceStyle: .dark), .init(accessibilityContrast: .high)]),
    ]

    @Test(arguments: [("InkPrimary", "Canvas"), ("InkSecondary", "Canvas"), ("InkMetadata", "Canvas"), ("InkSecondary", "SurfaceSecondary"),
                      ("InkSecondary", "SurfaceElevated"), ("InkMetadata", "SurfaceSecondary"), ("Accent", "Canvas"), ("OnAccent", "Accent"),
                      ("InkPrimary", "SelectionFill"), ("Link", "Canvas"), ("Destructive", "Canvas"), ("Positive", "Canvas"), ("Warning", "Canvas"),
                      ("ChipEmberInk", "ChipEmberFill"), ("ChipAmberInk", "ChipAmberFill"), ("ChipSageInk", "ChipSageFill"),
                      ("ChipMauveInk", "ChipMauveFill"), ("ChipStoneInk", "ChipStoneFill")])
    func textPairsMeetAA(_ pair: (String, String)) throws {
        for traits in Self.modes {
            let r = try ratio(pair.0, pair.1, traits)
            #expect(r >= 4.5, "\(pair.0) on \(pair.1) is \(String(format: "%.2f", r)):1 in \(traits.userInterfaceStyle == .dark ? "dark" : "light")\(traits.accessibilityContrast == .high ? " high contrast" : "")")
        }
    }
}

extension ContrastTests {
    /// The unread dot is a graphical indicator: WCAG non-text contrast of 3:1.
    @Test func signalDotMeetsNonTextContrast() throws {
        for traits in Self.modes { #expect(try ratio("Signal", "Canvas", traits) >= 3) }
    }
}
