import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ComposerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var composer: ComposerModel?
    let draft: Draft

    var body: some View {
        Group {
            if let composer { ComposerForm(composer: composer, close: { dismiss() }) }
        }
        .onAppear { if composer == nil { composer = ComposerModel(draft: draft, app: model) } }
    }
}

private struct ComposerForm: View {
    @Environment(AppModel.self) private var model
    @Bindable var composer: ComposerModel
    var close: () -> Void

    @State private var confirmClose = false
    @State private var confirmMissingAttachment = false
    @State private var showFiles = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var linkPrompt = false
    @State private var linkText = ""
    @State private var sending = false
    @FocusState private var subjectFocused: Bool

    private var title: String {
        switch composer.draft.kind {
        case .new: composer.draft.subject.isEmpty ? "New Message" : composer.draft.subject
        case .reply, .replyAll: "Reply"
        case .forward: "Forward"
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let note = model.composerNote {
                        Label { Text(note) } icon: { AuraRing() }
                            .font(.footnote)
                            .foregroundStyle(Color.slate.inkSecondary)
                            .padding(Spacing.sm)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .panel()
                            .padding(.horizontal, Spacing.md)
                            .padding(.top, Spacing.xs)
                    }
                    fields
                    BodyEditor(initial: composer.body, controller: composer.editor,
                               onChange: { composer.bodyChanged($0) },
                               onWritingTools: { composer.isWritingToolsActive = $0; if !$0 { composer.touch() } })
                        .padding(.horizontal, Spacing.xxs)
                    quoted
                    attachments
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.slate.canvas)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .confirmationDialog("Save this draft?", isPresented: $confirmClose, titleVisibility: .hidden) {
                Button("Save Draft") { Task { await composer.saveAndClose(); close() } }
                Button("Delete Draft", role: .destructive) { Task { await composer.discard(); close() } }
                Button("Keep Editing", role: .cancel) {}
            }
            .confirmationDialog("Send without an attachment?", isPresented: $confirmMissingAttachment, titleVisibility: .visible) {
                Button("Send Anyway") { Task { await send(skipChecks: true) } }
                Button("Add Attachment") { showFiles = true }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your message mentions an attachment, but nothing is attached.")
            }
            .alert("Couldn't continue", isPresented: Binding(get: { composer.error != nil }, set: { if !$0 { composer.error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(composer.error ?? "") }
            .alert("Add Link", isPresented: $linkPrompt) {
                TextField("https://", text: $linkText).keyboardType(.URL).textInputAutocapitalization(.never)
                Button("Add") {
                    let s = linkText.contains("://") ? linkText : "https://" + linkText
                    if let url = URL(string: s), url.host != nil { composer.editor.addLink(url) }
                    linkText = ""
                }
                Button("Cancel", role: .cancel) { linkText = "" }
            }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                for url in urls {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    if let data = try? Data(contentsOf: url) {
                        composer.addAttachment(data: data, filename: url.lastPathComponent, type: UTType(filenameExtension: url.pathExtension))
                    } else {
                        composer.error = "Couldn't read \(url.lastPathComponent)."
                    }
                }
            }
            .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 10, matching: .any(of: [.images, .videos]))
            .onChange(of: photoItems) { _, items in
                Task {
                    for (i, item) in items.enumerated() {
                        guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                        let type = item.supportedContentTypes.first
                        let ext = type?.preferredFilenameExtension ?? "jpg"
                        composer.addAttachment(data: data, filename: "Photo \(i + 1).\(ext)", type: type)
                    }
                    photoItems = []
                }
            }
        }
        .onDisappear {
            if !composer.finished { Task { await composer.saveAndClose() } }
        }
    }

    // MARK: Fields

    @ViewBuilder private var fields: some View {
        let participants: [EmailAddress] = []
        RecipientField(title: "To:", recipients: $composer.draft.to, accountID: composer.draft.accountID,
                       extraSuggestions: participants, onChange: composer.touch)
        separator
        if composer.showCcBcc {
            RecipientField(title: "Cc:", recipients: $composer.draft.cc, accountID: composer.draft.accountID,
                           extraSuggestions: participants, onChange: composer.touch)
            separator
            RecipientField(title: "Bcc:", recipients: $composer.draft.bcc, accountID: composer.draft.accountID,
                           extraSuggestions: participants, onChange: composer.touch)
            separator
            fromRow
            separator
        } else {
            Button { withAnimation { composer.showCcBcc = true } } label: {
                HStack {
                    Text(model.hasMultipleAccounts ? "Cc/Bcc, From:" : "Cc/Bcc").foregroundStyle(Color.slate.inkMetadata)
                    if model.hasMultipleAccounts, let a = composer.account {
                        Text(a.email).foregroundStyle(Color.slate.inkPrimary).lineLimit(1)
                    }
                    Spacer()
                }
                .font(.body)
                .padding(.horizontal, Spacing.md)
                .frame(minHeight: Spacing.minHit)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            separator
        }
        HStack(spacing: Spacing.xs) {
            Text("Subject:").foregroundStyle(Color.slate.inkMetadata).accessibilityHidden(true)
            TextField("", text: $composer.draft.subject, axis: .vertical)
                .focused($subjectFocused)
                .accessibilityLabel("Subject")
                .onChange(of: composer.draft.subject) { composer.touch() }
        }
        .font(.body)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 10)
        separator
    }

