import Foundation
import Network
import Observation
import UIKit
import AuthenticationServices
import SwiftUI

nonisolated enum ThreadAction: Hashable, Sendable {
    case archive, moveToInbox, trash, restore, markRead, markUnread, star, unstar, markImportant, markNotImportant
    case spam, notSpam
    case addLabel(String), removeLabel(String), moveToLabel(String)

    var change: (add: Set<String>, remove: Set<String>) {
        switch self {
        case .archive: ([], [SystemLabel.inbox])
        case .moveToInbox: ([SystemLabel.inbox], [])
        case .trash: ([SystemLabel.trash], [SystemLabel.inbox])
        case .restore: ([SystemLabel.inbox], [SystemLabel.trash])
        case .markRead: ([], [SystemLabel.unread])
        case .markUnread: ([SystemLabel.unread], [])
        case .star: ([SystemLabel.starred], [])
        case .unstar: ([], [SystemLabel.starred])
        case .markImportant: ([SystemLabel.important], [])
        case .markNotImportant: ([], [SystemLabel.important])
        case .spam: ([SystemLabel.spam], [SystemLabel.inbox])
        case .notSpam: ([SystemLabel.inbox], [SystemLabel.spam])
        case .addLabel(let l): ([l], [])
        case .removeLabel(let l): ([], [l])
        case .moveToLabel(let l): ([l], [SystemLabel.inbox])
        }
    }

    func pastTense(count: Int) -> String {
        let noun = count == 1 ? "conversation" : "\(count) conversations"
        let cap = count == 1 ? "Conversation" : "\(count) conversations"
        switch self {
        case .archive: return "Archived \(noun)"
        case .moveToInbox: return "Moved \(noun) to Inbox"
        case .trash: return "Moved \(noun) to Trash"
        case .restore: return "Restored \(noun) to Inbox"
        case .markRead: return "Marked \(noun) as read"
        case .markUnread: return "Marked \(noun) as unread"
        case .star: return "Starred \(noun)"
        case .unstar: return "Removed star"
        case .markImportant: return "Marked important"
        case .markNotImportant: return "Marked not important"
        case .spam: return "Moved \(noun) to Spam"
        case .notSpam: return "\(cap) moved to Inbox"
        case .addLabel: return "Label added"
        case .removeLabel: return "Label removed"
        case .moveToLabel: return "Moved \(noun)"
        }
    }

    var removesFromInbox: Bool { [.archive, .trash, .spam].contains(self) || { if case .moveToLabel = self { return true }; return false }() }
}

/// Haptic moments. Kept few and consistent so they carry meaning.
struct Feedback: Equatable {
    enum Kind { case action, sent, undo, error }
    let id = UUID()
    var kind: Kind

    var sensory: SensoryFeedback {
        switch kind {
        case .action: .impact(weight: .light)
        case .sent: .success
        case .undo: .impact(flexibility: .soft)
        case .error: .error
        }
    }
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    var message: String
    var undo: (@MainActor () async -> Void)?
    var isError = false
    static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
}

nonisolated struct AccountRuntime: Sendable {
    var account: Account
    var provider: any MailProvider
}

@MainActor @Observable
final class AppModel {
    let prefs = Preferences()
    let intelligence = IntelligenceService()
    let notifications = NotificationService()

    private(set) var store: MailStore!
    private(set) var outbox: Outbox!
    private(set) var draftSync: DraftSync!
    private(set) var sync: SyncCoordinator!
    private var providers: [String: any MailProvider] = [:]
    private let providerBox = ProviderBox()

    private(set) var accounts: [Account] = []
    private(set) var counts = MailStore.Counts()
    private(set) var outboxItems: [OutboxItem] = []
    private(set) var labels: [MailLabel] = []
    private(set) var focus = FocusClassifier(senderRules: [:], correspondents: [], identities: [])
    private(set) var syncing: Set<String> = []
    private(set) var lastSync: Date?
    private(set) var isOnline = true
    private(set) var launchError: String?

    /// Bumped whenever cached mail changes so visible lists reload.
    private(set) var dataVersion = 0

