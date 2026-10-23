import Foundation

nonisolated enum MessageAssembler {
    static let maxAttachmentBytes = 25 * 1024 * 1024

    enum AssemblyError: Error { case missingAttachment(String), tooLarge }

    static func raw(for draft: Draft, from: EmailAddress, messageID: String, date: Date) throws -> Data {
        let dir = try AppPaths.outgoingAttachments()
        var attachments: [MIMEBuilder.Attachment] = []
        var total = 0
        for a in draft.attachments {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(a.localPath)) else { throw AssemblyError.missingAttachment(a.filename) }
            total += data.count
            attachments.append(.init(filename: a.filename, mimeType: a.mimeType, data: data))
        }
        guard total <= maxAttachmentBytes else { throw AssemblyError.tooLarge }
        let rendered = DraftRenderer.render(draft)
        return MIMEBuilder.build(.init(from: from, to: draft.to, cc: draft.cc, bcc: draft.bcc, subject: draft.subject,
                                       plain: rendered.plain, html: rendered.html, inReplyTo: draft.inReplyTo, references: draft.references,
                                       messageID: messageID, date: date, attachments: attachments))
    }

    static func removeFiles(of draft: Draft) {
        guard let dir = try? AppPaths.outgoingAttachments() else { return }
        for a in draft.attachments { try? FileManager.default.removeItem(at: dir.appendingPathComponent(a.localPath)) }
    }
}

