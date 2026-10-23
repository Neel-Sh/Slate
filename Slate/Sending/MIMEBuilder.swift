import Foundation

/// Builds RFC 5322 / MIME messages for submission. Incoming MIME is parsed by Gmail; only generation lives here.
nonisolated enum MIMEBuilder {
    struct Attachment: Sendable {
        var filename: String
        var mimeType: String
        var data: Data
    }

    struct Input: Sendable {
        var from: EmailAddress
        var to: [EmailAddress]
        var cc: [EmailAddress]
        var bcc: [EmailAddress]
        var subject: String
        var plain: String
        var html: String
        var inReplyTo: String?
        var references: String?
        var messageID: String
        var date: Date
        var attachments: [Attachment]
    }

    static func makeMessageID(fromAddress: String) -> String {
        let domain = fromAddress.split(separator: "@").last.map(String.init) ?? "slate.local"
        return "<\(UUID().uuidString.lowercased()).slate@\(domain)>"
    }

    static func build(_ input: Input, boundarySeed: String = UUID().uuidString) -> Data {
        var headers: [(String, String)] = [
            ("From", formatAddress(input.from)),
            ("Date", rfc2822Date(input.date)),
            ("Message-ID", input.messageID),
            ("Subject", encodeHeader(input.subject)),
            ("MIME-Version", "1.0"),
        ]
        if !input.to.isEmpty { headers.append(("To", input.to.map(formatAddress).joined(separator: ", "))) }
        if !input.cc.isEmpty { headers.append(("Cc", input.cc.map(formatAddress).joined(separator: ", "))) }
        // Gmail delivers to Bcc recipients and strips this header from the delivered copies.
        if !input.bcc.isEmpty { headers.append(("Bcc", input.bcc.map(formatAddress).joined(separator: ", "))) }
        if let r = input.inReplyTo, !r.isEmpty { headers.append(("In-Reply-To", r)) }
        if let r = input.references, !r.isEmpty { headers.append(("References", r)) }

        let alt = "alt-" + boundarySeed
        var altBody = ""
        altBody += "--\(alt)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n"
        altBody += base64Lines(Data(normalizeNewlines(input.plain).utf8)) + "\r\n"
        altBody += "--\(alt)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n"
        altBody += base64Lines(Data(input.html.utf8)) + "\r\n"
        altBody += "--\(alt)--\r\n"

        var out = ""
        if input.attachments.isEmpty {
            headers.append(("Content-Type", "multipart/alternative; boundary=\"\(alt)\""))
            out = headers.map { "\($0.0): \($0.1)" }.joined(separator: "\r\n") + "\r\n\r\n" + altBody
        } else {
            let mixed = "mixed-" + boundarySeed
            headers.append(("Content-Type", "multipart/mixed; boundary=\"\(mixed)\""))
            out = headers.map { "\($0.0): \($0.1)" }.joined(separator: "\r\n") + "\r\n\r\n"
            out += "--\(mixed)\r\nContent-Type: multipart/alternative; boundary=\"\(alt)\"\r\n\r\n" + altBody
            for a in input.attachments {
                let safeName = a.filename.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
                let asciiName = safeName.allSatisfy(\.isASCII) ? safeName : "attachment" + (URL(fileURLWithPath: safeName).pathExtension.isEmpty ? "" : "." + URL(fileURLWithPath: safeName).pathExtension)
                let encodedName = safeName.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: ".-_"))) ?? asciiName
                out += "--\(mixed)\r\n"
                out += "Content-Type: \(a.mimeType); name=\"\(asciiName)\"\r\n"
                out += "Content-Disposition: attachment; filename=\"\(asciiName)\"; filename*=UTF-8''\(encodedName)\r\n"
                out += "Content-Transfer-Encoding: base64\r\n\r\n"
                out += base64Lines(a.data) + "\r\n"
            }
            out += "--\(mixed)--\r\n"
        }
        return Data(out.utf8)
    }

    // MARK: Helpers

    static func normalizeNewlines(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
    }

    static func base64Lines(_ data: Data) -> String {
        data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
    }

    static func rfc2822Date(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f.string(from: date)
    }

    /// RFC 2047 encoded-word for non-ASCII header text, split so each word stays under 75 characters.
    static func encodeHeader(_ s: String) -> String {
        let clean = s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        if clean.allSatisfy({ $0.isASCII }) { return clean }
        var words: [String] = []
        var chunk = ""
        for ch in clean {
            let candidate = chunk + String(ch)
            if Data(candidate.utf8).base64EncodedString().count > 45 {
                words.append(chunk); chunk = String(ch)
            } else { chunk = candidate }
        }
        if !chunk.isEmpty { words.append(chunk) }
        return words.map { "=?UTF-8?B?\(Data($0.utf8).base64EncodedString())?=" }.joined(separator: "\r\n ")
    }

    static func formatAddress(_ a: EmailAddress) -> String {
        // Line breaks can never reach a header value.
        let address = a.address.components(separatedBy: .newlines).joined().trimmingCharacters(in: .whitespaces)
        guard let name = a.name?.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces), !name.isEmpty else { return address }
        if !name.allSatisfy({ $0.isASCII }) { return "\(encodeHeader(name)) <\(address)>" }
        let specials = CharacterSet(charactersIn: "()<>[]:;@\\,.\"")
        if name.unicodeScalars.contains(where: specials.contains) {
            return "\"\(name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" <\(address)>"
        }
        return "\(name) <\(address)>"
    }

    static func decodeEncodedWords(_ s: String) -> String {
        let regex = try! NSRegularExpression(pattern: "=\\?([^?]+)\\?([bBqQ])\\?([^?]*)\\?=(\\s+(?==\\?))?")
        let ns = s as NSString
        var result = ""
        var last = 0
        for m in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let enc = ns.substring(with: m.range(at: 2)).uppercased()
            let text = ns.substring(with: m.range(at: 3))
            if enc == "B", let d = Data(base64Encoded: text) { result += String(decoding: d, as: UTF8.self) }
            else { result += qDecode(text) }
            last = m.range.location + m.range.length
        }
        return result + ns.substring(from: last)
    }

    private static func qDecode(_ s: String) -> String {
        var bytes: [UInt8] = []
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "_" { bytes.append(0x20) }
            else if c == "=", let end = s.index(i, offsetBy: 3, limitedBy: s.endIndex), let b = UInt8(s[s.index(after: i)..<end], radix: 16) {
                bytes.append(b); i = s.index(before: end)
            } else { bytes.append(contentsOf: Array(String(c).utf8)) }
            i = s.index(after: i)
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