    var scopeAccountID: String? { didSet { Task { await reloadMeta() } } }
    var mailbox: Mailbox = .inbox
    var path: [ThreadRef] = []
    var showMailboxes = false
    var composer: Draft? { didSet { if composer?.id != oldValue?.id && oldValue != nil { composerNote = nil } } }
    /// Shown above the body when a draft was generated, so its origin is always disclosed.
    var composerNote: String?
    var toast: Toast? { didSet { if toast?.isError == true { feedback = Feedback(kind: .error) } } }
    var feedback: Feedback?
    var showOnboarding = false
    var showSettings = false

    private var pathMonitor: NWPathMonitor?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    init() {
        do {
            store = try MailStore.openDefault()
        } catch {
            launchError = "Slate couldn't open its local storage. \(error.localizedDescription)"
            return
        }
        let box = providerBox
        let lookup: Outbox.Lookup = { id in await box.runtime(id).map { ($0.provider, $0.account) } }
        outbox = Outbox(store: store, lookup: lookup)
        draftSync = DraftSync(store: store, lookup: lookup)
        sync = SyncCoordinator(store: store)
        notifications.onOpen = { [weak self] url in self?.handle(url) }
    }

    // MARK: Launch

    func start() async {
        guard let store else { return }
        await outbox.setHandlers(onChange: { [weak self] in Task { @MainActor [weak self] in await self?.reloadOutbox() } },
                                 onSent: { [weak self] item in Task { @MainActor [weak self] in self?.didSend(item) } })
        accounts = (try? await store.accounts()) ?? []
        for a in accounts { await registerProvider(a) }
        showOnboarding = accounts.isEmpty && !prefs.hasCompletedOnboarding
        if ProcessInfo.processInfo.arguments.contains("-SlateSampleData") && accounts.isEmpty { await addSampleAccount() }
        await notifications.refreshAuthorization()
        await reloadMeta()
        await outbox.resume()
        startMonitoringNetwork()
        await refreshAll()
    }

    private func registerProvider(_ account: Account) async {
        let provider: (any MailProvider)?
        switch account.provider {
        case .sample: provider = SampleProvider(accountID: account.id, email: account.email)
        case .gmail: provider = GoogleOAuthConfig.fromBundle().map { GmailProvider(accountID: account.id, clientID: $0.clientID) }
        }
        if let provider {
            providers[account.id] = provider
            await providerBox.set(account.id, AccountRuntime(account: account, provider: provider))
        }
    }

    func provider(for accountID: String) -> (any MailProvider)? { providers[accountID] }
    func account(_ id: String) -> Account? { accounts.first { $0.id == id } }

    var scopeAccountIDs: [String] { scopeAccountID.map { [$0] } ?? accounts.map(\.id) }
    var scopeTitle: String { scopeAccountID.flatMap(account)?.shortLabel ?? (accounts.count > 1 ? "All Accounts" : accounts.first?.shortLabel ?? "") }
    var hasMultipleAccounts: Bool { accounts.count > 1 }
    var identities: Set<String> { Set(accounts.map { $0.email.lowercased() }) }

    func reloadMeta() async {
        guard let store else { return }
        counts = (try? await store.counts(accountIDs: scopeAccountIDs)) ?? .init()
        labels = (try? await store.labels(accountIDs: scopeAccountIDs)) ?? []
        focus = FocusClassifier(senderRules: (try? await store.senderRules()) ?? [:],
                                correspondents: (try? await store.knownCorrespondents(accountIDs: accounts.map(\.id))) ?? [],
                                identities: identities)
        await reloadOutbox()
        await updateBadge()
    }

    func reloadOutbox() async {
        outboxItems = await outbox?.items() ?? []
        counts.outbox = outboxItems.filter { $0.state != .sent && $0.state != .cancelled }.count
    }

    func dataChanged() {
        dataVersion += 1
        Task { await reloadMeta() }
    }

    // MARK: Sync

