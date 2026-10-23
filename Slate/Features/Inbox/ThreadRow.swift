import SwiftUI

struct ThreadRow: View {
    var thread: ThreadSummary
    var account: Account?
    var showAccount: Bool
    var chips: [MailLabel]
    var identities: Set<String>
    var showRecipients = false

    @Environment(\.dynamicTypeSize) private var typeSize

    private var senders: String {
        let others = thread.participants.filter { !identities.contains($0.normalized) }
        let includesMe = others.count < thread.participants.count
        var names = others.suffix(3).map { thread.participants.count > 1 ? $0.shortName : $0.displayName }
        if includesMe { names.append("me") }
        return names.isEmpty ? "(Unknown sender)" : names.joined(separator: ", ")
    }

    private var time: String { DateGrouping.rowTime(thread.lastDate) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            UnreadDot()
                .opacity(thread.isUnread ? 1 : 0)
                .frame(width: 10)
            .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 1 }

            VStack(alignment: .leading, spacing: 3) {
                if typeSize.isAccessibilitySize {
                    senderLine
                    metaLine
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                        senderLine
                        Spacer(minLength: Spacing.xs)
                        metaLine
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(thread.subject.isEmpty ? "(No subject)" : thread.subject)
                        .font(.callout)
                        .fontWeight(thread.isUnread ? .semibold : .medium)
                        .foregroundStyle(Color.slate.inkPrimary)
                        .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                    if !typeSize.isAccessibilitySize {
                        Spacer(minLength: 0)
                        chipView
                    }
                }
                if !thread.snippet.isEmpty {
                    Text(thread.snippet)
                        .font(.subheadline)
                        .foregroundStyle(Color.slate.inkSecondary)
                        .lineLimit(2)
                }
                if (typeSize.isAccessibilitySize && !chips.isEmpty) || thread.laterUntil.map({ $0 > .now }) == true {
                    footer
                }
            }
        }
        .padding(.vertical, Spacing.xs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var senderLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(senders)
                .font(.headline)
                .fontWeight(thread.isUnread ? .semibold : .regular)
                .foregroundStyle(Color.slate.inkPrimary)
                .lineLimit(1)
            if thread.messageCount > 1 {
                Text("\(thread.messageCount)")
                    .font(.footnote)
                    .foregroundStyle(Color.slate.inkMetadata)
            }
        }
    }

    private var metaLine: some View {
        HStack(spacing: 6) {
            if thread.labelIDs.contains(SystemLabel.draft) {
                Text("Draft").font(.footnote.weight(.medium)).foregroundStyle(Color.slate.destructive)
            }
            if thread.isStarred {
                Image(systemName: "star.fill").font(.caption2).foregroundStyle(Color.slate.warning)
            }
            if thread.hasAttachment {
                Image(systemName: "paperclip").font(.caption).foregroundStyle(Color.slate.inkMetadata)
            }
            if showAccount, let account { AccountTag(account: account) }
            Text(time)
                .font(.footnote)
                .foregroundStyle(Color.slate.inkMetadata)
                .lineLimit(1)
                .fixedSize()
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if let until = thread.laterUntil, until > .now {
                Label(until.formatted(.dateTime.weekday(.abbreviated).hour().minute()), systemImage: "clock")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.slate.inkSecondary)
            }
            if typeSize.isAccessibilitySize { chipView }
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    @ViewBuilder private var chipView: some View {
        if let l = chips.first {
            HStack(spacing: 4) {
                LabelChip(text: l.leafName, tone: ChipTone.forLabel(l.colorHex, name: l.name))
                if chips.count > 1 {
                    Text("+\(chips.count - 1)").font(.caption).foregroundStyle(Color.slate.inkMetadata)
                }
            }
            .layoutPriority(-1)
        }
    }

    private var accessibilityText: String {
        var parts: [String] = []
        if thread.isUnread { parts.append("Unread") }
        parts.append(senders)
        parts.append(thread.subject.isEmpty ? "No subject" : thread.subject)
        parts.append(time)
        if thread.messageCount > 1 { parts.append("\(thread.messageCount) messages") }
        if thread.hasAttachment { parts.append("Attachment") }
        if thread.isStarred { parts.append("Starred") }
        if let l = chips.first { parts.append("Label \(l.leafName)") }
        if showAccount, let account { parts.append(account.shortLabel) }
        parts.append(thread.snippet)
        return parts.joined(separator: ", ")
    }
}
