import SwiftUI

struct DraftsListView: View {
    @Environment(AppModel.self) private var model
    @State private var drafts: [Draft] = []

    var body: some View {
        List {
            ForEach(drafts) { d in
                Button { Task { await model.editDraft(d.id) } } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(d.allRecipients.isEmpty ? "No recipients" : d.allRecipients.map { $0.name ?? $0.address }.joined(separator: ", "))
                                .font(.headline).foregroundStyle(Color.slate.inkPrimary).lineLimit(1)
                            Spacer()
                            Text(DateGrouping.rowTime(d.updatedAt)).font(.footnote).foregroundStyle(Color.slate.inkMetadata)
                        }
                        Text(d.subject.isEmpty ? "(No subject)" : d.subject).font(.callout.weight(.medium)).foregroundStyle(Color.slate.inkPrimary)
                        Text(d.bodyText.trimmingCharacters(in: .whitespacesAndNewlines)).font(.subheadline)
                            .foregroundStyle(Color.slate.inkSecondary).lineLimit(2)
                        HStack {
                            Text(d.remoteDraftID != nil && d.syncedRevision >= d.localRevision ? "Saved to Gmail" : "Saved on this iPhone")
                                .font(.caption).foregroundStyle(Color.slate.inkMetadata)
                            Spacer()
                            if model.hasMultipleAccounts, let a = model.account(d.accountID) { AccountTag(account: a) }
                        }
                    }
                    .padding(.vertical, Spacing.xxs)
                }
                .swipeActions {
                    Button("Delete", role: .destructive) { Task { await model.discardDraft(d.id) } }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if drafts.isEmpty {
                EmptyStateView(title: "No drafts", message: "Drafts are saved on this iPhone as you type and synced to Gmail.", symbol: "doc")
            }
        }
        .task(id: model.dataVersion) { drafts = (try? await model.store.drafts(accountIDs: model.scopeAccountIDs)) ?? [] }
    }
}

struct OutboxListView: View {
    @Environment(AppModel.self) private var model

    private var items: [OutboxItem] {
        model.outboxItems.filter { $0.state != .sent && $0.state != .cancelled && model.scopeAccountIDs.contains($0.accountID) }.reversed()
    }

    var body: some View {
        List {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    HStack {
                        Text(item.snapshot.subject.isEmpty ? "(No subject)" : item.snapshot.subject).font(.headline).lineLimit(1)
                        Spacer()
                        statusLabel(item)
                    }
                    Text("To " + item.snapshot.allRecipients.map { $0.name ?? $0.address }.joined(separator: ", "))
                        .font(.subheadline).foregroundStyle(Color.slate.inkSecondary).lineLimit(1)
                    if let failure = item.failure {
                        Text(failure.message).font(.footnote).foregroundStyle(Color.slate.destructive)
                    } else if let detail = item.lastError, item.state == .queued || item.state == .ambiguous {
                        Text(detail).font(.footnote).foregroundStyle(Color.slate.inkSecondary)
                    }
                    if item.state == .ambiguous {
                        Text("Checking with Gmail whether this was sent before trying again.").font(.footnote).foregroundStyle(Color.slate.inkSecondary)
                    }
                    HStack(spacing: Spacing.md) {
                        if item.state.isCancellable {
                            Button("Cancel Send") { Task { await model.undoSend(item) } }
                        }
                        if item.state == .failed {
                            if item.failure != .missingAttachment && item.failure != .tooLarge && item.failure != .accountRemoved {
                                Button("Try Again") { Task { await model.retry(item) } }
                            }
                            Button("Edit") { Task { await model.editFailed(item) } }
                        }
                        if item.failure == .authentication { Button("Reconnect") { model.showSettings = true } }
                    }
                    .font(.subheadline.weight(.medium))
                    .buttonStyle(.borderless)
                    .padding(.top, 2)
                }
                .padding(.vertical, Spacing.xxs)
            }
        }
        .listStyle(.plain)
        .overlay {
            if items.isEmpty {
                EmptyStateView(title: "Outbox is empty", message: "Messages waiting to send appear here, including ones queued while offline.", symbol: "tray.and.arrow.up")
            }
        }
    }

    @ViewBuilder private func statusLabel(_ item: OutboxItem) -> some View {
        let (text, color): (String, Color) = switch item.state {
        case .pending: ("Pending", Color.slate.inkSecondary)
        case .queued: ("Waiting", Color.slate.inkSecondary)
        case .submitting: ("Sending", Color.slate.inkPrimary)
        case .ambiguous: ("Checking", Color.slate.warning)
        case .failed: ("Failed", Color.slate.destructive)
        case .sent: ("Sent", Color.slate.positive)
        case .cancelled: ("Cancelled", Color.slate.inkMetadata)
        }
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(color)
    }
}
