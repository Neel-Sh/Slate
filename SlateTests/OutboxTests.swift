import Foundation
import Testing
@testable import Slate

@Suite("Undo Send outbox", .serialized)
struct OutboxTests {
    let store: MailStore
    let provider = FakeProvider()
    let outbox: Outbox

    init() async throws {
        store = try Fixtures.store()
        let p = provider
        outbox = Outbox(store: store, lookup: { id in id == Fixtures.account.id ? (p, Fixtures.account) : nil })
        await outbox.setDelays(reconcile: 0.05, retry: 0.1)
    }

    private func state(_ id: String) async -> OutboxState? { try? await store.outboxItem(id)?.state }

    @Test func undoWithinWindowRestoresEditableDraftAndNeverSubmits() async throws {
        var draft = Fixtures.draft()
        draft.cc = [EmailAddress(name: nil, address: "cc@example.org")]
        draft.bcc = [EmailAddress(name: nil, address: "hidden@example.org")]
        try await store.saveDraft(draft)
        let item = try await outbox.enqueue(draft, undoWindow: 0.5)
        #expect(await state(item.id) == .pending)
        #expect(try await store.draft(draft.id)?.state == .inOutbox)

        let restored = try await outbox.undo(item.id)
        #expect(restored?.state == .editing)
        #expect(restored?.to == draft.to && restored?.cc == draft.cc && restored?.bcc == draft.bcc)
        #expect(restored?.bodyText == draft.bodyText)
        #expect(try await store.draft(draft.id)?.state == .editing)

        try await Task.sleep(for: .milliseconds(800))
        #expect(provider.sentCount == 0)
    }

    @Test func sendsExactlyOnceAfterWindow() async throws {
        let draft = Fixtures.draft()
        try await store.saveDraft(draft)
        let item = try await outbox.enqueue(draft, undoWindow: 0.1)
        #expect(await waitUntil { await state(item.id) == .sent })
        #expect(provider.sentCount == 1)
        // The draft is removed only after the provider accepted the message.
        #expect(try await store.draft(draft.id) == nil)
        #expect(try await outbox.undo(item.id) == nil)
    }

    @Test func twoQueuedSendsAreIndependent() async throws {
        let a = Fixtures.draft("First"), b = Fixtures.draft("Second")
        try await store.saveDraft(a); try await store.saveDraft(b)
        let first = try await outbox.enqueue(a, undoWindow: 0.4)
        let second = try await outbox.enqueue(b, undoWindow: 0.4)
        #expect(first.deadline <= second.deadline)
        let restored = try await outbox.undo(second.id)
        #expect(restored?.subject == "Second")
        #expect(await waitUntil { await state(first.id) == .sent })
        try await Task.sleep(for: .milliseconds(300))
        #expect(provider.sentCount == 1)
        #expect(MIMEPreview.parse(provider.sentRaw[0]).subject == "First")
    }

    @Test func undoLosesToSubmissionThatAlreadyStarted() async throws {
        let draft = Fixtures.draft()
        try await store.saveDraft(draft)
        let item = try await outbox.enqueue(draft, undoWindow: 0.05)
        #expect(await waitUntil { await state(item.id) == .sent })
        #expect(try await outbox.undo(item.id) == nil)
        #expect(provider.sentCount == 1)
    }

    @Test func offlineAtExpiryQueuesThenSendsOnce() async throws {
        provider.queueSends(.offline, .succeed)
        let draft = Fixtures.draft()
        try await store.saveDraft(draft)
        let item = try await outbox.enqueue(draft, undoWindow: 0.05)
        #expect(await waitUntil { await state(item.id) == .queued })
        #expect(await waitUntil { await state(item.id) == .sent })
        #expect(provider.sentCount == 1)
    }

    @Test func queuedMessageCanStillBeCancelled() async throws {
        provider.queueSends(.offline, .offline, .offline, .offline)
        await outbox.setDelays(reconcile: 0.05, retry: 5)
        let draft = Fixtures.draft()
        try await store.saveDraft(draft)
        let item = try await outbox.enqueue(draft, undoWindow: 0.05)
        #expect(await waitUntil { await state(item.id) == .queued })
        #expect(try await outbox.undo(item.id)?.subject == draft.subject)
        #expect(provider.sentCount == 0)
    }

