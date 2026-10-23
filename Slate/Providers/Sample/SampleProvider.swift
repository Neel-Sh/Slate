import Foundation

/// An in-memory mailbox used to explore the app without a Google account.
/// It is always presented as "Sample" and never touches the network.
nonisolated final class SampleProvider: MailProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String: MailMessage] = [:]
    private var userLabels: [MailLabel]
    private var history = 1000
    private let accountID: String
    private let email: String

    init(accountID: String, email: String, now: Date = .now) {
        self.accountID = accountID
        self.email = email
        let fixtures = SampleFixtures.make(accountID: accountID, me: email, now: now)
        for m in fixtures.messages { messages[m.id] = m }
        userLabels = fixtures.labels
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }

    func profile() async throws -> ProviderProfile { ProviderProfile(email: email, historyID: String(history)) }

    func labels(accountID: String) async throws -> [MailLabel] {
        let system = [SystemLabel.inbox, SystemLabel.starred, SystemLabel.important, SystemLabel.sent, SystemLabel.draft, SystemLabel.spam, SystemLabel.trash, SystemLabel.unread]
            .map { MailLabel(accountID: accountID, labelID: $0, name: $0.capitalized, kind: .system) }
        return system + locked { userLabels }
    }

    func listThreads(labelID: String?, query: String?, includeSpamTrash: Bool, pageToken: String?, maxResults: Int) async throws -> ThreadPage {
        let all = locked { Array(messages.values) }
        var threads: [String: Date] = [:]
        let parsed = query.map { SearchQuery.parse($0) }
        for m in all {
            if let labelID, !m.labelIDs.contains(labelID) { continue }
            if !includeSpamTrash && labelID != SystemLabel.spam && labelID != SystemLabel.trash
                && (m.labelIDs.contains(SystemLabel.spam) || m.labelIDs.contains(SystemLabel.trash)) { continue }
            if let parsed, !Self.matches(m, parsed) { continue }
            threads[m.threadID] = max(threads[m.threadID] ?? .distantPast, m.date)
        }
        let ids = threads.sorted { $0.value > $1.value }.map(\.key)
        let start = Int(pageToken ?? "0") ?? 0
        let slice = Array(ids.dropFirst(start).prefix(maxResults))
        return ThreadPage(threadIDs: slice, nextPageToken: start + slice.count < ids.count ? String(start + slice.count) : nil)
    }

    private static func matches(_ m: MailMessage, _ q: SearchQuery) -> Bool {
        let hay = [m.subject, m.from?.displayName ?? "", m.from?.address ?? "", m.bodyPlain ?? "", m.snippet,
                   m.attachments.map(\.filename).joined(separator: " ")].joined(separator: " ").lowercased()
        for c in q.clauses {
            let ok = c.alternatives.contains { t in
                switch t {
                case .text(let s), .phrase(let s): hay.contains(s.lowercased())
                case .from(let s): ((m.from?.address ?? "") + (m.from?.name ?? "")).lowercased().contains(s.lowercased())
                case .subject(let s): m.subject.lowercased().contains(s.lowercased())
                case .hasAttachment: !m.attachments.isEmpty
                case .filename(let s): m.attachments.contains { $0.filename.lowercased().contains(s.lowercased()) }
                case .isUnread(let u): m.isUnread == u
                case .isStarred: m.labelIDs.contains(SystemLabel.starred)
                case .after(let d): m.date >= d
                case .before(let d): m.date < d
                default: true
                }
            }
            if ok == c.negated { return false }
        }
        return true
    }

    func thread(id: String, accountID: String, full: Bool) async throws -> [MailMessage] {
        try await Task.sleep(for: .milliseconds(120))
        let msgs = locked { messages.values.filter { $0.threadID == id }.sorted { $0.date < $1.date } }
        guard !msgs.isEmpty else { throw ProviderError.notFound }
        return msgs.map { var m = $0; if !full { m.bodyPlain = nil; m.bodyHTML = nil; m.hasFullBody = false }; return m }
    }

    func history(since historyID: String) async throws -> HistoryDelta {
        HistoryDelta(newHistoryID: String(locked { history }))
    }

    func modifyThread(id: String, add: [String], remove: [String]) async throws {
        locked {
            for (k, m) in messages where m.threadID == id {
                var m = m
                m.labelIDs.subtract(remove)
                m.labelIDs.formUnion(add)
                messages[k] = m
            }
            history += 1
        }
    }

    func trashThread(id: String) async throws { try await modifyThread(id: id, add: [SystemLabel.trash], remove: [SystemLabel.inbox]) }
    func untrashThread(id: String) async throws { try await modifyThread(id: id, add: [], remove: [SystemLabel.trash]) }

    func send(raw: Data, threadID: String?) async throws -> SentMessage {
        try await Task.sleep(for: .milliseconds(400))
        let parsed = MIMEPreview.parse(raw)
        let id = "sample-sent-" + UUID().uuidString
        let thread = threadID ?? id
        let m = MailMessage(accountID: accountID, id: id, threadID: thread, from: EmailAddress(name: "You", address: email), to: parsed.to,
                            cc: parsed.cc, subject: parsed.subject, date: .now, snippet: String(parsed.text.prefix(120)),
                            labelIDs: [SystemLabel.sent], messageIDHeader: parsed.messageID, bodyPlain: parsed.text, hasFullBody: true)
        locked { messages[id] = m; history += 1 }
        return SentMessage(id: id, threadID: thread)
    }

    func findMessage(rfc822MessageID: String) async throws -> String? {
        locked { messages.values.first { $0.messageIDHeader == rfc822MessageID }?.id }
    }

    func createDraft(raw: Data, threadID: String?) async throws -> RemoteDraft { RemoteDraft(draftID: UUID().uuidString, messageID: UUID().uuidString) }
    func updateDraft(id: String, raw: Data, threadID: String?) async throws -> RemoteDraft { RemoteDraft(draftID: id, messageID: UUID().uuidString) }
    func remoteDraftMessageID(id: String) async throws -> String? { nil }
    func deleteDraft(id: String) async throws {}

    func attachment(messageID: String, attachmentID: String) async throws -> Data {
        let name = locked { messages[messageID]?.attachments.first { $0.attachmentID == attachmentID }?.filename } ?? "sample.txt"
        return SampleFixtures.attachmentData(named: name)
    }

    func createLabel(name: String, accountID: String) async throws -> MailLabel {
        let l = MailLabel(accountID: accountID, labelID: "Label_\(UUID().uuidString.prefix(6))", name: name, kind: .user)
        locked { userLabels.append(l) }
        return l
    }

    func renameLabel(id: String, name: String, accountID: String) async throws -> MailLabel {
        locked {
            if let i = userLabels.firstIndex(where: { $0.labelID == id }) { userLabels[i].name = name; return userLabels[i] }
            return MailLabel(accountID: accountID, labelID: id, name: name, kind: .user)
        }
    }

    func deleteLabel(id: String) async throws {
        locked {
            userLabels.removeAll { $0.labelID == id }
            for (k, m) in messages where m.labelIDs.contains(id) { var m = m; m.labelIDs.remove(id); messages[k] = m }
        }
    }

    func revoke() async {}
}

