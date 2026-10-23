import SwiftUI
import AuthenticationServices

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.webAuthenticationSession) private var webAuth
    @Environment(\.openURL) private var openURL
    @State private var connecting = false
    @State private var error: String?

    var body: some View {
        @Bindable var prefs = model.prefs
        NavigationStack {
            Form {
                Section {
                    ForEach(model.accounts) { a in
                        NavigationLink { AccountDetailView(accountID: a.id) } label: { AccountRow(account: a) }
                    }
                    .onMove { from, to in Task { await model.moveAccount(from: from, to: to) } }
                    Button {
                        Task { await connect() }
                    } label: {
                        HStack {
                            Label("Add Gmail Account", systemImage: "plus.circle")
                            if connecting { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(connecting)
                    if !model.accounts.contains(where: \.isSample) {
                        Button { Task { await model.addSampleAccount() } } label: { Label("Add Sample Mailbox", systemImage: "tray.full") }
                    }
                } header: { Text("Accounts") } footer: {
                    if !model.isGoogleConfigured {
                        Text("Gmail sign-in needs a Google iOS OAuth client ID in Config/Local.xcconfig. See docs/SETUP.md.")
                    } else {
                        Text("Each account syncs on its own; a problem with one never stops the others.")
                    }
                }

                Section("Sending") {
                    if model.accounts.count > 1 {
                        Picker("Default Account", selection: Binding(get: { prefs.defaultAccountID ?? model.accounts.first?.id ?? "" },
                                                                     set: { prefs.defaultAccountID = $0 })) {
                            ForEach(model.accounts) { Text($0.email).tag($0.id) }
                        }
                    }
                    Picker("Undo Send", selection: $prefs.undoSendSeconds) {
                        ForEach(Preferences.undoChoices, id: \.self) { Text("\($0) seconds").tag($0) }
                    }
                }

                Section {
                    Picker("Previews", selection: $prefs.previewPrivacy) {
                        ForEach(PreviewPrivacy.allCases) { Text($0.title).tag($0) }
                    }
                    notificationPermission
                } header: { Text("Notifications") } footer: {
                    Text("Slate checks for mail when it's open and when iOS allows a background refresh. Alerts while Slate isn't running need the push service described in docs/NOTIFICATIONS.md, which isn't set up yet. The badge counts unread Inbox conversations.")
                }

                Section("Inbox") {
                    Picker("Swipe Right", selection: $prefs.leadingSwipe) { ForEach(SwipeAction.allCases) { Text($0.title).tag($0) } }
                    Picker("Swipe Left", selection: $prefs.trailingSwipe) { ForEach(SwipeAction.allCases) { Text($0.title).tag($0) } }
                    Picker("Swipe Left (Second)", selection: $prefs.trailingSwipeSecondary) { ForEach(SwipeAction.allCases) { Text($0.title).tag($0) } }
                    DatePicker("Later “Morning”", selection: Binding(get: {
                        Calendar.current.date(bySettingHour: prefs.morningHour, minute: prefs.morningMinute, second: 0, of: .now) ?? .now
                    }, set: { d in
                        prefs.morningHour = Calendar.current.component(.hour, from: d)
                        prefs.morningMinute = Calendar.current.component(.minute, from: d)
                    }), displayedComponents: .hourAndMinute)
                }

                Section {
                    Picker("Remote Images", selection: $prefs.remoteImages) { ForEach(RemoteImagePolicy.allCases) { Text($0.title).tag($0) } }
                } header: { Text("Reading") } footer: {
                    Text("Remote images can tell senders when and where you opened a message. They're always blocked in Spam.")
                }

                Section {
                    Toggle("Summaries & Suggested Replies", isOn: Binding(get: { model.intelligence.enabled }, set: { model.intelligence.enabled = $0 }))
                    if case .unavailable(let reason) = model.intelligence.status {
                        Text(reason).font(.footnote).foregroundStyle(Color.slate.inkSecondary)
                    }
                } header: { Text("Intelligence") } footer: {
                    Text("Generated on this iPhone with Apple's on-device model. Your mail isn't uploaded. Suggestions only ever create a draft you can edit; nothing is sent for you.")
                }

                Section {
                    Toggle("Remember Recent Searches", isOn: $prefs.rememberSearches)
                    if !prefs.recentSearches.isEmpty {
                        Button("Clear Recent Searches", role: .destructive) { prefs.recentSearches = [] }
                    }
                } header: { Text("Privacy") } footer: {
                    Text("Mail is stored on this iPhone, excluded from backups, and removed when you remove an account. Sign-in tokens are kept in the Keychain on this device only.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if model.accounts.count > 1 { ToolbarItem(placement: .topBarLeading) { EditButton() } }
            }
            .alert("Couldn't add account", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
        }
    }

    @ViewBuilder private var notificationPermission: some View {
        switch model.notifications.authorization {
        case .notDetermined:
            Button("Turn On Notifications") { Task { await model.notifications.requestAuthorization() } }
        case .denied:
            Button("Notifications Are Off — Open Settings") {
                if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
            }
        default:
            EmptyView()
        }
    }

    private func connect() async {
        connecting = true
        defer { connecting = false }
        do {
            try await model.connectGmail(using: webAuth)
        } catch let e as ASWebAuthenticationSessionError where e.code == .canceledLogin {
            // User cancelled; nothing changed.
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

private struct AccountRow: View {
    var account: Account
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(account.friendlyName.isEmpty ? account.email : account.friendlyName).font(.body)
            if !account.friendlyName.isEmpty { Text(account.email).font(.footnote).foregroundStyle(Color.slate.inkSecondary) }
            if account.isSample {
                Text("Sample data — not a real mailbox").font(.footnote).foregroundStyle(Color.slate.warning)
            } else if account.status != .connected {
                Label(account.statusMessage ?? "Needs attention", systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(Color.slate.warning)
            }
        }
    }
}

struct AccountDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.webAuthenticationSession) private var webAuth
    var accountID: String
    @State private var account: Account?
    @State private var confirmRemove = false
    @State private var error: String?

    var body: some View {
        Form {
            if let account = Binding($account) {
                Section {
                    LabeledContent("Address", value: account.wrappedValue.email)
                    TextField("Friendly name (e.g. Personal)", text: account.friendlyName)
                    TextField("Your name on sent mail", text: account.displayName)
                } footer: {
                    Text("The friendly name appears in All Accounts and the account menu. Your name appears in the From line.")
                }
                Section {
                    TextField("Signature", text: account.signature, axis: .vertical).lineLimit(3...8)
                } header: { Text("Signature") } footer: {
                    Text("Added to new messages and replies from this account in Slate. Your Gmail web signature isn't changed.")
                }
                Section("Notifications") {
                    Picker("New Mail", selection: account.notificationMode) {
                        ForEach(NotificationMode.allCases) { Text($0.title).tag($0) }
                    }
                }
                if account.wrappedValue.status == .needsReconnect || account.wrappedValue.provider == .gmail {
                    Section {
                        if let last = account.wrappedValue.lastSyncAt {
                            LabeledContent("Last synced", value: last.formatted(.relative(presentation: .named)))
                        }
                        if account.wrappedValue.provider == .gmail {
                            Button(account.wrappedValue.status == .needsReconnect ? "Reconnect" : "Sign In Again") {
                                Task {
                                    do { try await model.connectGmail(using: webAuth, reconnecting: account.wrappedValue); self.account = model.account(accountID) }
                                    catch let e as ASWebAuthenticationSessionError where e.code == .canceledLogin {}
                                    catch { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
                                }
                            }
                        }
                    } footer: {
                        if account.wrappedValue.provider == .gmail {
                            Text("While the Google Cloud project is in Testing mode, Google asks you to sign in again every 7 days.")
                        }
                    }
                }
                Section {
                    Button("Remove Account", role: .destructive) { confirmRemove = true }
                } footer: {
                    Text("Removes this account's downloaded mail, drafts, outbox, Later reminders and notifications from this iPhone and signs Slate out. Nothing is deleted from Gmail.")
                }
            }
        }
        .navigationTitle(account?.shortLabel ?? "Account")
        .task { account = model.account(accountID) }
        .onDisappear { if let account { Task { await model.save(account) } } }
        .confirmationDialog("Remove \(account?.email ?? "")?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove Account", role: .destructive) {
                let id = accountID
                account = nil
                Task { await model.removeAccount(id) }
                dismiss()
            }
        }
        .alert("Couldn't reconnect", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }
}
