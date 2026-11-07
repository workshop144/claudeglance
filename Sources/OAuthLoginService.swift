import Foundation
import AppKit
import Security
import CryptoKit
import Network

// MARK: - OAuth configuration

/// Claude's public OAuth client used for browser sign-in. This is the same
/// PKCE public client the Claude Code CLI uses (no client secret). ClaudeGlance
/// asks it for the smallest scope `/api/oauth/usage` accepts (`scopes` below),
/// not the full set Claude Code requests.
///
/// Note: this is an *unofficial* reuse of Claude Code's public client — there's
/// no separate OAuth client registration for third-party usage apps. It works,
/// but Anthropic could change it; see SECURITY.md.
enum OAuthConfig {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let authorizeURL = "https://claude.ai/oauth/authorize"
    static let tokenURL = "https://console.anthropic.com/v1/oauth/token"
    /// The console "code" page the authorize flow redirects to; it displays a
    /// `code#state` string the user pastes back into ClaudeGlance. This is the
    /// manual fallback — the default flow redirects to a loopback server below.
    static let redirectURI = "https://console.anthropic.com/oauth/code/callback"
    /// Loopback redirect for the seamless flow: claude.ai sends the browser back
    /// to a one-shot HTTP server we run on 127.0.0.1 (same mechanism Claude Code
    /// uses), with [::1] on the same port held too, since `localhost` can resolve
    /// to either. The port is chosen at sign-in time.
    static func loopbackRedirectURI(port: UInt16) -> String {
        "http://localhost:\(port)/callback"
    }
    /// Least privilege: ClaudeGlance only reads `/api/oauth/usage`, which needs
    /// `user:profile`. Never request `org:create_api_key` (mints API keys) or, unless
    /// the server demands it, `user:inference` (runs models on the user's account):
    /// a leaked token pair should be able to read usage and nothing more.
    static let minimalScopes = "user:profile"
    /// Used only after the usage endpoint rejected a minimal-scope token for a
    /// missing scope (see `isMissingScopeRejection`); still never org:create_api_key.
    static let fallbackScopes = "user:profile user:inference"
    /// UserDefaults flag set when the fallback is needed; the next sign-in uses it.
    static let scopeFallbackKey = "oauthScopeFallback"
    static var scopes: String {
        oauthScopes(fallback: UserDefaults.standard.bool(forKey: scopeFallbackKey))
    }

    /// Our own Keychain item — created and owned by ClaudeGlance, so reading it
    /// never triggers the cross-app "allow access" password prompt that reading
    /// Claude Code's item did. Updated in place (never delete+re-add) so any ACL
    /// survives token refreshes.
    static let keychainService = "ClaudeGlance-credentials"
}

// MARK: - Scopes (pure, testable)

/// The scope string a sign-in requests.
func oauthScopes(fallback: Bool) -> String {
    fallback ? OAuthConfig.fallbackScopes : OAuthConfig.minimalScopes
}

