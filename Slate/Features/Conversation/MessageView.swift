import SwiftUI
import QuickLook

struct MessageView: View {
    @Environment(AppModel.self) private var model
    var message: MailMessage
    var account: Account?
    var isExpanded: Bool
    var isLatest: Bool
    var inlineImages: [String: Data]
    var toggle: () -> Void

    @State private var showDetails = false
    @State private var showQuoted = false
    @State private var loadImages = false

    private var isMe: Bool { model.identities.contains(message.from?.normalized ?? "") }

    var body: some View {
        VStack(alignment: .leading, spacing: isExpanded ? Spacing.md : Spacing.xs) {
            Button(action: toggle) { headerRow }
                .buttonStyle(.plain)
                .accessibilityHint(isExpanded ? "Collapses this message." : "Expands this message.")
            if isExpanded {
                if showDetails { details }
                bodyView
                if !message.visibleAttachments.isEmpty {
                    AttachmentList(message: message)
                }
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, isExpanded ? Spacing.md : Spacing.sm + 2)
    }

    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            if message.isUnread { UnreadDot() }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(isMe ? "Me" : (message.from?.displayName ?? "Unknown sender"))
                        .font(.headline)
                        .foregroundStyle(Color.slate.inkPrimary)
                        .lineLimit(1)
                    Spacer(minLength: Spacing.xs)
                    Text(message.date.formatted(Calendar.current.isDateInToday(message.date) ? .dateTime.hour().minute() : .dateTime.month(.abbreviated).day().hour().minute()))
                        .font(.footnote)
                        .foregroundStyle(Color.slate.inkMetadata)
                }
                if isExpanded {
                    Button { withAnimation(.snappy) { showDetails.toggle() } } label: {
                        HStack(spacing: 4) {
                            Text(recipientSummary).lineLimit(1)
                            Image(systemName: showDetails ? "chevron.up" : "chevron.down").font(.caption2.weight(.semibold))
                        }
                        .font(.footnote)
                        .foregroundStyle(Color.slate.inkSecondary)
                        .frame(minHeight: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showDetails ? "Hide details" : "Show details: \(recipientSummary)")
                } else {
                    Text(message.snippet)
                        .font(.subheadline)
                        .foregroundStyle(Color.slate.inkSecondary)
                        .lineLimit(1)
                }
            }
        }
        .contentShape(Rectangle())
    }

    private var recipientSummary: String {
        let all = message.to + message.cc
        let names = all.prefix(3).map { model.identities.contains($0.normalized) ? "me" : $0.shortName }
        let extra = all.count > 3 ? " +\(all.count - 3)" : ""
        return "to " + (names.isEmpty ? "undisclosed recipients" : names.joined(separator: ", ")) + extra
    }

    private var details: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Spacing.xs, verticalSpacing: 4) {
            if let from = message.from { detailRow("From", [from]) }
            if !message.replyTo.isEmpty { detailRow("Reply-To", message.replyTo) }
            if !message.to.isEmpty { detailRow("To", message.to) }
            if !message.cc.isEmpty { detailRow("Cc", message.cc) }
            // Bcc only exists on copies you sent; it is shown to you alone.
            if isMe && !message.bcc.isEmpty { detailRow("Bcc", message.bcc) }
            GridRow {
                Text("Date").foregroundStyle(Color.slate.inkMetadata)
                Text(message.date.formatted(date: .complete, time: .shortened)).foregroundStyle(Color.slate.inkSecondary)
            }
        }
        .font(.footnote)
        .textSelection(.enabled)
        .padding(Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private func detailRow(_ title: String, _ list: [EmailAddress]) -> some View {
        GridRow {
            Text(title).foregroundStyle(Color.slate.inkMetadata)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(list) { a in
                    Text(a.name.map { "\($0) <\(a.address)>" } ?? a.address).foregroundStyle(Color.slate.inkSecondary)
                }
            }
        }
    }

    // MARK: Body

    @ViewBuilder private var bodyView: some View {
        if let html = message.bodyHTML, !html.isEmpty {
            let inSpam = message.labelIDs.contains(SystemLabel.spam)
            let wantsImages = loadImages || (model.prefs.remoteImages == .always && !inSpam)
            if HTMLMessageView.hasRemoteContent(html) && !wantsImages {
                HStack {
                    Label("Remote images are blocked", systemImage: "photo.badge.exclamationmark")
                        .font(.footnote).foregroundStyle(Color.slate.inkSecondary)
                    Spacer()
                    if !inSpam {
                        Button("Load Images") { loadImages = true }.font(.footnote.weight(.semibold))
                    }
                }
            }
            HTMLMessageView(html: html, allowRemote: wantsImages, inlineImages: inlineImages, linksEnabled: !inSpam)
        } else if let plain = message.bodyPlain {
            let parts = PlainTextBody.split(plain)
            PlainTextBody(text: parts.main, linksEnabled: !message.labelIDs.contains(SystemLabel.spam))
            if let quoted = parts.quoted {
                Button(showQuoted ? "Hide Quoted Text" : "Show Quoted Text") { withAnimation { showQuoted.toggle() } }
                    .font(.footnote.weight(.medium))
                    .frame(minHeight: Spacing.minHit)
                if showQuoted {
                    PlainTextBody(text: quoted, linksEnabled: false)
                        .foregroundStyle(Color.slate.inkSecondary)
                        .padding(.leading, Spacing.sm)
                        .overlay(alignment: .leading) { Rectangle().fill(Color.slate.separator).frame(width: 2) }
                }
            }
        } else if message.hasFullBody {
            Text("This message has no text.").font(.footnote).foregroundStyle(Color.slate.inkMetadata)
        } else {
            HStack(spacing: Spacing.xs) {
                ProgressView().controlSize(.small)
                Text(message.snippet).font(.body).foregroundStyle(Color.slate.inkSecondary)
            }
        }
    }
}