/// Reads back the few headers the sample provider needs from a generated message.
nonisolated enum MIMEPreview {
    struct Parsed { var subject = ""; var to: [EmailAddress] = []; var cc: [EmailAddress] = []; var messageID: String?; var text = "" }

    static func parse(_ raw: Data) -> Parsed {
        let s = String(decoding: raw, as: UTF8.self)
        var p = Parsed()
        let headerEnd = s.range(of: "\r\n\r\n")?.lowerBound ?? s.endIndex
        for line in s[..<headerEnd].components(separatedBy: "\r\n") {
            if line.hasPrefix("Subject: ") { p.subject = MIMEBuilder.decodeEncodedWords(String(line.dropFirst(9))) }
            if line.hasPrefix("To: ") { p.to = EmailAddress.parseList(MIMEBuilder.decodeEncodedWords(String(line.dropFirst(4)))) }
            if line.hasPrefix("Cc: ") { p.cc = EmailAddress.parseList(MIMEBuilder.decodeEncodedWords(String(line.dropFirst(4)))) }
            if line.hasPrefix("Message-ID: ") { p.messageID = String(line.dropFirst(12)) }
        }
        if let r = s.range(of: "Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n") {
            let rest = s[r.upperBound...]
            let b64 = rest.prefix { $0 != "-" }.replacingOccurrences(of: "\r\n", with: "")
            p.text = Data(base64Encoded: b64).map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
        return p
    }
}