/// Whether a failed usage fetch is the server refusing the token for a missing
/// scope (a 403 whose body names a scope), which a refresh can't fix: the user
/// has to sign in again with the fallback scopes.
func isMissingScopeRejection(_ error: NSError) -> Bool {
    guard error.domain == "OAuthUsage", error.code == 403 else { return false }
    return error.localizedDescription.lowercased().contains("scope")
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
                           challenge: String,
                           manualCode: Bool = true) -> URL {
    var components = URLComponents(string: authorizeURL)!
    // `code=true` asks claude.ai to render the paste-me code page instead of
    // redirecting; the loopback flow wants the redirect, so it omits it.
    components.queryItems = (manualCode ? [URLQueryItem(name: "code", value: "true")] : []) + [
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

/// Parse the request line of the browser's loopback hit
/// (`GET /callback?code=…&state=… HTTP/1.1`). Nil for anything that isn't a
/// callback carrying a code — favicon requests, probes, etc.
func parseLoopbackRequestLine(_ line: String) -> (code: String, state: String?)? {
    let parts = line.split(separator: " ")
    guard parts.count >= 2, parts[0] == "GET",
          let comps = URLComponents(string: "http://localhost" + parts[1]),
          comps.path == "/callback",
          let code = comps.queryItems?.first(where: { $0.name == "code" })?.value,
          !code.isEmpty else { return nil }
    let state = comps.queryItems?.first(where: { $0.name == "state" })?.value
    return (code, state?.isEmpty == true ? nil : state)
}

/// Minimal HTML the browser lands on after the redirect. Kept plain and inline
/// so the tab reads as "done" instantly and can be closed.
func loopbackResponseHTML(success: Bool) -> String {
    let title = success ? "Signed in to ClaudeGlance" : "Sign-in didn't complete"
    let body = success
        ? "You can close this tab and return to the menu bar."
        : "Go back to ClaudeGlance and try again."
    return """
    <!doctype html><html><head><meta charset="utf-8"><title>\(title)</title>
    <style>body{font:15px -apple-system,system-ui,sans-serif;color:#222;background:#fafafa;
    display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
    div{text-align:center}h1{font-size:20px;margin:0 0 8px}p{color:#666;margin:0}</style></head>
    <body><div><h1>\(title)</h1><p>\(body)</p></div></body></html>
    """
}

/// Latches a one-shot continuation so it resumes exactly once. `NWListener`'s
/// `stateUpdateHandler` fires on the listener queue and can report a terminal
/// state more than once, so the resume has to be guarded — and a captured local
/// `var` can't do that job: mutating one from a concurrently-executing closure
/// is a warning today and an error under the Swift 6 language mode. The lock
/// makes the box safe to hand across queues; `@unchecked` because the compiler
/// can't see that the lock covers every access to `cont`.
private final class ContinuationLatch<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, Error>?

    init(_ cont: CheckedContinuation<T, Error>) { self.cont = cont }

    /// Resumes on the first call; every later call is a no-op.
    func resume(_ result: Result<T, Error>) {
        lock.lock()
        let pending = cont
        cont = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

/// The callback-handling state the listener queue and the caller both touch,
/// behind one lock (it used to be written on the main thread and read on the
/// listener queue unsynchronized).
private final class CallbackGate: @unchecked Sendable {
    private let lock = NSLock()
    private var handled = false
    private var expectedState = ""
    private var onCallback: ((String, String?) -> Void)?

    func arm(expectedState: String, onCallback: @escaping (String, String?) -> Void) {
        lock.lock(); defer { lock.unlock() }
        handled = false
        self.expectedState = expectedState
        self.onCallback = onCallback
    }

    func disarm() {
        lock.lock(); defer { lock.unlock() }
        onCallback = nil
    }

    /// The callback to run if `state` is the one in flight and nothing was
    /// delivered yet; marks it delivered. Nil means refuse.
    func claim(state: String?) -> ((String, String?) -> Void)? {
        lock.lock(); defer { lock.unlock() }
        guard !handled, !expectedState.isEmpty, state == expectedState, let cb = onCallback else { return nil }
        handled = true
        return cb
    }
}

/// Holds [::1]:<port> with a socket that is bound but never listening.
///
/// The redirect URI says `localhost` (what the OAuth client accepts), and
/// browsers resolve that to ::1 as well as 127.0.0.1, often trying ::1 first.
/// With only 127.0.0.1 bound, any local process could bind [::1]:<port> and
/// receive the browser's redirect with the authorization code (useless without
/// the PKCE verifier, but it blocks the sign-in). Owning the address closes that:
/// no one else can bind it, and since nothing listens, the browser's ::1 attempt
/// is refused at once and it falls back to 127.0.0.1.
///
/// A plain BSD socket because Network.framework refuses a second listener on the
/// same port in one process (EADDRINUSE) even though the kernel allows it.
final class LoopbackV6Reservation {
    private var fd: Int32

    /// Nil error means reserved, or no IPv6 loopback on this Mac (then the browser
    /// can't reach ::1 either, so there is nothing to protect). Throws the errno
    /// as a POSIXError when the address is taken.
    init(port: UInt16) throws {
        fd = socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else { fd = -1; return }
        var on: Int32 = 1
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = port.bigEndian
        addr.sin6_addr = in6addr_loopback
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            close(fd)
            fd = -1
            if code == EADDRINUSE { throw POSIXError(.EADDRINUSE) }
            return   // EADDRNOTAVAIL / EAFNOSUPPORT: no IPv6 loopback
        }
    }

    var isHeld: Bool { fd >= 0 }

    func release() {
        if fd >= 0 { close(fd) }
        fd = -1
    }

    deinit { release() }
}

/// One-shot loopback HTTP listener for the OAuth redirect. Binds 127.0.0.1 on
/// an ephemeral port and reserves [::1] on the same port (see
/// `LoopbackV6Reservation`), answers exactly one `/callback` hit carrying the
/// state of the sign-in in progress, then stops. Anything else it sees (other
/// paths, or a callback with a missing or wrong state, e.g. from another local
/// process) gets an error page and the listener stays up for the real browser
/// redirect.
final class OAuthCallbackServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.github.broots144.ClaudeGlance.oauth-callback")
    private let gate = CallbackGate()
    // `listeners`, `reservation` and `generation` are guarded by `lock`. Each
    // start() bumps the generation, so a superseded start can tell it was replaced.
    private let lock = NSLock()
    private var listeners: [NWListener] = []
    private var reservation: LoopbackV6Reservation?
    private var generation = 0

    /// Start listening; resolves with the bound port once the socket is ready.
    /// Throws `CancellationError` if `stop()` or a newer `start()` replaces it
    /// before then (a double-click on Sign in), instead of never returning.
    func start(expectedState: String, onCallback: @escaping (String, String?) -> Void) async throws -> UInt16 {
        stop()
        let myGeneration = bumpGeneration()
        gate.arm(expectedState: expectedState, onCallback: onCallback)

        var lastError: Error = POSIXError(.EADDRINUSE)
        for _ in 0..<5 {
            let listener = try makeListener(host: "127.0.0.1", port: .any)
            try adopt(listener, generation: myGeneration)
            let port = try await waitUntilReady(listener)
            do {
                try hold(LoopbackV6Reservation(port: port), generation: myGeneration)
                return port
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Someone already holds [::1] on this port: drop it and take a new one.
                lastError = error
                stopListeners(generation: myGeneration)
            }
        }
        throw lastError
    }

    /// Keep the reservation for this start, unless it was already superseded.
    private func hold(_ r: LoopbackV6Reservation, generation expected: Int) throws {
        lock.lock(); defer { lock.unlock() }
        guard generation == expected else { r.release(); throw CancellationError() }
        reservation = r
    }

    /// Cancel this start's listeners but keep its generation (a retry follows).
    private func stopListeners(generation expected: Int) {
        lock.lock()
        guard generation == expected else { lock.unlock(); return }
        let old = listeners
        listeners = []
        lock.unlock()
        old.forEach { $0.cancel() }
    }

    func stop() {
        lock.lock()
        let old = listeners
        let held = reservation
        listeners = []
        reservation = nil
        generation += 1
        lock.unlock()
        old.forEach { $0.cancel() }
        held?.release()
        gate.disarm()
    }

    private func bumpGeneration() -> Int {
        lock.lock(); defer { lock.unlock() }
        generation += 1
        return generation
    }

    /// Track a listener for `stop()`, unless this start was already superseded.
    private func adopt(_ listener: NWListener, generation expected: Int) throws {
        lock.lock()
        guard generation == expected else {
            lock.unlock()
            listener.cancel()
            throw CancellationError()
        }
        listeners.append(listener)
        lock.unlock()
    }

    private func makeListener(host: NWEndpoint.Host, port: NWEndpoint.Port) throws -> NWListener {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: host, port: port)
        // No address reuse: nothing else may share our port.
        params.allowLocalEndpointReuse = false
        let listener = try NWListener(using: params)
        let gate = self.gate, queue = self.queue
        listener.newConnectionHandler = { conn in OAuthCallbackServer.accept(conn, gate: gate, queue: queue) }
        return listener
    }

    private func waitUntilReady(_ listener: NWListener) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            let latch = ContinuationLatch(cont)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    // A `.ready` without a port isn't usable; stay unlatched so a
                    // later one can still resolve, exactly as before.
                    guard let port = listener.port?.rawValue else { return }
                    latch.resume(.success(port))
                case .failed(let err):
                    latch.resume(.failure(err))
                case .cancelled:
                    // Stopped (or replaced by a newer start) before it was ready.
                    latch.resume(.failure(CancellationError()))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    private static func accept(_ conn: NWConnection, gate: CallbackGate, queue: DispatchQueue) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, _, _ in
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let firstLine = text.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map(String.init) ?? text
            guard let parsed = parseLoopbackRequestLine(firstLine) else {
                respond(conn, status: "404 Not Found", html: loopbackResponseHTML(success: false))
                return
            }
            guard let cb = gate.claim(state: parsed.state) else {
                respond(conn, status: "400 Bad Request", html: loopbackResponseHTML(success: false))
                return
            }
            respond(conn, status: "200 OK", html: loopbackResponseHTML(success: true))
            DispatchQueue.main.async { cb(parsed.code, parsed.state) }
        }
    }

    private static func respond(_ conn: NWConnection, status: String, html: String) {
        let body = Data(html.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }
}

