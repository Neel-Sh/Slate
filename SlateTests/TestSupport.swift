import Foundation
@testable import Slate

/// Scriptable provider for exercising sync and send logic without a network.
final class FakeProvider: MailProvider, @unchecked Sendable {
    enum SendBehavior { case succeed, offline, indeterminate, unauthorized, rejected }

    private let lock = NSLock()
    private var _sendBehaviors: [SendBehavior] = []
    private var _sent: [Data] = []
    private var _acceptedMessageIDs: [String] = []
    private var _modifies: [(String, [String], [String])] = []
    var acceptEvenWhenIndeterminate = false

    func queueSends(_ b: SendBehavior...) { lock.withLock { _sendBehaviors += b } }
    var sentCount: Int { lock.withLock { _sent.count } }
    var sentRaw: [Data] { lock.withLock { _sent } }
    var modifies: [(String, [String], [String])] { lock.withLock { _modifies } }

    func profile() async throws -> ProviderProfile { ProviderProfile(email: "me@example.com", historyID: "1") }
    func labels(accountID: String) async throws -> [MailLabel] { [] }
    func listThreads(labelID: String?, query: String?, includeSpamTrash: Bool, pageToken: String?, maxResults: Int) async throws -> ThreadPage {
        ThreadPage(threadIDs: [], nextPageToken: nil)
    }
    func thread(id: String, accountID: String, full: Bool) async throws -> [MailMessage] { throw ProviderError.notFound }
    func history(since historyID: String) async throws -> HistoryDelta { HistoryDelta(newHistoryID: historyID) }
    func modifyThread(id: String, add: [String], remove: [String]) async throws { lock.withLock { _modifies.append((id, add, remove)) } }
    func trashThread(id: String) async throws {}
    func untrashThread(id: String) async throws {}

    func send(raw: Data, threadID: String?) async throws -> SentMessage {
        let behavior = lock.withLock { _sendBehaviors.isEmpty ? .succeed : _sendBehaviors.removeFirst() }
        let messageID = MIMEPreview.parse(raw).messageID ?? ""
        switch behavior {
        case .succeed:
            lock.withLock { _sent.append(raw); _acceptedMessageIDs.append(messageID) }
            return SentMessage(id: "m\(sentCount)", threadID: threadID ?? "t")
        case .offline: throw ProviderError.offline
        case .unauthorized: throw ProviderError.authenticationRequired
        case .rejected: throw ProviderError.rejected(status: 400, message: "Invalid To header")
        case .indeterminate:
            if acceptEvenWhenIndeterminate { lock.withLock { _sent.append(raw); _acceptedMessageIDs.append(messageID) } }
            throw ProviderError.indeterminate("timed out")
        }
    }

    func findMessage(rfc822MessageID: String) async throws -> String? {
        lock.withLock { _acceptedMessageIDs.contains(rfc822MessageID) ? "found" : nil }
    }
    func createDraft(raw: Data, threadID: String?) async throws -> RemoteDraft { RemoteDraft(draftID: "d1", messageID: "dm1") }
    func updateDraft(id: String, raw: Data, threadID: String?) async throws -> RemoteDraft { RemoteDraft(draftID: id, messageID: "dm2") }
    func remoteDraftMessageID(id: String) async throws -> String? { "dm1" }
    func deleteDraft(id: String) async throws {}
    func attachment(messageID: String, attachmentID: String) async throws -> Data { Data() }
    func createLabel(name: String, accountID: String) async throws -> MailLabel { MailLabel(accountID: accountID, labelID: "L", name: name, kind: .user) }
    func renameLabel(id: String, name: String, accountID: String) async throws -> MailLabel { MailLabel(accountID: accountID, labelID: id, name: name, kind: .user) }
    func deleteLabel(id: String) async throws {}
    func revoke() async {}
}

enum Fixtures {
    static let account = Account(id: "acct-1", email: "me@example.com", displayName: "Me Person", friendlyName: "Personal", provider: .gmail)
    static let work = Account(id: "acct-2", email: "me@work.example", displayName: "Me Person", friendlyName: "Work", provider: .gmail)

    static func store() throws -> MailStore { try MailStore(database: Database()) }

    static func draft(_ subject: String = "Hello", account: Account = account) -> Draft {
        var d = Draft(accountID: account.id)
        d.to = [EmailAddress(name: "Ann", address: "ann@example.org")]
        d.subject = subject
        d.bodyText = "Body of \(subject)"
        d.localRevision = 1
        return d
    }

    static func message(_ id: String, thread: String, account: String = account.id, from: String = "ann@example.org",
                        labels: Set<String> = [SystemLabel.inbox], date: Date = .now, subject: String = "Subject", body: String = "Body") -> MailMessage {
        MailMessage(accountID: account, id: id, threadID: thread, from: EmailAddress(name: nil, address: from),
                    to: [EmailAddress(name: nil, address: "me@example.com")], subject: subject, date: date, snippet: body,
                    labelIDs: labels, bodyPlain: body, hasFullBody: true)
    }
}

/// Polls until a condition holds (for asynchronous outbox timers).
func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping () async -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return await condition()
}
