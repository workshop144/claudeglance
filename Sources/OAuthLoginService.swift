import Foundation
import AppKit
import Security
import CryptoKit

// MARK: - OAuth configuration

/// Claude's public OAuth client used for browser sign-in. This is the same
/// PKCE public client the Claude Code CLI uses (no client secret), so a token
/// minted here carries the same scopes and works against the same
/// `/api/oauth/usage` endpoint ClaudeGlance reads.
///
/// Note: this is an *unofficial* reuse of Claude Code's public client — there's
/// no separate OAuth client registration for third-party usage apps. It works,
/// but Anthropic could change it; see SECURITY.md.
enum OAuthConfig {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let authorizeURL = "https://claude.ai/oauth/authorize"
    static let tokenURL = "https://console.anthropic.com/v1/oauth/token"
    /// The console "code" page the authorize flow redirects to; it displays a
    /// `code#state` string the user pastes back into ClaudeGlance.
    static let redirectURI = "https://console.anthropic.com/oauth/code/callback"
    static let scopes = "org:create_api_key user:profile user:inference"

    /// Our own Keychain item — created and owned by ClaudeGlance, so reading it
    /// never triggers the cross-app "allow access" password prompt that reading
    /// Claude Code's item did. Updated in place (never delete+re-add) so any ACL
    /// survives token refreshes.
    static let keychainService = "ClaudeGlance-credentials"
}

// MARK: - PKCE & callback parsing (pure, testable)

/// Base64url-encode without padding (RFC 7636 §A): `+`→`-`, `/`→`_`, drop `=`.
func base64URLEncode(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

/// A high-entropy PKCE code verifier (32 random bytes → 43-char base64url string).
func generateCodeVerifier(byteCount: Int = 32) -> String {
    var bytes = [UInt8](repeating: 0, count: byteCount)
    _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
    return base64URLEncode(Data(bytes))
}

/// The S256 code challenge for a verifier: base64url(SHA256(verifier)).
func codeChallenge(for verifier: String) -> String {
    let digest = SHA256.hash(data: Data(verifier.utf8))
    return base64URLEncode(Data(digest))
}

/// A random opaque `state` value to bind the request to the callback.
func generateState() -> String { generateCodeVerifier(byteCount: 32) }

/// Build the browser authorization URL for the PKCE flow.
func buildAuthorizationURL(clientID: String = OAuthConfig.clientID,
                           authorizeURL: String = OAuthConfig.authorizeURL,
                           redirectURI: String = OAuthConfig.redirectURI,
                           scope: String = OAuthConfig.scopes,
                           state: String,
                           challenge: String) -> URL {
    var components = URLComponents(string: authorizeURL)!
    components.queryItems = [
        URLQueryItem(name: "code", value: "true"),
        URLQueryItem(name: "client_id", value: clientID),
        URLQueryItem(name: "response_type", value: "code"),
        URLQueryItem(name: "redirect_uri", value: redirectURI),
        URLQueryItem(name: "scope", value: scope),
        URLQueryItem(name: "code_challenge", value: challenge),
        URLQueryItem(name: "code_challenge_method", value: "S256"),
        URLQueryItem(name: "state", value: state)
    ]
    return components.url!
}

/// Parse what the user pastes back from the console callback page. Accepts the
/// raw `code#state` the page shows, a bare code, or a full callback URL with
/// `?code=…&state=…`. Returns nil if no code can be found.
func parseAuthorizationCallback(_ pasted: String) -> (code: String, state: String?)? {
    let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    // Full URL form: pull code/state from the query.
    if trimmed.lowercased().hasPrefix("http"),
       let comps = URLComponents(string: trimmed),
       let code = comps.queryItems?.first(where: { $0.name == "code" })?.value {
        let state = comps.queryItems?.first(where: { $0.name == "state" })?.value
        return (code, state)
    }

    // `code#state` form (what the console page renders), or a bare code.
    let parts = trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
    let code = String(parts[0]).trimmingCharacters(in: .whitespaces)
    guard !code.isEmpty else { return nil }
    let state = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : nil
    return (code, state?.isEmpty == true ? nil : state)
}

/// Whether a token expiring at `expiresAt` should be refreshed now — true once
/// it's within `leeway` of expiry (default 5 min) so we never send a dead one.
func shouldRefreshToken(expiresAt: Date, now: Date = Date(), leeway: TimeInterval = 300) -> Bool {
    expiresAt.timeIntervalSince(now) <= leeway
}

// MARK: - Stored credentials & token response

/// What we persist in our own Keychain item. `expiresAt` is epoch seconds.
struct StoredCredentials: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Double

    var expiresAtDate: Date { Date(timeIntervalSince1970: expiresAt) }
}