// MARK: - Token endpoint errors (pure, testable)

/// The error for a non-200 token endpoint response. The description is a short
/// status line only: the response body (which can echo request detail) never
/// reaches the UI. DEBUG builds keep the body under `OAuthTokenBody` for logging.
/// A `Retry-After` header is carried along for the 429 backoff.
func oauthTokenHTTPError(status: Int, retryAfter: String?, body: Data) -> NSError {
    var info: [String: Any] = [NSLocalizedDescriptionKey: "Token endpoint returned HTTP \(status)."]
    if let retryAfter { info["Retry-After"] = retryAfter }
    #if DEBUG
    info["OAuthTokenBody"] = String(data: body.prefix(2048), encoding: .utf8) ?? "<binary>"
    #endif
    return NSError(domain: "OAuthToken", code: status, userInfo: info)
}

/// What Settings shows when the code exchange fails. Short and body-free.
func signInFailureMessage(for error: NSError) -> String {
    switch (error.domain, error.code) {
    case ("OAuthToken", 400), ("OAuthToken", 401):
        return "Sign-in failed: the code was rejected or expired. Please try again."
    case ("OAuthToken", 429):
        return "Sign-in failed: Anthropic is rate limiting sign-ins. Wait a minute and try again."
    case ("OAuthToken", 500...599):
        return "Sign-in failed: Anthropic's sign-in service is having trouble (HTTP \(error.code)). Try again shortly."
    case ("OAuthToken", let code) where code > 0:
        return "Sign-in failed (HTTP \(code)). Please try again."
    case (NSURLErrorDomain, _):
        return "Sign-in failed: can't reach Anthropic. Check your connection and try again."
    case ("Keychain", _):
        return "Sign-in failed: couldn't save your credentials to the Keychain."
    default:
        return "Sign-in failed. Please try again."
    }
}

