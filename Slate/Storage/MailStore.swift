import Foundation

/// Durable local state: accounts, cached mail, drafts, outbox, pending operations, Later.
/// Server truth (messages/labels) is kept separate from app-owned state (drafts, outbox, later, rules).
actor MailStore {
    let db: Database

    init(database: Database) throws {
        self.db = database
        try Self.migrate(db)
    }

    static func openDefault() throws -> MailStore {
        let dir = try AppPaths.dataDirectory()
        let url = dir.appendingPathComponent("mail.sqlite")
        let db = try Database(path: url.path)
        try AppPaths.protect(url)
        return try MailStore(database: db)
    }

    // MARK: Schema

    static func migrate(_ db: Database) throws {
        if db.userVersion < 1 {
            try db.execute("""
            CREATE TABLE IF NOT EXISTS accounts (id TEXT PRIMARY KEY, sort_order INTEGER, json TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS labels (account_id TEXT, label_id TEXT, name TEXT, kind TEXT, color TEXT, unread INTEGER,
                PRIMARY KEY (account_id, label_id));
            CREATE TABLE IF NOT EXISTS messages (account_id TEXT NOT NULL, message_id TEXT NOT NULL, thread_id TEXT NOT NULL,
                date REAL, is_draft INTEGER, has_full_body INTEGER, json TEXT NOT NULL,
                PRIMARY KEY (account_id, message_id));
            CREATE INDEX IF NOT EXISTS messages_thread ON messages(account_id, thread_id);
            CREATE TABLE IF NOT EXISTS threads (account_id TEXT NOT NULL, thread_id TEXT NOT NULL, subject TEXT, snippet TEXT,
                last_date REAL, participants TEXT, message_count INTEGER, has_attachment INTEGER, is_unread INTEGER,
                is_starred INTEGER, is_important INTEGER, label_ids TEXT, latest_from TEXT, is_list INTEGER, to_me INTEGER,
                PRIMARY KEY (account_id, thread_id));
            CREATE INDEX IF NOT EXISTS threads_date ON threads(last_date DESC);
            CREATE TABLE IF NOT EXISTS thread_labels (account_id TEXT, thread_id TEXT, label_id TEXT,
                PRIMARY KEY (account_id, thread_id, label_id));
            CREATE INDEX IF NOT EXISTS thread_labels_label ON thread_labels(account_id, label_id);
            CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(subject, sender, recipients, body, filenames,
                tokenize = 'unicode61 remove_diacritics 2');
            CREATE TABLE IF NOT EXISTS drafts (id TEXT PRIMARY KEY, account_id TEXT, state TEXT, updated_at REAL, json TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS outbox (id TEXT PRIMARY KEY, account_id TEXT, draft_id TEXT, state TEXT NOT NULL,
                deadline REAL, created_at REAL, attempts INTEGER DEFAULT 0, failure TEXT, last_error TEXT,
                provider_message_id TEXT, sent_at REAL, next_attempt_at REAL, message_id_header TEXT, snapshot TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS operations (id TEXT PRIMARY KEY, account_id TEXT, created_at REAL, attempts INTEGER DEFAULT 0,
                next_attempt_at REAL, json TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS later (account_id TEXT, thread_id TEXT, until REAL, created_at REAL, notified INTEGER DEFAULT 0,
                PRIMARY KEY (account_id, thread_id));
            CREATE TABLE IF NOT EXISTS recipients (account_id TEXT, address TEXT, name TEXT, last_used REAL, use_count INTEGER,
                PRIMARY KEY (account_id, address));
            CREATE TABLE IF NOT EXISTS sender_rules (address TEXT PRIMARY KEY, rule TEXT);
            CREATE TABLE IF NOT EXISTS sync_state (account_id TEXT, key TEXT, value TEXT, PRIMARY KEY (account_id, key));
            """)
            db.userVersion = 1
        }
    }

    // MARK: Accounts

    func accounts() throws -> [Account] {
        try db.query("SELECT json FROM accounts ORDER BY sort_order, id").compactMap { $0.json("json", as: Account.self) }
    }

    func saveAccount(_ account: Account) throws {
        try db.execute("INSERT INTO accounts (id, sort_order, json) VALUES (?,?,?) ON CONFLICT(id) DO UPDATE SET sort_order=excluded.sort_order, json=excluded.json",
                       [account.id, account.sortOrder, JSON.encode(account)])
    }

    /// Removes the account and every piece of local content that belongs to it.
    func removeAccount(_ id: String) throws {
        try db.transaction {
            try db.execute("DELETE FROM messages_fts WHERE rowid IN (SELECT rowid FROM messages WHERE account_id = ?)", [id])
            for table in ["messages", "threads", "thread_labels", "labels", "drafts", "outbox", "operations", "later", "recipients", "sync_state"] {
                try db.execute("DELETE FROM \(table) WHERE account_id = ?", [id])
            }
            try db.execute("DELETE FROM accounts WHERE id = ?", [id])
        }
    }

    /// Clears cached server state while keeping app-owned drafts, outbox, Later and pending operations.
    func clearServerCache(accountID: String) throws {
        try db.transaction {
            try db.execute("DELETE FROM messages_fts WHERE rowid IN (SELECT rowid FROM messages WHERE account_id = ?)", [accountID])
            try db.execute("DELETE FROM messages WHERE account_id = ?", [accountID])
            try db.execute("DELETE FROM threads WHERE account_id = ?", [accountID])
            try db.execute("DELETE FROM thread_labels WHERE account_id = ?", [accountID])
        }
    }

    func syncValue(_ accountID: String, _ key: String) throws -> String? {
        try db.query("SELECT value FROM sync_state WHERE account_id=? AND key=?", [accountID, key]).first?.string("value")
    }

    func setSyncValue(_ accountID: String, _ key: String, _ value: String?) throws {
        if let value {
            try db.execute("INSERT INTO sync_state VALUES (?,?,?) ON CONFLICT(account_id,key) DO UPDATE SET value=excluded.value", [accountID, key, value])
        } else {
            try db.execute("DELETE FROM sync_state WHERE account_id=? AND key=?", [accountID, key])
        }
    }

    // MARK: Labels

    func replaceLabels(accountID: String, _ labels: [MailLabel]) throws {
        try db.transaction {
            try db.execute("DELETE FROM labels WHERE account_id = ?", [accountID])
            for l in labels {
                try db.execute("INSERT INTO labels VALUES (?,?,?,?,?,?)", [accountID, l.labelID, l.name, l.kind.rawValue, l.colorHex, l.unreadThreads])
            }
        }
    }

    func upsertLabel(_ l: MailLabel) throws {
        try db.execute("INSERT INTO labels VALUES (?,?,?,?,?,?) ON CONFLICT(account_id,label_id) DO UPDATE SET name=excluded.name, color=excluded.color",
                       [l.accountID, l.labelID, l.name, l.kind.rawValue, l.colorHex, l.unreadThreads])
    }

    func deleteLabel(accountID: String, labelID: String) throws {
        try db.transaction {
            try db.execute("DELETE FROM labels WHERE account_id=? AND label_id=?", [accountID, labelID])
            try db.execute("DELETE FROM thread_labels WHERE account_id=? AND label_id=?", [accountID, labelID])
        }
    }

    func labels(accountIDs: [String]) throws -> [MailLabel] {
        guard !accountIDs.isEmpty else { return [] }
        let q = Array(repeating: "?", count: accountIDs.count).joined(separator: ",")
        return try db.query("SELECT * FROM labels WHERE account_id IN (\(q)) ORDER BY account_id, name COLLATE NOCASE", accountIDs).map {
            MailLabel(accountID: $0.string("account_id")!, labelID: $0.string("label_id")!, name: $0.string("name") ?? "",
                      kind: MailLabel.Kind(rawValue: $0.string("kind") ?? "user") ?? .user, colorHex: $0.string("color"), unreadThreads: $0.int("unread"))
        }
    }

    // MARK: Messages & threads

    /// Inserts or replaces messages and recomputes their threads. Existing full bodies are kept when a metadata-only copy arrives.
    func upsertMessages(_ messages: [MailMessage], accountEmail: String) throws {
        guard !messages.isEmpty else { return }
        var touched = Set<ThreadRef>()
        try db.transaction {
            for var m in messages {
                if !m.hasFullBody, let existing = try message(accountID: m.accountID, id: m.id), existing.hasFullBody {
                    m.bodyPlain = existing.bodyPlain
                    m.bodyHTML = existing.bodyHTML
                    m.attachments = existing.attachments
                    m.hasFullBody = true
                }
                try db.execute("""
                INSERT INTO messages (account_id, message_id, thread_id, date, is_draft, has_full_body, json) VALUES (?,?,?,?,?,?,?)
                ON CONFLICT(account_id, message_id) DO UPDATE SET thread_id=excluded.thread_id, date=excluded.date,
                    is_draft=excluded.is_draft, has_full_body=excluded.has_full_body, json=excluded.json
                """, [m.accountID, m.id, m.threadID, m.date, m.labelIDs.contains(SystemLabel.draft), m.hasFullBody, JSON.encode(m)])
                if let rowid = try db.query("SELECT rowid FROM messages WHERE account_id=? AND message_id=?", [m.accountID, m.id]).first?.int("rowid") {
                    try db.execute("DELETE FROM messages_fts WHERE rowid = ?", [rowid])
                    try db.execute("INSERT INTO messages_fts (rowid, subject, sender, recipients, body, filenames) VALUES (?,?,?,?,?,?)", [
                        rowid, m.subject,
                        [m.from?.name, m.from?.address].compactMap { $0 }.joined(separator: " "),
                        (m.to + m.cc).map { "\($0.name ?? "") \($0.address)" }.joined(separator: " "),
                        m.bodyPlain ?? HTMLText.plainText(fromHTML: m.bodyHTML ?? "") ?? m.snippet,
                        m.attachments.map(\.filename).joined(separator: " "),
                    ])
                }
                touched.insert(ThreadRef(accountID: m.accountID, threadID: m.threadID))
            }
            for ref in touched { try recomputeThread(ref, accountEmail: accountEmail) }
        }
    }

    /// Replaces a thread's complete message set (used after fetching a thread from the provider).
    func replaceThread(_ ref: ThreadRef, messages: [MailMessage], accountEmail: String) throws {
        let keep = Set(messages.map(\.id))
        let existing = try db.query("SELECT message_id, rowid FROM messages WHERE account_id=? AND thread_id=?", [ref.accountID, ref.threadID])
        try db.transaction {
            for row in existing where !keep.contains(row.string("message_id") ?? "") {
                try db.execute("DELETE FROM messages_fts WHERE rowid = ?", [row.int("rowid") ?? -1])
                try db.execute("DELETE FROM messages WHERE account_id=? AND message_id=?", [ref.accountID, row.string("message_id")])
            }
        }
        if messages.isEmpty {
            try db.transaction { try recomputeThread(ref, accountEmail: accountEmail) }
        } else {
            try upsertMessages(messages, accountEmail: accountEmail)
        }
    }

    func deleteMessages(accountID: String, ids: [String], accountEmail: String) throws {
        var touched = Set<ThreadRef>()
        try db.transaction {
            for id in ids {
                guard let row = try db.query("SELECT rowid, thread_id FROM messages WHERE account_id=? AND message_id=?", [accountID, id]).first else { continue }
                try db.execute("DELETE FROM messages_fts WHERE rowid = ?", [row.int("rowid") ?? -1])
                try db.execute("DELETE FROM messages WHERE account_id=? AND message_id=?", [accountID, id])
                touched.insert(ThreadRef(accountID: accountID, threadID: row.string("thread_id") ?? ""))
            }
            for ref in touched { try recomputeThread(ref, accountEmail: accountEmail) }
        }
    }

    func message(accountID: String, id: String) throws -> MailMessage? {
        try db.query("SELECT json FROM messages WHERE account_id=? AND message_id=?", [accountID, id]).first?.json("json", as: MailMessage.self)
    }

    func messages(in ref: ThreadRef) throws -> [MailMessage] {
        try db.query("SELECT json FROM messages WHERE account_id=? AND thread_id=? ORDER BY date", [ref.accountID, ref.threadID])
            .compactMap { $0.json("json", as: MailMessage.self) }
    }

    func threadIDs(accountID: String, labelID: String, newerThan: Date) throws -> [String] {
        try db.query("""
            SELECT t.thread_id FROM threads t JOIN thread_labels l ON l.account_id=t.account_id AND l.thread_id=t.thread_id
            WHERE t.account_id=? AND l.label_id=? AND t.last_date >= ?
            """, [accountID, labelID, newerThan]).compactMap { $0.string("thread_id") }
    }

    /// Applies an optimistic label change to every message currently in the thread.
    func applyLabelChange(_ ref: ThreadRef, add: Set<String>, remove: Set<String>, accountEmail: String) throws {
        var msgs = try messages(in: ref)
        for i in msgs.indices {
            msgs[i].labelIDs.subtract(remove)
            msgs[i].labelIDs.formUnion(add)
        }
        try upsertMessages(msgs, accountEmail: accountEmail)
    }

    private func recomputeThread(_ ref: ThreadRef, accountEmail: String) throws {
        let msgs = try messages(in: ref)
        try db.execute("DELETE FROM thread_labels WHERE account_id=? AND thread_id=?", [ref.accountID, ref.threadID])
        let visible = msgs.filter { !$0.labelIDs.contains(SystemLabel.draft) }
        guard let latest = visible.last else {
            try db.execute("DELETE FROM threads WHERE account_id=? AND thread_id=?", [ref.accountID, ref.threadID])
            return
        }
        var labels = Set<String>()
        msgs.forEach { labels.formUnion($0.labelIDs) }
        if msgs.contains(where: { $0.labelIDs.contains(SystemLabel.draft) }) { labels.insert(SystemLabel.draft) }
        var participants: [EmailAddress] = []
        for m in visible {
            if let f = m.from, !participants.contains(where: { $0.normalized == f.normalized }) { participants.append(f) }
        }
        let me = accountEmail.lowercased()
        let toMe = (latest.to + latest.cc).contains { $0.normalized == me }
        let subject = visible.first(where: { !$0.subject.isEmpty })?.subject ?? ""
        try db.execute("""
            INSERT INTO threads VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(account_id, thread_id) DO UPDATE SET subject=excluded.subject, snippet=excluded.snippet,
              last_date=excluded.last_date, participants=excluded.participants, message_count=excluded.message_count,
              has_attachment=excluded.has_attachment, is_unread=excluded.is_unread, is_starred=excluded.is_starred,
              is_important=excluded.is_important, label_ids=excluded.label_ids, latest_from=excluded.latest_from,
              is_list=excluded.is_list, to_me=excluded.to_me
            """, [
            ref.accountID, ref.threadID, subject, latest.snippet, latest.date, JSON.encode(participants), visible.count,
            visible.contains { !$0.visibleAttachments.isEmpty || $0.probablyHasAttachment },
            visible.contains { $0.isUnread }, labels.contains(SystemLabel.starred), labels.contains(SystemLabel.important),
            JSON.encode(Array(labels).sorted()), JSON.encode(latest.from), latest.listID != nil || latest.listUnsubscribe != nil, toMe,
        ])
        for l in labels {
            try db.execute("INSERT OR IGNORE INTO thread_labels VALUES (?,?,?)", [ref.accountID, ref.threadID, l])
        }
    }

    // MARK: Listing

    nonisolated struct ListCursor: Sendable, Hashable {
        var date: Date
        var key: String
    }

    func threads(mailbox: Mailbox, accountIDs: [String], before cursor: ListCursor?, limit: Int, now: Date = .now) throws -> [ThreadSummary] {
        let ids = mailbox.labelAccountID.map { [$0] } ?? accountIDs
        guard !ids.isEmpty else { return [] }
        let q = Array(repeating: "?", count: ids.count).joined(separator: ",")
        var sql = "SELECT t.*, lt.until AS later_until FROM threads t LEFT JOIN later lt ON lt.account_id=t.account_id AND lt.thread_id=t.thread_id WHERE t.account_id IN (\(q))"
        var params: [SQLBindable] = ids
        func has(_ label: String) -> String {
            params.append(label)
            return " AND EXISTS (SELECT 1 FROM thread_labels x WHERE x.account_id=t.account_id AND x.thread_id=t.thread_id AND x.label_id=?)"
        }
        let excludeSpamTrash = " AND NOT EXISTS (SELECT 1 FROM thread_labels x WHERE x.account_id=t.account_id AND x.thread_id=t.thread_id AND x.label_id IN ('SPAM','TRASH'))"
        switch mailbox {
        case .inbox:
            sql += has(SystemLabel.inbox)
            sql += " AND (lt.until IS NULL OR lt.until <= ?)"
            params.append(now)
        case .later:
            sql += " AND lt.until > ?"
            params.append(now)
        case .allMail:
            sql += excludeSpamTrash
        case .spam, .trash:
            sql += has(mailbox.providerLabelID!)
        case .drafts, .outbox:
            return []
        default:
            sql += has(mailbox.providerLabelID!) + excludeSpamTrash
        }
        if let cursor {
            sql += " AND (t.last_date < ? OR (t.last_date = ? AND (t.account_id || '/' || t.thread_id) < ?))"
            params += [cursor.date, cursor.date, cursor.key]
        }
        sql += " ORDER BY t.last_date DESC, (t.account_id || '/' || t.thread_id) DESC LIMIT ?"
        params.append(limit)
        return try db.query(sql, params).map(Self.summary)
    }

    static func summary(_ r: SQLRow) -> ThreadSummary {
        ThreadSummary(
            ref: ThreadRef(accountID: r.string("account_id") ?? "", threadID: r.string("thread_id") ?? ""),
            subject: r.string("subject") ?? "", snippet: r.string("snippet") ?? "",
            lastDate: r.date("last_date") ?? .distantPast,
            participants: r.json("participants", as: [EmailAddress].self) ?? [],
            messageCount: r.int("message_count") ?? 1, hasAttachment: r.bool("has_attachment"),
            isUnread: r.bool("is_unread"), isStarred: r.bool("is_starred"), isImportant: r.bool("is_important"),
            labelIDs: Set(r.json("label_ids", as: [String].self) ?? []),
            latestFrom: r.json("latest_from", as: EmailAddress?.self) ?? nil,
            isMailingList: r.bool("is_list"), toMe: r.bool("to_me"), laterUntil: r.date("later_until"))
    }

    func thread(_ ref: ThreadRef) throws -> ThreadSummary? {
        try db.query("SELECT t.*, lt.until AS later_until FROM threads t LEFT JOIN later lt ON lt.account_id=t.account_id AND lt.thread_id=t.thread_id WHERE t.account_id=? AND t.thread_id=?",
                     [ref.accountID, ref.threadID]).first.map(Self.summary)
    }

    nonisolated struct Counts: Sendable, Equatable {
        var inboxUnread: [String: Int] = [:]
        var drafts = 0, outbox = 0, later = 0
        var labelUnread: [String: Int] = [:]
    }

    func counts(accountIDs: [String], now: Date = .now) throws -> Counts {
        var c = Counts()
        guard !accountIDs.isEmpty else { return c }
        let q = Array(repeating: "?", count: accountIDs.count).joined(separator: ",")
        for r in try db.query("""
            SELECT t.account_id, COUNT(*) AS n FROM threads t JOIN thread_labels l ON l.account_id=t.account_id AND l.thread_id=t.thread_id AND l.label_id='INBOX'
            LEFT JOIN later lt ON lt.account_id=t.account_id AND lt.thread_id=t.thread_id
            WHERE t.account_id IN (\(q)) AND t.is_unread=1 AND (lt.until IS NULL OR lt.until <= ?) GROUP BY t.account_id
            """, accountIDs + [now]) {
            c.inboxUnread[r.string("account_id") ?? ""] = r.int("n") ?? 0
        }
        for r in try db.query("""
            SELECT l.account_id, l.label_id, COUNT(*) AS n FROM thread_labels l JOIN threads t ON l.account_id=t.account_id AND l.thread_id=t.thread_id
            JOIN labels lb ON lb.account_id=l.account_id AND lb.label_id=l.label_id AND lb.kind='user'
            WHERE l.account_id IN (\(q)) AND t.is_unread=1 GROUP BY l.account_id, l.label_id
            """, accountIDs) {
            c.labelUnread[(r.string("account_id") ?? "") + "/" + (r.string("label_id") ?? "")] = r.int("n") ?? 0
        }
        c.drafts = try db.query("SELECT COUNT(*) AS n FROM drafts WHERE account_id IN (\(q)) AND state='editing'", accountIDs).first?.int("n") ?? 0
        c.outbox = try db.query("SELECT COUNT(*) AS n FROM outbox WHERE account_id IN (\(q)) AND state IN ('pending','queued','submitting','ambiguous','failed')", accountIDs).first?.int("n") ?? 0
        c.later = try db.query("SELECT COUNT(*) AS n FROM later WHERE account_id IN (\(q)) AND until > ?", accountIDs + [now]).first?.int("n") ?? 0
        return c
    }

    // MARK: Search

    func search(_ query: SearchQuery, accountIDs: [String], mailbox: Mailbox?, limit: Int = 100) throws -> [ThreadSummary] {
        guard !accountIDs.isEmpty else { return [] }
        let built = query.localSQL(accountIDs: accountIDs, mailbox: mailbox, limit: limit)
        return try db.query(built.sql, built.params).map(Self.summary)
    }

    // MARK: Drafts

    func saveDraft(_ draft: Draft) throws {
        try db.execute("INSERT INTO drafts VALUES (?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET account_id=excluded.account_id, state=excluded.state, updated_at=excluded.updated_at, json=excluded.json",
                       [draft.id, draft.accountID, draft.state.rawValue, draft.updatedAt, JSON.encode(draft)])
    }

    func draft(_ id: String) throws -> Draft? {
        try db.query("SELECT json FROM drafts WHERE id=?", [id]).first?.json("json", as: Draft.self)
    }

    func drafts(accountIDs: [String]) throws -> [Draft] {
        guard !accountIDs.isEmpty else { return [] }
        let q = Array(repeating: "?", count: accountIDs.count).joined(separator: ",")
        return try db.query("SELECT json FROM drafts WHERE account_id IN (\(q)) AND state='editing' ORDER BY updated_at DESC", accountIDs)
            .compactMap { $0.json("json", as: Draft.self) }
    }

    func deleteDraft(_ id: String) throws {
        try db.execute("DELETE FROM drafts WHERE id=?", [id])
    }

    // MARK: Outbox (compare-and-swap state transitions)

    func insertOutbox(_ item: OutboxItem, lockingDraft draft: Draft) throws {
        try db.transaction {
            var locked = draft
            locked.state = .inOutbox
            try saveDraft(locked)
            try db.execute("INSERT INTO outbox (id, account_id, draft_id, state, deadline, created_at, message_id_header, snapshot) VALUES (?,?,?,?,?,?,?,?)",
                           [item.id, item.accountID, item.draftID, item.state.rawValue, item.deadline, item.createdAt, item.messageIDHeader, JSON.encode(item.snapshot)])
        }
    }

    /// Atomically moves an item between states. Returns false if another transition won.
    func transitionOutbox(_ id: String, from: Set<OutboxState>, to: OutboxState) throws -> Bool {
        let q = from.map { "'\($0.rawValue)'" }.joined(separator: ",")
        return try db.execute("UPDATE outbox SET state=? WHERE id=? AND state IN (\(q))", [to.rawValue, id]) == 1
    }

    func updateOutbox(_ id: String, attempts: Int? = nil, failure: OutboxFailure?? = nil, lastError: String?? = nil,
                      providerMessageID: String? = nil, sentAt: Date? = nil, nextAttemptAt: Date?? = nil) throws {
        var sets: [String] = [], params: [SQLBindable] = []
        if let attempts { sets.append("attempts=?"); params.append(attempts) }
        if let failure { sets.append("failure=?"); params.append(failure?.rawValue) }
        if let lastError { sets.append("last_error=?"); params.append(lastError) }
        if let providerMessageID { sets.append("provider_message_id=?"); params.append(providerMessageID) }
        if let sentAt { sets.append("sent_at=?"); params.append(sentAt) }
        if let nextAttemptAt { sets.append("next_attempt_at=?"); params.append(nextAttemptAt) }
        guard !sets.isEmpty else { return }
        try db.execute("UPDATE outbox SET \(sets.joined(separator: ",")) WHERE id=?", params + [id])
    }

    func outboxItem(_ id: String) throws -> OutboxItem? {
        try db.query("SELECT * FROM outbox WHERE id=?", [id]).first.flatMap(Self.outbox)
    }

    func outboxItems(states: Set<OutboxState>? = nil) throws -> [OutboxItem] {
        var sql = "SELECT * FROM outbox"
        if let states { sql += " WHERE state IN (\(states.map { "'\($0.rawValue)'" }.joined(separator: ",")))" }
        return try db.query(sql + " ORDER BY created_at").compactMap(Self.outbox)
    }

    func deleteOutbox(_ id: String) throws { try db.execute("DELETE FROM outbox WHERE id=?", [id]) }

    func pruneSentOutbox(olderThan date: Date) throws {
        try db.execute("DELETE FROM outbox WHERE state IN ('sent','cancelled') AND created_at < ?", [date])
    }

    static func outbox(_ r: SQLRow) -> OutboxItem? {
        guard let snapshot = r.json("snapshot", as: Draft.self) else { return nil }
        return OutboxItem(id: r.string("id") ?? "", accountID: r.string("account_id") ?? "", draftID: r.string("draft_id") ?? "",
                          state: OutboxState(rawValue: r.string("state") ?? "") ?? .failed, deadline: r.date("deadline") ?? .now,
                          createdAt: r.date("created_at") ?? .now, attempts: r.int("attempts") ?? 0,
                          failure: r.string("failure").flatMap(OutboxFailure.init(rawValue:)), lastError: r.string("last_error"),
                          snapshot: snapshot, messageIDHeader: r.string("message_id_header") ?? "",
                          providerMessageID: r.string("provider_message_id"), sentAt: r.date("sent_at"), nextAttemptAt: r.date("next_attempt_at"))
    }

    // MARK: Pending provider operations

    func enqueueOperation(_ op: PendingOperation) throws {
        try db.execute("INSERT INTO operations (id, account_id, created_at, json) VALUES (?,?,?,?)", [op.id, op.accountID, op.createdAt, JSON.encode(op)])
    }

    func operations(accountID: String) throws -> [PendingOperation] {
        try db.query("SELECT json, attempts FROM operations WHERE account_id=? ORDER BY created_at", [accountID]).compactMap {
            var op = $0.json("json", as: PendingOperation.self)
            op?.attempts = $0.int("attempts") ?? 0
            return op
        }
    }

    func completeOperation(_ id: String) throws { try db.execute("DELETE FROM operations WHERE id=?", [id]) }

    func bumpOperation(_ id: String) throws { try db.execute("UPDATE operations SET attempts = attempts + 1 WHERE id=?", [id]) }

    // MARK: Later

    func setLater(_ ref: ThreadRef, until: Date?) throws {
        if let until {
            try db.execute("INSERT INTO later VALUES (?,?,?,?,0) ON CONFLICT(account_id,thread_id) DO UPDATE SET until=excluded.until, notified=0",
                           [ref.accountID, ref.threadID, until, Date.now])
        } else {
            try db.execute("DELETE FROM later WHERE account_id=? AND thread_id=?", [ref.accountID, ref.threadID])
        }
    }

    func laterEntries() throws -> [LaterEntry] {
        try db.query("SELECT * FROM later ORDER BY until").map {
            LaterEntry(ref: ThreadRef(accountID: $0.string("account_id") ?? "", threadID: $0.string("thread_id") ?? ""),
                       until: $0.date("until") ?? .now, createdAt: $0.date("created_at") ?? .now)
        }
    }

    // MARK: Recipients & rules

    func recordRecipients(accountID: String, _ addresses: [EmailAddress]) throws {
        for a in addresses where a.isValid {
            try db.execute("""
                INSERT INTO recipients VALUES (?,?,?,?,1) ON CONFLICT(account_id,address) DO UPDATE SET
                name=COALESCE(excluded.name, recipients.name), last_used=excluded.last_used, use_count=recipients.use_count+1
                """, [accountID, a.normalized, a.name, Date.now])
        }
    }

    func recipientSuggestions(accountID: String, prefix: String, limit: Int = 6) throws -> [EmailAddress] {
        let like = "%" + prefix.lowercased().replacingOccurrences(of: "%", with: "") + "%"
        return try db.query("""
            SELECT address, name FROM recipients WHERE account_id=? AND (address LIKE ? OR lower(name) LIKE ?)
            ORDER BY use_count DESC, last_used DESC LIMIT ?
            """, [accountID, like, like, limit]).map { EmailAddress(name: $0.string("name"), address: $0.string("address") ?? "") }
    }

    func isKnownCorrespondent(accountID: String, address: String) throws -> Bool {
        try !db.query("SELECT 1 FROM recipients WHERE account_id=? AND address=?", [accountID, address.lowercased()]).isEmpty
    }

    func knownCorrespondents(accountIDs: [String]) throws -> Set<String> {
        guard !accountIDs.isEmpty else { return [] }
        let q = Array(repeating: "?", count: accountIDs.count).joined(separator: ",")
        return Set(try db.query("SELECT account_id || '|' || address AS k FROM recipients WHERE account_id IN (\(q))", accountIDs).compactMap { $0.string("k") })
    }

    func senderRules() throws -> [String: String] {
        Dictionary(uniqueKeysWithValues: try db.query("SELECT * FROM sender_rules").compactMap { r in
            r.string("address").map { ($0, r.string("rule") ?? "") }
        })
    }

    func setSenderRule(_ address: String, rule: String?) throws {
        if let rule {
            try db.execute("INSERT INTO sender_rules VALUES (?,?) ON CONFLICT(address) DO UPDATE SET rule=excluded.rule", [address.lowercased(), rule])
        } else {
            try db.execute("DELETE FROM sender_rules WHERE address=?", [address.lowercased()])
        }
    }
}

/// A provider mutation that is applied optimistically and replayed until it succeeds.
nonisolated struct PendingOperation: Codable, Sendable, Identifiable {
    enum Kind: Codable, Sendable {
        case modify(threadID: String, add: [String], remove: [String])
        case trash(threadID: String)
        case untrash(threadID: String)
        case deleteRemoteDraft(draftID: String)
    }
    var id: String = UUID().uuidString
    var accountID: String
    var kind: Kind
    var createdAt: Date = .now
    var attempts: Int = 0
}
