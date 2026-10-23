import Foundation

/// A parsed subset of Gmail search syntax that can run against the local cache and be forwarded to Gmail.
///
/// Supported: free text, "quoted phrases", from: to: cc: subject: label: filename:, is:unread/read/starred/important,
/// has:attachment, after:/before: (YYYY/MM/DD or YYYY-MM-DD), in:inbox/sent/spam/trash/anywhere, OR, and -exclusion.
nonisolated struct SearchQuery: Equatable, Sendable {
    enum Term: Equatable, Sendable {
        case text(String)
        case phrase(String)
        case from(String), to(String), cc(String), subject(String), label(String), filename(String)
        case isUnread(Bool), isStarred, isImportant, hasAttachment
        case after(Date), before(Date)
        case inMailbox(String)
    }

    struct Clause: Equatable, Sendable {
        /// Terms joined with OR. A single term is the usual case.
        var alternatives: [Term]
        var negated: Bool
    }

    var raw: String
    var clauses: [Clause]

    var isEmpty: Bool { clauses.isEmpty }
    var includesSpamTrash: Bool {
        clauses.contains { c in c.alternatives.contains { if case .inMailbox(let m) = $0 { return ["anywhere", "spam", "trash"].contains(m) }; return false } }
    }

    // MARK: Parsing

    static func parse(_ input: String, calendar: Calendar = .current) -> SearchQuery {
        let tokens = tokenize(input)
        var clauses: [Clause] = []
        var pendingOr = false
        for tok in tokens {
            if tok == "OR" || tok == "|" { pendingOr = !clauses.isEmpty; continue }
            var negated = false
            var t = tok
            if t.hasPrefix("-") && t.count > 1 { negated = true; t.removeFirst() }
            guard let term = parseTerm(t, calendar: calendar) else { continue }
            if pendingOr, var last = clauses.popLast(), !last.negated, !negated {
                last.alternatives.append(term)
                clauses.append(last)
            } else {
                clauses.append(Clause(alternatives: [term], negated: negated))
            }
            pendingOr = false
        }
        return SearchQuery(raw: input, clauses: clauses)
    }

    static func tokenize(_ s: String) -> [String] {
        var tokens: [String] = []
        var cur = ""
        var inQuote = false, depth = 0
        for ch in s {
            if ch == "\"" { inQuote.toggle(); cur.append(ch); continue }
            if !inQuote && ch == "(" { depth += 1 }
            if !inQuote && ch == ")" { depth = max(0, depth - 1) }
            if ch.isWhitespace && !inQuote && depth == 0 {
                if !cur.isEmpty { tokens.append(cur); cur = "" }
            } else { cur.append(ch) }
        }
        if !cur.isEmpty { tokens.append(cur) }
        return tokens
    }

    private static func unquote(_ v: String) -> String {
        var v = v
        if (v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2) || (v.hasPrefix("(") && v.hasSuffix(")") && v.count >= 2) {
            v = String(v.dropFirst().dropLast())
        }
        return v.trimmingCharacters(in: .whitespaces)
    }

    static func parseDate(_ v: String, calendar: Calendar) -> Date? {
        let parts = v.split(whereSeparator: { $0 == "/" || $0 == "-" }).compactMap { Int($0) }
        if parts.count == 3 {
            return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        }
        if let secs = TimeInterval(v), secs > 100_000_000 { return Date(timeIntervalSince1970: secs) }
        return nil
    }

    private static func parseTerm(_ t: String, calendar: Calendar) -> Term? {
        if t.hasPrefix("\"") { let p = unquote(t); return p.isEmpty ? nil : .phrase(p) }
        guard let colon = t.firstIndex(of: ":"), colon != t.startIndex else { return .text(t) }
        let key = t[..<colon].lowercased()
        let value = unquote(String(t[t.index(after: colon)...]))
        guard !value.isEmpty else { return .text(t) }
        switch key {
        case "from": return .from(value)
        case "to": return .to(value)
        case "cc": return .cc(value)
        case "subject": return .subject(value)
        case "label": return .label(value)
        case "filename": return .filename(value)
        case "is":
            switch value.lowercased() {
            case "unread": return .isUnread(true)
            case "read": return .isUnread(false)
            case "starred": return .isStarred
            case "important": return .isImportant
            default: return .text(t)
            }
        case "has": return value.lowercased() == "attachment" ? .hasAttachment : .text(t)
        case "after", "newer": return parseDate(value, calendar: calendar).map(Term.after)
        case "before", "older": return parseDate(value, calendar: calendar).map(Term.before)
        case "in": return .inMailbox(value.lowercased())
        default: return .text(t)
        }
    }

    // MARK: Provider query

    /// Query string for Gmail. Dates become epoch seconds so they are interpreted in the user's time zone rather than Gmail's default.
    var providerQuery: String {
        clauses.map { c in
            let parts = c.alternatives.map(Self.providerString)
            let joined = parts.count > 1 ? "{" + parts.joined(separator: " ") + "}" : parts[0]
            return (c.negated ? "-" : "") + joined
        }.joined(separator: " ")
    }

    private static func q(_ v: String) -> String { v.contains(" ") ? "\"\(v)\"" : v }

    private static func providerString(_ t: Term) -> String {
        switch t {
        case .text(let s): s
        case .phrase(let s): "\"\(s)\""
        case .from(let s): "from:\(q(s))"
        case .to(let s): "to:\(q(s))"
        case .cc(let s): "cc:\(q(s))"
        case .subject(let s): "subject:\(q(s))"
        case .label(let s): "label:\(s.replacingOccurrences(of: " ", with: "-"))"
        case .filename(let s): "filename:\(q(s))"
        case .isUnread(let u): u ? "is:unread" : "is:read"
        case .isStarred: "is:starred"
        case .isImportant: "is:important"
        case .hasAttachment: "has:attachment"
        case .after(let d): "after:\(Int(d.timeIntervalSince1970))"
        case .before(let d): "before:\(Int(d.timeIntervalSince1970))"
        case .inMailbox(let m): "in:\(m)"
        }
    }

    // MARK: Local SQL

    private static func ftsLiteral(_ s: String, prefix: Bool) -> String {
        let cleaned = s.replacingOccurrences(of: "\"", with: "")
        return "\"\(cleaned)\"" + (prefix ? "*" : "")
    }

    func localSQL(accountIDs: [String], mailbox: Mailbox?, limit: Int) -> (sql: String, params: [SQLBindable]) {
        var params: [SQLBindable] = accountIDs
        let q = Array(repeating: "?", count: accountIDs.count).joined(separator: ",")
        var conditions: [String] = ["t.account_id IN (\(q))"]

        func fts(_ expr: String) -> String {
            params.append(expr)
            return "EXISTS (SELECT 1 FROM messages m JOIN messages_fts f ON f.rowid = m.rowid WHERE m.account_id=t.account_id AND m.thread_id=t.thread_id AND messages_fts MATCH ?)"
        }
        func hasLabel(_ id: String) -> String {
            params.append(id)
            return "EXISTS (SELECT 1 FROM thread_labels x WHERE x.account_id=t.account_id AND x.thread_id=t.thread_id AND x.label_id=?)"
        }
        func condition(_ term: Term) -> String {
            switch term {
            case .text(let s): return fts(Self.ftsLiteral(s, prefix: true))
            case .phrase(let s): return fts(Self.ftsLiteral(s, prefix: false))
            case .from(let s): return fts("sender : " + Self.ftsLiteral(s, prefix: true))
            case .to(let s), .cc(let s): return fts("recipients : " + Self.ftsLiteral(s, prefix: true))
            case .subject(let s): return fts("subject : " + Self.ftsLiteral(s, prefix: true))
            case .filename(let s): return fts("filenames : " + Self.ftsLiteral(s, prefix: true))
            case .label(let name):
                params.append(name.replacingOccurrences(of: "-", with: " ")); params.append(name); params.append(name.uppercased())
                return """
                EXISTS (SELECT 1 FROM thread_labels x WHERE x.account_id=t.account_id AND x.thread_id=t.thread_id AND
                (x.label_id IN (SELECT label_id FROM labels lb WHERE lb.account_id=t.account_id AND (lower(lb.name)=lower(?) OR lower(lb.name)=lower(?))) OR x.label_id=?))
                """
            case .isUnread(let u): return "t.is_unread = \(u ? 1 : 0)"
            case .isStarred: return "t.is_starred = 1"
            case .isImportant: return "t.is_important = 1"
            case .hasAttachment: return "t.has_attachment = 1"
            case .after(let d):
                params.append(d)
                return "EXISTS (SELECT 1 FROM messages m WHERE m.account_id=t.account_id AND m.thread_id=t.thread_id AND m.date >= ?)"
            case .before(let d):
                params.append(d)
                return "EXISTS (SELECT 1 FROM messages m WHERE m.account_id=t.account_id AND m.thread_id=t.thread_id AND m.date < ?)"
            case .inMailbox(let m):
                switch m {
                case "anywhere": return "1"
                case "inbox": return hasLabel(SystemLabel.inbox)
                case "sent": return hasLabel(SystemLabel.sent)
                case "spam": return hasLabel(SystemLabel.spam)
                case "trash": return hasLabel(SystemLabel.trash)
                case "starred": return hasLabel(SystemLabel.starred)
                default: return "1"
                }
            }
        }

        for c in clauses {
            let alt = c.alternatives.map(condition)
            let joined = alt.count > 1 ? "(" + alt.joined(separator: " OR ") + ")" : alt[0]
            conditions.append(c.negated ? "NOT \(joined)" : joined)
        }
        if !includesSpamTrash && mailbox != .spam && mailbox != .trash {
            conditions.append("NOT EXISTS (SELECT 1 FROM thread_labels x WHERE x.account_id=t.account_id AND x.thread_id=t.thread_id AND x.label_id IN ('SPAM','TRASH'))")
        }
        if let id = mailbox?.providerLabelID { conditions.append(hasLabel(id)) }

        params.append(limit)
        let sql = "SELECT t.*, lt.until AS later_until FROM threads t LEFT JOIN later lt ON lt.account_id=t.account_id AND lt.thread_id=t.thread_id WHERE "
            + conditions.joined(separator: " AND ") + " ORDER BY t.last_date DESC LIMIT ?"
        return (sql, params)
    }
}
