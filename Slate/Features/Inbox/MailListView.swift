import SwiftUI

struct MailListView: View {
    @Environment(AppModel.self) private var model
    @State private var searchText = ""
    @State private var searchPresented = false
    @State private var searchScope: SearchScope = .allAccounts

    var body: some View {
        MailListContent(searchText: $searchText, searchScope: $searchScope)
            .searchable(text: $searchText, isPresented: $searchPresented, placement: .toolbar, prompt: "Search Mail")
            .searchScopes($searchScope, activation: .onSearchPresentation) {
                Text(model.hasMultipleAccounts && model.scopeAccountID == nil ? "All Accounts" : model.scopeTitle).tag(SearchScope.allAccounts)
                if model.mailbox != .inbox && model.mailbox.providerLabelID != nil {
                    Text(model.mailbox.title).tag(SearchScope.currentMailbox)
                }
            }
    }
}

enum SearchScope: Hashable { case allAccounts, currentMailbox }

private struct MailListContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isSearching) private var isSearching
    @Binding var searchText: String
    @Binding var searchScope: SearchScope

    @State private var list = ThreadListModel()
    @State private var selection = Set<ThreadRef>()
    @State private var editMode: EditMode = .inactive
    @State private var laterTargets: [ThreadRef]?
    @State private var labelTargets: [ThreadRef]?
    @State private var focusInfo: ThreadSummary?
    @State private var filters: Set<MailFilter> = []

    private var mailbox: Mailbox { model.mailbox }
    private var isInbox: Bool { mailbox == .inbox }
    /// Inbox and label views share one row of tabs so moving between them stays in place.
    private var showsTabs: Bool {
        if case .label = mailbox { return true }
        return isInbox
    }
    private var showsFocused: Bool { isInbox && model.prefs.showFocused }

    private var visibleThreads: [ThreadSummary] {
        list.threads.filter { t in
            (!showsFocused || model.focus.reason(for: t) != nil) && filters.allSatisfy { $0.matches(t) }
        }
    }

    /// The subtitle always says what is being shown, so an active filter is never hidden.
    private var subtitle: String {
        let names = MailFilter.allCases.filter(filters.contains).map(\.title)
        return names.isEmpty ? model.scopeTitle : (names + [model.scopeTitle]).filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        Group {
            if isSearching {
                SearchView(text: $searchText, scope: searchScope)
            } else if mailbox == .drafts {
                DraftsListView()
            } else if mailbox == .outbox {
                OutboxListView()
            } else {
                threadList
            }
        }
        .navigationTitle(mailbox.title)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .environment(\.editMode, $editMode)
        .task(id: "\(mailbox.id)|\(model.scopeAccountIDs)|\(model.dataVersion)") {
            await list.reload(model, mailbox: mailbox)
            selection = selection.intersection(Set(list.threads.map(\.ref)))
        }
        .onChange(of: mailbox) { editMode = .inactive; selection = [] }
        .onChange(of: selection) { _, new in
            // Outside Select mode a tap selects the row's value; treat it as opening the conversation.
            guard !editMode.isEditing, let ref = new.first else { return }
            selection = []
            model.path.append(ref)
        }
        .sheet(item: Binding(get: { laterTargets.map(RefList.init) }, set: { laterTargets = $0?.refs })) { targets in
            LaterPicker(refs: targets.refs) { editMode = .inactive; selection = [] }
        }
        .sheet(item: Binding(get: { labelTargets.map(RefList.init) }, set: { labelTargets = $0?.refs })) { targets in
            LabelPicker(refs: targets.refs) { editMode = .inactive; selection = [] }
        }
        .sheet(item: $focusInfo) { t in FocusExplanation(thread: t) }
    }

    // MARK: List

    @ViewBuilder private var threadList: some View {
        let groups = Dictionary(grouping: visibleThreads) { mailbox == .later ? DateGrouping.Group.today : DateGrouping.group($0.lastDate) }
        List(selection: $selection) {
            if showsTabs {
                InboxTabs()
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.slate.canvas)
                    .listRowInsets(EdgeInsets())
                    .selectionDisabled()
            }
            accountProblems
            if mailbox == .later && !visibleThreads.isEmpty {
                Text("Later is kept on this iPhone. These conversations stay in your Gmail inbox elsewhere and return here at the time you chose.")
                    .font(.footnote).foregroundStyle(Color.slate.inkSecondary)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.slate.canvas)
                    .selectionDisabled()
            }
            ForEach(groups.keys.sorted(), id: \.self) { group in
                Section {
                    ForEach(groups[group] ?? []) { t in row(t) }
                } header: {
                    if mailbox != .later {
                        Text(group.title)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(Color.slate.inkMetadata)
                            .listRowInsets(EdgeInsets(top: Spacing.lg, leading: Spacing.md + 2, bottom: Spacing.xxs, trailing: Spacing.md))
                    }
                }
            }
            if !list.reachedEnd && list.loadedOnce && !visibleThreads.isEmpty && mailbox != .later {
                // A small spinner on the canvas, so paging never draws a band across the list.
                ProgressView()
                    .controlSize(.small)
                    .tint(Color.slate.inkMetadata)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.lg)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.slate.canvas)
                    .listRowSeparator(.hidden)
                    .accessibilityLabel("Loading more conversations")
                    .task(id: filters.isEmpty ? 0 : list.threads.count) { await list.loadMore(model, mailbox: mailbox) }
                    .selectionDisabled()
            }
        }
        .listStyle(.plain)
        .listSectionSpacing(0)
        .environment(\.defaultMinListHeaderHeight, 24)
        .scrollContentBackground(.hidden)
        .background(Color.slate.canvas)
        .refreshable { await model.refreshAll() }
        .overlay {
            if list.loadedOnce && visibleThreads.isEmpty { emptyState }
        }
    }

    private func row(_ t: ThreadSummary) -> some View {
        let account = model.account(t.ref.accountID)
        let chips = t.labelIDs.compactMap { id in model.labels.first { $0.accountID == t.ref.accountID && $0.labelID == id && $0.kind == .user } }
            .filter { if case .label(_, let current, _) = mailbox { return $0.labelID != current }; return true }
            .sorted { $0.name < $1.name }
        return NavigationLink(value: t.ref) {
            ThreadRow(thread: t, account: account, showAccount: model.hasMultipleAccounts && model.scopeAccountID == nil,
                      chips: chips, identities: model.identities)
        }
        .navigationLinkIndicatorVisibility(.hidden)
        .listRowInsets(EdgeInsets(top: 0, leading: Spacing.sm, bottom: 0, trailing: Spacing.md))
        .listRowSeparatorTint(Color.slate.separator)
        .listRowBackground(Color.slate.canvas)
        .swipeActions(edge: .leading, allowsFullSwipe: true) { swipe(model.prefs.leadingSwipe, t) }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            swipe(model.prefs.trailingSwipe, t)
            swipe(model.prefs.trailingSwipeSecondary, t)
        }
        .contextMenu { ThreadMenu(threads: [t], onLater: { laterTargets = [t.ref] }, onLabel: { labelTargets = [t.ref] }, onWhyFocused: isInbox ? { focusInfo = t } : nil) }
        .accessibilityActions {
            Button(t.isUnread ? "Mark as Read" : "Mark as Unread") { act(t.isUnread ? .markRead : .markUnread, [t.ref], toast: false) }
            if mailbox == .inbox { Button("Archive") { act(.archive, [t.ref]) } }
            Button("Later") { laterTargets = [t.ref] }
            Button(t.inTrash ? "Move to Inbox" : "Move to Trash") { act(t.inTrash ? .restore : .trash, [t.ref]) }
        }
    }

    @ViewBuilder private func swipe(_ action: SwipeAction, _ t: ThreadSummary) -> some View {
        switch action {
        case .none: EmptyView()
        case .toggleRead:
            Button { act(t.isUnread ? .markRead : .markUnread, [t.ref], toast: false) } label: {
                Label(t.isUnread ? "Read" : "Unread", systemImage: t.isUnread ? "envelope.open" : "envelope.badge")
            }.tint(Color(white: 0.42))
        case .archive:
            if t.inInbox {
                Button { act(.archive, [t.ref]) } label: { Label("Archive", systemImage: "archivebox") }.tint(Color(red: 0.24, green: 0.39, blue: 0.29))
            } else if t.inTrash || t.inSpam {
                Button { act(t.inTrash ? .restore : .notSpam, [t.ref]) } label: { Label("Inbox", systemImage: "tray.and.arrow.down") }.tint(Color.slate.positive)
            }
        case .later:
            Button { laterTargets = [t.ref] } label: { Label("Later", systemImage: "clock") }.tint(Color(red: 0.80, green: 0.45, blue: 0.16))
        case .trash:
            if !t.inTrash {
                Button(role: .destructive) { act(.trash, [t.ref]) } label: { Label("Trash", systemImage: "trash") }
            }
        case .star:
            Button { act(t.isStarred ? .unstar : .star, [t.ref], toast: false) } label: {
                Label(t.isStarred ? "Unstar" : "Star", systemImage: t.isStarred ? "star.slash" : "star")
            }.tint(Color.slate.warning)
        }
    }

    private func act(_ action: ThreadAction, _ refs: [ThreadRef], toast: Bool = true) {
        Task { await model.perform(action, on: refs, toast: toast) }
    }

    @ViewBuilder private var accountProblems: some View {
        ForEach(model.accounts.filter { $0.status != .connected && model.scopeAccountIDs.contains($0.id) }) { a in
            Button { model.showSettings = true } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.status == .needsReconnect ? "Reconnect \(a.email)" : "\(a.shortLabel) isn't syncing")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Color.slate.inkPrimary)
                        Text(a.statusMessage ?? "Other accounts are unaffected.")
                            .font(.footnote).foregroundStyle(Color.slate.inkSecondary)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(Color.slate.warning)
                }
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.slate.canvas)
            .selectionDisabled()
        }
        if !model.isOnline {
            Label("You're offline. Downloaded messages are available.", systemImage: "wifi.slash")
                .font(.footnote).foregroundStyle(Color.slate.inkSecondary)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.slate.canvas)
                .selectionDisabled()
        }
    }

    @ViewBuilder private var emptyState: some View {
        if !filters.isEmpty && !list.threads.isEmpty {
            EmptyStateView(title: "No matching conversations", message: "Nothing here matches \(MailFilter.allCases.filter(filters.contains).map(\.title).joined(separator: " and ")).",
                           symbol: "line.3.horizontal.decrease", actionTitle: "Clear Filters") { withAnimation(Motion.standard) { filters = [] } }
        } else if model.accounts.isEmpty {
            EmptyStateView(title: "No accounts", message: "Add a Gmail account to get started.", symbol: "person.crop.circle.badge.plus",
                           actionTitle: "Add Account") { model.showSettings = true }
        } else if showsFocused && !list.threads.isEmpty {
            EmptyStateView(title: "Nothing in Focused", message: nil, symbol: "checkmark.circle", actionTitle: "View All Mail") {
                model.prefs.showFocused = false
            }
        } else {
            let message: String? = switch mailbox {
            case .later: "Swipe a conversation and choose Later to bring it back when you need it."
            case .spam: "Gmail deletes messages in Spam after 30 days."
            case .trash: "Gmail deletes messages in Trash after 30 days."
            default: model.syncing.isEmpty ? nil : "Checking for mail…"
            }
            EmptyStateView(title: mailbox == .inbox ? "No new mail" : "No conversations", message: message, symbol: mailbox.symbol)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if editMode.isEditing {
            ToolbarItem(placement: .topBarLeading) {
                Button(selection.count == visibleThreads.count && !selection.isEmpty ? "Deselect All" : "Select All Visible") {
                    selection = selection.count == visibleThreads.count ? [] : Set(visibleThreads.map(\.ref))
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { withAnimation { editMode = .inactive; selection = [] } }.fontWeight(.semibold)
            }
            ToolbarItemGroup(placement: .bottomBar) { bulkBar }
        } else {
            ToolbarItem(placement: .topBarLeading) {
                Button { model.showMailboxes = true } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").fontWeight(.semibold)
                        Text("Mailboxes")
                    }
                }
                .accessibilityLabel("Mailboxes")
            }
            if mailbox.isThreadList {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Select") { withAnimation { editMode = .active } }
                }
            }
            if mailbox.isThreadList || model.hasMultipleAccounts {
                ToolbarItem(placement: .bottomBar) {
                    FilterMenu(filters: $filters, showsMailFilters: mailbox.isThreadList)
                }
                ToolbarSpacer(.fixed, placement: .bottomBar)
            }
            DefaultToolbarItem(kind: .search, placement: .bottomBar)
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button { model.compose() } label: { Label("Compose", systemImage: "square.and.pencil") }
                    .disabled(model.accounts.isEmpty)
            }
        }
    }

    @ViewBuilder private var bulkBar: some View {
        let refs = Array(selection)
        let selected = list.threads.filter { selection.contains($0.ref) }
        if mailbox == .trash {
            Button("Move to Inbox") { act(.restore, refs); finishBulk() }.disabled(refs.isEmpty)
        } else if mailbox == .spam {
            Button("Not Spam") { act(.notSpam, refs); finishBulk() }.disabled(refs.isEmpty)
        } else {
            Button { act(.archive, refs); finishBulk() } label: { Label("Archive", systemImage: "archivebox") }
                .disabled(refs.isEmpty || !selected.contains(where: \.inInbox))
        }
        Spacer()
        Text(refs.isEmpty ? "Select Conversations" : "\(refs.count) Selected")
            .font(.footnote.weight(.medium))
            .monospacedDigit()
        Spacer()
        Menu {
            ThreadMenu(threads: selected, onLater: { laterTargets = refs }, onLabel: { labelTargets = refs }, onWhyFocused: nil, bulk: true) {
                finishBulk()
            }
        } label: { Label("More", systemImage: "ellipsis") }
            .disabled(refs.isEmpty)
        if mailbox != .trash {
            Button(role: .destructive) { act(.trash, refs); finishBulk() } label: { Label("Trash", systemImage: "trash") }
                .disabled(refs.isEmpty)
        }
    }

    private func finishBulk() {
        withAnimation { editMode = .inactive; selection = [] }
    }
}

