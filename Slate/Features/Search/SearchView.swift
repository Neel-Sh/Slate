import SwiftUI
import Observation

@MainActor @Observable
final class SearchModel {
    var local: [ThreadSummary] = []
    var remote: [ThreadSummary] = []
    var remoteState: RemoteState = .idle
    private var task: Task<Void, Never>?
    private var generation = 0

    enum RemoteState: Equatable { case idle, searching, done, offline, failed(String) }

    /// Cached results appear immediately; Gmail results follow. Stale responses from earlier keystrokes are dropped.
    func run(_ text: String, scope: SearchScope, app: AppModel) {
        task?.cancel()
        generation += 1
        let gen = generation
        let query = SearchQuery.parse(text)
        guard !query.isEmpty, let store = app.store else {
            local = []; remote = []; remoteState = .idle
            return
        }
        let mailbox: Mailbox? = scope == .currentMailbox ? app.mailbox : nil
        let accountIDs = mailbox?.labelAccountID.map { [$0] } ?? app.scopeAccountIDs
        task = Task {
            let found = (try? await store.search(query, accountIDs: accountIDs, mailbox: mailbox)) ?? []
            guard gen == generation else { return }
            local = found
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, gen == generation else { return }
            remoteState = .searching
            var providerQuery = query.providerQuery
            if let mailbox, let label = mailbox.providerLabelID { providerQuery += " label:\(label)" }
            var collected: [ThreadSummary] = []
            var anyOffline = false, failure: String?
            for id in accountIDs {
                guard let p = app.provider(for: id), let account = app.account(id) else { continue }
                do {
                    let page = try await p.listThreads(labelID: nil, query: providerQuery, includeSpamTrash: query.includesSpamTrash,
                                                       pageToken: nil, maxResults: 25)
                    let localIDs = Set(found.map(\.ref))
                    let missing = page.threadIDs.filter { !localIDs.contains(ThreadRef(accountID: id, threadID: $0)) }
                    try await app.sync.fetchThreads(missing, account: account, provider: p, full: false)
                    for t in missing {
                        if let s = try await store.thread(ThreadRef(accountID: id, threadID: t)) { collected.append(s) }
                    }
                } catch ProviderError.offline {
                    anyOffline = true
                } catch is CancellationError {
                    return
                } catch {
                    failure = (error as? LocalizedError)?.errorDescription
                }
                guard gen == generation else { return }
            }
            guard gen == generation else { return }
            remote = collected.sorted { $0.lastDate > $1.lastDate }
            remoteState = anyOffline ? .offline : failure.map { .failed($0) } ?? .done
        }
    }
}

struct SearchView: View {
    @Environment(AppModel.self) private var model
    @Binding var text: String
    var scope: SearchScope
    @State private var search = SearchModel()

    private static let filters: [(String, String)] = [
        ("Unread", "is:unread"), ("Starred", "is:starred"), ("Attachments", "has:attachment"), ("Important", "is:important"),
        ("Last 7 days", "after:\(Self.daysAgo(7))"), ("Older than a year", "before:\(Self.daysAgo(365))"), ("Spam & Trash", "in:anywhere"),
    ]

    private static func daysAgo(_ n: Int) -> String {
        let d = Calendar.current.date(byAdding: .day, value: -n, to: .now)!
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!)
    }

    var body: some View {
        List {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.xs) {
                        ForEach(Self.filters, id: \.1) { title, token in
                            let on = text.contains(token)
                            Button {
                                text = on ? text.replacingOccurrences(of: token, with: "").trimmingCharacters(in: .whitespaces)
                                          : (text.isEmpty ? token : text + " " + token)
                            } label: {
                                Text(title).font(.subheadline)
                                    .padding(.horizontal, Spacing.sm).frame(minHeight: 34)
                                    .foregroundStyle(on ? Color.slate.accent : Color.slate.inkPrimary)
                                    .background(on ? Color.slate.selectionFill : Color.slate.surfaceSecondary, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listRowInsets(EdgeInsets(top: Spacing.xs, leading: Spacing.md, bottom: Spacing.xs, trailing: Spacing.md))
                .listRowSeparator(.hidden)
            }

            if text.trimmingCharacters(in: .whitespaces).isEmpty {
                if !model.prefs.recentSearches.isEmpty {
                    Section {
                        ForEach(model.prefs.recentSearches, id: \.self) { s in
                            Button { text = s } label: { Label(s, systemImage: "clock.arrow.circlepath").foregroundStyle(Color.slate.inkPrimary) }
                        }
                    } header: {
                        HStack {
                            Text("Recent")
                            Spacer()
                            Button("Clear") { model.prefs.recentSearches = [] }.font(.footnote)
                        }
                    }
                }
                Section {
                } footer: {
                    Text("Tip: Gmail search works here — from:, to:, subject:, label:, filename:, has:attachment, is:unread, after:2026/01/31, \"exact phrase\", OR, and -exclude.")
                }
            } else {
                Section {
                    if search.local.isEmpty {
                        Text("No downloaded matches").foregroundStyle(Color.slate.inkMetadata)
                    }
                    ForEach(search.local) { row($0) }
                } header: { Text("On This iPhone") }

                Section {
                    switch search.remoteState {
                    case .searching: HStack { ProgressView(); Text("Searching Gmail…").foregroundStyle(Color.slate.inkSecondary) }
                    case .offline: Label("You're offline. Showing downloaded results only.", systemImage: "wifi.slash").foregroundStyle(Color.slate.inkSecondary)
                    case .failed(let m): Label(m, systemImage: "exclamationmark.circle").foregroundStyle(Color.slate.inkSecondary)
                    case .done where search.remote.isEmpty: Text("No additional results in Gmail").foregroundStyle(Color.slate.inkMetadata)
                    default: EmptyView()
                    }
                    ForEach(search.remote) { row($0) }
                } header: { Text(model.hasMultipleAccounts && model.scopeAccountID == nil ? "From Gmail · All Accounts" : "From Gmail") }
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.immediately)
        .onChange(of: text, initial: true) { _, new in search.run(new, scope: scope, app: model) }
        .onChange(of: scope) { _, new in search.run(text, scope: new, app: model) }
        .onSubmit(of: .search) { model.prefs.remember(search: text) }
    }

    private func row(_ t: ThreadSummary) -> some View {
        NavigationLink(value: t.ref) {
            ThreadRow(thread: t, account: model.account(t.ref.accountID), showAccount: model.hasMultipleAccounts, chips: [], identities: model.identities)
        }
        .simultaneousGesture(TapGesture().onEnded { model.prefs.remember(search: text) })
    }
}
