import XCTest
@testable import ClaudeGlance

// MARK: - URL stubbing for the network seam

/// Intercepts requests so `UsageService.fetchOAuthUsage` can be tested without a
/// real network. Configure `statusCode`/`responseData` before each call.
final class MockURLProtocol: URLProtocol {
    static var statusCode = 200
    static var responseData = Data()
    static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        MockURLProtocol.lastRequest = request
        let response = HTTPURLResponse(url: request.url!, statusCode: MockURLProtocol.statusCode,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: MockURLProtocol.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }
}

final class UsageServiceNetworkTests: XCTestCase {

    private let validBody = """
    {
      "five_hour": { "utilization": 35.0, "resets_at": "2026-03-19T19:00:00+00:00" },
      "seven_day": { "utilization": 71.0, "resets_at": "2026-03-20T11:00:00+00:00" },
      "seven_day_sonnet": null
    }
    """.data(using: .utf8)!

    func testDecodesSuccessfulResponse() async throws {
        MockURLProtocol.statusCode = 200
        MockURLProtocol.responseData = validBody
        UsageService.shared.urlSession = MockURLProtocol.session()

        let response = try await UsageService.shared.fetchOAuthUsage(accessToken: "test-token")
        XCTAssertEqual(response.fiveHour?.utilization, 35.0)
        XCTAssertEqual(response.sevenDay?.utilization, 71.0)
    }