/// Durable Undo Send queue.
///
/// Each send is an immutable snapshot with its own deadline. Undo and submission both claim the item with a
/// compare-and-swap on its persisted state, so exactly one of them can win. Once submission starts it is never
/// offered as cancellable; an interrupted submission is reconciled against Gmail by Message-ID before any retry.
actor Outbox {
    typealias Lookup = @Sendable (String) async -> (provider: any MailProvider, account: Account)?

    private let store: MailStore
    private let lookup: Lookup
    private let now: @Sendable () -> Date
    private var timers: [String: Task<Void, Never>] = [:]
    private var onChange: (@Sendable () -> Void)?
    private var onSent: (@Sendable (OutboxItem) -> Void)?
    /// Delay before checking Gmail after an ambiguous outcome, so an in-flight acceptance can land.
    var reconcileDelay: TimeInterval = 15
    var retryDelay: TimeInterval = 30

    init(store: MailStore, lookup: @escaping Lookup, now: @escaping @Sendable () -> Date = { .now }) {
        self.store = store
        self.lookup = lookup
        self.now = now
    }

    func setHandlers(onChange: @escaping @Sendable () -> Void, onSent: @escaping @Sendable (OutboxItem) -> Void) {
        self.onChange = onChange
        self.onSent = onSent
    }

    func setDelays(reconcile: TimeInterval, retry: TimeInterval) {
        reconcileDelay = reconcile
        retryDelay = retry
    }

    enum EnqueueError: LocalizedError {
        case noRecipients, invalidRecipient(String), accountUnavailable
        var errorDescription: String? {
            switch self {
            case .noRecipients: "Add at least one recipient."
            case .invalidRecipient(let a): "“\(a)” isn't a valid email address."
            case .accountUnavailable: "The sending account isn't available."
            }
        }
    }

    // MARK: Public API

    @discardableResult
    func enqueue(_ draft: Draft, undoWindow: TimeInterval) async throws -> OutboxItem {
        guard !draft.allRecipients.isEmpty else { throw EnqueueError.noRecipients }
        if let bad = draft.allRecipients.first(where: { !$0.isValid }) { throw EnqueueError.invalidRecipient(bad.address) }
        guard let (_, account) = await lookup(draft.accountID) else { throw EnqueueError.accountUnavailable }
        var snapshot = draft
        snapshot.state = .inOutbox
        snapshot.updatedAt = now()
        let item = OutboxItem(accountID: draft.accountID, draftID: draft.id, state: .pending, deadline: now().addingTimeInterval(undoWindow),
                              createdAt: now(), snapshot: snapshot, messageIDHeader: MIMEBuilder.makeMessageID(fromAddress: account.email))
        try await store.insertOutbox(item, lockingDraft: draft)
        schedule(item.id, at: item.deadline)
        onChange?()
        return item
    }

    /// Cancels a send that has not started submission. Returns the restored, editable draft, or nil if it was too late.
    func undo(_ id: String) async throws -> Draft? {
        guard try await store.transitionOutbox(id, from: [.pending, .queued], to: .cancelled) else { return nil }
        timers[id]?.cancel()
        timers[id] = nil
        guard let item = try await store.outboxItem(id) else { return nil }
        var draft = item.snapshot
        draft.state = .editing
        draft.localRevision += 1
        draft.updatedAt = now()
        try await store.saveDraft(draft)
        try await store.deleteOutbox(id)
        onChange?()
        return draft
    }

    /// Turns a failed send back into an editable draft.
    func returnToDrafts(_ id: String) async throws -> Draft? {
        guard try await store.transitionOutbox(id, from: [.failed], to: .cancelled) else { return try await undo(id) }
        guard let item = try await store.outboxItem(id) else { return nil }
        var draft = item.snapshot
        draft.state = .editing
        draft.localRevision += 1
        try await store.saveDraft(draft)
        try await store.deleteOutbox(id)
        onChange?()
        return draft
    }

    func retry(_ id: String) async throws {
        guard try await store.transitionOutbox(id, from: [.failed], to: .queued) else { return }
        try await store.updateOutbox(id, failure: .some(nil), lastError: .some(nil))
        onChange?()
        schedule(id, at: now())
    }

    /// Re-arms every unfinished item after launch.
    func resume() async {
        guard let items = try? await store.outboxItems(states: [.pending, .queued, .submitting, .ambiguous]) else { return }
        for item in items {
            switch item.state {
            case .pending: schedule(item.id, at: item.deadline)
            case .queued: schedule(item.id, at: max(item.nextAttemptAt ?? now(), now()))
            case .submitting:
                // The app stopped while submitting: the provider may have accepted it.
                if (try? await store.transitionOutbox(item.id, from: [.submitting], to: .ambiguous)) == true {
                    scheduleReconcile(item.id, after: 0)
                }
            case .ambiguous: scheduleReconcile(item.id, after: 0)
            default: break
            }
        }
        try? await store.pruneSentOutbox(olderThan: now().addingTimeInterval(-7 * 86400))
        onChange?()
    }

    func connectivityRestored() async {
        guard let items = try? await store.outboxItems(states: [.queued, .ambiguous]) else { return }
        for item in items {
            if item.state == .queued { schedule(item.id, at: now()) } else { scheduleReconcile(item.id, after: 0) }
        }
    }

    func items() async -> [OutboxItem] { (try? await store.outboxItems()) ?? [] }

    var hasUnfinishedWork: Bool {
        get async { !((try? await store.outboxItems(states: [.pending, .queued, .submitting, .ambiguous])) ?? []).isEmpty }
    }

    /// Submits everything in its undo window immediately (used when the system is about to suspend the app).
    func earliestDeadline() async -> Date? {
        (try? await store.outboxItems(states: [.pending]))?.map(\.deadline).min()
    }

    // MARK: Scheduling

    private func schedule(_ id: String, at date: Date) {
        timers[id]?.cancel()
        let delay = max(0, date.timeIntervalSince(now()))
        timers[id] = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            await self?.fire(id)
        }
    }

    private func scheduleReconcile(_ id: String, after delay: TimeInterval) {
        timers[id]?.cancel()
        timers[id] = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            await self?.reconcile(id)
        }
    }

    private func fire(_ id: String) async {
        timers[id] = nil
        guard (try? await store.transitionOutbox(id, from: [.pending, .queued], to: .submitting)) == true,
              let item = try? await store.outboxItem(id) else { return }
        onChange?()
        await submit(item)
    }

    // MARK: Submission

    private func fail(_ item: OutboxItem, _ failure: OutboxFailure, detail: String? = nil, from: OutboxState = .submitting) async {
        _ = try? await store.transitionOutbox(item.id, from: [from], to: .failed)
        try? await store.updateOutbox(item.id, failure: .some(failure), lastError: .some(detail))
        onChange?()
    }

    private func submit(_ item: OutboxItem) async {
        guard let (provider, account) = await lookup(item.accountID) else { return await fail(item, .accountRemoved) }
        let raw: Data
        do {
            raw = try MessageAssembler.raw(for: item.snapshot, from: account.fromAddress, messageID: item.messageIDHeader, date: item.createdAt)
        } catch MessageAssembler.AssemblyError.tooLarge {
            return await fail(item, .tooLarge)
        } catch {
            return await fail(item, .missingAttachment)
        }
        try? await store.updateOutbox(item.id, attempts: item.attempts + 1)
        do {
            let sent = try await provider.send(raw: raw, threadID: item.snapshot.threadID)
            await markSent(item, providerID: sent.id, from: .submitting)
        } catch let error as ProviderError {
            switch error {
            case .offline:
                // The request never left the device; safe to retry.
                await requeue(item, from: .submitting, at: now().addingTimeInterval(retryDelay), detail: error.localizedDescription)
            case .rateLimited(let after):
                await requeue(item, from: .submitting, at: now().addingTimeInterval(after ?? retryDelay), detail: error.localizedDescription)
            case .authenticationRequired:
                await fail(item, .authentication)
            case .rejected(let status, let message):
                await fail(item, status == 413 ? .tooLarge : .rejected, detail: message)
            case .indeterminate, .server, .notFound, .historyExpired, .notConfigured:
                _ = try? await store.transitionOutbox(item.id, from: [.submitting], to: .ambiguous)
                try? await store.updateOutbox(item.id, lastError: .some(error.localizedDescription))
                onChange?()
                scheduleReconcile(item.id, after: reconcileDelay)
            }
        } catch {
            _ = try? await store.transitionOutbox(item.id, from: [.submitting], to: .ambiguous)
            onChange?()
            scheduleReconcile(item.id, after: reconcileDelay)
        }
    }

    private func requeue(_ item: OutboxItem, from: OutboxState, at date: Date, detail: String?) async {
        guard (try? await store.transitionOutbox(item.id, from: [from], to: .queued)) == true else { return }
        try? await store.updateOutbox(item.id, lastError: .some(detail), nextAttemptAt: .some(date))
        onChange?()
        schedule(item.id, at: date)
    }

    private func reconcile(_ id: String) async {
        timers[id] = nil
        guard let item = try? await store.outboxItem(id), item.state == .ambiguous else { return }
        guard let (provider, _) = await lookup(item.accountID) else { return await fail(item, .accountRemoved, from: .ambiguous) }
        do {
            if let found = try await provider.findMessage(rfc822MessageID: item.messageIDHeader) {
                await markSent(item, providerID: found, from: .ambiguous)
            } else if item.attempts >= 5 {
                await fail(item, .rejected, detail: "Couldn't confirm whether this message was sent. Check Sent before trying again.", from: .ambiguous)
            } else {
                await requeue(item, from: .ambiguous, at: now().addingTimeInterval(retryDelay), detail: "Not found in Gmail; sending again.")
            }
        } catch ProviderError.authenticationRequired {
            await fail(item, .authentication, from: .ambiguous)
        } catch {
            // Still can't reach Gmail. Stay ambiguous; never resend blindly.
            scheduleReconcile(id, after: retryDelay)
        }
    }

    private func markSent(_ item: OutboxItem, providerID: String, from: OutboxState) async {
        guard (try? await store.transitionOutbox(item.id, from: [from], to: .sent)) == true else { return }
        try? await store.updateOutbox(item.id, failure: .some(nil), lastError: .some(nil), providerMessageID: providerID, sentAt: now())
        try? await store.deleteDraft(item.draftID)
        if let remote = item.snapshot.remoteDraftID {
            try? await store.enqueueOperation(PendingOperation(accountID: item.accountID, kind: .deleteRemoteDraft(draftID: remote)))
        }
        try? await store.recordRecipients(accountID: item.accountID, item.snapshot.allRecipients)
        MessageAssembler.removeFiles(of: item.snapshot)
        var sent = item
        sent.state = .sent
        sent.providerMessageID = providerID
        onChange?()
        onSent?(sent)
    }
}