/// Whether a token expiring at `expiresAt` should be refreshed now — true once
/// it's within `leeway` of expiry (default 5 min) so we never send a dead one.
func shouldRefreshToken(expiresAt: Date, now: Date = Date(), leeway: TimeInterval = 300) -> Bool {
    expiresAt.timeIntervalSince(now) <= leeway
}

/// What to do with the stored credentials item at launch.
enum LaunchKeychainAction: Equatable {
    case recreate     // readable: delete and re-add it so only this build is trusted
    case deleteStale  // present but refused or unreadable: remove it, sign in again
    case keep         // absent, or the keychain is locked right now: leave it alone
}

/// Decide the launch-time action from the read status and whether the data decoded.
func launchKeychainAction(status: OSStatus, decoded: Bool) -> LaunchKeychainAction {
    switch status {
    case errSecSuccess:
        return decoded ? .recreate : .deleteStale
    case errSecAuthFailed, errSecUserCanceled:
        return .deleteStale
    default:
        // errSecItemNotFound, or errSecInteractionNotAllowed while the keychain is
        // still locked at login: nothing to do (a later read or login handles it).
        return .keep
    }
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

// MARK: - Refresh coordination (pure / testable)

/// Runs one async operation at a time and hands every concurrent caller the same
/// result. The token endpoint rotates refresh tokens, so two refreshes racing with
/// the same refresh token end with the loser getting `invalid_grant`; funnelling
/// them through one task means only one refresh is ever in flight.
final class SingleFlight<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight: Task<T, Error>?

    func run(_ operation: @escaping () async throws -> T) async throws -> T {
        let task = joinOrStart(operation)
        defer { finished(task) }
        return try await task.value
    }

    /// The task in flight, or a new one running `operation`. Synchronous so the
    /// lock is never held across a suspension point.
    private func joinOrStart(_ operation: @escaping () async throws -> T) -> Task<T, Error> {
        lock.lock(); defer { lock.unlock() }
        if let task = inFlight { return task }
        let task = Task { try await operation() }
        inFlight = task
        return task
    }

    private func finished(_ task: Task<T, Error>) {
        lock.lock(); defer { lock.unlock() }
        if inFlight == task { inFlight = nil }
    }
}

/// Whether a refresh rejected with 400/401 really means the session is dead.
/// Not when the stored item holds a different, newer pair: then another refresh
/// (e.g. a second running copy of the app) already rotated the token and the
/// stored credentials are the live ones, not something to delete. An older
/// stored pair (left behind by a failed save) never wins over the rejected one.
func refreshRejectionEndsSession(rejected: StoredCredentials, stored: StoredCredentials?) -> Bool {
    guard let stored else { return true }
    return stored.refreshToken == rejected.refreshToken || stored.expiresAt <= rejected.expiresAt
}

/// Where the credentials live. Production uses the app's own Keychain item; the
/// seam exists so tests never read or write a developer's real sign-in.
struct CredentialStore {
    var load: () -> StoredCredentials?
    var save: (StoredCredentials) throws -> Void
    var delete: () -> Void
}

