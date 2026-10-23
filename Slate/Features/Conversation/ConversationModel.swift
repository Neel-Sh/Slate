import Foundation
import Observation

@MainActor @Observable
final class ConversationModel {
    let ref: ThreadRef
    private(set) var thread: ThreadSummary?
    private(set) var messages: [MailMessage] = []
    private(set) var isLoadingBody = false
    private(set) var loadError: String?
    private(set) var missing = false
    /// cid → data for inline images, per message.
    private(set) var inlineImages: [String: [String: Data]] = [:]
    var expanded: Set<String> = []

    // Intelligence state — always on demand.
    enum GenState<T: Equatable>: Equatable { case idle, loading, ready(T), failed(String) }
    var summary: GenState<ThreadDigest> = .idle
    var intentions: GenState<[ReplyIntention]> = .idle
    var draftingIntention: ReplyIntention.ID?
    var suggestionsDismissed = false

    init(ref: ThreadRef) { self.ref = ref }

    var latest: MailMessage? { messages.last }

    func load(_ app: AppModel) async {
        guard let store = app.store else { return }
        thread = try? await store.thread(ref)
        let cached = (try? await store.messages(in: ref))?.filter { !$0.labelIDs.contains(SystemLabel.draft) } ?? []
        if !cached.isEmpty { setMessages(cached) }
        guard app.account(ref.accountID) != nil else { missing = true; return }

        if cached.isEmpty || cached.contains(where: { !$0.hasFullBody }), let provider = app.provider(for: ref.accountID),
           let account = app.account(ref.accountID) {
            isLoadingBody = true
            defer { isLoadingBody = false }
            do {
                let full = try await provider.thread(id: ref.threadID, accountID: ref.accountID, full: true)
                try await store.replaceThread(ref, messages: full, accountEmail: account.email)
                setMessages(full.filter { !$0.labelIDs.contains(SystemLabel.draft) })
                thread = try? await store.thread(ref)
                loadError = nil
            } catch ProviderError.notFound {
                try? await store.replaceThread(ref, messages: [], accountEmail: account.email)
                missing = true
            } catch {
                loadError = cached.isEmpty ? (error as? LocalizedError)?.errorDescription ?? "Couldn't load this conversation."
                    : "Showing the downloaded copy. \((error as? LocalizedError)?.errorDescription ?? "")"
            }
        }
        if messages.isEmpty && !isLoadingBody && loadError == nil { missing = true }
        await loadInlineImages(app)
        if thread?.isUnread == true {
            await app.perform(.markRead, on: [ref], toast: false)
            thread = try? await store.thread(ref)
        }
    }

    private func setMessages(_ list: [MailMessage]) {
        let firstLoad = messages.isEmpty
        messages = list.sorted { $0.date < $1.date }
        if firstLoad {
            // Expand unread messages and the latest one; earlier read messages stay collapsed.
            expanded = Set(messages.filter(\.isUnread).map(\.id))
            if let last = messages.last { expanded.insert(last.id) }
        }
        // A newer reply makes earlier generated content stale.
        if case .ready(let digest) = summary, digest.sourceMessageIDs != messages.map(\.id) { summary = .idle }
        if case .ready = intentions, let last = messages.last, intentionsSource != last.id { intentions = .idle }
    }

    private var intentionsSource: String?

    private func loadInlineImages(_ app: AppModel) async {
        guard let provider = app.provider(for: ref.accountID) else { return }
        for m in messages where (m.bodyHTML ?? "").contains("cid:") {
            var map: [String: Data] = [:]
            for a in m.attachments where a.contentID != nil && a.size < 3_000_000 {
                if let d = a.inlineData { map[a.contentID!] = d }
                else if let id = a.attachmentID, let d = try? await provider.attachment(messageID: m.id, attachmentID: id) { map[a.contentID!] = d }
            }
            inlineImages[m.id] = map
        }
    }

    // MARK: Intelligence

    var isLongEnoughToSummarize: Bool {
        messages.count >= 3 || messages.reduce(0) { $0 + ($1.bodyPlain?.count ?? $1.snippet.count) } > 1500
    }

    func summarize(_ app: AppModel) async {
        summary = .loading
        do { summary = .ready(try await app.intelligence.summarize(messages)) }
        catch { summary = .failed(IntelligenceService.message(for: error)) }
    }

    func suggest(_ app: AppModel) async {
        guard let last = messages.last, let account = app.account(ref.accountID) else { return }
        intentions = .loading
        intentionsSource = last.id
        do {
            let list = try await app.intelligence.intentions(messages, userName: account.displayName.isEmpty ? account.email : account.displayName)
            // Ignore a late response if a newer message arrived meanwhile.
            guard messages.last?.id == last.id else { intentions = .idle; return }
            intentions = list.isEmpty ? .failed("No suggestions for this message.") : .ready(list)
        } catch {
            intentions = .failed(IntelligenceService.message(for: error))
        }
    }

    /// Produces an editable draft for the chosen intention. It never sends.
    func draft(_ intention: ReplyIntention, app: AppModel) async {
        guard let last = messages.last, let account = app.account(ref.accountID) else { return }
        draftingIntention = intention.id
        defer { draftingIntention = nil }
        do {
            let body = try await app.intelligence.draftReply(intention, messages: messages,
                                                              userName: account.displayName.isEmpty ? account.email : account.displayName)
            await app.reply(.reply, to: last, body: body)
            app.composerNote = "Written on this iPhone from your choice “\(intention.label)”. Review it before sending."
        } catch {
            app.toast = Toast(message: IntelligenceService.message(for: error), isError: true)
        }
    }
}
