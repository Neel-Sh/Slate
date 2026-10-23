import SwiftUI

struct MailboxesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var newLabelAccount: Account?
    @State private var labelName = ""
    @State private var renaming: MailLabel?
    @State private var deleting: MailLabel?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if model.hasMultipleAccounts {
                    Section {
                        Picker("Showing", selection: Binding(get: { model.scopeAccountID }, set: { model.scopeAccountID = $0 })) {
                            Text("All Accounts").tag(String?.none)
                            ForEach(model.accounts) { a in Text(a.friendlyName.isEmpty ? a.email : a.friendlyName).tag(Optional(a.id)) }
                        }
                    }
                }
                Section {
                    ForEach(Mailbox.standard) { box in
                        mailboxRow(box)
                    }
                } footer: {
                    Text("Inbox counts are unread conversations. Later, Drafts and Outbox show how many items they hold.")
                }
                let byAccount = Dictionary(grouping: model.labels.filter { $0.kind == .user }, by: \.accountID)
                ForEach(model.accounts.filter { model.scopeAccountIDs.contains($0.id) }) { account in
                    Section {
                        ForEach(byAccount[account.id] ?? []) { label in
                            labelRow(label)
                        }
                        Button { newLabelAccount = account } label: {
                            Label("New Label", systemImage: "plus")
                        }
                    } header: {
                        Text(model.hasMultipleAccounts ? "Labels · \(account.shortLabel)" : "Labels")
                    }
                }
                Section {
                    Button { dismiss(); model.showSettings = true } label: { Label("Settings", systemImage: "gear") }
                }
            }
            .navigationTitle("Mailboxes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .alert("New Label", isPresented: Binding(get: { newLabelAccount != nil }, set: { if !$0 { newLabelAccount = nil } })) {
                TextField("Name", text: $labelName)
                Button("Create") {
                    let name = labelName, account = newLabelAccount
                    labelName = ""
                    Task {
                        do { if let account { _ = try await model.createLabel(name, accountID: account.id) } }
                        catch { self.error = (error as? LocalizedError)?.errorDescription ?? "Couldn't create the label." }
                    }
                }
                Button("Cancel", role: .cancel) { labelName = "" }
            } message: {
                Text("Use “/” to nest labels, for example Clients/Northwind.")
            }
            .alert("Rename Label", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $labelName)
                Button("Rename") {
                    let name = labelName, label = renaming
                    labelName = ""
                    Task {
                        do { if let label { try await model.renameLabel(label, to: name) } }
                        catch { self.error = (error as? LocalizedError)?.errorDescription ?? "Couldn't rename the label." }
                    }
                }
                Button("Cancel", role: .cancel) { labelName = "" }
            }
            .confirmationDialog("Delete “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible) {
                Button("Delete Label", role: .destructive) {
                    let label = deleting
                    Task {
                        do { if let label { try await model.deleteLabel(label) } }
                        catch { self.error = (error as? LocalizedError)?.errorDescription ?? "Couldn't delete the label." }
                    }
                }
            } message: {
                Text("Only the label is deleted. Its conversations stay in All Mail and keep their other labels.")
            }
            .alert("Something went wrong", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
        }
    }

    private func mailboxRow(_ box: Mailbox) -> some View {
        let count: Int = switch box {
        case .inbox: model.counts.inboxUnread.values.reduce(0, +)
        case .later: model.counts.later
        case .drafts: model.counts.drafts
        case .outbox: model.counts.outbox
        default: 0
        }
        return Button {
            model.mailbox = box
            model.path = []
            dismiss()
        } label: {
            HStack {
                Label(box.title, systemImage: box.symbol).foregroundStyle(Color.slate.inkPrimary)
                Spacer()
                if count > 0 { Text("\(count)").monospacedDigit().foregroundStyle(Color.slate.inkMetadata) }
                if model.mailbox == box { Image(systemName: "checkmark").foregroundStyle(Color.slate.accent).accessibilityLabel("Selected") }
            }
        }
        .accessibilityLabel(count > 0 ? "\(box.title), \(count)" : box.title)
    }

    private func labelRow(_ label: MailLabel) -> some View {
        let box = Mailbox.label(accountID: label.accountID, labelID: label.labelID, name: label.name)
        let count = model.counts.labelUnread[label.accountID + "/" + label.labelID] ?? 0
        let depth = label.name.filter { $0 == "/" }.count
        return Button {
            model.mailbox = box
            model.path = []
            dismiss()
        } label: {
            HStack {
                Circle().fill(ChipTone.forLabel(label.colorHex, name: label.name).ink).frame(width: 8, height: 8).accessibilityHidden(true)
                Text(label.leafName).foregroundStyle(Color.slate.inkPrimary)
                Spacer()
                if count > 0 { Text("\(count)").monospacedDigit().foregroundStyle(Color.slate.inkMetadata) }
                if model.mailbox == box { Image(systemName: "checkmark").foregroundStyle(Color.slate.accent) }
            }
            .padding(.leading, CGFloat(depth) * Spacing.md)
        }
        .contextMenu {
            Button("Rename", systemImage: "pencil") { labelName = label.name; renaming = label }
            Button("Delete Label", systemImage: "trash", role: .destructive) { deleting = label }
        }
        .swipeActions {
            Button("Delete", role: .destructive) { deleting = label }
            Button("Rename") { labelName = label.name; renaming = label }
        }
    }
}