    @Test func ambiguousOutcomeIsReconciledWithoutResending() async throws {
        provider.acceptEvenWhenIndeterminate = true
        provider.queueSends(.indeterminate)
        let draft = Fixtures.draft()
        try await store.saveDraft(draft)
        let item = try await outbox.enqueue(draft, undoWindow: 0.05)
        #expect(await waitUntil { await state(item.id) == .sent })
        #expect(provider.sentCount == 1)
    }

    @Test func ambiguousOutcomeNotFoundIsRetriedOnce() async throws {
        provider.queueSends(.indeterminate, .succeed)
        let draft = Fixtures.draft()
        try await store.saveDraft(draft)
        let item = try await outbox.enqueue(draft, undoWindow: 0.05)
        #expect(await waitUntil { await state(item.id) == .sent })
        #expect(provider.sentCount == 1)
    }

    @Test func authenticationFailureKeepsMessageAndExplains() async throws {
        provider.queueSends(.unauthorized)
        let draft = Fixtures.draft()
        try await store.saveDraft(draft)
        let item = try await outbox.enqueue(draft, undoWindow: 0.05)
        #expect(await waitUntil { await state(item.id) == .failed })
        let failed = try await store.outboxItem(item.id)
        #expect(failed?.failure == .authentication)
        #expect(failed?.snapshot.subject == draft.subject)
        // After reconnecting, Try Again sends it.
        try await outbox.retry(item.id)
        #expect(await waitUntil { await state(item.id) == .sent })
        #expect(provider.sentCount == 1)
    }

    @Test func failedSendCanReturnToDrafts() async throws {
        provider.queueSends(.rejected)
        let draft = Fixtures.draft()
        try await store.saveDraft(draft)
        let item = try await outbox.enqueue(draft, undoWindow: 0.05)
        #expect(await waitUntil { await state(item.id) == .failed })
        let restored = try await outbox.returnToDrafts(item.id)
        #expect(restored?.state == .editing)
        #expect(try await store.outboxItem(item.id) == nil)
    }

    @Test func relaunchResumesPendingAndReconcilesInterruptedSubmission() async throws {
        // Simulate a crash: one item still in its window, one stuck mid-submission whose send actually landed.
        let pendingDraft = Fixtures.draft("Pending"), stuckDraft = Fixtures.draft("Stuck")
        try await store.saveDraft(pendingDraft); try await store.saveDraft(stuckDraft)
        let pending = OutboxItem(accountID: Fixtures.account.id, draftID: pendingDraft.id, state: .pending, deadline: .now.addingTimeInterval(0.1),
                                 snapshot: pendingDraft, messageIDHeader: "<p@example.com>")
        let stuck = OutboxItem(accountID: Fixtures.account.id, draftID: stuckDraft.id, state: .submitting, deadline: .now.addingTimeInterval(-5),
                               snapshot: stuckDraft, messageIDHeader: "<s@example.com>")
        try await store.insertOutbox(pending, lockingDraft: pendingDraft)
        try await store.insertOutbox(stuck, lockingDraft: stuckDraft)
        provider.acceptEvenWhenIndeterminate = true
        provider.queueSends(.indeterminate) // records <s@…> as accepted without the app knowing
        _ = try? await provider.send(raw: MIMEBuilder.build(.init(from: Fixtures.account.fromAddress, to: stuckDraft.to, cc: [], bcc: [],
                                                                     subject: "Stuck", plain: "", html: "", messageID: "<s@example.com>",
                                                                     date: .now, attachments: [])), threadID: nil)
        let before = provider.sentCount

        let fresh = Outbox(store: store, lookup: { [provider] _ in (provider, Fixtures.account) })
        await fresh.setDelays(reconcile: 0.05, retry: 0.1)
        await fresh.resume()
        #expect(await waitUntil { await state(stuck.id) == .sent })
        #expect(await waitUntil { await state(pending.id) == .sent })
        #expect(provider.sentCount == before + 1) // only the pending one was submitted
    }

    @Test func neverFallsBackToAnotherAccount() async throws {
        let draft = Fixtures.draft(account: Fixtures.work) // lookup only knows acct-1
        try await store.saveDraft(draft)
        await #expect(throws: Outbox.EnqueueError.self) { try await outbox.enqueue(draft, undoWindow: 0.05) }
        #expect(provider.sentCount == 0)
    }

    @Test func rejectsInvalidRecipientsBeforeQueueing() async throws {
        var draft = Fixtures.draft()
        draft.to = [EmailAddress(name: nil, address: "not an address")]
        await #expect(throws: Outbox.EnqueueError.self) { try await outbox.enqueue(draft, undoWindow: 0.05) }
    }
}
