import Foundation
import CryptoKit
import Security

nonisolated struct OAuthTokens: Codable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var scope: String
}

/// Keychain storage for per-account OAuth tokens. Never written to logs, the database, or shared containers.
nonisolated enum TokenVault {
    private static let service = "com.neelsharma.Slate.oauth"

    static func save(_ tokens: OAuthTokens, accountID: String) throws {
        let data = try JSONEncoder().encode(tokens)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: accountID]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        // Available after first unlock so pending sends and background refresh can run while locked; never synced or migrated.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    static func load(accountID: String) -> OAuthTokens? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: accountID, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(OAuthTokens.self, from: data)
    }

    static func delete(accountID: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: accountID]
        SecItemDelete(query as CFDictionary)
    }
}

/// Google OAuth 2.0 for native apps: system browser session, PKCE (S256), state verification, custom-scheme redirect.
nonisolated struct GoogleOAuthConfig: Sendable {
    var clientID: String
    /// `gmail.modify` covers read, compose, send, labels, drafts, trash/untrash and spam moves. It cannot permanently delete.
    var scopes = ["https://www.googleapis.com/auth/gmail.modify"]

    var reversedClientID: String { clientID.split(separator: ".").reversed().joined(separator: ".") }
    var redirectScheme: String { reversedClientID }
    var redirectURI: String { "\(reversedClientID):/oauth2redirect" }

    static func fromBundle() -> GoogleOAuthConfig? {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "SlateGoogleClientID") as? String,
              id.hasSuffix(".apps.googleusercontent.com") else { return nil }
        return GoogleOAuthConfig(clientID: id)
    }
}

nonisolated struct PKCE: Sendable {
    let verifier: String
    let challenge: String
    let state: String

    init() {
        verifier = Self.randomURLSafe(bytes: 48)
        challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
        state = Self.randomURLSafe(bytes: 24)
    }

    static func randomURLSafe(bytes: Int) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return data.base64URLEncodedString()
    }
}

nonisolated enum GoogleOAuth {
    static func authorizationURL(config: GoogleOAuthConfig, pkce: PKCE, loginHint: String?) -> URL {
        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        c.queryItems = [
            .init(name: "client_id", value: config.clientID),
            .init(name: "redirect_uri", value: config.redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: config.scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: pkce.state),
            // select_account lets several Google accounts be added one after another.
            .init(name: "prompt", value: "select_account consent"),
        ]
        if let loginHint { c.queryItems?.append(.init(name: "login_hint", value: loginHint)) }
        return c.url!
    }

    /// Validates the redirect and returns the authorization code.
    static func code(from callback: URL, pkce: PKCE) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value {
            throw ProviderError.rejected(status: 400, message: error == "access_denied" ? "Access wasn't granted." : "Google sign-in failed (\(error)).")
        }
        guard items.first(where: { $0.name == "state" })?.value == pkce.state else {
            throw ProviderError.rejected(status: 400, message: "Sign-in response didn't match. Please try again.")
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw ProviderError.rejected(status: 400, message: "Google didn't return an authorization code.")
        }
        return code
    }

    static func exchange(code: String, config: GoogleOAuthConfig, pkce: PKCE, session: URLSession = .shared) async throws -> OAuthTokens {
        try await tokenRequest([
            "code": code, "client_id": config.clientID, "redirect_uri": config.redirectURI,
            "grant_type": "authorization_code", "code_verifier": pkce.verifier,
        ], previousRefresh: nil, session: session)
    }

    static func refresh(_ tokens: OAuthTokens, clientID: String, session: URLSession = .shared) async throws -> OAuthTokens {
        try await tokenRequest(["refresh_token": tokens.refreshToken, "client_id": clientID, "grant_type": "refresh_token"],
                               previousRefresh: tokens.refreshToken, session: session)
    }

    private static func tokenRequest(_ form: [String: String], previousRefresh: String?, session: URLSession) async throws -> OAuthTokens {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: req) } catch { throw ProviderError.offline }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        struct Body: Decodable { var access_token: String?; var refresh_token: String?; var expires_in: Double?; var scope: String?; var error: String? }
        let body = try? JSONDecoder().decode(Body.self, from: data)
        guard status == 200, let access = body?.access_token else {
            // invalid_grant: revoked, expired (7-day Testing-mode limit) or password change.
            if body?.error == "invalid_grant" || status == 400 || status == 401 { throw ProviderError.authenticationRequired }
            throw ProviderError.server(status: status)
        }
        guard let refresh = body?.refresh_token ?? previousRefresh else { throw ProviderError.authenticationRequired }
        return OAuthTokens(accessToken: access, refreshToken: refresh, expiresAt: Date().addingTimeInterval((body?.expires_in ?? 3600) - 60),
                           scope: body?.scope ?? "")
    }

    static func revoke(token: String) async {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = "token=\(token.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? "")".data(using: .utf8)
        _ = try? await URLSession.shared.data(for: req)
    }
}

/// Serializes token refresh for one account so concurrent requests share a single refresh.
actor TokenProvider {
    private let accountID: String
    private let clientID: String
    private var refreshing: Task<OAuthTokens, Error>?

    init(accountID: String, clientID: String) {
        self.accountID = accountID
        self.clientID = clientID
    }

    func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let tokens = TokenVault.load(accountID: accountID) else { throw ProviderError.authenticationRequired }
        if !forceRefresh && tokens.expiresAt > .now { return tokens.accessToken }
        if let refreshing { return try await refreshing.value.accessToken }
        let task = Task { [accountID, clientID] in
            let fresh = try await GoogleOAuth.refresh(tokens, clientID: clientID)
            try TokenVault.save(fresh, accountID: accountID)
            return fresh
        }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value.accessToken
    }
}

nonisolated extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b = b.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.count % 4 != 0 { b.append("=") }
        self.init(base64Encoded: b)
    }
}

nonisolated extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&+=?/:")
        return set
    }()
}
