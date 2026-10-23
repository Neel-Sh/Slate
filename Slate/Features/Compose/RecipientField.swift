import SwiftUI

struct RecipientField: View {
    var title: String
    @Binding var recipients: [EmailAddress]
    var accountID: String
    var extraSuggestions: [EmailAddress]
    var onChange: () -> Void

    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var suggestions: [EmailAddress] = []
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(Color.slate.inkMetadata)
                    .accessibilityHidden(true)
                FlowLayout(spacing: 6) {
                    ForEach(recipients) { r in token(r) }
                    TextField(recipients.isEmpty ? "" : "", text: $text)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focused)
                        .frame(minWidth: 80)
                        .onSubmit { commit() }
                        .onChange(of: text) { _, new in handleTyping(new) }
                        .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
                        .accessibilityLabel("\(title.replacingOccurrences(of: ":", with: "")) field, \(recipients.count) recipients")
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture { focused = true }

            if focused && !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(suggestions) { s in
                        Button {
                            add([s])
                            text = ""
                            suggestions = []
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.displayName).font(.subheadline.weight(.medium)).foregroundStyle(Color.slate.inkPrimary)
                                if s.name != nil { Text(s.address).font(.footnote).foregroundStyle(Color.slate.inkSecondary) }
                            }
                            .frame(maxWidth: .infinity, minHeight: Spacing.minHit, alignment: .leading)
                            .padding(.horizontal, Spacing.md)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(Color.slate.surfaceSecondary)
            }
        }
    }

    private func token(_ r: EmailAddress) -> some View {
        let valid = r.isValid
        return Menu {
            Text(r.address)
            Button("Copy Address", systemImage: "doc.on.doc") { UIPasteboard.general.string = r.address }
            Button("Remove", systemImage: "xmark", role: .destructive) { remove(r) }
        } label: {
            HStack(spacing: 3) {
                if !valid { Image(systemName: "exclamationmark.circle.fill").font(.caption) }
                Text(r.name ?? r.address).lineLimit(1)
            }
            .font(.subheadline)
            .foregroundStyle(valid ? Color.slate.accent : Color.slate.destructive)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(valid ? Color.slate.selectionFill : Color.slate.destructive.opacity(0.12), in: Capsule())
            .overlay { if !valid { Capsule().strokeBorder(Color.slate.destructive, lineWidth: 1) } }
        }
        .accessibilityLabel(valid ? (r.name.map { "\($0), \(r.address)" } ?? r.address) : "Invalid address \(r.address)")
        .accessibilityAction(named: "Remove") { remove(r) }
    }

    private func handleTyping(_ new: String) {
        // Commit on separators, including pasted lists of addresses.
        if new.contains(",") || new.contains(";") || new.contains("\n") || (new.contains(" ") && new.contains("@") && !new.contains("<")) {
            commit()
            return
        }
        let q = new.trimmingCharacters(in: .whitespaces)
        guard q.count >= 1, let store = model.store else { suggestions = []; return }
        let account = accountID
        let extra = extraSuggestions.filter { $0.address.localizedCaseInsensitiveContains(q) || ($0.name ?? "").localizedCaseInsensitiveContains(q) }
        Task {
            let recent = (try? await store.recipientSuggestions(accountID: account, prefix: q)) ?? []
            let existing = Set(recipients.map(\.normalized))
            var seen = Set<String>()
            suggestions = (recent + extra).filter { !existing.contains($0.normalized) && seen.insert($0.normalized).inserted }.prefix(5).map { $0 }
        }
    }

    private func commit() {
        let parsed = EmailAddress.parseList(text.replacingOccurrences(of: "\n", with: ","))
        if !parsed.isEmpty { add(parsed) }
        text = ""
        suggestions = []
    }

    private func add(_ list: [EmailAddress]) {
        var existing = Set(recipients.map(\.normalized))
        for a in list where existing.insert(a.normalized).inserted { recipients.append(a) }
        onChange()
    }

    private func remove(_ r: EmailAddress) {
        recipients.removeAll { $0.normalized == r.normalized }
        onChange()
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for (i, s) in subviews.enumerated() {
            var size = s.sizeThatFits(.unspecified)
            if i == subviews.count - 1 { size.width = max(size.width, min(120, width)) }
            size.width = min(size.width, width)
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for (i, s) in subviews.enumerated() {
            var size = s.sizeThatFits(.unspecified)
            let isLast = i == subviews.count - 1
            size.width = min(size.width, bounds.width)
            if x > bounds.minX && x + max(size.width, isLast ? 120 : 0) > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            if isLast { size.width = bounds.maxX - x }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