struct LabelPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var refs: [ThreadRef]
    var done: () -> Void
    @State private var threads: [ThreadSummary] = []
    @State private var newName = ""

    private var accountIDs: Set<String> { Set(refs.map(\.accountID)) }

    var body: some View {
        NavigationStack {
            List {
                if accountIDs.count > 1 {
                    Section {
                        Text("Labels belong to one account. Choose a label from each account below; it applies only to that account's conversations.")
                            .font(.footnote).foregroundStyle(Color.slate.inkSecondary)
                    }
                }
                ForEach(model.accounts.filter { accountIDs.contains($0.id) }) { account in
                    let targets = refs.filter { $0.accountID == account.id }
                    Section(accountIDs.count > 1 || model.hasMultipleAccounts ? account.shortLabel : "") {
                        ForEach(model.labels.filter { $0.accountID == account.id && $0.kind == .user }) { label in
                            let state = membership(label, targets)
                            HStack {
                                Button {
                                    Task { await model.perform(state == .all ? .removeLabel(label.labelID) : .addLabel(label.labelID), on: targets, toast: false); await reload() }
                                } label: {
                                    HStack {
                                        Image(systemName: state == .all ? "checkmark.circle.fill" : state == .some ? "minus.circle" : "circle")
                                            .foregroundStyle(state == .none ? Color.slate.inkMetadata : Color.slate.accent)
                                        Text(label.name).foregroundStyle(Color.slate.inkPrimary)
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityValue(state == .all ? "Applied" : state == .some ? "Applied to some" : "Not applied")
                                Menu {
                                    Button("Move Here", systemImage: "arrow.right.circle") {
                                        Task { await model.perform(.moveToLabel(label.labelID), on: targets); dismiss(); done() }
                                    }
                                } label: { Image(systemName: "ellipsis.circle").foregroundStyle(Color.slate.inkSecondary) }
                                .accessibilityLabel("More for \(label.name)")
                            }
                            .frame(minHeight: Spacing.minHit)
                        }
                        HStack {
                            TextField("New label", text: $newName)
                            Button("Create & Apply") {
                                let name = newName
                                newName = ""
                                Task {
                                    if let l = try? await model.createLabel(name, accountID: account.id) {
                                        await model.perform(.addLabel(l.labelID), on: targets, toast: false)
                                        await reload()
                                    }
                                }
                            }
                            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
                Section {
                } footer: {
                    Text("Adding a label keeps conversations where they are. Move Here adds the label and removes them from Inbox. Labels apply to messages in the conversation now; later replies won't inherit them.")
                }
            }
            .navigationTitle("Labels")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss(); done() } } }
            .task { await reload() }
        }
        .presentationDetents([.medium, .large])
    }

    private enum Membership { case none, some, all }

    private func membership(_ label: MailLabel, _ targets: [ThreadRef]) -> Membership {
        let ts = threads.filter { targets.contains($0.ref) }
        let n = ts.filter { $0.labelIDs.contains(label.labelID) }.count
        return n == 0 ? .none : (n == ts.count ? .all : .some)
    }

    private func reload() async {
        var out: [ThreadSummary] = []
        for r in refs { if let t = try? await model.store.thread(r) { out.append(t) } }
        threads = out
    }
}

struct LaterPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var refs: [ThreadRef]
    var done: () -> Void
    @State private var custom = Date.now.addingTimeInterval(3600 * 24)
    @State private var current: Date?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(LaterPreset.allCases) { preset in
                        if let date = preset.date(from: .now, morning: model.prefs.morning) {
                            Button { choose(date) } label: {
                                HStack {
                                    Label(preset.title, systemImage: preset.symbol).foregroundStyle(Color.slate.inkPrimary)
                                    Spacer()
                                    Text(date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                                        .foregroundStyle(Color.slate.inkMetadata)
                                }
                            }
                        }
                    }
                }
                Section("Pick Date & Time") {
                    DatePicker("Date and time", selection: $custom, in: Date.now.addingTimeInterval(60)..., displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.graphical)
                    Button("Set Later") { choose(custom) }
                }
                if let current {
                    Section {
                        Button("Return to Inbox Now", role: .destructive) {
                            Task { await model.clearLater(refs); dismiss(); done() }
                        }
                    } footer: {
                        Text("Currently set for \(current.formatted(date: .abbreviated, time: .shortened)).")
                    }
                }
                Section {
                } footer: {
                    Text("Later hides conversations in Slate until the time you choose, then returns them to your Inbox with a reminder. Gmail isn't changed, and a new reply brings a conversation back right away.")
                }
            }
            .navigationTitle("Later")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task {
                if let entries = try? await model.store.laterEntries() {
                    current = entries.first { refs.contains($0.ref) && $0.until > .now }?.until
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func choose(_ date: Date) {
        Task {
            if model.notifications.authorization == .notDetermined { await model.notifications.requestAuthorization() }
            await model.setLater(refs, until: date)
            dismiss()
            done()
        }
    }
}