    func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for a in accounts where a.status != .needsReconnect { group.addTask { await self.refresh(a.id) } }
        }
        lastSync = .now
        resurfaceLater()
    }

    func refresh(_ accountID: String) async {
        guard var account = account(accountID), let provider = providers[accountID] else { return }
        syncing.insert(accountID)
        defer { syncing.remove(accountID) }
        let result = await sync.sync(account, provider: provider)
        account = self.account(accountID) ?? account
        if let error = result.error {
            switch error {
            case .authenticationRequired:
                account.status = .needsReconnect
                account.statusMessage = "Reconnect to continue syncing."
            case .offline:
                isOnline = false
            default:
                account.status = .syncError
                account.statusMessage = error.localizedDescription
            }
        } else {
            account.status = .connected
            account.statusMessage = nil
            account.historyID = result.historyID ?? account.historyID
            account.lastSyncAt = .now
            isOnline = true
        }
        await save(account)
        if !result.newInboxMessages.isEmpty { await notifyNewMail(result.newInboxMessages, account: account) }
        await clearLaterOnNewReply(result.newInboxMessages)
        dataChanged()
    }

    func loadMore(_ mailbox: Mailbox, tokens: [String: String?]) async -> [String: String?] {
        var next = tokens
        for id in mailbox.labelAccountID.map({ [$0] }) ?? scopeAccountIDs {
            guard let a = account(id), let p = providers[id], tokens[id] != .some(nil) else { continue }
            next[id] = (try? await sync.loadMore(mailbox: mailbox, account: a, provider: p, pageToken: tokens[id] ?? nil)) ?? .some(nil)
        }
        dataChanged()
        return next
    }

    func backgroundRefresh() async {
        await refreshAll()
    }

    private func notifyNewMail(_ messages: [MailMessage], account: Account) async {
        guard account.notificationMode != .off else { return }
        var list = messages
        if account.notificationMode == .focused {
            var kept: [MailMessage] = []
            for m in messages {
                if let t = try? await store.thread(ThreadRef(accountID: account.id, threadID: m.threadID)), focus.reason(for: t) != nil { kept.append(m) }
            }
            list = kept
        }
        await notifications.postNewMail(list, account: account, privacy: prefs.previewPrivacy, multipleAccounts: hasMultipleAccounts)
    }

    /// Badge = unread Inbox conversations across accounts with notifications on, each (account, thread) counted once.
    func updateBadge() async {
        guard let store else { return }
        let ids = accounts.filter { $0.notificationMode != .off }.map(\.id)
        let c = (try? await store.counts(accountIDs: ids)) ?? .init()
        notifications.setBadge(c.inboxUnread.values.reduce(0, +))
    }

    private func startMonitoringNetwork() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let online = path.status == .satisfied
                let restored = online && !self.isOnline
                self.isOnline = online
                if restored {
                    await self.outbox.connectivityRestored()
                    await self.refreshAll()
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "slate.network"))
        pathMonitor = monitor
    }

    // MARK: Accounts

    func save(_ account: Account) async {
        try? await store.saveAccount(account)
        if let i = accounts.firstIndex(where: { $0.id == account.id }) { accounts[i] = account } else { accounts.append(account) }
        if let p = providers[account.id] { await providerBox.set(account.id, AccountRuntime(account: account, provider: p)) }
    }

    func addSampleAccount() async {
        guard !accounts.contains(where: \.isSample) else { return }
        let a = Account(id: "sample", email: "you@sample.example", displayName: "You", friendlyName: "Sample", provider: .sample,
                        signature: "— Sent from Slate", sortOrder: accounts.count)
        await save(a)
        await registerProvider(a)
        prefs.hasCompletedOnboarding = true
        showOnboarding = false
        await refresh(a.id)
    }

    var isGoogleConfigured: Bool { GoogleOAuthConfig.fromBundle() != nil }

    /// Runs the Google sign-in. If the Google account is already connected, its tokens are replaced (reconnect).
    func connectGmail(using session: WebAuthenticationSession, reconnecting existing: Account? = nil) async throws {
        guard let config = GoogleOAuthConfig.fromBundle() else {
            throw ProviderError.notConfigured("Add your Google iOS client ID to Config/Local.xcconfig to connect Gmail.")
        }
        let pkce = PKCE()
        let url = GoogleOAuth.authorizationURL(config: config, pkce: pkce, loginHint: existing?.email)
        let callback = try await session.authenticate(using: url, callback: .customScheme(config.redirectScheme), additionalHeaderFields: [:])
        let code = try GoogleOAuth.code(from: callback, pkce: pkce)
        let tokens = try await GoogleOAuth.exchange(code: code, config: config, pkce: pkce)

        let tempID = UUID().uuidString
        try TokenVault.save(tokens, accountID: tempID)
        let probe = GmailProvider(accountID: tempID, clientID: config.clientID)
        let profile: ProviderProfile
        do { profile = try await probe.profile() } catch { TokenVault.delete(accountID: tempID); throw error }

        let match = accounts.first { $0.provider == .gmail && $0.email.caseInsensitiveCompare(profile.email) == .orderedSame }
        if let existing, match?.id != existing.id {
            TokenVault.delete(accountID: tempID)
            throw ProviderError.rejected(status: 400, message: "You signed in as \(profile.email), but this account is \(existing.email). Nothing was changed.")
        }
        var account: Account
        if let match {
            try TokenVault.save(tokens, accountID: match.id)
            TokenVault.delete(accountID: tempID)
            account = match
            account.status = .connected
            account.statusMessage = nil
        } else {
            account = Account(id: tempID, email: profile.email, displayName: "", friendlyName: "", provider: .gmail, sortOrder: accounts.count)
        }
        await save(account)
        await registerProvider(account)
        if prefs.defaultAccountID == nil { prefs.defaultAccountID = account.id }
        prefs.hasCompletedOnboarding = true
        showOnboarding = false
        await refresh(account.id)
    }

    /// Stops work for the account and removes every local trace of it. Other accounts are unaffected.
    func removeAccount(_ id: String) async {
        guard let account = account(id) else { return }
        await providers[id]?.revoke()
        providers[id] = nil
        await providerBox.remove(id)
        TokenVault.delete(accountID: id)
        try? await store.removeAccount(id)
        AppPaths.removeAccountFiles(accountID: id)
        await notifications.removeAll(for: id)
        accounts.removeAll { $0.id == id }
        if scopeAccountID == id { scopeAccountID = nil }
        if prefs.defaultAccountID == id { prefs.defaultAccountID = accounts.first(where: { !$0.isSample })?.id ?? accounts.first?.id }
        path.removeAll { $0.accountID == id }
        if composer?.accountID == id { composer = nil }
        if account.isSample && accounts.isEmpty { prefs.hasCompletedOnboarding = false; showOnboarding = true }
        dataChanged()
    }

    func moveAccount(from: IndexSet, to: Int) async {
        accounts.move(fromOffsets: from, toOffset: to)
        for (i, var a) in accounts.enumerated() { a.sortOrder = i; await save(a) }
    }

    // MARK: Thread actions

    func perform(_ action: ThreadAction, on refs: [ThreadRef], toast showToast: Bool = true) async {
        guard !refs.isEmpty else { return }
        feedback = Feedback(kind: .action)
        var previous: [ThreadRef: Set<String>] = [:]
        for ref in refs {
            guard let account = account(ref.accountID) else { continue }
            previous[ref] = (try? await store.thread(ref))?.labelIDs ?? []
            let change = action.change
            try? await store.applyLabelChange(ref, add: change.add, remove: change.remove, accountEmail: account.email)
            let kind: PendingOperation.Kind = switch action {
            case .trash: .trash(threadID: ref.threadID)
            default: .modify(threadID: ref.threadID, add: Array(change.add), remove: Array(change.remove))
            }
            try? await store.enqueueOperation(PendingOperation(accountID: ref.accountID, kind: kind))
            if action == .restore { try? await store.enqueueOperation(PendingOperation(accountID: ref.accountID, kind: .untrash(threadID: ref.threadID))) }
        }
        if action.removesFromInbox { path.removeAll { refs.contains($0) } }
        dataChanged()
        flushOperations(for: Set(refs.map(\.accountID)))
        if showToast {
            toast = Toast(message: action.pastTense(count: refs.count)) { [weak self] in
                await self?.restoreLabels(previous, wasTrash: action == .trash)
            }
        }
    }

    /// Undo: put each thread's labels back exactly as they were.
    private func restoreLabels(_ previous: [ThreadRef: Set<String>], wasTrash: Bool) async {
        for (ref, labels) in previous {
            guard let account = account(ref.accountID), let current = try? await store.thread(ref) else { continue }
            let add = labels.subtracting(current.labelIDs).subtracting([SystemLabel.trash, SystemLabel.draft, SystemLabel.sent])
            let remove = current.labelIDs.subtracting(labels).subtracting([SystemLabel.draft, SystemLabel.sent])
            try? await store.applyLabelChange(ref, add: add, remove: remove, accountEmail: account.email)
            if wasTrash { try? await store.enqueueOperation(PendingOperation(accountID: ref.accountID, kind: .untrash(threadID: ref.threadID))) }
            let realRemove = remove.subtracting([SystemLabel.trash])
            if !add.isEmpty || !realRemove.isEmpty {
                try? await store.enqueueOperation(PendingOperation(accountID: ref.accountID, kind: .modify(threadID: ref.threadID, add: Array(add), remove: Array(realRemove))))
            }
        }
        dataChanged()
        flushOperations(for: Set(previous.keys.map(\.accountID)))
    }

    private func flushOperations(for accountIDs: Set<String>) {
        for id in accountIDs {
            guard let a = account(id), let p = providers[id] else { continue }
            Task { await sync.replayOperations(a, provider: p) }
        }
    }

    // MARK: Labels

    func createLabel(_ name: String, accountID: String) async throws -> MailLabel {
        guard let p = providers[accountID] else { throw ProviderError.offline }
        let l = try await p.createLabel(name: name.trimmingCharacters(in: .whitespaces), accountID: accountID)
        try await store.upsertLabel(l)
        await reloadMeta()
        return l
    }

    func renameLabel(_ label: MailLabel, to name: String) async throws {
        guard let p = providers[label.accountID] else { throw ProviderError.offline }
        try await store.upsertLabel(try await p.renameLabel(id: label.labelID, name: name, accountID: label.accountID))
        await reloadMeta()
    }

    /// Deletes the label only. Messages keep every other label and remain in All Mail.
    func deleteLabel(_ label: MailLabel) async throws {
        guard let p = providers[label.accountID] else { throw ProviderError.offline }
        try await p.deleteLabel(id: label.labelID)
        try await store.deleteLabel(accountID: label.accountID, labelID: label.labelID)
        if case .label(_, let id, _) = mailbox, id == label.labelID { mailbox = .inbox }
        dataChanged()
    }

    // MARK: Later

    func setLater(_ refs: [ThreadRef], until date: Date) async {
        for ref in refs {
            try? await store.setLater(ref, until: date)
            let subject = (try? await store.thread(ref))?.subject ?? ""
            await notifications.scheduleLaterReminder(ref, subject: subject, at: date, privacy: prefs.previewPrivacy)
        }
        path.removeAll { refs.contains($0) }
        dataChanged()
        let when = date.formatted(.relative(presentation: .named))
        toast = Toast(message: refs.count == 1 ? "Back in Inbox \(when)" : "\(refs.count) conversations back \(when)") { [weak self] in
            await self?.clearLater(refs)
        }
    }

    func clearLater(_ refs: [ThreadRef]) async {
        for ref in refs {
            try? await store.setLater(ref, until: nil)
            notifications.cancelLaterReminder(ref)
        }
        dataChanged()
    }

    /// Policy: a new incoming message in a conversation set for Later brings it back to the Inbox immediately.
    private func clearLaterOnNewReply(_ messages: [MailMessage]) async {
        let refs = Set(messages.map { ThreadRef(accountID: $0.accountID, threadID: $0.threadID) })
        guard !refs.isEmpty, let entries = try? await store.laterEntries() else { return }
        let hits = entries.filter { refs.contains($0.ref) && $0.until > .now }.map(\.ref)
        if !hits.isEmpty { await clearLater(hits) }
    }

    private func resurfaceLater() {
        Task {
            guard let entries = try? await store.laterEntries() else { return }
            for e in entries where e.until <= .now { try? await store.setLater(e.ref, until: nil) }
            dataChanged()
        }
    }

    func setSenderRule(_ address: String, focused: Bool?) async {
        try? await store.setSenderRule(address, rule: focused.map { $0 ? "always" : "never" })
        dataChanged()
    }

    // MARK: Composing & sending

    var defaultSendingAccount: Account? {
        if let id = scopeAccountID, let a = account(id) { return a }
        return prefs.defaultAccountID.flatMap(account) ?? accounts.first
    }

    func compose(to: [EmailAddress] = [], subject: String = "", body: String = "") {
        guard let account = defaultSendingAccount else { return }
        var d = ReplyFactory.newDraft(account: account)
        d.to = to
        d.subject = subject
        if !body.isEmpty { d.bodyText = body + d.bodyText }
        composer = d
    }

    func reply(_ kind: ComposeKind, to message: MailMessage, body: String? = nil) async {
        // Always answer from the account that received the message.
        guard let account = account(message.accountID) else { return }
        var d = ReplyFactory.draft(kind: kind, replyingTo: message, account: account, identities: identities)
        if let body { d.bodyText = body + d.bodyText }
        if kind == .forward { d.attachments = await forwardedAttachments(message) }
        composer = d
    }

    private func forwardedAttachments(_ m: MailMessage) async -> [DraftAttachment] {
        guard let p = providers[m.accountID], let dir = try? AppPaths.outgoingAttachments() else { return [] }
        var out: [DraftAttachment] = []
        for a in m.visibleAttachments {
            let data: Data?
            if let inline = a.inlineData { data = inline } else if let id = a.attachmentID { data = try? await p.attachment(messageID: m.id, attachmentID: id) } else { data = nil }
            guard let data else { continue }
            let local = UUID().uuidString + "-" + a.filename.replacingOccurrences(of: "/", with: "_")
            guard (try? data.write(to: dir.appendingPathComponent(local), options: .completeFileProtectionUntilFirstUserAuthentication)) != nil else { continue }
            out.append(DraftAttachment(filename: a.filename, mimeType: a.mimeType, size: data.count, localPath: local))
        }
        return out
    }

    func editDraft(_ id: String) async {
        if let d = try? await store.draft(id) { composer = d }
    }

    func saveDraftLocally(_ draft: Draft) async {
        try? await store.saveDraft(draft)
    }

    func pushDraft(_ id: String) async -> DraftSync.Outcome {
        await draftSync.push(id)
    }

    func discardDraft(_ id: String) async {
        await draftSync.discard(id)
        flushOperations(for: Set(accounts.map(\.id)))
        dataChanged()
    }

    func send(_ draft: Draft) async throws {
        try await store.saveDraft(draft)
        try await outbox.enqueue(draft, undoWindow: TimeInterval(prefs.undoSendSeconds))
        feedback = Feedback(kind: .action)
        composer = nil
        await reloadOutbox()
    }

    func undoSend(_ item: OutboxItem) async {
        do {
            if let draft = try await outbox.undo(item.id) {
                feedback = Feedback(kind: .undo)
                composer = draft
            } else {
                toast = Toast(message: "Too late to undo — this message is already sending.", isError: true)
            }
        } catch {
            toast = Toast(message: "Couldn't undo. The message is still in Outbox.", isError: true)
        }
        dataChanged()
    }

    func editFailed(_ item: OutboxItem) async {
        if let draft = try? await outbox.returnToDrafts(item.id) { composer = draft }
        dataChanged()
    }

    func retry(_ item: OutboxItem) async {
        try? await outbox.retry(item.id)
    }

    private func didSend(_ item: OutboxItem) {
        feedback = Feedback(kind: .sent)
        if let a = account(item.accountID), let p = providers[a.id] {
            Task {
                if let thread = item.snapshot.threadID {
                    _ = try? await sync.fetchThreads([thread], account: a, provider: p, full: false)
                }
                await refresh(a.id)
            }
        }
        dataChanged()
    }

    // MARK: Lifecycle

    func didEnterBackground() {
        Task {
            guard await outbox.hasUnfinishedWork else { return }
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Send pending mail") { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    let waiting = self.outboxItems.filter { $0.state == .pending || $0.state == .queued }.count
                    if waiting > 0 { await self.notifications.postOutboxWaiting(count: waiting) }
                    UIApplication.shared.endBackgroundTask(self.backgroundTask)
                    self.backgroundTask = .invalid
                }
            }
            // Release the assertion once the queue drains.
            while await outbox.hasUnfinishedWork, backgroundTask != .invalid { try? await Task.sleep(for: .seconds(1)) }
            if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
        }
    }

    // MARK: Deep links

    func handle(_ url: URL) {
        guard let target = DeepLink.parse(url) else { return }
        switch target {
        case .thread(let ref):
            guard account(ref.accountID) != nil else {
                toast = Toast(message: "That account is no longer connected.", isError: true)
                return
            }
            mailbox = .inbox
            path = [ref]
        case .mailbox(let m):
            mailbox = m
            path = []
        case .compose(let to, let subject, let body):
            compose(to: to.filter(\.isValid), subject: subject, body: body)
        }
    }
}

/// Thread-safe registry the outbox and draft sync use to resolve an account's provider. No fallback account is ever returned.
actor ProviderBox {
    private var runtimes: [String: AccountRuntime] = [:]
    func set(_ id: String, _ r: AccountRuntime) { runtimes[id] = r }
    func remove(_ id: String) { runtimes[id] = nil }
    func runtime(_ id: String) -> AccountRuntime? { runtimes[id] }
}
