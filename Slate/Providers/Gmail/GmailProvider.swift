import Foundation

/// Gmail REST client for one account. All requests carry that account's token only.
nonisolated final class GmailProvider: MailProvider, @unchecked Sendable {
    private let tokens: TokenProvider
    private let accountID: String
    private let session: URLSession
    private let api = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/")!
    private let upload = URL(string: "https://gmail.googleapis.com/upload/gmail/v1/users/me/")!

    init(accountID: String, clientID: String, session: URLSession = GmailProvider.defaultSession) {
        self.accountID = accountID
        self.tokens = TokenProvider(accountID: accountID, clientID: clientID)
        self.session = session
    }

    static let defaultSession: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.waitsForConnectivity = false
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    // MARK: Transport

    private func request(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil,
                         contentType: String = "application/json", base: URL? = nil) async throws -> Data {
        var comps = URLComponents(url: (base ?? api).appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var attempt = 0
        var forceRefresh = false
        while true {
            attempt += 1
            var req = URLRequest(url: comps.url!)
            req.httpMethod = method
            req.httpBody = body
            if body != nil { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
            req.setValue("Bearer \(try await tokens.accessToken(forceRefresh: forceRefresh))", forHTTPHeaderField: "Authorization")
            let data: Data, response: URLResponse
            do {
                (data, response) = try await session.data(for: req)
            } catch let error as URLError {
                switch error.code {
                case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff:
                    throw ProviderError.offline
                case .cancelled: throw CancellationError()
                default: throw ProviderError.indeterminate(error.localizedDescription)
                }
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200..<300: return data
            case 401 where attempt == 1:
                forceRefresh = true
                continue
            case 401: throw ProviderError.authenticationRequired
            case 404: throw ProviderError.notFound
            case 429, 403 where Self.isRateLimit(data):
                let retry = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
                if attempt < 3 && method == "GET" {
                    try await Task.sleep(for: .seconds(retry ?? Double(attempt * 2)))
                    continue
                }
                throw ProviderError.rateLimited(retryAfter: retry)
            case 500..<600:
                if attempt < 3 && method == "GET" { try await Task.sleep(for: .seconds(Double(attempt))); continue }
                throw ProviderError.server(status: status)
            default:
                let message = (try? JSONDecoder().decode(GmailDTO.ErrorBody.self, from: data))?.error?.message ?? "Request failed (\(status))."
                throw ProviderError.rejected(status: status, message: message)
            }
        }
    }

    private static func isRateLimit(_ data: Data) -> Bool {
        let s = String(decoding: data, as: UTF8.self)
        return s.contains("rateLimitExceeded") || s.contains("userRateLimitExceeded")
    }

    private func get<T: Decodable>(_ path: String, _ query: [URLQueryItem] = [], as: T.Type) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await request("GET", path, query: query))
    }

    private func json(_ obj: [String: Any]) -> Data { (try? JSONSerialization.data(withJSONObject: obj)) ?? Data() }

    /// multipart/related upload: JSON metadata + message/rfc822. Supports messages up to Gmail's 35 MB upload limit.
    private func uploadMessage(_ method: String, _ path: String, metadata: [String: Any], raw: Data) async throws -> Data {
        let boundary = "slate-" + UUID().uuidString
        var body = Data()
        body.append("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        body.append(json(metadata))
        body.append("\r\n--\(boundary)\r\nContent-Type: message/rfc822\r\n\r\n".data(using: .utf8)!)
        body.append(raw)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        return try await request(method, path, query: [.init(name: "uploadType", value: "multipart")], body: body,
                                 contentType: "multipart/related; boundary=\(boundary)", base: upload)
    }

    // MARK: MailProvider

    func profile() async throws -> ProviderProfile {
        let p = try await get("profile", as: GmailDTO.Profile.self)
        return ProviderProfile(email: p.emailAddress, historyID: p.historyId)
    }

    func labels(accountID: String) async throws -> [MailLabel] {
        let list = try await get("labels", as: GmailDTO.LabelList.self)
        var result: [MailLabel] = []
        for l in list.labels ?? [] where l.labelListVisibility != "labelHide" || l.type != "system" {
            result.append(GmailMapper.label(l, accountID: accountID))
        }
        return result
    }

    func listThreads(labelID: String?, query: String?, includeSpamTrash: Bool, pageToken: String?, maxResults: Int) async throws -> ThreadPage {
        var q: [URLQueryItem] = [.init(name: "maxResults", value: String(maxResults))]
        if let labelID { q.append(.init(name: "labelIds", value: labelID)) }
        if let query, !query.isEmpty { q.append(.init(name: "q", value: query)) }
        if includeSpamTrash { q.append(.init(name: "includeSpamTrash", value: "true")) }
        if let pageToken { q.append(.init(name: "pageToken", value: pageToken)) }
        let list = try await get("threads", q, as: GmailDTO.ThreadList.self)
        return ThreadPage(threadIDs: list.threads?.map(\.id) ?? [], nextPageToken: list.nextPageToken)
    }

    private static let metadataHeaders = ["From", "To", "Cc", "Subject", "Date", "Reply-To", "Message-ID", "References", "In-Reply-To", "List-Unsubscribe", "List-Id"]

    func thread(id: String, accountID: String, full: Bool) async throws -> [MailMessage] {
        var q: [URLQueryItem] = [.init(name: "format", value: full ? "full" : "metadata")]
        if !full { q += Self.metadataHeaders.map { .init(name: "metadataHeaders", value: $0) } }
        var t = try await get("threads/\(id)", q, as: GmailDTO.Thread.self)
        if full, var messages = t.messages {
            for i in messages.indices {
                if let payload = messages[i].payload {
                    messages[i].payload = try await resolveLargeBodies(payload, messageID: messages[i].id)
                }
            }
            t.messages = messages
        }
        return (t.messages ?? []).map { GmailMapper.message($0, accountID: accountID, full: full) }
    }

    /// Large text bodies arrive as attachment references; fetch them so the reader has the full text.
    private func resolveLargeBodies(_ part: GmailDTO.Part, messageID: String) async throws -> GmailDTO.Part {
        var part = part
        let mime = (part.mimeType ?? "").lowercased()
        if (mime == "text/plain" || mime == "text/html"), (part.filename ?? "").isEmpty, part.body?.data == nil,
           let attachmentID = part.body?.attachmentId {
            let data = try await attachment(messageID: messageID, attachmentID: attachmentID)
            part.body?.data = data.base64URLEncodedString()
            part.body?.attachmentId = nil
        }
        if let parts = part.parts {
            var resolved: [GmailDTO.Part] = []
            for p in parts { resolved.append(try await resolveLargeBodies(p, messageID: messageID)) }
            part.parts = resolved
        }
        return part
    }

    func history(since historyID: String) async throws -> HistoryDelta {
        var delta = HistoryDelta(newHistoryID: historyID)
        var pageToken: String?
        repeat {
            var q: [URLQueryItem] = [.init(name: "startHistoryId", value: historyID), .init(name: "maxResults", value: "500")]
            for t in ["messageAdded", "messageDeleted", "labelAdded", "labelRemoved"] { q.append(.init(name: "historyTypes", value: t)) }
            if let pageToken { q.append(.init(name: "pageToken", value: pageToken)) }
            let page: GmailDTO.HistoryList
            do { page = try await get("history", q, as: GmailDTO.HistoryList.self) }
            catch ProviderError.notFound { throw ProviderError.historyExpired }
            for r in page.history ?? [] {
                for a in r.messagesAdded ?? [] {
                    delta.changedThreadIDs.insert(a.message.threadId)
                    if (a.message.labelIds ?? []).contains(SystemLabel.inbox) { delta.addedInboxMessageIDs.insert(a.message.id) }
                }
                for d in r.messagesDeleted ?? [] {
                    delta.deletedMessageIDs.insert(d.message.id)
                    delta.changedThreadIDs.insert(d.message.threadId)
                }
                for c in (r.labelsAdded ?? []) + (r.labelsRemoved ?? []) { delta.changedThreadIDs.insert(c.message.threadId) }
            }
            delta.newHistoryID = page.historyId
            pageToken = page.nextPageToken
        } while pageToken != nil
        return delta
    }

    func modifyThread(id: String, add: [String], remove: [String]) async throws {
        _ = try await request("POST", "threads/\(id)/modify", body: json(["addLabelIds": add, "removeLabelIds": remove]))
    }

    func trashThread(id: String) async throws { _ = try await request("POST", "threads/\(id)/trash") }
    func untrashThread(id: String) async throws { _ = try await request("POST", "threads/\(id)/untrash") }

    func send(raw: Data, threadID: String?) async throws -> SentMessage {
        var meta: [String: Any] = [:]
        if let threadID { meta["threadId"] = threadID }
        let data = try await uploadMessage("POST", "messages/send", metadata: meta, raw: raw)
        let m = try JSONDecoder().decode(GmailDTO.Message.self, from: data)
        return SentMessage(id: m.id, threadID: m.threadId)
    }

    func findMessage(rfc822MessageID: String) async throws -> String? {
        let id = rfc822MessageID.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        let list = try await get("messages", [.init(name: "q", value: "rfc822msgid:\(id)"), .init(name: "includeSpamTrash", value: "true")],
                                 as: GmailDTO.MessageList.self)
        return list.messages?.first?.id
    }

    func createDraft(raw: Data, threadID: String?) async throws -> RemoteDraft {
        var message: [String: Any] = [:]
        if let threadID { message["threadId"] = threadID }
        let d = try JSONDecoder().decode(GmailDTO.Draft.self, from: try await uploadMessage("POST", "drafts", metadata: ["message": message], raw: raw))
        return RemoteDraft(draftID: d.id, messageID: d.message?.id ?? "")
    }

    func updateDraft(id: String, raw: Data, threadID: String?) async throws -> RemoteDraft {
        var message: [String: Any] = [:]
        if let threadID { message["threadId"] = threadID }
        let d = try JSONDecoder().decode(GmailDTO.Draft.self,
                                         from: try await uploadMessage("PUT", "drafts/\(id)", metadata: ["id": id, "message": message], raw: raw))
        return RemoteDraft(draftID: d.id, messageID: d.message?.id ?? "")
    }

    func remoteDraftMessageID(id: String) async throws -> String? {
        do { return try await get("drafts/\(id)", [.init(name: "format", value: "minimal")], as: GmailDTO.Draft.self).message?.id }
        catch ProviderError.notFound { return nil }
    }

    func deleteDraft(id: String) async throws {
        do { _ = try await request("DELETE", "drafts/\(id)") } catch ProviderError.notFound {}
    }

    func attachment(messageID: String, attachmentID: String) async throws -> Data {
        let a = try await get("messages/\(messageID)/attachments/\(attachmentID)", as: GmailDTO.Attachment.self)
        guard let s = a.data, let d = Data(base64URLEncoded: s) else { throw ProviderError.notFound }
        return d
    }

    func createLabel(name: String, accountID: String) async throws -> MailLabel {
        let data = try await request("POST", "labels", body: json(["name": name, "labelListVisibility": "labelShow", "messageListVisibility": "show"]))
        return GmailMapper.label(try JSONDecoder().decode(GmailDTO.Label.self, from: data), accountID: accountID)
    }

    func renameLabel(id: String, name: String, accountID: String) async throws -> MailLabel {
        let data = try await request("PATCH", "labels/\(id)", body: json(["name": name]))
        return GmailMapper.label(try JSONDecoder().decode(GmailDTO.Label.self, from: data), accountID: accountID)
    }

    func deleteLabel(id: String) async throws { _ = try await request("DELETE", "labels/\(id)") }

    func revoke() async {
        if let t = TokenVault.load(accountID: accountID) { await GoogleOAuth.revoke(token: t.refreshToken) }
    }
}