struct RefList: Identifiable {
    var refs: [ThreadRef]
    var id: String { refs.map { $0.accountID + $0.threadID }.joined() }
}

/// Quick filters on the loaded list. They narrow what is shown and never change mail.
enum MailFilter: String, CaseIterable, Identifiable {
    case unread, starred, attachments
    var id: String { rawValue }
    var title: String {
        switch self {
        case .unread: "Unread"
        case .starred: "Starred"
        case .attachments: "Attachments"
        }
    }
    var symbol: String {
        switch self {
        case .unread: "envelope.badge"
        case .starred: "star"
        case .attachments: "paperclip"
        }
    }
    func matches(_ t: ThreadSummary) -> Bool {
        switch self {
        case .unread: t.isUnread
        case .starred: t.isStarred
        case .attachments: t.hasAttachment
        }
    }
}

/// One place to choose what the list shows: quick filters and, with several accounts, which account.
struct FilterMenu: View {
    @Environment(AppModel.self) private var model
    @Binding var filters: Set<MailFilter>
    var showsMailFilters: Bool

    private var isActive: Bool { !filters.isEmpty || model.scopeAccountID != nil }

    var body: some View {
        Menu {
            if showsMailFilters {
                Section("Show Only") {
                    ForEach(MailFilter.allCases) { f in
                        Toggle(f.title, systemImage: f.symbol, isOn: Binding(
                            get: { filters.contains(f) },
                            set: { on in withAnimation(Motion.standard) { if on { filters.insert(f) } else { filters.remove(f) } } }))
                    }
                }
            }
            if model.hasMultipleAccounts {
                Section("Account") {
                    Picker("Account", selection: Binding(get: { model.scopeAccountID }, set: { model.scopeAccountID = $0 })) {
                        Text("All Accounts").tag(String?.none)
                        ForEach(model.accounts) { a in
                            Text(a.shortLabel).tag(Optional(a.id))
                        }
                    }
                    .pickerStyle(.inline)
                }
            }
            if isActive {
                Section {
                    Button("Clear Filters", systemImage: "xmark") {
                        withAnimation(Motion.standard) { filters = []; model.scopeAccountID = nil }
                    }
                }
            }
        } label: {
            // Filled when something is narrowing the list, as in Mail.
            Label("Filter", systemImage: isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
        }
        .menuActionDismissBehavior(.disabled)
        .sensoryFeedback(.selection, trigger: filters)
        .accessibilityValue(isActive ? "On" : "Off")
    }
}

/// Shared actions for the context menu, the bulk "More" menu and the conversation toolbar.
struct ThreadMenu: View {
    @Environment(AppModel.self) private var model
    var threads: [ThreadSummary]
    var onLater: () -> Void
    var onLabel: () -> Void
    var onWhyFocused: (() -> Void)?
    var bulk = false
    var after: () -> Void = {}

