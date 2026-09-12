import XCTest
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
        let port = try await server.start { code, state in
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
