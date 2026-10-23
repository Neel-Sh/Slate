import Foundation
import Observation
import SwiftUI

/// Pages a mailbox from the local cache, then extends it from the provider when the cache runs out.
@MainActor @Observable
final class ThreadListModel {
    private(set) var threads: [ThreadSummary] = []
    private(set) var isLoadingMore = false
    private(set) var reachedEnd = false
    private(set) var loadedOnce = false
    private var providerTokens: [String: String?] = [:]
    private var key: String = ""

    static let pageSize = 50

    func reload(_ model: AppModel, mailbox: Mailbox) async {
        guard let store = model.store else { return }
        let newKey = mailbox.id + "|" + model.scopeAccountIDs.joined(separator: ",")
        if newKey != key {
            key = newKey
            providerTokens = [:]
            reachedEnd = false
            threads = []
        }
        // Keep at least as many rows as are visible so reloading never moves the scroll position.
        let limit = max(Self.pageSize, threads.count)
        let fresh = (try? await store.threads(mailbox: mailbox, accountIDs: model.scopeAccountIDs, before: nil, limit: limit)) ?? []
        if loadedOnce && Set(fresh.map(\.ref)) != Set(threads.map(\.ref)) {
            withAnimation(Motion.standard) { threads = fresh }
        } else {
            threads = fresh
        }
        loadedOnce = true
        if mailbox == .later { threads.sort { ($0.laterUntil ?? .distantFuture) < ($1.laterUntil ?? .distantFuture) } }
    }

    func loadMore(_ model: AppModel, mailbox: Mailbox) async {
        guard !isLoadingMore, !reachedEnd, let store = model.store, mailbox != .later else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let cursor = threads.last.map { MailStore.ListCursor(date: $0.lastDate, key: $0.ref.accountID + "/" + $0.ref.threadID) }
        var page = (try? await store.threads(mailbox: mailbox, accountIDs: model.scopeAccountIDs, before: cursor, limit: Self.pageSize)) ?? []
        if page.isEmpty {
            let exhausted = model.scopeAccountIDs.allSatisfy { providerTokens[$0] == .some(nil) }
            guard !exhausted else { reachedEnd = true; return }
            providerTokens = await model.loadMore(mailbox, tokens: providerTokens)
            page = (try? await store.threads(mailbox: mailbox, accountIDs: model.scopeAccountIDs, before: cursor, limit: Self.pageSize)) ?? []
            if page.isEmpty && model.scopeAccountIDs.allSatisfy({ providerTokens[$0] == .some(nil) }) { reachedEnd = true }
        }
        let existing = Set(threads.map(\.ref))
        threads += page.filter { !existing.contains($0.ref) }
    }
}