    private var refs: [ThreadRef] { threads.map(\.ref) }

    var body: some View {
        let anyUnread = threads.contains(where: \.isUnread)
        let allStarred = !threads.isEmpty && threads.allSatisfy(\.isStarred)
        let anyInbox = threads.contains(where: \.inInbox)
        let allSpam = !threads.isEmpty && threads.allSatisfy(\.inSpam)
        let allTrash = !threads.isEmpty && threads.allSatisfy(\.inTrash)
        Section {
            Button(anyUnread ? "Mark as Read" : "Mark as Unread", systemImage: anyUnread ? "envelope.open" : "envelope.badge") {
                run(anyUnread ? .markRead : .markUnread, toast: bulk)
            }
            Button(allStarred ? "Remove Star" : "Star", systemImage: allStarred ? "star.slash" : "star") { run(allStarred ? .unstar : .star, toast: bulk) }
            if threads.allSatisfy(\.isImportant) {
                Button("Mark Not Important", systemImage: "exclamationmark.circle") { run(.markNotImportant, toast: true) }
            } else {
                Button("Mark Important", systemImage: "exclamationmark.circle") { run(.markImportant, toast: true) }
            }
        }
        Section {
            Button("Later…", systemImage: "clock") { onLater() }
            Button("Labels…", systemImage: "tag") { onLabel() }
            if anyInbox {
                Button("Archive", systemImage: "archivebox") { run(.archive) }
            } else if !allTrash && !allSpam {
                Button("Move to Inbox", systemImage: "tray.and.arrow.down") { run(.moveToInbox) }
            }
        }
        Section {
            if allSpam {
                Button("Not Spam", systemImage: "tray.and.arrow.down") { run(.notSpam) }
            } else {
                Button("Move to Spam", systemImage: "xmark.octagon") { run(.spam) }
            }
            if allTrash {
                Button("Move to Inbox", systemImage: "arrow.uturn.backward") { run(.restore) }
            } else {
                Button("Move to Trash", systemImage: "trash", role: .destructive) { run(.trash) }
            }
        }
        if let onWhyFocused, threads.count == 1 {
            Section { Button("Why Is This Focused?", systemImage: "questionmark.circle") { onWhyFocused() } }
        }
    }