/// Plain-text mail with detected links, selectable text and comfortable line spacing.
struct PlainTextBody: View {
    var text: String
    var linksEnabled: Bool

    static func split(_ text: String) -> (main: String, quoted: String?) {
        let lines = text.components(separatedBy: "\n")
        if let idx = lines.firstIndex(where: {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return (t.hasPrefix("On ") && t.hasSuffix("wrote:")) || t.hasPrefix("-----Original Message")
        }) ?? lines.firstIndex(where: { $0.hasPrefix(">") }) {
            let main = lines[..<idx].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let quoted = lines[idx...].joined(separator: "\n")
            if !main.isEmpty { return (main, quoted) }
        }
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), nil)
    }

    var body: some View {
        Text(attributed)
            .font(.body)
            .foregroundStyle(Color.slate.inkPrimary)
            .lineSpacing(4)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var attributed: AttributedString {
        var a = AttributedString(text)
        guard linksEnabled, let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return a }
        let ns = text as NSString
        for match in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let url = match.url, ["http", "https", "mailto", "tel"].contains(url.scheme?.lowercased() ?? ""),
                  let range = Range(match.range, in: text), let lower = AttributedString.Index(range.lowerBound, within: a),
                  let upper = AttributedString.Index(range.upperBound, within: a) else { continue }
            a[lower..<upper].link = url
            a[lower..<upper].foregroundColor = Color.slate.link
        }
        return a
    }
}

struct AttachmentList: View {
    @Environment(AppModel.self) private var model
    var message: MailMessage
    @State private var downloading: Set<String> = []
    @State private var files: [String: URL] = [:]
    @State private var preview: URL?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            ForEach(message.visibleAttachments) { a in
                HStack(spacing: Spacing.sm) {
                    Image(systemName: symbol(a.mimeType))
                        .font(.title3)
                        .foregroundStyle(Color.slate.inkSecondary)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(a.filename).font(.subheadline.weight(.medium)).lineLimit(1).truncationMode(.middle)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(a.size), countStyle: .file))
                            .font(.caption).foregroundStyle(Color.slate.inkMetadata)
                    }
                    Spacer()
                    if downloading.contains(a.id) {
                        ProgressView().controlSize(.small)
                    } else if let url = files[a.id] {
                        ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                            .frame(width: Spacing.minHit, height: Spacing.minHit)
                            .accessibilityLabel("Share \(a.filename)")
                    }
                }
                .padding(.horizontal, Spacing.sm)
                .frame(minHeight: 52)
                .panel()
                .contentShape(Rectangle())
                .onTapGesture { Task { await open(a) } }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Opens a preview")
            }
            if let error { Text(error).font(.footnote).foregroundStyle(Color.slate.destructive) }
        }
        .quickLookPreview($preview)
    }

    private func symbol(_ mime: String) -> String {
        if mime.hasPrefix("image/") { return "photo" }
        if mime == "application/pdf" { return "doc.richtext" }
        if mime.contains("zip") { return "doc.zipper" }
        if mime.hasPrefix("text/") { return "doc.text" }
        return "doc"
    }

    private func open(_ a: AttachmentInfo) async {
        if let url = files[a.id] { preview = url; return }
        guard let provider = model.provider(for: message.accountID), let dir = try? AppPaths.attachmentCache(accountID: message.accountID) else { return }
        downloading.insert(a.id)
        defer { downloading.remove(a.id) }
        do {
            let data: Data
            if let inline = a.inlineData { data = inline }
            else if let id = a.attachmentID { data = try await provider.attachment(messageID: message.id, attachmentID: id) }
            else { throw ProviderError.notFound }
            let folder = dir.appendingPathComponent(message.id, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let safe = a.filename.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
            let url = folder.appendingPathComponent(safe.isEmpty ? "attachment" : safe)
            try data.write(to: url, options: .completeFileProtectionUntilFirstUserAuthentication)
            files[a.id] = url
            preview = url
            error = nil
        } catch {
            self.error = "Couldn't download \(a.filename). \((error as? LocalizedError)?.errorDescription ?? "")"
        }
    }
}
