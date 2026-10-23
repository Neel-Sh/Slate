import Foundation

/// Synchronizes one account at a time; accounts never block one another.
actor SyncCoordinator {
    private let store: MailStore
    private var running: [String: Task<SyncResult, Never>] = [:]

    init(store: MailStore) { self.store = store }

    nonisolated struct SyncResult: Sendable {
        var accountID: String
        var error: ProviderError?
        var newInboxMessages: [MailMessage] = []
        var historyID: String?
    }

    static let initialInboxCount = 60
    static let prefetchBodies = 20

    /// Runs (or joins) a sync for the account.
    func sync(_ account: Account, provider: any MailProvider) async -> SyncResult {
        if let task = running[account.id] { return await task.value }
        let task = Task { await self.perform(account, provider: provider) }
        running[account.id] = task
        let result = await task.value
        running[account.id] = nil
        return result
    }

    private func perform(_ account: Account, provider: any MailProvider) async -> SyncResult {
        var result = SyncResult(accountID: account.id)
        do {
            await replayOperations(account, provider: provider)
            if let history = account.historyID {
                do {
                    result = try await delta(account, provider: provider, since: history)
                } catch ProviderError.historyExpired {
                    result = try await fullSync(account, provider: provider)
                }
            } else {
                result = try await fullSync(account, provider: provider)
            }
        } catch let e as ProviderError {
            result.error = e
        } catch is CancellationError {
        } catch {
            result.error = .indeterminate(error.localizedDescription)
        }
        return result
    }

    /// Bounded initial (or recovery) sync. App-owned drafts, outbox, Later and pending operations are untouched.
    private func fullSync(_ account: Account, provider: any MailProvider) async throws -> SyncResult {
        // Record the history point first so nothing that arrives during the listing is missed.
        let profile = try await provider.profile()
        let labels = try await provider.labels(accountID: account.id)
        try await store.replaceLabels(accountID: account.id, labels)
        let page = try await provider.listThreads(labelID: SystemLabel.inbox, query: nil, includeSpamTrash: false, pageToken: nil,
                                                  maxResults: Self.initialInboxCount)
        let fetched = try await fetchThreads(page.threadIDs, account: account, provider: provider, full: false)
        // Threads cached locally as Inbox but no longer in the first page window are re-checked.
        if let oldest = fetched.flatMap({ $0 }).map(\.date).min() {
            let local = Set(try await store.threadIDs(accountID: account.id, labelID: SystemLabel.inbox, newerThan: oldest))
            let stale = local.subtracting(page.threadIDs)
            _ = try await fetchThreads(Array(stale), account: account, provider: provider, full: false)
        }
        _ = try await fetchThreads(Array(page.threadIDs.prefix(Self.prefetchBodies)), account: account, provider: provider, full: true)
        var r = SyncResult(accountID: account.id)
        r.historyID = profile.historyID
        return r
    }

    private func delta(_ account: Account, provider: any MailProvider, since: String) async throws -> SyncResult {
        let d = try await provider.history(since: since)
        if !d.deletedMessageIDs.isEmpty {
            try await store.deleteMessages(accountID: account.id, ids: Array(d.deletedMessageIDs), accountEmail: account.email)
        }
        _ = try await fetchThreads(Array(d.changedThreadIDs), account: account, provider: provider, full: false)
        var r = SyncResult(accountID: account.id)
        r.historyID = d.newHistoryID
        for id in d.addedInboxMessageIDs {
            if let m = try await store.message(accountID: account.id, id: id), m.labelIDs.contains(SystemLabel.inbox),
               m.from?.normalized != account.email.lowercased() {
                r.newInboxMessages.append(m)
            }
        }
        if !d.changedThreadIDs.isEmpty {
            try await store.replaceLabels(accountID: account.id, try await provider.labels(accountID: account.id))
        }
        return r
    }

    /// Fetches threads with bounded concurrency and stores them. Threads that vanished are removed locally.
    @discardableResult
    func fetchThreads(_ ids: [String], account: Account, provider: any MailProvider, full: Bool) async throws -> [[MailMessage]] {
        var results: [[MailMessage]] = []
        let chunks = stride(from: 0, to: ids.count, by: 6).map { Array(ids[$0..<min($0 + 6, ids.count)]) }
        for chunk in chunks {
            try Task.checkCancellation()
            let batch = try await withThrowingTaskGroup(of: (String, [MailMessage]?).self) { group in
                for id in chunk {
                    group.addTask {
                        do { return (id, try await provider.thread(id: id, accountID: account.id, full: full)) }
                        catch ProviderError.notFound { return (id, nil) }
                    }
                }
                var out: [(String, [MailMessage]?)] = []
                for try await r in group { out.append(r) }
                return out
            }
            for (id, messages) in batch {
                try await store.replaceThread(ThreadRef(accountID: account.id, threadID: id), messages: messages ?? [], accountEmail: account.email)
                if let messages { results.append(messages) }
            }
        }
        return results
    }

    /// Fetches the next page of a mailbox from the provider so the list can extend beyond the cache.
    func loadMore(mailbox: Mailbox, account: Account, provider: any MailProvider, pageToken: String?) async throws -> String? {
        let page = try await provider.listThreads(labelID: mailbox.providerLabelID, query: mailbox == .allMail ? "-in:spam -in:trash" : nil,
                                                  includeSpamTrash: mailbox == .spam || mailbox == .trash, pageToken: pageToken, maxResults: 30)
        try await fetchThreads(page.threadIDs, account: account, provider: provider, full: false)
        return page.nextPageToken
    }

    // MARK: Pending operations

    func replayOperations(_ account: Account, provider: any MailProvider) async {
        guard let ops = try? await store.operations(accountID: account.id) else { return }
        for op in ops {
            do {
                try await Self.execute(op, provider: provider)
                try? await store.completeOperation(op.id)
            } catch let e as ProviderError where e.isTransient {
                try? await store.bumpOperation(op.id)
                break // keep order; retry on next sync
            } catch ProviderError.notFound {
                try? await store.completeOperation(op.id)
            } catch ProviderError.authenticationRequired {
                break
            } catch {
                // Permanent rejection: drop it and let the next fetch restore server truth.
                try? await store.completeOperation(op.id)
                if case .modify(let t, _, _) = op.kind { _ = try? await fetchThreads([t], account: account, provider: provider, full: false) }
            }
        }
    }

    static func execute(_ op: PendingOperation, provider: any MailProvider) async throws {
        switch op.kind {
        case .modify(let t, let add, let remove): try await provider.modifyThread(id: t, add: add, remove: remove)
        case .trash(let t): try await provider.trashThread(id: t)
        case .untrash(let t): try await provider.untrashThread(id: t)
        case .deleteRemoteDraft(let d): try await provider.deleteDraft(id: d)
        }
    }
}
