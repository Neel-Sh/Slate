import Foundation
import Observation
import UIKit
import UniformTypeIdentifiers

@MainActor @Observable
final class ComposerModel {
    var draft: Draft
    var body: NSAttributedString
    var showCcBcc: Bool
    var savedState: SaveState = .idle
    var error: String?
    var isWritingToolsActive = false
    var rewriting: RewriteStyle?
    /// The body before the last generated rewrite, so it can be restored exactly.
    var preRewriteBody: NSAttributedString?
    let editor = BodyEditorController()

    enum SaveState: Equatable { case idle, savedLocally, syncedToGmail, keptBoth, failed(String) }

    private var saveTask: Task<Void, Never>?
    private var pushTask: Task<Void, Never>?
    private weak var app: AppModel?
    private(set) var finished = false

    init(draft: Draft, app: AppModel) {
        self.draft = draft
        self.body = DraftRenderer.attributedBody(draft)
        self.showCcBcc = !draft.cc.isEmpty || !draft.bcc.isEmpty
        self.app = app
    }

    var account: Account? { app?.account(draft.accountID) }
    var canSend: Bool { !draft.allRecipients.isEmpty && !finished }
    var invalidRecipients: [EmailAddress] { draft.allRecipients.filter { !$0.isValid } }

    // MARK: Editing

    func bodyChanged(_ text: NSAttributedString) {
        body = text
        touch()
    }

    func touch() {
        draft.localRevision += 1
        draft.updatedAt = .now
        scheduleSave()
    }

    private func syncBodyIntoDraft() {
        draft.bodyText = body.string
        var hasFormatting = false
        body.enumerateAttributes(in: NSRange(location: 0, length: body.length)) { attrs, _, stop in
            if attrs[.link] != nil { hasFormatting = true; stop.pointee = true; return }
            if let f = attrs[.font] as? UIFont, !f.fontDescriptor.symbolicTraits.intersection([.traitBold, .traitItalic]).isEmpty {
                hasFormatting = true; stop.pointee = true
            }
        }
        draft.bodyRTF = hasFormatting ? DraftRenderer.rtfData(body) : nil
    }

