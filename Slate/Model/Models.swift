import Foundation

// MARK: - Accounts

nonisolated enum ProviderKind: String, Codable, Sendable {
    case gmail
    /// Built-in sample mailbox. Never connected to a real service and always labelled as sample data.
    case sample
}

nonisolated enum AccountStatus: String, Codable, Sendable {
    case connected
    case needsReconnect
    case syncError
}

nonisolated enum NotificationMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case all, focused, off
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All New Mail"
        case .focused: "Focused Only"
        case .off: "Off"
        }
    }
}

nonisolated struct Account: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var email: String
    /// Name placed in the From header.
    var displayName: String
    /// Optional friendly name such as "Personal" or "Work".
    var friendlyName: String
    var provider: ProviderKind
    var status: AccountStatus = .connected
    var statusMessage: String?
    var signature: String = ""
    var notificationMode: NotificationMode = .all
    var sortOrder: Int = 0
    var historyID: String?
    var lastSyncAt: Date?

    var shortLabel: String { friendlyName.isEmpty ? email : friendlyName }
    var isSample: Bool { provider == .sample }
    var fromAddress: EmailAddress { EmailAddress(name: displayName.isEmpty ? nil : displayName, address: email) }
}

// MARK: - Addresses

nonisolated struct EmailAddress: Hashable, Codable, Sendable, Identifiable {
    var name: String?
    var address: String

    var id: String { address.lowercased() }
    var displayName: String {
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        return address
    }
    /// First name for compact participant lists.
    var shortName: String {
        guard let name, !name.isEmpty else { return address.split(separator: "@").first.map(String.init) ?? address }
        if name.contains(",") { return name.split(separator: ",").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? name }
        return name.split(separator: " ").first.map(String.init) ?? name
    }
    var normalized: String { address.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }

    var isValid: Bool {
        let a = address.trimmingCharacters(in: .whitespaces)
        guard let at = a.firstIndex(of: "@"), a.filter({ $0 == "@" }).count == 1 else { return false }
        let local = a[..<at], domain = a[a.index(after: at)...]
        return !local.isEmpty && domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".")
            && !a.contains(where: { $0.isWhitespace || $0 == "<" || $0 == ">" || $0 == "," })
    }

    /// Parses an RFC 5322 address-list header value: `"Lane, Jo" <jo@x.com>, b@y.com, Name <c@z.com>`.
    static func parseList(_ value: String) -> [EmailAddress] {
        var items: [String] = []
        var current = ""
        var inQuotes = false, inAngle = false
        for ch in value {
            switch ch {
            case "\"": inQuotes.toggle(); current.append(ch)
            case "<" where !inQuotes: inAngle = true; current.append(ch)
            case ">" where !inQuotes: inAngle = false; current.append(ch)
            case ",", ";":
                if inQuotes || inAngle { current.append(ch) } else { items.append(current); current = "" }
            default: current.append(ch)
            }
        }
        items.append(current)
        return items.compactMap { parse($0) }
    }

    static func parse(_ raw: String) -> EmailAddress? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let lt = s.lastIndex(of: "<"), let gt = s.lastIndex(of: ">"), lt < gt {
            let address = String(s[s.index(after: lt)..<gt]).trimmingCharacters(in: .whitespaces)
            var name = String(s[..<lt]).trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 {
                name = String(name.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
            }
            guard !address.isEmpty else { return nil }
            return EmailAddress(name: name.isEmpty ? nil : name, address: address)
        }
        return EmailAddress(name: nil, address: s)
    }
}

// MARK: - Labels & mailboxes

nonisolated enum SystemLabel {
    static let inbox = "INBOX", unread = "UNREAD", starred = "STARRED", important = "IMPORTANT"
    static let sent = "SENT", draft = "DRAFT", spam = "SPAM", trash = "TRASH"
    static let categoryPrefix = "CATEGORY_"
}

nonisolated struct MailLabel: Identifiable, Hashable, Codable, Sendable {
    enum Kind: String, Codable, Sendable { case system, user }
    var accountID: String
    var labelID: String
    var name: String
    var kind: Kind
    var colorHex: String?
    var unreadThreads: Int?

    var id: String { accountID + "/" + labelID }
    /// Gmail nests labels with "/" in their names.
    var leafName: String { name.split(separator: "/").last.map(String.init) ?? name }
}

