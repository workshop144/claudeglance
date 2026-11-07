import XCTest
import Security
@testable import ClaudeGlance

// MARK: - PKCE

final class PKCETests: XCTestCase {

    func testBase64URLDropsPaddingAndUsesURLAlphabet() {
        // 0xFB 0xFF would be "+/8=" in standard base64; base64url is "-_8".
        XCTAssertEqual(base64URLEncode(Data([0xFB, 0xFF])), "-_8")
        XCTAssertFalse(base64URLEncode(Data([0x00, 0x00, 0x00])).contains("="))
    }

    func testCodeChallengeMatchesRFC7636Vector() {
        // The canonical S256 example from RFC 7636 Appendix B.
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(codeChallenge(for: verifier), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testGeneratedVerifierIsURLSafeAndHighEntropy() {
        let verifier = generateCodeVerifier()
        // 32 bytes → 43 base64url chars, no padding, no URL-unsafe characters.
        XCTAssertEqual(verifier.count, 43)
        XCTAssertFalse(verifier.contains("="))
        XCTAssertFalse(verifier.contains("+"))
        XCTAssertFalse(verifier.contains("/"))
        // Two draws should not collide.
        XCTAssertNotEqual(generateCodeVerifier(), generateCodeVerifier())
    }
}

// MARK: - Authorization URL

final class AuthorizationURLTests: XCTestCase {

    private func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    func testIncludesPKCEAndClientParameters() {
        let url = buildAuthorizationURL(state: "the-state", challenge: "the-challenge")
        XCTAssertTrue(url.absoluteString.hasPrefix(OAuthConfig.authorizeURL))
        let q = query(url)
        XCTAssertEqual(q["client_id"], OAuthConfig.clientID)
        XCTAssertEqual(q["response_type"], "code")
        XCTAssertEqual(q["redirect_uri"], OAuthConfig.redirectURI)
        XCTAssertEqual(q["scope"], OAuthConfig.scopes)
        XCTAssertEqual(q["code_challenge"], "the-challenge")
        XCTAssertEqual(q["code_challenge_method"], "S256")
        XCTAssertEqual(q["state"], "the-state")
    }

    // Security regression (L1, 2026-11-07): least-privilege scopes.
    func testDefaultScopeIsUserProfileOnly() {
        XCTAssertEqual(oauthScopes(fallback: false), "user:profile")
        let q = query(buildAuthorizationURL(scope: oauthScopes(fallback: false), state: "s", challenge: "c"))
        XCTAssertEqual(q["scope"], "user:profile")
    }

    func testNoScopeEverRequestsAPIKeyCreation() {
        for fallback in [false, true] {
            XCTAssertFalse(oauthScopes(fallback: fallback).contains("org:create_api_key"))
        }
        XCTAssertFalse(OAuthConfig.scopes.contains("org:create_api_key"))
        let url = buildAuthorizationURL(state: "s", challenge: "c")
        XCTAssertFalse(query(url)["scope"]!.contains("org:create_api_key"))
        XCTAssertFalse(url.absoluteString.contains("create_api_key"))
    }

    func testFallbackAddsOnlyInference() {
        XCTAssertEqual(Set(oauthScopes(fallback: true).split(separator: " ")),
                       ["user:profile", "user:inference"])
    }

    func testMissingScopeRejectionDetection() {
        func err(_ domain: String, _ code: Int, _ body: String) -> NSError {
            NSError(domain: domain, code: code, userInfo: [NSLocalizedDescriptionKey: "HTTP \(code): \(body)"])
        }
        XCTAssertTrue(isMissingScopeRejection(err("OAuthUsage", 403,
            #"{"error":{"type":"permission_error","message":"OAuth token does not meet scope requirement user:inference"}}"#)))
        XCTAssertFalse(isMissingScopeRejection(err("OAuthUsage", 403, #"{"error":"forbidden"}"#)))
        XCTAssertFalse(isMissingScopeRejection(err("OAuthUsage", 401, "invalid scope")))
        XCTAssertFalse(isMissingScopeRejection(err("OAuthToken", 403, "scope")))
    }
}

// MARK: - Loopback redirect (seamless flow)

final class LoopbackCallbackTests: XCTestCase {

    func testParsesCodeAndStateFromRequestLine() {
        let parsed = parseLoopbackRequestLine("GET /callback?code=abc123&state=xyz HTTP/1.1")
        XCTAssertEqual(parsed?.code, "abc123")
        XCTAssertEqual(parsed?.state, "xyz")
    }

    func testIgnoresOtherPathsAndMethods() {
        XCTAssertNil(parseLoopbackRequestLine("GET /favicon.ico HTTP/1.1"))
        XCTAssertNil(parseLoopbackRequestLine("POST /callback?code=abc HTTP/1.1"))
        XCTAssertNil(parseLoopbackRequestLine("GET /callback?state=only HTTP/1.1"))
        XCTAssertNil(parseLoopbackRequestLine(""))
    }

    func testLoopbackAuthorizationURLOmitsManualCodeFlag() {
        let url = buildAuthorizationURL(redirectURI: OAuthConfig.loopbackRedirectURI(port: 54321),
                                        state: "s", challenge: "c", manualCode: false)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let q = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        XCTAssertNil(q["code"])
        XCTAssertEqual(q["redirect_uri"], "http://localhost:54321/callback")
    }

    func testManualAuthorizationURLKeepsCodeFlag() {
        let url = buildAuthorizationURL(state: "s", challenge: "c")
        XCTAssertTrue(url.absoluteString.contains("code=true"))
    }

    func testServerBindsLoopbackAndAnswersCallback() async throws {
        let server = OAuthCallbackServer()
        let got = expectation(description: "callback delivered")
        var received: (String, String?)?
        let port = try await server.start(expectedState: "ST1") { code, state in
            received = (code, state)
            got.fulfill()
        }
        XCTAssertGreaterThan(port, 0)

        let url = URL(string: "http://127.0.0.1:\(port)/callback?code=CODE1&state=ST1")!
        let (data, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("Signed in"))

        await fulfillment(of: [got], timeout: 2)
        XCTAssertEqual(received?.0, "CODE1")
        XCTAssertEqual(received?.1, "ST1")
        server.stop()
    }
}

extension LoopbackCallbackTests {

    /// Another local process racing the browser: a callback with no state or the
    /// wrong state is refused and must not consume the one-shot listener.
    func testServerRefusesMissingOrWrongStateAndStaysUp() async throws {
        let server = OAuthCallbackServer()
        let got = expectation(description: "only the matching callback is delivered")
        var received: [(String, String?)] = []
        let port = try await server.start(expectedState: "ST1") { code, state in
            received.append((code, state))
            got.fulfill()
        }
        func status(_ query: String) async throws -> Int? {
            let url = URL(string: "http://127.0.0.1:\(port)/callback?\(query)")!
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode
        }
        let noState = try await status("code=EVIL1")
        XCTAssertEqual(noState, 400)
        let wrongState = try await status("code=EVIL2&state=WRONG")
        XCTAssertEqual(wrongState, 400)
        let real = try await status("code=REAL&state=ST1")
        XCTAssertEqual(real, 200)

        await fulfillment(of: [got], timeout: 2)
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.0, "REAL")
        server.stop()
    }
}

// MARK: - Callback parsing

final class AuthorizationCallbackTests: XCTestCase {

    func testParsesCodeHashStateForm() {
        let parsed = parseAuthorizationCallback("  abc123#xyz789  ")
        XCTAssertEqual(parsed?.code, "abc123")
        XCTAssertEqual(parsed?.state, "xyz789")
    }

    func testParsesBareCode() {
        let parsed = parseAuthorizationCallback("just-a-code")
        XCTAssertEqual(parsed?.code, "just-a-code")
        XCTAssertNil(parsed?.state)
    }

    func testParsesFullCallbackURL() {
        let parsed = parseAuthorizationCallback("https://console.anthropic.com/oauth/code/callback?code=AAA&state=BBB")
        XCTAssertEqual(parsed?.code, "AAA")
        XCTAssertEqual(parsed?.state, "BBB")
    }

    func testEmptyInputReturnsNil() {
        XCTAssertNil(parseAuthorizationCallback("   "))
        XCTAssertNil(parseAuthorizationCallback("#only-state"))
    }
}

// MARK: - Token refresh decision

final class ShouldRefreshTokenTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testRefreshesWhenExpired() {
        XCTAssertTrue(shouldRefreshToken(expiresAt: now.addingTimeInterval(-1), now: now))
    }

    func testRefreshesWithinLeeway() {
        // 4 minutes left, default 5-minute leeway → refresh now.
        XCTAssertTrue(shouldRefreshToken(expiresAt: now.addingTimeInterval(4 * 60), now: now))
    }

    func testDoesNotRefreshWhenComfortablyValid() {
        XCTAssertFalse(shouldRefreshToken(expiresAt: now.addingTimeInterval(60 * 60), now: now))
    }
}

// MARK: - Stored credentials & token response decoding

final class OAuthCredentialsTests: XCTestCase {

    func testTokenResponseDecodesSnakeCase() throws {
        let json = """
        { "access_token": "at", "refresh_token": "rt", "expires_in": 28800 }
        """.data(using: .utf8)!
        let token = try JSONDecoder().decode(OAuthTokenResponse.self, from: json)
        XCTAssertEqual(token.accessToken, "at")
        XCTAssertEqual(token.refreshToken, "rt")
        XCTAssertEqual(token.expiresIn, 28800)
    }

    func testTokenResponseAllowsMissingRefreshToken() throws {
        // The refresh grant may not echo a new refresh token.
        let json = #"{ "access_token": "at", "expires_in": 3600 }"#.data(using: .utf8)!
        let token = try JSONDecoder().decode(OAuthTokenResponse.self, from: json)
        XCTAssertNil(token.refreshToken)
    }

    func testStoredCredentialsRoundTrip() throws {
        let creds = StoredCredentials(accessToken: "a", refreshToken: "r", expiresAt: 1_700_000_000)
        let data = try JSONEncoder().encode(creds)
        let decoded = try JSONDecoder().decode(StoredCredentials.self, from: data)
        XCTAssertEqual(decoded.accessToken, "a")
        XCTAssertEqual(decoded.refreshToken, "r")
        XCTAssertEqual(decoded.expiresAtDate, Date(timeIntervalSince1970: 1_700_000_000))
    }
}

final class LaunchKeychainActionTests: XCTestCase {
    func testReadableItemIsRecreatedUnderThisBuild() {
        // A pre-hardened build's item must not survive launch with its old access list.
        XCTAssertEqual(launchKeychainAction(status: errSecSuccess, decoded: true), .recreate)
    }

    func testUndecodableItemIsDeleted() {
        XCTAssertEqual(launchKeychainAction(status: errSecSuccess, decoded: false), .deleteStale)
    }

    func testRefusedItemIsDeleted() {
        XCTAssertEqual(launchKeychainAction(status: errSecAuthFailed, decoded: false), .deleteStale)
        XCTAssertEqual(launchKeychainAction(status: errSecUserCanceled, decoded: false), .deleteStale)
    }

    func testMissingOrLockedItemIsLeftAlone() {
        XCTAssertEqual(launchKeychainAction(status: errSecItemNotFound, decoded: false), .keep)
        XCTAssertEqual(launchKeychainAction(status: errSecInteractionNotAllowed, decoded: false), .keep)
    }
}

// MARK: - Token refresh is single-flight (refresh-token reuse race)

/// A token endpoint that rotates refresh tokens like the real one: each refresh
/// token works once; reusing it gets 400 invalid_grant.
final class RotatingTokenEndpoint: URLProtocol {
    private static let lock = NSLock()
    private static var valid: Set<String> = []
    private static var issued = 0
    static var refreshCalls = 0

    static func reset(validRefreshToken: String) {
        lock.lock(); defer { lock.unlock() }
        valid = [validRefreshToken]; issued = 0; refreshCalls = 0
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RotatingTokenEndpoint.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map { stream -> Data in
            stream.open(); defer { stream.close() }
            var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
            return data
        } ?? Data()
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: String] ?? [:]
        let presented = json["refresh_token"] ?? ""

        Self.lock.lock()
        Self.refreshCalls += 1
        let ok = Self.valid.remove(presented) != nil
        var payload = Data(#"{"error":"invalid_grant"}"#.utf8)
        if ok {
            Self.issued += 1
            let next = "rt-\(Self.issued)"
            Self.valid.insert(next)
            payload = Data(#"{"access_token":"at-\#(Self.issued)","refresh_token":"\#(next)","expires_in":3600}"#.utf8)
        }
        Self.lock.unlock()

        // Answer a little later so concurrent callers really overlap.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            let response = HTTPURLResponse(url: self.request.url!, statusCode: ok ? 200 : 400,
                                           httpVersion: nil, headerFields: nil)!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: payload)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }
}

/// In-memory stand-in for the Keychain item.
final class MemoryCredentialBox: @unchecked Sendable {
    private let lock = NSLock()
    private var creds: StoredCredentials?
    var failSaves = false
    init(_ creds: StoredCredentials?) { self.creds = creds }
    var current: StoredCredentials? { lock.lock(); defer { lock.unlock() }; return creds }
    var store: CredentialStore {
        CredentialStore(
            load: { [self] in current },
            save: { [self] c in
                if failSaves { throw NSError(domain: "Keychain", code: -25299) }
                lock.lock(); creds = c; lock.unlock()
            },
            delete: { [self] in lock.lock(); creds = nil; lock.unlock() })
    }
}

final class TokenRefreshRaceTests: XCTestCase {

    private func expired(_ refresh: String) -> StoredCredentials {
        StoredCredentials(accessToken: "old", refreshToken: refresh,
                          expiresAt: Date().addingTimeInterval(-60).timeIntervalSince1970)
    }

    func testConcurrentCallersShareOneRefreshAndStaySignedIn() async throws {
        RotatingTokenEndpoint.reset(validRefreshToken: "rt-0")
        let box = MemoryCredentialBox(expired("rt-0"))
        let service = OAuthLoginService(testStore: box.store, urlSession: RotatingTokenEndpoint.session())

        let tokens = try await withThrowingTaskGroup(of: String.self) { group -> [String] in
            for _ in 0..<5 { group.addTask { try await service.validAccessToken() } }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        XCTAssertEqual(Set(tokens), ["at-1"])
        XCTAssertEqual(RotatingTokenEndpoint.refreshCalls, 1)
        XCTAssertEqual(box.current?.refreshToken, "rt-1")
        let state = await MainActor.run { service.state }
        XCTAssertNotEqual(state, .signedOut)
    }

    func testFailedSaveKeepsRotatedTokensInMemory() async throws {
        RotatingTokenEndpoint.reset(validRefreshToken: "rt-0")
        let box = MemoryCredentialBox(expired("rt-0"))
        box.failSaves = true
        let service = OAuthLoginService(testStore: box.store, urlSession: RotatingTokenEndpoint.session())

        let first = try await service.validAccessToken()
        XCTAssertEqual(first, "at-1")
        // The save failed, so the Keychain still holds the spent rt-0. A forced
        // refresh must use the in-memory rt-1 rather than sign the user out.
        service.invalidateCache()
        box.failSaves = false
        let second = try await service.validAccessToken()
        XCTAssertEqual(second, "at-2")
        XCTAssertEqual(box.current?.refreshToken, "rt-2")
    }

    func testSignOutDuringRefreshIsNotUndone() async throws {
        RotatingTokenEndpoint.reset(validRefreshToken: "rt-0")
        let box = MemoryCredentialBox(expired("rt-0"))
        let service = OAuthLoginService(testStore: box.store, urlSession: RotatingTokenEndpoint.session())

        let refresh = Task { try await service.validAccessToken() }
        try await Task.sleep(nanoseconds: 50_000_000)   // endpoint answers after 0.2s
        await MainActor.run { service.signOut() }
        _ = try? await refresh.value

        XCTAssertEqual(RotatingTokenEndpoint.refreshCalls, 1)
        XCTAssertNil(box.current, "the refreshed pair must not be written back after sign-out")
        let state = await MainActor.run { service.state }
        XCTAssertEqual(state, .signedOut)
    }

    func testRejectionEndsSessionOnlyForTheStoredToken() {
        let rejected = StoredCredentials(accessToken: "a", refreshToken: "rt-1", expiresAt: 100)
        XCTAssertTrue(refreshRejectionEndsSession(rejected: rejected, stored: nil))
        XCTAssertTrue(refreshRejectionEndsSession(rejected: rejected, stored: rejected))
        // A different, newer pair in the store means someone else rotated it.
        let newer = StoredCredentials(accessToken: "b", refreshToken: "rt-2", expiresAt: 200)
        XCTAssertFalse(refreshRejectionEndsSession(rejected: rejected, stored: newer))
        // An older leftover never wins.
        let older = StoredCredentials(accessToken: "c", refreshToken: "rt-0", expiresAt: 50)
        XCTAssertTrue(refreshRejectionEndsSession(rejected: rejected, stored: older))
    }
}

// MARK: - Restarting the loopback sign-in never strands the first listener

final class CallbackServerRestartTests: XCTestCase {

    func testSupersededStartFinishesInsteadOfHanging() async throws {
        let server = OAuthCallbackServer()
        // Double-click on Sign in: two start() calls overlap. Whichever runs last
        // wins; the other must return (CancellationError), never hang.
        let results = await withTaskGroup(of: Result<UInt16, Error>.self) { group -> [Result<UInt16, Error>] in
            for state in ["A", "B"] {
                group.addTask {
                    do { return .success(try await server.start(expectedState: state) { _, _ in }) }
                    catch { return .failure(error) }
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.contains { if case .success = $0 { return true } else { return false } })
        for case .failure(let error) in results {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        server.stop()
    }

    func testStopBeforeReadyCancelsTheWait() async throws {
        let server = OAuthCallbackServer()
        let done = expectation(description: "start() returns after stop()")
        Task {
            _ = try? await server.start(expectedState: "A") { _, _ in }
            done.fulfill()
        }
        server.stop()
        await fulfillment(of: [done], timeout: 3)
    }
}

// MARK: - `localhost` resolves to sockets the app owns

final class LoopbackDualStackTests: XCTestCase {

    /// Try to bind [::1]:port the way another local process would.
    private func otherProcessCanBindIPv6(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = port.bigEndian
        addr.sin6_addr = in6addr_loopback
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0
            }
        }
    }

    func testIPv6LoopbackPortIsHeldWhileSignInRuns() async throws {
        let server = OAuthCallbackServer()
        let port = try await server.start(expectedState: "S") { _, _ in }
        XCTAssertEqual(OAuthConfig.loopbackRedirectURI(port: port), "http://localhost:\(port)/callback")
        // Another process can't take the ::1 side of `localhost` from us...
        XCTAssertFalse(otherProcessCanBindIPv6(port))
        server.stop()
        // ...and it's released with the listener.
        XCTAssertTrue(otherProcessCanBindIPv6(port))
    }

    func testLocalhostRedirectStillReachesTheListener() async throws {
        let server = OAuthCallbackServer()
        let got = expectation(description: "callback via localhost")
        let port = try await server.start(expectedState: "S6") { code, _ in
            XCTAssertEqual(code, "LH")
            got.fulfill()
        }
        // ::1 is refused at once (reserved, not listening); the client falls back to 127.0.0.1.
        let url = URL(string: "http://localhost:\(port)/callback?code=LH&state=S6")!
        let (_, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        await fulfillment(of: [got], timeout: 3)
        server.stop()
    }

    func testTakenIPv6PortIsReported() async throws {
        let server = OAuthCallbackServer()
        let port = try await server.start(expectedState: "S") { _, _ in }
        defer { server.stop() }
        // A squatter already on [::1]:port makes the reservation fail (start() then retries).
        XCTAssertThrowsError(try LoopbackV6Reservation(port: port))
    }
}