// MARK: - OAuthLoginService

final class OAuthLoginService: ObservableObject {
    static let shared = OAuthLoginService()

    enum AuthState: Equatable {
        case signedOut
        case awaitingBrowser       // browser opened, loopback server waiting for the redirect
        case awaitingCode          // browser opened (manual flow), waiting for the pasted code
        case signedIn(Date)        // associated value = current token expiry
        case error(String)
    }

    @Published private(set) var state: AuthState = .signedOut

    // Injectable for testing the token exchange/refresh network calls.
    var urlSession: URLSession = .shared

    // PKCE material for the in-flight login.
    private var pendingVerifier: String?
    private var pendingState: String?
    private var pendingRedirectURI: String = OAuthConfig.redirectURI
    private let callbackServer = OAuthCallbackServer()

    // In-memory credentials so each usage poll doesn't hit the Keychain, and so a
    // refreshed pair stays usable even if persisting it failed (the old refresh
    // token is already spent by then). A 401 forces a refresh via `needsRefresh`.
    // Guarded by `cacheLock`: callers run on arbitrary tasks.
    private let cacheLock = NSLock()
    private var cachedCredentials: StoredCredentials?
    private var needsRefresh = false
    /// Set when a refreshed pair couldn't be saved; the next call retries the save.
    private var needsPersist = false
    /// Bumped by sign-out and sign-in. A token refresh that started under an older
    /// generation is dropped, so signing out mid-refresh can't write the
    /// refreshed pair back to the Keychain and sign the user in again.
    private var sessionGeneration = 0
    private let refreshFlight = SingleFlight<StoredCredentials>()

    private let store: CredentialStore

    private init() {
        store = CredentialStore(load: OAuthLoginService.keychainLoad,
                                save: OAuthLoginService.keychainSave,
                                delete: OAuthLoginService.keychainDelete)
        // Reflect any stored session on launch so the UI starts in the right state,
        // after re-creating the item under this build (see reclaimStoredCredentials).
        if let creds = reclaimStoredCredentials() {
            state = .signedIn(creds.expiresAtDate)
        }
    }

    /// Test-only: a service over an in-memory store, with no launch-time Keychain work.
    init(testStore: CredentialStore, urlSession: URLSession) {
        store = testStore
        self.urlSession = urlSession
        if let creds = testStore.load() { state = .signedIn(creds.expiresAtDate) }
    }

