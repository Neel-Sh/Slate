import UIKit

/// Turns a draft's editable body (plain text + optional RTF formatting) into the plain and HTML parts that are sent.
nonisolated enum DraftRenderer {
    static func attributedBody(_ draft: Draft) -> NSAttributedString {
        if let rtf = draft.bodyRTF,
           let a = try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
            return a
        }
        return NSAttributedString(string: draft.bodyText)
    }

    static func rtfData(_ a: NSAttributedString) -> Data? {
        try? a.data(from: NSRange(location: 0, length: a.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    static func render(_ draft: Draft) -> (plain: String, html: String) {
        let body = attributedBody(draft)
        var plain = body.string
        var html = "<div dir=\"auto\" style=\"font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:15px\">" + html(from: body)
        if let q = draft.quoted, draft.includeQuoted {
            plain += "\n\n" + q.attribution + "\n" + q.plain.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
            let inner = q.html ?? HTMLText.escape(q.plain).replacingOccurrences(of: "\n", with: "<br>")
            html += "<br><div>\(HTMLText.escape(q.attribution))</div>"
            html += "<blockquote style=\"margin:0 0 0 .8ex;border-left:1px solid #ccc;padding-left:1ex\">\(inner)</blockquote>"
        }
        html += "</div>"
        return (plain, html)
    }

    /// Minimal semantic HTML: paragraphs, bold, italic, links and bulleted lists ("• " lines).
    static func html(from a: NSAttributedString) -> String {
        let ns = a.string as NSString
        var out = ""
        var inList = false
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byParagraphs]) { text, range, _, _ in
            var content = range
            let isBullet = (text ?? "").hasPrefix("• ")
            if isBullet { content.location += 2; content.length -= 2 }
            let inner = runsHTML(a, range: content)
            if isBullet {
                if !inList { out += "<ul>"; inList = true }
                out += "<li>\(inner)</li>"
            } else {
                if inList { out += "</ul>"; inList = false }
                out += inner.isEmpty ? "<div><br></div>" : "<div>\(inner)</div>"
            }
        }
        if inList { out += "</ul>" }
        return out
    }

    private static func runsHTML(_ a: NSAttributedString, range: NSRange) -> String {
        guard range.length > 0 else { return "" }
        var out = ""
        a.enumerateAttributes(in: range) { attrs, r, _ in
            var t = HTMLText.escape((a.string as NSString).substring(with: r))
            if let font = attrs[.font] as? UIFont {
                let traits = font.fontDescriptor.symbolicTraits
                if traits.contains(.traitBold) { t = "<b>\(t)</b>" }
                if traits.contains(.traitItalic) { t = "<i>\(t)</i>" }
            }
            if let link = (attrs[.link] as? URL)?.absoluteString ?? attrs[.link] as? String,
               let scheme = URL(string: link)?.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
                t = "<a href=\"\(HTMLText.escape(link))\">\(t)</a>"
            }
            out += t
        }
        return out
    }
}

/// Builds reply, reply-all and forward drafts with correct recipients and threading headers.
nonisolated enum ReplyFactory {
    static func subject(_ s: String, kind: ComposeKind) -> String {
        let lower = s.lowercased()
        switch kind {
        case .reply, .replyAll: return lower.hasPrefix("re:") ? s : "Re: " + s
        case .forward: return lower.hasPrefix("fwd:") || lower.hasPrefix("fw:") ? s : "Fwd: " + s
        case .new: return s
        }
    }

    /// - Parameter identities: every address the user sends as (all connected accounts), removed from reply-all.
    static func draft(kind: ComposeKind, replyingTo m: MailMessage, account: Account, identities: Set<String>) -> Draft {
        var d = Draft(accountID: account.id, kind: kind)
        let mine = identities.union([account.email.lowercased()])
        let fromMe = mine.contains(m.from?.normalized ?? "")
        let primary = m.replyTo.isEmpty ? [m.from].compactMap { $0 } : m.replyTo

        switch kind {
        case .reply:
            d.to = fromMe ? m.to : primary
        case .replyAll:
            if fromMe {
                d.to = m.to
                d.cc = m.cc
            } else {
                d.to = primary + m.to.filter { !mine.contains($0.normalized) }
                d.cc = m.cc.filter { !mine.contains($0.normalized) }
            }
        case .forward, .new:
            break
        }
        // Never carry hidden recipients into a reply, and never list the same address twice.
        d.to = dedupe(d.to, excluding: [])
        d.cc = dedupe(d.cc, excluding: Set(d.to.map(\.normalized)))
        if kind == .replyAll && d.to.isEmpty, let first = d.cc.first { d.to = [first]; d.cc.removeFirst() }

        d.subject = subject(m.subject, kind: kind)
        if kind == .reply || kind == .replyAll {
            d.threadID = m.threadID
            d.inReplyTo = m.messageIDHeader
            d.references = [m.references, m.messageIDHeader].compactMap { $0 }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        }
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        let sender = m.from.map { $0.name.map { "\($0) <\(m.from!.address)>" } ?? $0.address } ?? "Unknown sender"
        let plain = m.bodyPlain ?? HTMLText.plainText(fromHTML: m.bodyHTML ?? "") ?? m.snippet
        if kind == .forward {
            let header = ["---------- Forwarded message ----------", "From: \(sender)", "Date: \(df.string(from: m.date))",
                          "Subject: \(m.subject)", "To: \(m.to.map(MIMEBuilder.formatAddress).joined(separator: ", "))"]
            d.quoted = QuotedContent(attribution: header.joined(separator: "\n"), plain: plain, html: m.bodyHTML.map(sanitizeQuotedHTML))
        } else {
            d.quoted = QuotedContent(attribution: "On \(df.string(from: m.date)), \(sender) wrote:", plain: plain, html: m.bodyHTML.map(sanitizeQuotedHTML))
        }
        applySignature(&d, signature: account.signature)
        return d
    }

    static func newDraft(account: Account) -> Draft {
        var d = Draft(accountID: account.id)
        applySignature(&d, signature: account.signature)
        return d
    }

    static func signatureBlock(_ signature: String) -> String {
        signature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\n\n" + signature.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Inserts a signature, or swaps the previous one if it is still present unchanged at the end of the body.
    static func applySignature(_ d: inout Draft, signature: String) {
        let newBlock = signatureBlock(signature)
        if !d.appliedSignature.isEmpty, d.bodyText.hasSuffix(d.appliedSignature) {
            d.bodyText = String(d.bodyText.dropLast(d.appliedSignature.count)) + newBlock
            d.bodyRTF = nil
        } else if d.appliedSignature.isEmpty && d.bodyText.isEmpty {
            d.bodyText = newBlock
        } else if d.appliedSignature.isEmpty {
            d.bodyText += newBlock
            d.bodyRTF = nil
        }
        d.appliedSignature = newBlock
    }

    static func dedupe(_ list: [EmailAddress], excluding: Set<String>) -> [EmailAddress] {
        var seen = excluding
        return list.filter { seen.insert($0.normalized).inserted }
    }

    /// Quoted HTML is kept as data only: scripts and event handlers are removed before it is re-sent.
    static func sanitizeQuotedHTML(_ html: String) -> String {
        var s = html.replacingOccurrences(of: "(?is)<script[^>]*>.*?</script>", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)\\son[a-z]+\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+)", with: "", options: .regularExpression)
        return s
    }
}