    private func run(_ action: ThreadAction, toast: Bool = true) {
        let refs = refs
        Task { await model.perform(action, on: refs, toast: toast) }
        after()
    }
}

struct FocusExplanation: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var thread: ThreadSummary

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let reason = model.focus.reason(for: thread) {
                        Label(reason.explanation, systemImage: "checkmark.circle")
                    } else {
                        Label("Not in Focused. It looks like a mailing list, an automated message, or mail that wasn't sent directly to you.", systemImage: "circle")
                    }
                } footer: {
                    Text("Focused is a suggestion made on this iPhone. It never archives or hides mail — All always shows everything.")
                }
                if let sender = thread.latestFrom {
                    Section("Always for \(sender.displayName)") {
                        Button("Always Show in Focused") { Task { await model.setSenderRule(sender.address, focused: true); dismiss() } }
                        Button("Never Show in Focused") { Task { await model.setSenderRule(sender.address, focused: false); dismiss() } }
                        Button("Use Automatic Sorting") { Task { await model.setSenderRule(sender.address, focused: nil); dismiss() } }
                    }
                }
            }
            .navigationTitle("Focused")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

/// All, Focused, then the account's labels, as quiet pills that scroll sideways.
/// The selected view is filled; the rest are plain text. Picking a label opens that label's conversations.
struct InboxTabs: View {
    @Environment(AppModel.self) private var model
    @Namespace private var ns