    /// Launch-time Keychain migration. An item's access list trusts the build that
    /// created it, and approving the post-update prompt adds the new build without
    /// removing the old one. An item written by a build without the hardened runtime
    /// (1.7.4 and earlier) would therefore stay readable by that old binary started
    /// with an injected library until the next login or token refresh. Re-creating
    /// the item on every launch drops those stale entries right after an update; a
    /// marker would not do, since the old trusted build could forge it. An item we
    /// may no longer read (access denied at the prompt, or undecodable) is deleted
    /// so it doesn't linger; the user signs in again.
    private func reclaimStoredCredentials() -> StoredCredentials? {
        // Unit tests run inside a host copy of the app: never rewrite or delete a
        // developer's real sign-in from a test build.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return loadCredentials()
        }
        let (status, data) = OAuthLoginService.copyCredentialsData()
        let decoded = data.flatMap { try? JSONDecoder().decode(StoredCredentials.self, from: $0) }
        switch launchKeychainAction(status: status, decoded: decoded != nil) {
        case .recreate:
            guard let creds = decoded else { return nil }
            // A failed re-create saves nothing and leaves the user signed out rather
            // than keep tokens in an item we couldn't take back.
            do { try saveCredentials(creds) } catch { return nil }
            return creds
        case .deleteStale:
            deleteCredentials()
            return nil
        case .keep:
            return nil
        }
    }

    var isSignedIn: Bool { loadCredentials() != nil }

    // MARK: Login flow

    /// Step 1 (default): start a loopback listener, then open the browser. When
    /// claude.ai redirects back, the listener completes the exchange itself —
    /// nothing to copy or paste. Falls back to the manual code flow if the
    /// listener can't bind.
    @MainActor
    func beginLogin() {
        let verifier = generateCodeVerifier()
        let stateValue = generateState()
        pendingVerifier = verifier
        pendingState = stateValue
        state = .awaitingBrowser

        Task { @MainActor in
            do {
                let port = try await callbackServer.start(expectedState: stateValue) { [weak self] code, returnedState in
                    guard let self else { return }
                    Task { @MainActor in
                        await self.completeLogin(code: code, returnedState: returnedState, requireState: true)
                    }
                }
                let redirect = OAuthConfig.loopbackRedirectURI(port: port)
                pendingRedirectURI = redirect
                let url = buildAuthorizationURL(redirectURI: redirect,
                                                state: stateValue,
                                                challenge: codeChallenge(for: verifier),
                                                manualCode: false)
                NSWorkspace.shared.open(url)
            } catch is CancellationError {
                // A newer sign-in (or a cancel) replaced this listener: that flow
                // owns the UI now, so don't tear it down with the paste fallback.
            } catch {
                // Couldn't listen locally (sandbox/firewall) — use the paste flow.
                beginManualLogin()
            }
        }
    }

    /// Step 1 (fallback): open the browser to the console code page; the user
    /// pastes the `code#state` it shows into Settings.
    @MainActor
    func beginManualLogin() {
        callbackServer.stop()
        let verifier = generateCodeVerifier()
        let stateValue = generateState()
        pendingVerifier = verifier
        pendingState = stateValue
        pendingRedirectURI = OAuthConfig.redirectURI
        let url = buildAuthorizationURL(redirectURI: OAuthConfig.redirectURI,
                                        state: stateValue,
                                        challenge: codeChallenge(for: verifier),
                                        manualCode: true)
        state = .awaitingCode
        NSWorkspace.shared.open(url)
    }

    /// Abort an in-flight sign-in (either flow) without touching stored credentials.
    @MainActor
    func cancelLogin() {
        callbackServer.stop()
        pendingVerifier = nil
        pendingState = nil
        state = loadCredentials().map { .signedIn($0.expiresAtDate) } ?? .signedOut
    }

    /// Step 2 (manual): exchange the pasted `code#state` for tokens and persist them.
    @MainActor
    func completeLogin(pastedInput: String) async {
        guard let parsed = parseAuthorizationCallback(pastedInput) else {
            state = .error("Couldn't read that code. Copy the whole value from the page.")
            return
        }
        await completeLogin(code: parsed.code, returnedState: parsed.state)
    }

    /// Step 2 (shared): verify state, exchange the code, persist, and refresh usage.
    /// The loopback redirect must carry the state we sent (`requireState`); a
    /// pasted bare code, typed by the user themselves, may omit it.
    @MainActor
    func completeLogin(code: String, returnedState: String?, requireState: Bool = false) async {
        callbackServer.stop()
        guard let verifier = pendingVerifier, let expected = pendingState else {
            state = .error("Start sign-in first, then paste the code.")
            return
        }
        // CSRF guard: a state that came back (or is required) must be the one we sent.
        if (requireState || returnedState != nil) && returnedState != expected {
            state = .error("Sign-in state mismatch — please try again.")
            return
        }
        do {
            let creds = try await exchangeCode(code: code,
                                               state: expected,
                                               verifier: verifier,
                                               redirectURI: pendingRedirectURI)
            try startSession(creds)
            pendingVerifier = nil
            pendingState = nil
            state = .signedIn(creds.expiresAtDate)
            // Pull fresh usage immediately now that we're authenticated, and
            // bring the app forward so the result is visible without hunting.
            UsageService.shared.fetchUsage(manual: true)
            NSApp.activate(ignoringOtherApps: true)
        } catch let error as NSError {
            state = .error(signInFailureMessage(for: error))
        }
    }

    @MainActor
    func signOut() {
        callbackServer.stop()
        // Bump, delete and clear under one lock so an in-flight refresh can't save
        // its result in between (see `commitRefreshed`).
        cacheLock.lock()
        sessionGeneration += 1
        store.delete()
        cachedCredentials = nil
        needsRefresh = false
        needsPersist = false
        cacheLock.unlock()
        pendingVerifier = nil
        pendingState = nil
        state = .signedOut
    }

    // MARK: Token access (used by UsageService)

    /// Force a refresh on the next call — used when the usage endpoint returns
    /// 401/403 (token rotated or rejected). The cached refresh token is kept: it's
    /// what the forced refresh needs.
    func invalidateCache() {
        cacheLock.lock(); defer { cacheLock.unlock() }
        needsRefresh = true
    }

    /// Return a valid bearer token, refreshing first if it's missing or near
    /// expiry. Throws if we're not signed in or the refresh token is dead.
    /// Concurrent callers share one refresh (see `SingleFlight`).
    func validAccessToken() async throws -> String {
        if let creds = freshCachedCredentials() { return creds.accessToken }
        return try await refreshFlight.run { [self] in try await loadOrRefresh() }.accessToken
    }

    /// The cached credentials if they're good to send as-is.
    private func freshCachedCredentials() -> StoredCredentials? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        guard !needsRefresh, !needsPersist, let creds = cachedCredentials,
              !shouldRefreshToken(expiresAt: creds.expiresAtDate) else { return nil }
        return creds
    }

    /// The slow path, only ever run by one task at a time. Every Keychain and
    /// cache write goes through a helper that takes `cacheLock` and checks the
    /// session generation captured here, so a sign-out (or a new sign-in) that
    /// lands while this runs can't be undone by it: old tokens are never written
    /// back after sign-out, and a newer sign-in's tokens are never deleted.
    private func loadOrRefresh() async throws -> StoredCredentials {
        let generation = currentSessionGeneration()
        let (cached, forced, unsaved) = cacheSnapshot()
        if unsaved, let cached {
            guard persistIfCurrent(cached, generation: generation) else { return try sessionChangedResult() }
        }
        // Prefer the in-memory pair: it can be newer than the Keychain item when a
        // save failed.
        guard let creds = cached ?? store.load() else {
            await setBackgroundState(.signedOut)
            throw OAuthLoginService.notSignedInError
        }
        if !forced, !shouldRefreshToken(expiresAt: creds.expiresAtDate) {
            guard cacheIfCurrent(creds, generation: generation) else { return try sessionChangedResult() }
            return creds
        }
        do {
            let fresh = try await refresh(refreshToken: creds.refreshToken)
            // Signed out (or in again) while the refresh ran: drop its result.
            guard commitRefreshed(fresh, generation: generation) else {
                return try sessionChangedResult()
            }
            await setBackgroundState(.signedIn(fresh.expiresAtDate))
            return fresh
        } catch let error as NSError {
            // A 400/401 from the token endpoint means the refresh token is dead —
            // sign out so the UI prompts a fresh login. Transient/network errors
            // (5xx, 429, offline) keep the session so we can retry next poll.
            if error.domain == "OAuthToken", error.code == 400 || error.code == 401 {
                switch endRejectedSession(rejected: creds, generation: generation) {
                case .sessionChanged:
                    return try sessionChangedResult()
                case .rotatedElsewhere(let stored):
                    // Something else already rotated it: the stored pair is live.
                    return stored
                case .ended:
                    await setBackgroundState(.signedOut)
                    throw OAuthLoginService.sessionExpiredError
                }
            }
            throw error
        }
    }

    /// Outcome of a refresh the token endpoint rejected (see `endRejectedSession`).
    private enum RejectionOutcome {
        case sessionChanged
        case rotatedElsewhere(StoredCredentials)
        case ended
    }

    /// Decide, and apply, what a rejected refresh means, all under `cacheLock` and
    /// only for the session the refresh started under. Reading the store, then
    /// deleting it, in one critical section means a sign-in that completes in
    /// between can't have its fresh credentials deleted.
    private func endRejectedSession(rejected: StoredCredentials, generation: Int) -> RejectionOutcome {
        cacheLock.lock(); defer { cacheLock.unlock() }
        guard generation == sessionGeneration else { return .sessionChanged }
        let stored = store.load()
        if !refreshRejectionEndsSession(rejected: rejected, stored: stored), let stored {
            cachedCredentials = stored
            needsRefresh = false
            return .rotatedElsewhere(stored)
        }
        store.delete()
        cachedCredentials = nil
        needsRefresh = false
        needsPersist = false
        return .ended
    }

    /// Cache, then save, a refreshed pair, but only if the session is the one the
    /// refresh started under. Cache first: the old refresh token is spent now, so
    /// losing the new pair to a failed save would sign the user out on the next
    /// refresh. Held under `cacheLock` so `signOut` can't interleave.
    private func commitRefreshed(_ fresh: StoredCredentials, generation: Int) -> Bool {
        cacheLock.lock(); defer { cacheLock.unlock() }
        guard generation == sessionGeneration else { return false }
        cachedCredentials = fresh
        needsRefresh = false
        needsPersist = (try? store.save(fresh)) == nil
        return true
    }

    /// What a refresh returns when the session changed under it: the new
    /// session's pair if there is one, else not signed in.
    private func sessionChangedResult() throws -> StoredCredentials {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let current = cachedCredentials { return current }
        throw OAuthLoginService.notSignedInError
    }

    private func currentSessionGeneration() -> Int {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return sessionGeneration
    }

    /// A completed sign-in: new generation, save, cache, as one step under
    /// `cacheLock`, so a refresh from the previous session can't interleave.
    private func startSession(_ creds: StoredCredentials) throws {
        cacheLock.lock(); defer { cacheLock.unlock() }
        sessionGeneration += 1
        try store.save(creds)
        cachedCredentials = creds
        needsRefresh = false
        needsPersist = false
    }

    /// Save to the store, unless the session changed since `generation` (then
    /// nothing is written and false is returned). On a failed save the pair stays
    /// in memory and the next call retries.
    private func persistIfCurrent(_ creds: StoredCredentials, generation: Int) -> Bool {
        cacheLock.lock(); defer { cacheLock.unlock() }
        guard generation == sessionGeneration else { return false }
        needsPersist = (try? store.save(creds)) == nil
        return true
    }

    private func cacheSnapshot() -> (StoredCredentials?, Bool, Bool) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return (cachedCredentials, needsRefresh, needsPersist)
    }

    static let notSignedInError = NSError(
        domain: "OAuth", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Sign in to Claude in Settings to see your usage."])
    static let sessionExpiredError = NSError(
        domain: "OAuth", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Session expired — sign in to Claude again in Settings."])

    // MARK: Network

    private func exchangeCode(code: String, state: String, verifier: String,
                              redirectURI: String) async throws -> StoredCredentials {
        try await postToken(body: [
            "grant_type": "authorization_code",
            "code": code,
            "state": state,
            "client_id": OAuthConfig.clientID,
            "redirect_uri": redirectURI,
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
            throw oauthTokenHTTPError(status: http.statusCode,
                                      retryAfter: http.value(forHTTPHeaderField: "Retry-After"),
                                      body: data)
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

    func loadCredentials() -> StoredCredentials? { store.load() }

    private static func keychainLoad() -> StoredCredentials? {
        let (status, data) = copyCredentialsData()
        guard status == errSecSuccess, let data else { return nil }
        return try? JSONDecoder().decode(StoredCredentials.self, from: data)
    }

    private static func copyCredentialsData() -> (OSStatus, Data?) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: OAuthConfig.keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    /// Persist credentials in a fresh item this app creates. An item's access list
    /// belongs to whoever created it, so updating an existing match in place would
    /// write our tokens into an item another app could have planted under our
    /// service name with an access list that lets it read them back. Delete and
    /// re-add instead; if the old item can't be removed, save nothing.
    private func saveCredentials(_ creds: StoredCredentials) throws { try store.save(creds) }

    private static func keychainSave(_ creds: StoredCredentials) throws {
        let data = try JSONEncoder().encode(creds)
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: OAuthConfig.keychainService
        ]
        let deleteStatus = SecItemDelete(match as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw NSError(domain: "Keychain", code: Int(deleteStatus),
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't replace the stored credentials (status \(deleteStatus))."])
        }
        var add = match
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        // errSecDuplicateItem here means something re-created the item between the
        // delete and the add: fail rather than fall back to updating it.
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw NSError(domain: "Keychain", code: Int(addStatus),
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't save credentials (status \(addStatus))."])
        }
    }

    private func deleteCredentials() { store.delete() }

    private static func keychainDelete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: OAuthConfig.keychainService
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: Cache helpers

    /// Cache `creds` for later calls, unless the session changed since `generation`.
    private func cacheIfCurrent(_ creds: StoredCredentials, generation: Int) -> Bool {
        cacheLock.lock(); defer { cacheLock.unlock() }
        guard generation == sessionGeneration else { return false }
        cachedCredentials = creds
        needsRefresh = false
        return true
    }

    /// A state change from the token path (usage polls, refreshes). It never
    /// replaces a sign-in in progress: the poll runs while signed out too, and
    /// resetting `.awaitingCode` would hide the paste field mid-copy.
    @MainActor
    private func setBackgroundState(_ newState: AuthState) {
        state = backgroundAuthTransition(from: state, to: newState)
    }

    #if DEBUG
    /// Test-only: complete a sign-in with `creds` without the browser round trip.
    func startSessionForTesting(_ creds: StoredCredentials) throws { try startSession(creds) }

    /// Test-only: put the service in a given UI state (e.g. a sign-in in progress)
    /// without opening a browser.
    @MainActor
    func setStateForTesting(_ newState: AuthState) { state = newState }
    #endif
}

/// The state after a background (poll or refresh) update to `proposed`. A sign-in
/// in progress (`.awaitingBrowser`, `.awaitingCode`) is owned by the sign-in flow
/// and only it, or a cancel, may leave it; every other state takes the update.
func backgroundAuthTransition(from current: OAuthLoginService.AuthState,
                              to proposed: OAuthLoginService.AuthState) -> OAuthLoginService.AuthState {
    switch current {
    case .awaitingBrowser, .awaitingCode:
        return current
    case .signedOut, .signedIn, .error:
        return proposed
    }
}