nonisolated enum Mailbox: Hashable, Codable, Sendable, Identifiable {
    case inbox, later, starred, important, drafts, outbox, sent, allMail, spam, trash
    case label(accountID: String, labelID: String, name: String)

    var id: String {
        switch self {
        case .label(let a, let l, _): "label:\(a)/\(l)"
        default: title
        }
    }

    static let standard: [Mailbox] = [.inbox, .later, .starred, .important, .drafts, .outbox, .sent, .allMail, .spam, .trash]

    var title: String {
        switch self {
        case .inbox: "Inbox"
        case .later: "Later"
        case .starred: "Starred"
        case .important: "Important"
        case .drafts: "Drafts"
        case .outbox: "Outbox"
        case .sent: "Sent"
        case .allMail: "All Mail"
        case .spam: "Spam"
        case .trash: "Trash"
        case .label(_, _, let name): name
        }
    }

    var symbol: String {
        switch self {
        case .inbox: "tray"
        case .later: "clock"
        case .starred: "star"
        case .important: "exclamationmark.circle"
        case .drafts: "doc"
        case .outbox: "tray.and.arrow.up"
        case .sent: "paperplane"
        case .allMail: "archivebox"
        case .spam: "xmark.octagon"
        case .trash: "trash"
        case .label: "tag"
        }
    }

    /// The provider label that defines membership, if any.
    var providerLabelID: String? {
        switch self {
        case .inbox: SystemLabel.inbox
        case .starred: SystemLabel.starred
        case .important: SystemLabel.important
        case .sent: SystemLabel.sent
        case .spam: SystemLabel.spam
        case .trash: SystemLabel.trash
        case .label(_, let id, _): id
        case .allMail, .later, .drafts, .outbox: nil
        }
    }

    var labelAccountID: String? {
        if case .label(let a, _, _) = self { return a }
        return nil
    }

    var isThreadList: Bool { self != .drafts && self != .outbox }
}

// MARK: - Threads & messages

nonisolated struct ThreadRef: Hashable, Codable, Sendable {
    var accountID: String
    var threadID: String
}

nonisolated enum FocusReason: String, Codable, Sendable {
    case vip, important, directCorrespondent, repliedBefore, userRule
    var explanation: String {
        switch self {
        case .vip: "From someone you marked as always Focused."
        case .important: "Gmail marked this conversation as important."
        case .directCorrespondent: "Sent directly to you by a person, not a mailing list."
        case .repliedBefore: "From someone you've written to before."
        case .userRule: "Matches a Focused rule you created."
        }
    }
}

nonisolated struct ThreadSummary: Identifiable, Hashable, Sendable {
    var ref: ThreadRef
    var subject: String
    var snippet: String
    var lastDate: Date
    var participants: [EmailAddress]
    var messageCount: Int
    var hasAttachment: Bool
    var isUnread: Bool
    var isStarred: Bool
    var isImportant: Bool
    var labelIDs: Set<String>
    var latestFrom: EmailAddress?
    var isMailingList: Bool
    var toMe: Bool
    var laterUntil: Date?

    var id: ThreadRef { ref }
    var inInbox: Bool { labelIDs.contains(SystemLabel.inbox) }
    var inSpam: Bool { labelIDs.contains(SystemLabel.spam) }
    var inTrash: Bool { labelIDs.contains(SystemLabel.trash) }
}

nonisolated struct AttachmentInfo: Hashable, Codable, Sendable, Identifiable {
    var attachmentID: String?
    var partID: String
    var filename: String
    var mimeType: String
    var size: Int
    var contentID: String?
    var isInline: Bool
    /// Present for small parts that the provider returned inline.
    var inlineData: Data?

    var id: String { partID + ":" + filename }
}

nonisolated struct MailMessage: Identifiable, Hashable, Codable, Sendable {
    var accountID: String
    var id: String
    var threadID: String
    var from: EmailAddress?
    var to: [EmailAddress] = []
    var cc: [EmailAddress] = []
    var bcc: [EmailAddress] = []
    var replyTo: [EmailAddress] = []
    var subject: String = ""
    var date: Date
    var snippet: String = ""
    var labelIDs: Set<String> = []
    var messageIDHeader: String?
    var references: String?
    var inReplyTo: String?
    var listUnsubscribe: String?
    var listID: String?
    var bodyPlain: String?
    var bodyHTML: String?
    var hasFullBody: Bool = false
    var probablyHasAttachment: Bool = false
    var attachments: [AttachmentInfo] = []

    var isUnread: Bool { labelIDs.contains(SystemLabel.unread) }
    var visibleAttachments: [AttachmentInfo] { attachments.filter { !($0.isInline && $0.contentID != nil) } }
}