    private enum Tab: Hashable { case all, focused, label(String) }

    private var selected: Tab {
        switch model.mailbox {
        case .inbox: model.prefs.showFocused ? .focused : .all
        case .label(let account, let label, _): .label(account + "/" + label)
        default: .all
        }
    }

    private var labels: [MailLabel] {
        model.labels.filter { $0.kind == .user }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: Spacing.xxs) {
                    tab("All", .all, count: model.counts.inboxUnread.values.reduce(0, +),
                        hint: "Every conversation in your Inbox.") { open(.inbox, focused: false) }
                    tab("Focused", .focused, hint: "Conversations from people that likely need you.") { open(.inbox, focused: true) }
                    if !labels.isEmpty {
                        Capsule()
                            .fill(Color.slate.separator)
                            .frame(width: 1, height: 18)
                            .padding(.horizontal, Spacing.xxs)
                            .accessibilityHidden(true)
                    }
                    ForEach(labels) { l in
                        tab(l.leafName, .label(l.id), count: model.counts.labelUnread[l.id] ?? 0, hint: "Conversations labeled \(l.name).") {
                            open(.label(accountID: l.accountID, labelID: l.labelID, name: l.name), focused: nil)
                        }
                    }
                }
                .padding(.horizontal, Spacing.md)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .onAppear { proxy.scrollTo(selected, anchor: .center) }
            .onChange(of: selected) { _, new in withAnimation(Motion.standard) { proxy.scrollTo(new, anchor: .center) } }
        }
        .sensoryFeedback(.selection, trigger: selected)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inbox view")
    }

    private func open(_ mailbox: Mailbox, focused: Bool?) {
        withAnimation(Motion.standard) {
            if let focused { model.prefs.showFocused = focused }
            model.mailbox = mailbox
        }
    }

    private func tab(_ title: String, _ tab: Tab, count: Int = 0, hint: String, action: @escaping () -> Void) -> some View {
        let isSelected = tab == selected
        return Button(action: action) {
            HStack(spacing: 5) {
                Text(title).lineLimit(1)
                if count > 0 {
                    Text("\(count)").monospacedDigit().foregroundStyle(Color.slate.inkMetadata)
                }
            }
            .font(.subheadline.weight(isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? Color.slate.inkPrimary : Color.slate.inkSecondary)
            .padding(.horizontal, 14)
            .frame(minHeight: 34)
            .background {
                if isSelected {
                    Capsule().fill(Color.slate.surfaceSecondary).matchedGeometryEffect(id: "tab", in: ns)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(minHeight: Spacing.minHit)
        .id(tab)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(hint)
    }
}
