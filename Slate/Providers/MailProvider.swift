import Foundation

nonisolated enum ProviderError: Error, Equatable, LocalizedError {
    /// Access token could not be refreshed; the user must reconnect.
    case authenticationRequired
    /// Stored history cursor is older than the provider keeps; a full resync is required.
    case historyExpired
    case notFound
    case rateLimited(retryAfter: TimeInterval?)
    /// The request never reached the provider (offline, DNS, etc.).
    case offline
    /// The request may have reached the provider but no response arrived.
    case indeterminate(String)
    case rejected(status: Int, message: String)
    case server(status: Int)
    case notConfigured(String)

    var errorDescription: String? {
        switch self {
        case .authenticationRequired: "Reconnect to continue syncing."
        case .historyExpired: "Mail needs a full refresh."
        case .notFound: "This item no longer exists."
        case .rateLimited: "Gmail asked Slate to slow down. Trying again shortly."
        case .offline: "You're offline. Downloaded messages are available."
        case .indeterminate: "The connection was interrupted."
        case .rejected(_, let m): m
        case .server(let s): "Gmail had a problem (\(s)). Trying again shortly."
        case .notConfigured(let m): m
        }
    }

    var isTransient: Bool {
        switch self {
        case .rateLimited, .offline, .indeterminate, .server: true
        default: false
        }
    }
}

nonisolated struct ProviderProfile: Sendable {
    var email: String
    var historyID: String
}

nonisolated struct ThreadPage: Sendable {
    var threadIDs: [String]
    var nextPageToken: String?
}

nonisolated struct HistoryDelta: Sendable {
    var changedThreadIDs: Set<String> = []
    var deletedMessageIDs: Set<String> = []
    var addedInboxMessageIDs: Set<String> = []
    var newHistoryID: String
}

nonisolated struct SentMessage: Sendable {
    var id: String
    var threadID: String
}

nonisolated struct RemoteDraft: Sendable {
    var draftID: String
    var messageID: String
}

/// One connected mailbox. Every instance is bound to exactly one account; there is no cross-account fallback.
nonisolated protocol MailProvider: Sendable {
    func profile() async throws -> ProviderProfile
    func labels(accountID: String) async throws -> [MailLabel]
    func listThreads(labelID: String?, query: String?, includeSpamTrash: Bool, pageToken: String?, maxResults: Int) async throws -> ThreadPage
    /// Fetches a thread. `full` includes bodies and attachment metadata.
    func thread(id: String, accountID: String, full: Bool) async throws -> [MailMessage]
    func history(since historyID: String) async throws -> HistoryDelta
    func modifyThread(id: String, add: [String], remove: [String]) async throws
    func trashThread(id: String) async throws
    func untrashThread(id: String) async throws
    func send(raw: Data, threadID: String?) async throws -> SentMessage
    /// Looks up a message by its RFC 822 Message-ID, including Sent/Spam/Trash, to reconcile an ambiguous send.
    func findMessage(rfc822MessageID: String) async throws -> String?
    func createDraft(raw: Data, threadID: String?) async throws -> RemoteDraft
    func updateDraft(id: String, raw: Data, threadID: String?) async throws -> RemoteDraft
    /// Current message ID of a remote draft, or nil if it was deleted elsewhere.
    func remoteDraftMessageID(id: String) async throws -> String?
    func deleteDraft(id: String) async throws
    func attachment(messageID: String, attachmentID: String) async throws -> Data
    func createLabel(name: String, accountID: String) async throws -> MailLabel
    func renameLabel(id: String, name: String, accountID: String) async throws -> MailLabel
    func deleteLabel(id: String) async throws
    func revoke() async
}
