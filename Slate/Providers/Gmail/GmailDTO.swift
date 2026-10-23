import Foundation

/// Wire types for the Gmail REST API (v1).
nonisolated enum GmailDTO {
    struct Profile: Decodable { var emailAddress: String; var historyId: String }

    struct Header: Decodable { var name: String; var value: String }
    struct Body: Decodable { var attachmentId: String?; var size: Int?; var data: String? }
    struct Part: Decodable {
        var partId: String?
        var mimeType: String?
        var filename: String?
        var headers: [Header]?
        var body: Body?
        var parts: [Part]?

        func header(_ name: String) -> String? { headers?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value }
    }
    struct Message: Decodable {
        var id: String
        var threadId: String
        var labelIds: [String]?
        var snippet: String?
        var historyId: String?
        var internalDate: String?
        var payload: Part?
        var sizeEstimate: Int?
    }
    struct Thread: Decodable { var id: String; var historyId: String?; var messages: [Message]? }
    struct ThreadList: Decodable {
        struct Item: Decodable { var id: String }
        var threads: [Item]?
        var nextPageToken: String?
    }
    struct MessageList: Decodable {
        struct Item: Decodable { var id: String; var threadId: String }
        var messages: [Item]?
    }
    struct HistoryList: Decodable {
        struct MessageRef: Decodable { var message: Message }
        struct LabelChange: Decodable { var message: Message; var labelIds: [String]? }
        struct Record: Decodable {
            var id: String
            var messagesAdded: [MessageRef]?
            var messagesDeleted: [MessageRef]?
            var labelsAdded: [LabelChange]?
            var labelsRemoved: [LabelChange]?
        }
        var history: [Record]?
        var nextPageToken: String?
        var historyId: String
    }
    struct Label: Decodable {
        struct Color: Decodable { var textColor: String?; var backgroundColor: String? }
        var id: String
        var name: String
        var type: String?
        var threadsUnread: Int?
        var color: Color?
        var labelListVisibility: String?
    }
    struct LabelList: Decodable { var labels: [Label]? }
    struct Draft: Decodable { var id: String; var message: Message? }
    struct Attachment: Decodable { var data: String? }
    struct ErrorBody: Decodable {
        struct Inner: Decodable { var code: Int?; var message: String?; var status: String? }
        var error: Inner?
    }
}

/// Converts Gmail's server-parsed MIME tree into our message model.
/// Gmail decodes the transfer encoding; we still honour each part's declared charset.
nonisolated enum GmailMapper {
    static func message(_ m: GmailDTO.Message, accountID: String, full: Bool) -> MailMessage {
        let p = m.payload
        let date = m.internalDate.flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) } ?? .now
        var msg = MailMessage(accountID: accountID, id: m.id, threadID: m.threadId, date: date)
        msg.labelIDs = Set(m.labelIds ?? [])
        msg.snippet = HTMLText.decodeEntities(m.snippet ?? "")
        msg.subject = p?.header("Subject") ?? ""
        msg.from = p?.header("From").flatMap { EmailAddress.parseList($0).first }
        msg.to = p?.header("To").map(EmailAddress.parseList) ?? []
        msg.cc = p?.header("Cc").map(EmailAddress.parseList) ?? []
        msg.bcc = p?.header("Bcc").map(EmailAddress.parseList) ?? []
        msg.replyTo = p?.header("Reply-To").map(EmailAddress.parseList) ?? []
        msg.messageIDHeader = p?.header("Message-ID") ?? p?.header("Message-Id")
        msg.references = p?.header("References")
        msg.inReplyTo = p?.header("In-Reply-To")
        msg.listUnsubscribe = p?.header("List-Unsubscribe")
        msg.listID = p?.header("List-Id")
        msg.probablyHasAttachment = (p?.mimeType ?? "").lowercased() == "multipart/mixed"
        if full, let p {
            var plain: String?, html: String?, attachments: [AttachmentInfo] = []
            walk(p, plain: &plain, html: &html, attachments: &attachments)
            msg.bodyPlain = plain
            msg.bodyHTML = html
            msg.attachments = attachments
            msg.hasFullBody = true
            msg.probablyHasAttachment = attachments.contains { !$0.isInline || $0.contentID == nil }
        }
        return msg
    }

    static func walk(_ part: GmailDTO.Part, plain: inout String?, html: inout String?, attachments: inout [AttachmentInfo]) {
        let mime = (part.mimeType ?? "").lowercased()
        let disposition = (part.header("Content-Disposition") ?? "").lowercased()
        let filename = part.filename ?? ""
        let isAttachment = !filename.isEmpty || disposition.hasPrefix("attachment") || (part.body?.attachmentId != nil && !mime.hasPrefix("text/"))
        if mime.hasPrefix("multipart/") {
            part.parts?.forEach { walk($0, plain: &plain, html: &html, attachments: &attachments) }
            return
        }
        if isAttachment {
            let cid = part.header("Content-ID")?.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
            attachments.append(AttachmentInfo(
                attachmentID: part.body?.attachmentId, partID: part.partId ?? UUID().uuidString,
                filename: filename.isEmpty ? (cid ?? "attachment") : filename, mimeType: mime, size: part.body?.size ?? 0,
                contentID: cid, isInline: disposition.hasPrefix("inline") || (cid != nil && !disposition.hasPrefix("attachment")),
                inlineData: part.body?.data.flatMap { Data(base64URLEncoded: $0) }))
            return
        }
        guard let data = part.body?.data.flatMap({ Data(base64URLEncoded: $0) }) else { return }
        let text = decode(data, contentType: part.header("Content-Type"))
        if mime == "text/plain", plain == nil { plain = text }
        else if mime == "text/html", html == nil { html = text }
        else if mime == "text/plain" { plain = (plain ?? "") + "\n" + text }
    }

    static func decode(_ data: Data, contentType: String?) -> String {
        if let ct = contentType?.lowercased(), let range = ct.range(of: "charset=") {
            let charset = ct[range.upperBound...].split(whereSeparator: { $0 == ";" || $0 == " " }).first
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) } ?? "utf-8"
            let cf = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            if cf != kCFStringEncodingInvalidId {
                let enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
                if let s = String(data: data, encoding: enc) { return s }
            }
        }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    static func label(_ l: GmailDTO.Label, accountID: String) -> MailLabel {
        MailLabel(accountID: accountID, labelID: l.id, name: displayName(l), kind: l.type == "system" ? .system : .user,
                  colorHex: l.color?.backgroundColor, unreadThreads: l.threadsUnread)
    }

    private static func displayName(_ l: GmailDTO.Label) -> String {
        switch l.id {
        case "CATEGORY_PERSONAL": "Primary"
        case "CATEGORY_SOCIAL": "Social"
        case "CATEGORY_PROMOTIONS": "Promotions"
        case "CATEGORY_UPDATES": "Updates"
        case "CATEGORY_FORUMS": "Forums"
        default: l.name
        }
    }
}
