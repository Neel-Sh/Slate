import SwiftUI

struct ConversationView: View {
    @Environment(AppModel.self) private var model
    @State private var convo: ConversationModel
    @State private var showLater = false
    @State private var showLabels = false
    @State private var showAllPoints = false

    init(ref: ThreadRef) { _convo = State(initialValue: ConversationModel(ref: ref)) }

    private var account: Account? { model.account(convo.ref.accountID) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    header
                    if convo.missing {
                        EmptyStateView(title: "Conversation unavailable", message: "It may have been deleted or moved in Gmail.", symbol: "questionmark.folder")
                            .padding(.top, Spacing.xxl)
                    }
                    if let error = convo.loadError {
                        Label(error, systemImage: "wifi.exclamationmark")
                            .font(.footnote).foregroundStyle(Color.slate.inkSecondary)
                            .padding(.horizontal, Spacing.md).padding(.bottom, Spacing.sm)
                    }
                    summarySection(proxy)
                    ForEach(convo.messages) { m in
                        MessageView(message: m, account: account, isExpanded: convo.expanded.contains(m.id),
                                    isLatest: m.id == convo.latest?.id, inlineImages: convo.inlineImages[m.id] ?? [:]) {
                            withAnimation(.snappy) {
                                if convo.expanded.contains(m.id) { convo.expanded.remove(m.id) } else { convo.expanded.insert(m.id) }
                            }
                        }
                        .id(m.id)
                        Divider().overlay(Color.slate.separator).padding(.leading, Spacing.md)
                    }
                    if convo.isLoadingBody && convo.messages.isEmpty {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, Spacing.xxl)
                    }
                    suggestedReply
                    Color.clear.frame(height: 80)
                }
            }
            .background(Color.slate.canvas)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .task(id: model.dataVersion) { await convo.load(model) }
        .sheet(isPresented: $showLater) { LaterPicker(refs: [convo.ref]) {} }
        .sheet(isPresented: $showLabels) { LabelPicker(refs: [convo.ref]) {} }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(convo.thread?.subject.isEmpty == false ? convo.thread!.subject : (convo.messages.first?.subject ?? ""))
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.slate.inkPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
            let userLabels = (convo.thread?.labelIDs ?? []).compactMap { id in
                model.labels.first { $0.accountID == convo.ref.accountID && $0.labelID == id && $0.kind == .user }
            }
            let later = convo.thread?.laterUntil.flatMap { $0 > .now ? $0 : nil }
            let showsAccount = model.hasMultipleAccounts && account != nil
            if !userLabels.isEmpty || convo.thread?.inSpam == true || convo.thread?.inTrash == true || later != nil || showsAccount {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { metadata(userLabels, later: later, showsAccount: showsAccount) }
                    VStack(alignment: .leading, spacing: 6) { metadata(userLabels, later: later, showsAccount: showsAccount) }
                }
            }
            if convo.thread?.inSpam == true {
                Text("This conversation is in Spam. Links and images are blocked. Choose Not Spam to move it to your Inbox.")
                    .font(.footnote).foregroundStyle(Color.slate.inkSecondary)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.top, Spacing.xs)
        .padding(.bottom, Spacing.lg)
    }

    @ViewBuilder private func metadata(_ userLabels: [MailLabel], later: Date?, showsAccount: Bool) -> some View {
        if showsAccount, let account { AccountTag(account: account) }
        ForEach(userLabels) { LabelChip(text: $0.leafName, tone: ChipTone.forLabel($0.colorHex, name: $0.name)) }
        if convo.thread?.inSpam == true { LabelChip(text: "Spam", tone: .amber) }
        if convo.thread?.inTrash == true { LabelChip(text: "Trash", tone: .stone) }
        if let later {
            Label("Later · \(later.formatted(.dateTime.weekday().hour().minute()))", systemImage: "clock")
                .font(.caption.weight(.medium)).foregroundStyle(Color.slate.inkSecondary)
        }
    }

    // MARK: Summary

    @ViewBuilder private func summarySection(_ proxy: ScrollViewProxy) -> some View {
        if model.intelligence.isAvailable && convo.isLongEnoughToSummarize && convo.thread?.isMailingList != true
            && !Self.isAutomated(convo.latest?.from) {
            Group {
                switch convo.summary {
                case .idle:
                    Button { Task { await convo.summarize(model) } } label: {
                        HStack(spacing: 6) {
                            AuraRing()
                            Text("Summarize")
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.slate.inkPrimary)
                        .padding(.horizontal, Spacing.sm)
                        .frame(minHeight: 34)
                        .background(Color.slate.surfaceSecondary, in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: Spacing.minHit)
                    .accessibilityLabel("Summarize Conversation")
                case .loading:
                    HStack(spacing: Spacing.xs) {
                        ProgressView().controlSize(.small)
                        Text("Summarizing…").font(.subheadline).foregroundStyle(Color.slate.inkSecondary)
                    }
                    .frame(minHeight: Spacing.minHit)
                case .failed(let message):
                    HStack {
                        Text(message).font(.footnote).foregroundStyle(Color.slate.inkSecondary)
                        Spacer()
                        Button("Try Again") { Task { await convo.summarize(model) } }.font(.footnote.weight(.semibold))
                    }
                    .padding(Spacing.sm).panel()
                case .ready(let digest):
                    let points = showAllPoints ? digest.points : Array(digest.points.prefix(3))
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        HStack {
                            GeneratedBadge(title: "Summary")
                            Spacer()
                            Button { convo.summary = .idle; showAllPoints = false } label: {
                                Image(systemName: "xmark").font(.caption.weight(.semibold)).foregroundStyle(Color.slate.inkMetadata)
                            }
                            .frame(width: Spacing.minHit, height: 28)
                            .accessibilityLabel("Dismiss summary")
                        }
                        ForEach(points) { p in
                            Button {
                                if let id = p.messageID {
                                    convo.expanded.insert(id)
                                    withAnimation { proxy.scrollTo(id, anchor: .top) }
                                }
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                                    Circle().fill(Color.slate.inkMetadata).frame(width: 4, height: 4)
                                        .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 4 }
                                    Text(p.text)
                                        .font(.subheadline)
                                        .foregroundStyle(Color.slate.inkPrimary)
                                        .lineSpacing(2)
                                        .multilineTextAlignment(.leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(p.messageID == nil)
                            .accessibilityHint(p.messageID != nil ? "Shows the message this comes from." : "")
                        }
                        if digest.points.count > points.count {
                            Button("Show \(digest.points.count - points.count) More") { withAnimation(Motion.standard) { showAllPoints = true } }
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(Color.slate.inkSecondary)
                        }
                        Text("Made on this iPhone and may be wrong. Tap a point to see its message.")
                            .font(.caption).foregroundStyle(Color.slate.inkMetadata)
                            .padding(.top, Spacing.xxs)
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.top, Spacing.xs)
                    .padding(.bottom, Spacing.md)
                    .panel()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.md)
            .padding(.bottom, Spacing.sm)
        }
    }

    // MARK: Suggested reply

    @ViewBuilder private var suggestedReply: some View {
        if let last = convo.latest, let account, !model.identities.contains(last.from?.normalized ?? ""),
           convo.thread?.inSpam != true, convo.thread?.isMailingList != true, !Self.isAutomated(last.from),
           !convo.suggestionsDismissed, model.intelligence.isAvailable {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    GeneratedBadge(title: "Suggested reply")
                    Spacer()
                    Button("Discard") { withAnimation { convo.suggestionsDismissed = true } }
                        .font(.subheadline)
                        .frame(minHeight: Spacing.minHit)
                }
                .padding(.horizontal, Spacing.sm)

                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        Text("To:").font(.subheadline).foregroundStyle(Color.slate.inkMetadata)
                        Text(last.from?.displayName ?? "").font(.subheadline.weight(.medium)).foregroundStyle(Color.slate.accent)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.slate.selectionFill, in: Capsule())
                        Spacer()
                        if model.hasMultipleAccounts { Text("From \(account.shortLabel)").font(.caption).foregroundStyle(Color.slate.inkMetadata) }
                    }
                    .padding(Spacing.sm)
                    Divider().overlay(Color.slate.separator)
                    intentionList(last)
                }
                .background(Color.slate.surfaceElevated, in: RoundedRectangle(cornerRadius: Spacing.panelRadius - 2, style: .continuous))
            }
            .padding(Spacing.xxs)
            .panel()
            .padding(.horizontal, Spacing.md)
            .padding(.top, Spacing.lg)
        }
    }

    /// Replies to no-reply and notification senders go nowhere useful, so no suggestions are offered.
    static func isAutomated(_ from: EmailAddress?) -> Bool {
        let local = from?.address.split(separator: "@").first?.lowercased() ?? ""
        return ["noreply", "no-reply", "donotreply", "do-not-reply", "notifications", "mailer-daemon"].contains { local.contains($0) }
    }

    @ViewBuilder private func intentionList(_ last: MailMessage) -> some View {
        switch convo.intentions {
        case .idle:
            Button { Task { await convo.suggest(model) } } label: {
                Label("Suggest Ways to Reply", systemImage: "text.bubble")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity, minHeight: Spacing.minHit, alignment: .leading)
                    .padding(.horizontal, Spacing.sm)
            }
        case .loading:
            HStack(spacing: Spacing.sm) {
                ProgressView().controlSize(.small)
                Text("Reading the conversation on this iPhone…").font(.subheadline).foregroundStyle(Color.slate.inkSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: Spacing.minHit, alignment: .leading)
            .padding(.horizontal, Spacing.sm)
        case .failed(let message):
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(message).font(.footnote).foregroundStyle(Color.slate.inkSecondary)
                Button("Reply Without Suggestions") { Task { await model.reply(.reply, to: last) } }.font(.subheadline.weight(.medium))
            }
            .padding(Spacing.sm)
        case .ready(let options):
            VStack(spacing: 0) {
                ForEach(Array(options.enumerated()), id: \.element.id) { i, o in
                    IntentionRow(number: i + 1, intention: o, isWorking: convo.draftingIntention == o.id) {
                        Task { await convo.draft(o, app: model) }
                    }
                    .disabled(convo.draftingIntention != nil)
                }
                IntentionRow(number: options.count + 1, intention: ReplyIntention(label: "Write my own", detail: ""), isWorking: false) {
                    Task { await model.reply(.reply, to: last) }
                }
            }
            .padding(.vertical, Spacing.xxs)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        let refs = [convo.ref]
        ToolbarItemGroup(placement: .bottomBar) {
            if convo.thread?.inTrash == true {
                Button { Task { await model.perform(.restore, on: refs) } } label: { Label("Move to Inbox", systemImage: "tray.and.arrow.down") }
            } else if convo.thread?.inSpam == true {
                Button { Task { await model.perform(.notSpam, on: refs) } } label: { Label("Not Spam", systemImage: "tray.and.arrow.down") }
            } else if convo.thread?.inInbox == true {
                Button { Task { await model.perform(.archive, on: refs) } } label: { Label("Archive", systemImage: "archivebox") }
            } else {
                Button { Task { await model.perform(.moveToInbox, on: refs) } } label: { Label("Move to Inbox", systemImage: "tray.and.arrow.down") }
            }
            Button { showLater = true } label: { Label("Later", systemImage: "clock") }
            Button { showLabels = true } label: { Label("Labels", systemImage: "tag") }
            Spacer()
            if let last = convo.latest {
                Menu {
                    Button("Reply", systemImage: "arrowshape.turn.up.left") { Task { await model.reply(.reply, to: last) } }
                    if (last.to.count + last.cc.count) > 1 {
                        Button("Reply All", systemImage: "arrowshape.turn.up.left.2") { Task { await model.reply(.replyAll, to: last) } }
                    }
                    Button("Forward", systemImage: "arrowshape.turn.up.right") { Task { await model.reply(.forward, to: last) } }
                } label: {
                    Label("Reply", systemImage: "arrowshape.turn.up.left")
                } primaryAction: {
                    Task { await model.reply(.reply, to: last) }
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if let t = convo.thread {
                    ThreadMenu(threads: [t], onLater: { showLater = true }, onLabel: { showLabels = true }, onWhyFocused: nil)
                }
            } label: { Label("More", systemImage: "ellipsis") }
        }
    }
}

private struct IntentionRow: View {
    var number: Int
    var intention: ReplyIntention
    var isWorking: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.sm) {
                Text("\(number)")
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(Color.slate.inkSecondary)
                    .frame(width: 28, height: 28)
                    .background(Color.slate.surfaceSecondary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(intention.label).font(.body).foregroundStyle(Color.slate.inkPrimary)
                    if !intention.detail.isEmpty {
                        Text(intention.detail).font(.footnote).foregroundStyle(Color.slate.inkSecondary).lineLimit(2)
                    }
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if isWorking { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .frame(minHeight: Spacing.minHit + 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(IntentionButtonStyle())
        .accessibilityLabel("Option \(number): \(intention.label)")
        .accessibilityHint("Creates an editable draft. Nothing is sent.")
    }
}

private struct IntentionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.slate.selectionFill : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