/// Keeps the provider's copy of a local draft up to date without overwriting edits made elsewhere.
actor DraftSync {
    private let store: MailStore
    private let lookup: Outbox.Lookup

    init(store: MailStore, lookup: @escaping Outbox.Lookup) {
        self.store = store
        self.lookup = lookup
    }

    enum Outcome: Equatable { case unchanged, synced, keptBoth, failed(String) }

    @discardableResult
    func push(_ draftID: String) async -> Outcome {
        guard let draft = try? await store.draft(draftID), draft.state == .editing, draft.localRevision > draft.syncedRevision,
              !draft.isEffectivelyEmpty, let (provider, account) = await lookup(draft.accountID), !account.isSample else { return .unchanged }
        let revision = draft.localRevision
        do {
            let raw = try MessageAssembler.raw(for: draft, from: account.fromAddress,
                                               messageID: MIMEBuilder.makeMessageID(fromAddress: account.email), date: .now)
            var outcome = Outcome.synced
            let remote: RemoteDraft
            if let id = draft.remoteDraftID {
                let current = try await provider.remoteDraftMessageID(id: id)
                if current == nil {
                    remote = try await provider.createDraft(raw: raw, threadID: draft.threadID)
                } else if current != draft.remoteMessageID {
                    // Edited in Gmail since our last sync: keep their version and store ours separately.
                    remote = try await provider.createDraft(raw: raw, threadID: draft.threadID)
                    outcome = .keptBoth
                } else {
                    remote = try await provider.updateDraft(id: id, raw: raw, threadID: draft.threadID)
                }
            } else {
                remote = try await provider.createDraft(raw: raw, threadID: draft.threadID)
            }
            // Re-read so a newer local edit made during the upload is never overwritten.
            guard var latest = try await store.draft(draftID), latest.state == .editing else {
                try? await provider.deleteDraft(id: remote.draftID)
                return .unchanged
            }
            latest.remoteDraftID = remote.draftID
            latest.remoteMessageID = remote.messageID
            latest.syncedRevision = max(latest.syncedRevision, revision)
            try await store.saveDraft(latest)
            return outcome
        } catch {
            return .failed((error as? LocalizedError)?.errorDescription ?? "Couldn't sync draft.")
        }
    }

    func discard(_ draftID: String) async {
        guard let draft = try? await store.draft(draftID) else { return }
        try? await store.deleteDraft(draftID)
        if let remote = draft.remoteDraftID {
            try? await store.enqueueOperation(PendingOperation(accountID: draft.accountID, kind: .deleteRemoteDraft(draftID: remote)))
        }
        MessageAssembler.removeFiles(of: draft)
    }
}