    /// Local save shortly after typing stops; Gmail draft sync a few seconds later. Paused while Writing Tools edits the text.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, !isWritingToolsActive else { return }
            await saveLocally()
        }
        pushTask?.cancel()
        pushTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, !isWritingToolsActive else { return }
            await pushRemote()
        }
    }

    func saveLocally() async {
        guard let app, !finished else { return }
        syncBodyIntoDraft()
        if draft.isEffectivelyEmpty && draft.remoteDraftID == nil { return }
        await app.saveDraftLocally(draft)
        savedState = .savedLocally
    }

    func pushRemote() async {
        guard let app, !finished, !(account?.isSample ?? true) else { return }
        await saveLocally()
        switch await app.pushDraft(draft.id) {
        case .synced: savedState = .syncedToGmail
        case .keptBoth: savedState = .keptBoth
        case .failed(let m): savedState = .failed(m)
        case .unchanged: break
        }
        // Pick up remote IDs without clobbering newer edits.
        if let stored = try? await app.store.draft(draft.id) {
            draft.remoteDraftID = stored.remoteDraftID
            draft.remoteMessageID = stored.remoteMessageID
            draft.syncedRevision = stored.syncedRevision
        }
    }

    // MARK: Accounts

    /// Changing From is always explicit. Signature and sending identity are re-applied; the old Gmail draft is removed.
    func changeAccount(to id: String) {
        guard let app, id != draft.accountID, let newAccount = app.account(id) else { return }
        syncBodyIntoDraft()
        if let remote = draft.remoteDraftID {
            let old = draft.accountID
            Task { try? await app.store.enqueueOperation(PendingOperation(accountID: old, kind: .deleteRemoteDraft(draftID: remote))) }
        }
        draft.remoteDraftID = nil
        draft.remoteMessageID = nil
        draft.syncedRevision = 0
        draft.accountID = id
        // A reply's thread belongs to the receiving account; from another account it becomes a new conversation.
        if draft.kind == .reply || draft.kind == .replyAll { draft.threadID = nil }
        ReplyFactory.applySignature(&draft, signature: newAccount.signature)
        body = DraftRenderer.attributedBody(draft)
        editor.replaceAll(body)
        touch()
    }

    // MARK: Attachments

    func addAttachment(data: Data, filename: String, type: UTType?) {
        guard let dir = try? AppPaths.outgoingAttachments() else { return }
        let total = draft.attachments.reduce(0) { $0 + $1.size } + data.count
        guard total <= MessageAssembler.maxAttachmentBytes else {
            error = "Attachments can total up to 25 MB. Share large files as a link instead."
            return
        }
        let local = UUID().uuidString + "-" + filename.replacingOccurrences(of: "/", with: "_")
        do {
            try data.write(to: dir.appendingPathComponent(local), options: .completeFileProtectionUntilFirstUserAuthentication)
            draft.attachments.append(DraftAttachment(filename: filename, mimeType: type?.preferredMIMEType ?? "application/octet-stream",
                                                     size: data.count, localPath: local))
            touch()
        } catch {
            self.error = "Couldn't add \(filename)."
        }
    }

    func removeAttachment(_ a: DraftAttachment) {
        draft.attachments.removeAll { $0.id == a.id }
        if let dir = try? AppPaths.outgoingAttachments() { try? FileManager.default.removeItem(at: dir.appendingPathComponent(a.localPath)) }
        touch()
    }

    /// Transparent rule: the body mentions an attachment but none is attached.
    var mentionsMissingAttachment: Bool {
        guard draft.attachments.isEmpty else { return false }
        let text = body.string.lowercased()
        return ["attached", "attachment", "enclosed", "i've attached", "see attached"].contains { text.contains($0) }
    }

    // MARK: Finish

    func send() async -> Bool {
        guard let app else { return false }
        syncBodyIntoDraft()
        saveTask?.cancel(); pushTask?.cancel()
        do {
            try await app.send(draft)
            finished = true
            return true
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "Couldn't send. Your draft is saved."
            return false
        }
    }

    func saveAndClose() async {
        saveTask?.cancel(); pushTask?.cancel()
        await saveLocally()
        finished = true
        let id = draft.id
        if let app, !draft.isEffectivelyEmpty {
            Task { _ = await app.pushDraft(id); app.dataChanged() }
            app.toast = Toast(message: "Draft saved")
        }
    }

    func discard() async {
        saveTask?.cancel(); pushTask?.cancel()
        finished = true
        await app?.discardDraft(draft.id)
    }

    // MARK: Rewrite

    func rewrite(_ style: RewriteStyle) async {
        guard let app else { return }
        let original = body
        let revision = draft.localRevision
        rewriting = style
        defer { rewriting = nil }
        do {
            let editable = draft.appliedSignature.isEmpty ? original.string : original.string.replacingOccurrences(of: draft.appliedSignature, with: "")
            let result = try await app.intelligence.rewrite(editable, style: style)
            // Never overwrite edits made while the model was working.
            guard draft.localRevision == revision else {
                error = "Your draft changed while rewriting, so the suggestion was discarded."
                return
            }
            preRewriteBody = original
            let new = NSAttributedString(string: result + draft.appliedSignature,
                                         attributes: [.font: UIFont.preferredFont(forTextStyle: .body), .foregroundColor: UIColor.label])
            body = new
            editor.replaceAll(new)
            touch()
        } catch {
            self.error = IntelligenceService.message(for: error)
        }
    }

    func undoRewrite() {
        guard let previous = preRewriteBody else { return }
        body = previous
        editor.replaceAll(previous)
        preRewriteBody = nil
        touch()
    }
}