    func testSendsOAuthHeaders() async throws {
        MockURLProtocol.statusCode = 200
        MockURLProtocol.responseData = validBody
        UsageService.shared.urlSession = MockURLProtocol.session()

        _ = try await UsageService.shared.fetchOAuthUsage(accessToken: "secret-token")
        let req = MockURLProtocol.lastRequest
        XCTAssertEqual(req?.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
        XCTAssertEqual(req?.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
    }

    func testNon200ThrowsWithStatusCodeAsErrorCode() async {
        // The 429 backoff in fetchUsage keys off error.code == 429, so the status
        // code MUST surface as the NSError code.
        MockURLProtocol.statusCode = 429
        MockURLProtocol.responseData = Data("rate limited".utf8)
        UsageService.shared.urlSession = MockURLProtocol.session()

        do {
            _ = try await UsageService.shared.fetchOAuthUsage(accessToken: "test-token")
            XCTFail("expected fetch to throw on HTTP 429")
        } catch let error as NSError {
            XCTAssertEqual(error.code, 429)
        }
    }

    func testServerErrorThrows() async {
        MockURLProtocol.statusCode = 500
        MockURLProtocol.responseData = Data("boom".utf8)
        UsageService.shared.urlSession = MockURLProtocol.session()

        do {
            _ = try await UsageService.shared.fetchOAuthUsage(accessToken: "test-token")
            XCTFail("expected fetch to throw on HTTP 500")
        } catch let error as NSError {
            XCTAssertEqual(error.code, 500)
        }
    }
}

// MARK: - OAuthUsageResponse decoding

final class OAuthUsageResponseTests: XCTestCase {

    func testDecodesFullResponse() throws {
        let json = """
        {
          "five_hour":   { "utilization": 35.0, "resets_at": "2026-03-19T19:00:00.367134+00:00" },
          "seven_day":   { "utilization": 71.0, "resets_at": "2026-03-20T11:00:00.367161+00:00" },
          "seven_day_sonnet": { "utilization": 27.0, "resets_at": "2026-03-20T12:00:00.367175+00:00" },
          "seven_day_oauth_apps": null,
          "seven_day_opus": null,
          "seven_day_cowork": null,
          "iguana_necktie": null,
          "extra_usage": { "is_enabled": false, "monthly_limit": null, "used_credits": null, "utilization": null }
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(OAuthUsageResponse.self, from: json)

        XCTAssertEqual(response.fiveHour?.utilization, 35.0)
        XCTAssertEqual(response.sevenDay?.utilization, 71.0)
        XCTAssertEqual(response.sevenDaySonnet?.utilization, 27.0)
    }

    func testDecodesNullSonnet() throws {
        let json = """
        {
          "five_hour":   { "utilization": 10.0, "resets_at": "2026-03-19T19:00:00+00:00" },
          "seven_day":   { "utilization": 20.0, "resets_at": "2026-03-20T11:00:00+00:00" },
          "seven_day_sonnet": null
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(OAuthUsageResponse.self, from: json)

        XCTAssertNil(response.sevenDaySonnet)
        XCTAssertEqual(response.fiveHour?.utilization, 10.0)
    }

    func testDecodesAllNulls() throws {
        let json = """
        {
          "five_hour": null,
          "seven_day": null,
          "seven_day_sonnet": null
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(OAuthUsageResponse.self, from: json)

        XCTAssertNil(response.fiveHour)
        XCTAssertNil(response.sevenDay)
        XCTAssertNil(response.sevenDaySonnet)
    }

    func testDecodesNullResetsAt() throws {
        // The real /api/oauth/usage response returns `resets_at: null` for a
        // period that has nothing to reset (e.g. seven_day_sonnet at 0% usage).
        // The whole response must still decode, with resetsAtDate resolving nil.
        let json = """
        {
          "five_hour":   { "utilization": 35.0, "resets_at": "2026-03-19T19:00:00.367134+00:00" },
          "seven_day":   { "utilization": 71.0, "resets_at": "2026-03-20T11:00:00.367161+00:00" },
          "seven_day_sonnet": { "utilization": 0.0, "resets_at": null }
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(OAuthUsageResponse.self, from: json)

        XCTAssertEqual(response.sevenDaySonnet?.utilization, 0.0)
        XCTAssertNil(response.sevenDaySonnet?.resetsAt)
        XCTAssertNil(response.sevenDaySonnet?.resetsAtDate)
        // Periods that do have a reset time are unaffected.
        XCTAssertNotNil(response.fiveHour?.resetsAtDate)
    }

    func testResetsAtDateParsesWithFractionalSeconds() throws {
        let json = """
        {
          "five_hour": { "utilization": 35.0, "resets_at": "2026-03-19T19:00:00.367134+00:00" },
          "seven_day": null, "seven_day_sonnet": null
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(OAuthUsageResponse.self, from: json)
        XCTAssertNotNil(response.fiveHour?.resetsAtDate, "resetsAt date should parse successfully")
    }

    func testUtilizationConvertsToInt() throws {
        let json = """
        {
          "five_hour":   { "utilization": 34.7, "resets_at": "2026-03-19T19:00:00+00:00" },
          "seven_day":   { "utilization": 71.2, "resets_at": "2026-03-20T11:00:00+00:00" },
          "seven_day_sonnet": { "utilization": 26.9, "resets_at": "2026-03-20T12:00:00+00:00" }
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(OAuthUsageResponse.self, from: json)

        // Int() truncates (floors), matching how snapshot builds utilization
        XCTAssertEqual(Int(response.fiveHour!.utilization), 34)
        XCTAssertEqual(Int(response.sevenDay!.utilization), 71)
        XCTAssertEqual(Int(response.sevenDaySonnet!.utilization), 26)
    }
}

// MARK: - calculateUtilization

final class CalculateUtilizationTests: XCTestCase {

    func testZeroTokensIsZeroPercent() {
        XCTAssertEqual(calculateUtilization(tokens: 0, limit: 100_000), 0)
    }

    func testHalfLimitIsFiftyPercent() {
        XCTAssertEqual(calculateUtilization(tokens: 50_000, limit: 100_000), 50)
    }

    func testExceedingLimitCapsAtHundred() {
        XCTAssertEqual(calculateUtilization(tokens: 200_000, limit: 100_000), 100)
    }

    func testExactLimitIsHundredPercent() {
        XCTAssertEqual(calculateUtilization(tokens: 100_000, limit: 100_000), 100)
    }

    func testZeroLimitReturnsZero() {
        XCTAssertEqual(calculateUtilization(tokens: 50_000, limit: 0), 0)
    }

    func testRoundsDown() {
        XCTAssertEqual(calculateUtilization(tokens: 1, limit: 3), 33)
    }
}

// MARK: - Metrics formatting

final class MetricsFormattingTests: XCTestCase {

    func testFormatTokenCount() {
        XCTAssertEqual(formatTokenCount(950), "950")
        XCTAssertEqual(formatTokenCount(1_200), "1.2K")
        XCTAssertEqual(formatTokenCount(44_100_000), "44.1M")
        XCTAssertEqual(formatTokenCount(0), "0")
    }

    func testFormatDuration() {
        XCTAssertEqual(formatDuration(0), "0m")
        XCTAssertEqual(formatDuration(45), "45s")
        XCTAssertEqual(formatDuration(2_048), "34m 8s")
        XCTAssertEqual(formatDuration(3_900), "1h 5m")
    }
}

// MARK: - formatTimeRemaining

final class FormatTimeRemainingTests: XCTestCase {

    func testPastDateReturnsNow() {
        let past = Date().addingTimeInterval(-60)
        XCTAssertEqual(formatTimeRemaining(until: past), "now")
    }

    func testFortyFiveMinutesRemaining() {
        let now = Date()
        XCTAssertEqual(formatTimeRemaining(until: now.addingTimeInterval(45 * 60), from: now), "45m")
    }

    func testTwoHoursThirtyMinutes() {
        let now = Date()
        XCTAssertEqual(formatTimeRemaining(until: now.addingTimeInterval(2 * 3600 + 30 * 60), from: now), "2h 30m")
    }

    func testExactlyOneHour() {
        let now = Date()
        XCTAssertEqual(formatTimeRemaining(until: now.addingTimeInterval(3600), from: now), "1h 0m")
    }
}

// MARK: - Ring gauge fill fraction

final class RingFillFractionTests: XCTestCase {

    func testZeroAndFull() {
        XCTAssertEqual(ringFillFraction(forPercent: 0), 0.0, accuracy: 0.0001)
        XCTAssertEqual(ringFillFraction(forPercent: 100), 1.0, accuracy: 0.0001)
    }

    func testMidpoint() {
        XCTAssertEqual(ringFillFraction(forPercent: 50), 0.5, accuracy: 0.0001)
    }

    func testClampsOutOfRange() {
        // Transient readings outside 0–100 must never draw past a full circle
        // (or a negative arc).
        XCTAssertEqual(ringFillFraction(forPercent: -10), 0.0, accuracy: 0.0001)
        XCTAssertEqual(ringFillFraction(forPercent: 150), 1.0, accuracy: 0.0001)
    }

    func testImageIsTemplateAndSized() {
        // The gauge must be a template image so it adapts to light/dark menu bars.
        let image = menuBarRingImage(fiveHourPercent: 35, sevenDayPercent: 71)
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.size.width, 18, accuracy: 0.5)
        XCTAssertEqual(image.size.height, 18, accuracy: 0.5)
    }
}

// MARK: - formatTimeRemainingCompact (menu-bar "4h12m" form)

final class FormatTimeRemainingCompactTests: XCTestCase {

    func testPastDateReturnsNow() {
        XCTAssertEqual(formatTimeRemainingCompact(until: Date().addingTimeInterval(-1)), "now")
    }

    func testCompactHoursAndMinutesHaveNoSpace() {
        let now = Date()
        XCTAssertEqual(formatTimeRemainingCompact(until: now.addingTimeInterval(4 * 3600 + 12 * 60), from: now), "4h12m")
    }

    func testCompactMinutesOnly() {
        let now = Date()
        XCTAssertEqual(formatTimeRemainingCompact(until: now.addingTimeInterval(45 * 60), from: now), "45m")
    }

    func testCompactExactHourShowsZeroMinutes() {
        let now = Date()
        XCTAssertEqual(formatTimeRemainingCompact(until: now.addingTimeInterval(3600), from: now), "1h0m")
    }
}

// MARK: - extra_usage decoding (the OAuth "Usage credits" object)

final class ExtraUsageDecodingTests: XCTestCase {

    func testDisabledExtraUsageHasNilUtilization() throws {
        let json = """
        {
          "five_hour": { "utilization": 35.0, "resets_at": "2026-03-19T19:00:00+00:00" },
          "seven_day": null, "seven_day_sonnet": null,
          "extra_usage": { "is_enabled": false, "monthly_limit": null, "used_credits": null, "utilization": null }
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(OAuthUsageResponse.self, from: json)
        XCTAssertEqual(response.extraUsage?.isEnabled, false)
        XCTAssertNil(response.extraUsage?.utilization)
    }

    func testEnabledExtraUsageDecodesUtilization() throws {
        let json = """
        {
          "five_hour": null, "seven_day": null, "seven_day_sonnet": null,
          "extra_usage": { "is_enabled": true, "utilization": 42.0 }
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(OAuthUsageResponse.self, from: json)
        XCTAssertEqual(response.extraUsage?.isEnabled, true)
        XCTAssertEqual(response.extraUsage?.utilization, 42.0)
    }

    func testMissingExtraUsageIsNil() throws {
        let json = """
        { "five_hour": null, "seven_day": null, "seven_day_sonnet": null }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(OAuthUsageResponse.self, from: json)
        XCTAssertNil(response.extraUsage)
    }
}

// MARK: - ServiceStatusIndicator mapping

final class ServiceStatusIndicatorTests: XCTestCase {

    func testKnownIndicatorsMap() {
        XCTAssertEqual(ServiceStatusIndicator(rawValue: "none"), ServiceStatusIndicator.none)
        XCTAssertEqual(ServiceStatusIndicator(rawValue: "minor"), .minor)
        XCTAssertEqual(ServiceStatusIndicator(rawValue: "major"), .major)
        XCTAssertEqual(ServiceStatusIndicator(rawValue: "critical"), .critical)
        XCTAssertEqual(ServiceStatusIndicator(rawValue: "maintenance"), .maintenance)
    }

    func testUnknownIndicatorIsNilSoCallerFallsBack() {
        // Statuspage could add a new level; the decoder uses `?? .unknown`, so an
        // unrecognized raw value must not crash — it just maps to nil here.
        XCTAssertNil(ServiceStatusIndicator(rawValue: "apocalypse"))
    }
}

// MARK: - AppSettings Codable migration

final class AppSettingsDecodingTests: XCTestCase {

    private func decode(_ json: String) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: json.data(using: .utf8)!)
    }

    func testEmptyObjectYieldsAllDefaults() throws {
        let s = try decode("{}")
        XCTAssertEqual(s.warningThreshold, 80.0)
        XCTAssertEqual(s.criticalThreshold, 90.0)
        XCTAssertTrue(s.notificationsEnabled)
        XCTAssertTrue(s.showFiveHour)
        XCTAssertTrue(s.showSevenDay)
        XCTAssertFalse(s.showSonnet)
        XCTAssertTrue(s.showFiveHourReset)
        XCTAssertFalse(s.showSevenDayReset)
        XCTAssertTrue(s.showHealth)
        XCTAssertTrue(s.showActivity)
        XCTAssertTrue(s.showUsageCredits)
    }

    func testLegacyCompactDisplayKeyIsIgnoredAndDoesNotThrow() throws {
        // Older builds persisted a now-removed `compactDisplay` key. Decoding must
        // ignore it and fall back to defaults rather than failing (which would
        // wipe every other setting).
        let s = try decode(#"{ "compactDisplay": true, "warningThreshold": 65.0 }"#)
        XCTAssertEqual(s.warningThreshold, 65.0)
        XCTAssertTrue(s.showFiveHour)   // default preserved
        XCTAssertFalse(s.showSonnet)    // default preserved
    }

    func testPartialSettingsOverrideOnlyTheirOwnKeys() throws {
        let s = try decode(#"{ "showSonnet": true, "showFiveHour": false, "criticalThreshold": 95.0 }"#)
        XCTAssertTrue(s.showSonnet)
        XCTAssertFalse(s.showFiveHour)
        XCTAssertEqual(s.criticalThreshold, 95.0)
        XCTAssertEqual(s.warningThreshold, 80.0) // untouched → default
    }

    func testRoundTripPreservesValues() throws {
        var original = AppSettings()
        original.warningThreshold = 55
        original.criticalThreshold = 99
        original.notificationsEnabled = false
        original.showSonnet = true
        original.showSevenDayReset = true
        original.showHealth = false
        original.showUsageCredits = false

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded.warningThreshold, 55)
        XCTAssertEqual(decoded.criticalThreshold, 99)
        XCTAssertFalse(decoded.notificationsEnabled)
        XCTAssertTrue(decoded.showSonnet)
        XCTAssertTrue(decoded.showSevenDayReset)
        XCTAssertFalse(decoded.showHealth)
        XCTAssertFalse(decoded.showUsageCredits)
    }
}

// MARK: - activeSeconds (working-time gap summing)

final class ActiveSecondsTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    func testEmptyAndSingleAreZero() {
        XCTAssertEqual(activeSeconds([]), 0)
        XCTAssertEqual(activeSeconds([base]), 0)
    }

    func testSumsGapsUnderFiveMinutes() {
        let times = [base, base.addingTimeInterval(60), base.addingTimeInterval(120)]
        XCTAssertEqual(activeSeconds(times), 120)
    }

    func testIgnoresGapsOverFiveMinutes() {
        // 60s gap counts; the following 400s idle gap does not.
        let times = [base, base.addingTimeInterval(60), base.addingTimeInterval(460)]
        XCTAssertEqual(activeSeconds(times), 60)
    }

    func testExactlyFiveMinuteGapCounts() {
        let times = [base, base.addingTimeInterval(300)]
        XCTAssertEqual(activeSeconds(times), 300)
    }

    func testUnsortedInputIsSortedFirst() {
        let times = [base.addingTimeInterval(120), base, base.addingTimeInterval(60)]
        XCTAssertEqual(activeSeconds(times), 120)
    }
}

// MARK: - aggregateMetrics (jsonl → today/yesterday usage)

final class AggregateMetricsTests: XCTestCase {

    // A fixed clock; "today"/"yesterday" are derived from it via the same
    // Calendar the production code uses, so the tests are wall-clock independent.
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    /// A timestamp `offset` seconds from the start of `now`'s local day.
    private func todayStamp(_ offset: TimeInterval) -> String {
        iso(Calendar.current.startOfDay(for: now).addingTimeInterval(offset))
    }

    private func line(ts: String, id: String? = nil, reqId: String? = nil,
                      input: Int = 0, output: Int = 0, cacheR: Int = 0, cacheC: Int = 0) -> String {
        var msg = "\"usage\":{\"input_tokens\":\(input),\"output_tokens\":\(output),\"cache_read_input_tokens\":\(cacheR),\"cache_creation_input_tokens\":\(cacheC)}"
        if let id { msg = "\"id\":\"\(id)\"," + msg }
        var fields = ["\"timestamp\":\"\(ts)\"", "\"message\":{\(msg)}"]
        if let reqId { fields.append("\"requestId\":\"\(reqId)\"") }
        return "{" + fields.joined(separator: ",") + "}"
    }

    func testEmptyInputIsEmptyMetrics() {
        let m = aggregateMetrics(jsonlContents: [], now: now)
        XCTAssertEqual(m.todayMessages, 0)
        XCTAssertEqual(m.todayTokens, 0)
        XCTAssertFalse(m.hasData)
    }

    func testSumsTodayTokensAndCounts() {
        let content = [
            line(ts: todayStamp(10 * 3600), id: "a", reqId: "1", input: 100, output: 50, cacheR: 30, cacheC: 20),
            line(ts: todayStamp(10 * 3600 + 60), id: "b", reqId: "2", input: 10, output: 5, cacheR: 0, cacheC: 0)
        ].joined(separator: "\n")

        let m = aggregateMetrics(jsonlContents: [content], now: now)
        XCTAssertEqual(m.todayMessages, 2)
        XCTAssertEqual(m.todayTokens, 100 + 50 + 30 + 20 + 10 + 5)
        XCTAssertEqual(m.todayActiveSeconds, 60)
        XCTAssertTrue(m.hasData)
    }

    func testCachePercentUsesInputSideOnly() {
        // cache% = cacheRead / (input + cacheRead + cacheCreate); output excluded.
        let content = line(ts: todayStamp(36_000), id: "a", reqId: "1",
                           input: 50, output: 999, cacheR: 30, cacheC: 20)
        let m = aggregateMetrics(jsonlContents: [content], now: now)
        XCTAssertEqual(m.todayCachePercent, 30) // 30 / (50+30+20) = 30%
    }

    func testDuplicateMessageAndRequestIdCountedOnce() {
        let dup = line(ts: todayStamp(36_000), id: "same", reqId: "same", input: 100)
        let m = aggregateMetrics(jsonlContents: [dup, dup], now: now)
        XCTAssertEqual(m.todayMessages, 1)
        XCTAssertEqual(m.todayTokens, 100)
    }

    func testSameIdDifferentRequestIdCountedTwice() {
        // Distinct requestId → distinct key → both counted (matches ccusage).
        let a = line(ts: todayStamp(36_000), id: "x", reqId: "1", input: 100)
        let b = line(ts: todayStamp(36_060), id: "x", reqId: "2", input: 100)
        let m = aggregateMetrics(jsonlContents: ["\(a)\n\(b)"], now: now)
        XCTAssertEqual(m.todayMessages, 2)
        XCTAssertEqual(m.todayTokens, 200)
    }

    func testLinesWithoutIdsAreNotDeduped() {
        // Both id and requestId nil → key is ":" → never deduped.
        let l = line(ts: todayStamp(36_000), input: 100)
        let m = aggregateMetrics(jsonlContents: ["\(l)\n\(l)"], now: now)
        XCTAssertEqual(m.todayMessages, 2)
        XCTAssertEqual(m.todayTokens, 200)
    }

    func testYesterdayTokensTrackedSeparately() {
        let today = line(ts: todayStamp(36_000), id: "t", reqId: "1", input: 100)
        let yesterday = line(ts: todayStamp(-2 * 3600), id: "y", reqId: "2", input: 70, output: 30)
        let m = aggregateMetrics(jsonlContents: ["\(today)\n\(yesterday)"], now: now)
        XCTAssertEqual(m.todayTokens, 100)
        XCTAssertEqual(m.todayMessages, 1)
        XCTAssertEqual(m.yesterdayTokens, 100) // 70 + 30
    }

    func testOlderThanYesterdayIsIgnored() {
        let old = line(ts: todayStamp(-26 * 3600), id: "o", reqId: "1", input: 500)
        let m = aggregateMetrics(jsonlContents: [old], now: now)
        XCTAssertEqual(m.todayTokens, 0)
        XCTAssertEqual(m.yesterdayTokens, 0)
    }

    func testMalformedLinesAndEntriesWithoutUsageAreSkipped() {
        let good = line(ts: todayStamp(36_000), id: "g", reqId: "1", input: 100)
        let noUsage = #"{"timestamp":"\#(todayStamp(36_060))","message":{"id":"n"}}"#
        let content = ["not json at all", "", good, noUsage, "{ broken"].joined(separator: "\n")
        let m = aggregateMetrics(jsonlContents: [content], now: now)
        XCTAssertEqual(m.todayMessages, 1)
        XCTAssertEqual(m.todayTokens, 100)
    }

    func testDedupSpansMultipleFiles() {
        // The same entry appearing across two transcript files counts once.
        let dup = line(ts: todayStamp(36_000), id: "shared", reqId: "r", input: 100)
        let m = aggregateMetrics(jsonlContents: [dup, dup], now: now)
        XCTAssertEqual(m.todayMessages, 1)
    }
}