/// The token endpoint response (`authorization_code` and `refresh_token` grants).
struct OAuthTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Double

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

// MARK: - OAuthLoginService

final class OAuthLoginService: ObservableObject {
    static let shared = OAuthLoginService()

    enum AuthState: Equatable {
        case signedOut
        case awaitingCode          // browser opened, waiting for the pasted code
        case signedIn(Date)        // associated value = current token expiry
        case error(String)
    }

    @Published private(set) var state: AuthState = .signedOut

    // Injectable for testing the token exchange/refresh network calls.
    var urlSession: URLSession = .shared

    // PKCE material for the in-flight login.
    private var pendingVerifier: String?
    private var pendingState: String?

    // In-memory token cache so each usage poll doesn't hit the Keychain. (Reading
    // our own item is unprompted and cheap, but the cache also lets a 401 force a
    // refresh on the next call via `needsRefresh`.)
    private var cachedAccessToken: String?
    private var cachedExpiresAt: Date?
    private var needsRefresh = false

    private init() {
        // Reflect any stored session on launch so the UI starts in the right state.
        if let creds = loadCredentials() {
            state = .signedIn(creds.expiresAtDate)
        }
    }

    var isSignedIn: Bool { loadCredentials() != nil }

    // MARK: Login flow

    /// Step 1: generate PKCE material and open the browser to authorize.
    @MainActor
    func beginLogin() {
        let verifier = generateCodeVerifier()
        let stateValue = generateState()
        pendingVerifier = verifier
        pendingState = stateValue
        let url = buildAuthorizationURL(state: stateValue, challenge: codeChallenge(for: verifier))
        state = .awaitingCode
        NSWorkspace.shared.open(url)
    }