    private var fromRow: some View {
        HStack(spacing: Spacing.xs) {
            Text("From:").foregroundStyle(Color.slate.inkMetadata)
            Menu {
                Picker("From", selection: Binding(get: { composer.draft.accountID }, set: { composer.changeAccount(to: $0) })) {
                    ForEach(model.accounts) { a in
                        Text(a.friendlyName.isEmpty ? a.email : "\(a.friendlyName) — \(a.email)").tag(a.id)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(composer.account?.email ?? "Choose account").lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.caption)
                }
                .foregroundStyle(Color.slate.inkPrimary)
            }
            .disabled(model.accounts.count < 2)
            Spacer()
        }
        .font(.body)
        .padding(.horizontal, Spacing.md)
        .frame(minHeight: Spacing.minHit)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("From \(composer.account?.email ?? "")")
    }

    private var separator: some View {
        Rectangle().fill(Color.slate.separator).frame(height: 1 / UIScreen.main.scale).padding(.leading, Spacing.md)
    }

    @ViewBuilder private var quoted: some View {
        if let q = composer.draft.quoted {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Toggle(isOn: $composer.draft.includeQuoted) {
                    Text(composer.draft.kind == .forward ? "Include forwarded message" : "Include quoted text")
                        .font(.subheadline).foregroundStyle(Color.slate.inkSecondary)
                }
                .onChange(of: composer.draft.includeQuoted) { composer.touch() }
                if composer.draft.includeQuoted {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(q.attribution).font(.footnote).foregroundStyle(Color.slate.inkMetadata)
                        Text(q.plain).font(.footnote).foregroundStyle(Color.slate.inkSecondary).lineLimit(8)
                    }
                    .padding(.leading, Spacing.sm)
                    .overlay(alignment: .leading) { Rectangle().fill(Color.slate.separator).frame(width: 2) }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
        }
    }

    @ViewBuilder private var attachments: some View {
        if !composer.draft.attachments.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                ForEach(composer.draft.attachments) { a in
                    HStack {
                        Image(systemName: "paperclip").foregroundStyle(Color.slate.inkSecondary)
                        Text(a.filename).font(.subheadline).lineLimit(1).truncationMode(.middle)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(a.size), countStyle: .file))
                            .font(.caption).foregroundStyle(Color.slate.inkMetadata)
                        Spacer()
                        Button { composer.removeAttachment(a) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Color.slate.inkMetadata) }
                            .frame(width: Spacing.minHit, height: Spacing.minHit)
                            .accessibilityLabel("Remove \(a.filename)")
                    }
                    .padding(.leading, Spacing.sm)
                    .panel()
                }
                let total = composer.draft.attachments.reduce(0) { $0 + $1.size }
                Text("\(ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)) of 25 MB")
                    .font(.caption).foregroundStyle(Color.slate.inkMetadata)
            }
            .padding(Spacing.md)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel", systemImage: "xmark") {
                if composer.draft.isEffectivelyEmpty && composer.draft.remoteDraftID == nil {
                    Task { await composer.discard(); close() }
                } else { confirmClose = true }
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button { Task { await send(skipChecks: false) } } label: {
                if sending { ProgressView() } else { Label("Send", systemImage: "arrow.up") }
            }
            .buttonStyle(.glassProminent)
            .disabled(!composer.canSend || sending)
            .accessibilityLabel("Send")
        }
        ToolbarItemGroup(placement: .bottomBar) {
            Menu {
                Button("Photo Library", systemImage: "photo.on.rectangle") { showPhotos = true }
                Button("Files", systemImage: "folder") { showFiles = true }
            } label: { Label("Attach", systemImage: "paperclip") }
            Menu {
                Button("Bold", systemImage: "bold") { composer.editor.toggle(.traitBold) }
                Button("Italic", systemImage: "italic") { composer.editor.toggle(.traitItalic) }
                Button("Bulleted List", systemImage: "list.bullet") { composer.editor.toggleBullets() }
                Button("Link…", systemImage: "link") { linkPrompt = true }
            } label: { Label("Format", systemImage: "textformat") }
            if model.intelligence.isAvailable {
                Menu {
                    if composer.preRewriteBody != nil {
                        Button("Restore My Version", systemImage: "arrow.uturn.backward") { composer.undoRewrite() }
                        Divider()
                    }
                    ForEach(RewriteStyle.allCases) { style in
                        Button(style.title) { Task { await composer.rewrite(style) } }
                    }
                } label: {
                    if composer.rewriting != nil { ProgressView() } else { Label("Rewrite", systemImage: "pencil.line") }
                }
                .disabled(composer.body.string.replacingOccurrences(of: composer.draft.appliedSignature, with: "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Spacer()
            saveStatus
        }
    }

    @ViewBuilder private var saveStatus: some View {
        let text: String? = switch composer.savedState {
        case .idle: nil
        case .savedLocally: "Draft saved on this iPhone"
        case .syncedToGmail: "Draft saved to Gmail"
        case .keptBoth: "Edited elsewhere — both versions kept"
        case .failed: "Draft saved on this iPhone"
        }
        if let text {
            Text(text).font(.caption).foregroundStyle(Color.slate.inkMetadata).lineLimit(1)
        }
    }

    private func send(skipChecks: Bool) async {
        if !composer.invalidRecipients.isEmpty {
            composer.error = "Check \(composer.invalidRecipients.map(\.address).joined(separator: ", ")) — it isn't a valid email address."
            return
        }
        if !skipChecks && composer.mentionsMissingAttachment {
            confirmMissingAttachment = true
            return
        }
        sending = true
        defer { sending = false }
        if await composer.send() { close() }
    }
}
