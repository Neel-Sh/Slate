import Foundation

nonisolated enum AppPaths {
    /// Application Support/Slate — excluded from backup, protected until first unlock so background work can run.
    static func dataDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        var dir = base.appendingPathComponent("Slate", isDirectory: true)
        try ensure(&dir)
        return dir
    }

    /// Outgoing attachments copied in from Files/Photos. Kept until the message is sent or discarded.
    static func outgoingAttachments() throws -> URL {
        var dir = try dataDirectory().appendingPathComponent("Outgoing", isDirectory: true)
        try ensure(&dir)
        return dir
    }

    /// Downloaded incoming attachments; evictable cache.
    static func attachmentCache(accountID: String) throws -> URL {
        let base = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        var dir = base.appendingPathComponent("Attachments/\(accountID)", isDirectory: true)
        try ensure(&dir)
        return dir
    }

    static func removeAccountFiles(accountID: String) {
        if let dir = try? attachmentCache(accountID: accountID) { try? FileManager.default.removeItem(at: dir) }
    }

    private static func ensure(_ dir: inout URL) throws {
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
    }

    static func protect(_ url: URL) throws {
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
    }
}

nonisolated enum HTMLText {
    /// Fast, dependency-free HTML → text for indexing and previews. Not used for display.
    static func plainText(fromHTML html: String) -> String? {
        guard !html.isEmpty else { return nil }
        var s = html
        for (pattern, replacement) in [("(?is)<(script|style|head|title)[^>]*>.*?</\\1>", " "),
                                       ("(?i)<br\\s*/?>", "\n"), ("(?i)</(p|div|tr|li|h[1-6]|blockquote)>", "\n")] {
            s = s.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        s = decodeEntities(s)
        s = s.replacingOccurrences(of: "[ \\t\\u00A0]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\n\\s*\\n\\s*\\n+", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeEntities(_ s: String) -> String {
        var out = s
        let named = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'",
                     "&rsquo;": "\u{2019}", "&lsquo;": "\u{2018}", "&rdquo;": "\u{201D}", "&ldquo;": "\u{201C}", "&mdash;": "\u{2014}",
                     "&ndash;": "\u{2013}", "&hellip;": "\u{2026}", "&zwnj;": "", "&#8203;": ""]
        for (k, v) in named { out = out.replacingOccurrences(of: k, with: v) }
        if out.contains("&") {
            for (k, v) in latin1 { out = out.replacingOccurrences(of: "&\(k);", with: v) }
        }
        let regex = try! NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);")
        let ns = out as NSString
        var result = ""
        var last = 0
        for m in regex.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let hex = ns.substring(with: m.range(at: 1)) == "x"
            let num = ns.substring(with: m.range(at: 2))
            if let code = UInt32(num, radix: hex ? 16 : 10), let scalar = Unicode.Scalar(code) { result.append(Character(scalar)) }
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    /// Common named entities from HTML's Latin-1 set (the ones Gmail snippets use for accented text).
    private static let latin1: [String: String] = {
        let names = ["iexcl", "cent", "pound", "curren", "yen", "brvbar", "sect", "uml", "copy", "ordf", "laquo", "not", "shy", "reg", "macr",
                     "deg", "plusmn", "sup2", "sup3", "acute", "micro", "para", "middot", "cedil", "sup1", "ordm", "raquo", "frac14", "frac12",
                     "frac34", "iquest", "Agrave", "Aacute", "Acirc", "Atilde", "Auml", "Aring", "AElig", "Ccedil", "Egrave", "Eacute", "Ecirc",
                     "Euml", "Igrave", "Iacute", "Icirc", "Iuml", "ETH", "Ntilde", "Ograve", "Oacute", "Ocirc", "Otilde", "Ouml", "times",
                     "Oslash", "Ugrave", "Uacute", "Ucirc", "Uuml", "Yacute", "THORN", "szlig", "agrave", "aacute", "acirc", "atilde", "auml",
                     "aring", "aelig", "ccedil", "egrave", "eacute", "ecirc", "euml", "igrave", "iacute", "icirc", "iuml", "eth", "ntilde",
                     "ograve", "oacute", "ocirc", "otilde", "ouml", "divide", "oslash", "ugrave", "uacute", "ucirc", "uuml", "yacute", "thorn", "yuml"]
        var map: [String: String] = ["euro": "\u{20AC}", "trade": "\u{2122}", "bull": "\u{2022}"]
        for (i, n) in names.enumerated() { map[n] = String(Character(Unicode.Scalar(0xA1 + i)!)) }
        return map
    }()

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