// MARK: - Drafts

nonisolated enum ComposeKind: String, Codable, Sendable {
    case new, reply, replyAll, forward
}

nonisolated struct QuotedContent: Hashable, Codable, Sendable {
    var attribution: String
    var plain: String
    var html: String?
}

nonisolated struct DraftAttachment: Hashable, Codable, Sendable, Identifiable {
    var id: String = UUID().uuidString
    var filename: String
    var mimeType: String
    var size: Int
    /// Path relative to the app's protected attachments directory.
    var localPath: String
}

nonisolated enum DraftState: String, Codable, Sendable {
    case editing
    /// Locked while an outbox submission version exists.
    case inOutbox
}

nonisolated struct Draft: Identifiable, Hashable, Codable, Sendable {
    var id: String = UUID().uuidString
    var accountID: String
    var kind: ComposeKind = .new
    var threadID: String?
    var inReplyTo: String?
    var references: String?
    var to: [EmailAddress] = []
    var cc: [EmailAddress] = []
    var bcc: [EmailAddress] = []
    var subject: String = ""
    /// Plain text of the editable body (signature included).
    var bodyText: String = ""
    /// RTF archive of the editable body when it contains formatting.
    var bodyRTF: Data?
    var quoted: QuotedContent?
    var includeQuoted: Bool = true
    var attachments: [DraftAttachment] = []
    /// The signature text last inserted, so changing From can replace it if untouched.
    var appliedSignature: String = ""
    var remoteDraftID: String?
    var remoteMessageID: String?
    var localRevision: Int = 0
    var syncedRevision: Int = 0
    var state: DraftState = .editing
    var createdAt: Date = .now
    var updatedAt: Date = .now

    var isEffectivelyEmpty: Bool {
        to.isEmpty && cc.isEmpty && bcc.isEmpty && subject.trimmingCharacters(in: .whitespaces).isEmpty
            && bodyText.replacingOccurrences(of: appliedSignature, with: "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && attachments.isEmpty
    }
    var allRecipients: [EmailAddress] { to + cc + bcc }
}

// MARK: - Outbox

nonisolated enum OutboxState: String, Codable, Sendable {
    /// Inside the Undo Send window.
    case pending
    /// Past the window; waiting for connectivity or a retry.
    case queued
    /// Submission to the provider has started. Cannot be cancelled.
    case submitting
    case sent
    case failed
    /// The provider may or may not have accepted it; reconciling before any retry.
    case ambiguous
    case cancelled

    var isCancellable: Bool { self == .pending || self == .queued }
    var isActive: Bool { self == .pending || self == .queued || self == .submitting || self == .ambiguous }
}

nonisolated enum OutboxFailure: String, Codable, Sendable {
    case authentication, rejected, missingAttachment, tooLarge, accountRemoved
    var message: String {
        switch self {
        case .authentication: "Reconnect this account to send. Your message is saved in Outbox."
        case .rejected: "Gmail didn't accept this message. It's saved in Outbox."
        case .missingAttachment: "An attachment is no longer available. Edit the message to fix it."
        case .tooLarge: "This message is larger than Gmail allows (about 25 MB of attachments)."
        case .accountRemoved: "The sending account was removed. Choose another account and send again."
        }
    }
}

nonisolated struct OutboxItem: Identifiable, Hashable, Codable, Sendable {
    var id: String = UUID().uuidString
    var accountID: String
    var draftID: String
    var state: OutboxState
    var deadline: Date
    var createdAt: Date = .now
    var attempts: Int = 0
    var failure: OutboxFailure?
    var lastError: String?
    /// Immutable submission version.
    var snapshot: Draft
    var messageIDHeader: String
    var providerMessageID: String?
    var sentAt: Date?
    var nextAttemptAt: Date?
}

// MARK: - Later

nonisolated struct LaterEntry: Hashable, Codable, Sendable {
    var ref: ThreadRef
    var until: Date
    var createdAt: Date
}