    /// Step 2: exchange the pasted `code#state` for tokens and persist them.
    @MainActor
    func completeLogin(pastedInput: String) async {
        guard let verifier = pendingVerifier else {
            state = .error("Start sign-in first, then paste the code.")
            return
        }
        guard let parsed = parseAuthorizationCallback(pastedInput) else {
            state = .error("Couldn't read that code. Copy the whole value from the page.")
            return
        }
        // If the page returned a state, it must match the one we sent (CSRF guard).
        if let returned = parsed.state, let expected = pendingState, returned != expected {
            state = .error("Sign-in state mismatch — please try again.")
            return
        }
        do {
            let creds = try await exchangeCode(code: parsed.code,
                                               state: parsed.state ?? pendingState ?? "",
                                               verifier: verifier)
            try saveCredentials(creds)
            cache(creds)
            pendingVerifier = nil
            pendingState = nil
            state = .signedIn(creds.expiresAtDate)
            // Pull fresh usage immediately now that we're authenticated.
            UsageService.shared.fetchUsage(manual: true)
        } catch let error as NSError {
            state = .error("Sign-in failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    func signOut() {
        deleteCredentials()
        clearCache()
        pendingVerifier = nil
        pendingState = nil
        state = .signedOut
    }

    // MARK: Token access (used by UsageService)

    /// Drop the cached access token and force a refresh on the next call — used
    /// when the usage endpoint returns 401/403 (token rotated or rejected).
    func invalidateCache() {
        cachedAccessToken = nil
        cachedExpiresAt = nil
        needsRefresh = true
    }

    /// Return a valid bearer token, refreshing first if it's missing or near
    /// expiry. Throws if we're not signed in or the refresh token is dead.
    func validAccessToken() async throws -> String {
        if !needsRefresh, let token = cachedAccessToken, let exp = cachedExpiresAt,
           !shouldRefreshToken(expiresAt: exp) {
            return token
        }
        guard let creds = loadCredentials() else {
            await setState(.signedOut)
            throw OAuthLoginService.notSignedInError
        }
        if !needsRefresh, !shouldRefreshToken(expiresAt: creds.expiresAtDate) {
            cache(creds)
            return creds.accessToken
        }
        // Refresh.
        do {
            let fresh = try await refresh(refreshToken: creds.refreshToken)
            try saveCredentials(fresh)
            cache(fresh)
            needsRefresh = false
            await setState(.signedIn(fresh.expiresAtDate))
            return fresh.accessToken
        } catch let error as NSError {
            // A 400/401 from the token endpoint means the refresh token is dead —
            // sign out so the UI prompts a fresh login. Transient/network errors
            // (5xx, offline) keep the session so we can retry next poll.
            if error.code == 400 || error.code == 401 {
                deleteCredentials()
                clearCache()
                await setState(.signedOut)
                throw OAuthLoginService.sessionExpiredError
            }
            throw error
        }
    }

    static let notSignedInError = NSError(
        domain: "OAuth", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Sign in to Claude in Settings to see your usage."])
    static let sessionExpiredError = NSError(
        domain: "OAuth", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Session expired — sign in to Claude again in Settings."])

    // MARK: Network

    private func exchangeCode(code: String, state: String, verifier: String) async throws -> StoredCredentials {
        try await postToken(body: [
            "grant_type": "authorization_code",
            "code": code,
            "state": state,
            "client_id": OAuthConfig.clientID,
            "redirect_uri": OAuthConfig.redirectURI,
            "code_verifier": verifier
        ], fallbackRefreshToken: nil)
    }

    private func refresh(refreshToken: String) async throws -> StoredCredentials {
        try await postToken(body: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": OAuthConfig.clientID
        ], fallbackRefreshToken: refreshToken)
    }

    /// POST to the token endpoint and map the response to StoredCredentials. The
    /// refresh grant may omit a new refresh token; fall back to the existing one.
    private func postToken(body: [String: String], fallbackRefreshToken: String?) async throws -> StoredCredentials {
        var request = URLRequest(url: URL(string: OAuthConfig.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? "<no body>"
            throw NSError(domain: "OAuthToken", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(detail)"])
        }
        let token = try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
        guard let refreshToken = token.refreshToken ?? fallbackRefreshToken else {
            throw NSError(domain: "OAuthToken", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Token response had no refresh token."])
        }
        return StoredCredentials(accessToken: token.accessToken,
                                 refreshToken: refreshToken,
                                 expiresAt: Date().timeIntervalSince1970 + token.expiresIn)
    }

    // MARK: Keychain (our own item — no cross-app prompt)

    func loadCredentials() -> StoredCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: OAuthConfig.keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(StoredCredentials.self, from: data)
    }

    /// Persist credentials, updating the existing item in place when present so
    /// the user-granted ACL is preserved across refreshes (delete+re-add wipes it).
    private func saveCredentials(_ creds: StoredCredentials) throws {
        let data = try JSONEncoder().encode(creds)
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: OAuthConfig.keychainService
        ]
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemUpdate(match as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = match
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw NSError(domain: "Keychain", code: Int(addStatus),
                              userInfo: [NSLocalizedDescriptionKey: "Couldn't save credentials (status \(addStatus))."])
            }
        } else if status != errSecSuccess {
            throw NSError(domain: "Keychain", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't update credentials (status \(status))."])
        }
    }

    private func deleteCredentials() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: OAuthConfig.keychainService
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: Cache helpers

    private func cache(_ creds: StoredCredentials) {
        cachedAccessToken = creds.accessToken
        cachedExpiresAt = creds.expiresAtDate
    }

    private func clearCache() {
        cachedAccessToken = nil
        cachedExpiresAt = nil
        needsRefresh = false
    }

    @MainActor
    private func setState(_ newState: AuthState) { state = newState }
}
