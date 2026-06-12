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

// MARK: - Streaks & activity strip

final class ActivityTests: XCTestCase {

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private func day(_ y: Int, _ mo: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d))!
    }

    func testCurrentStreakCountsConsecutiveDaysEndingToday() {
        let today = day(2023, 11, 14)
        let active: Set<Date> = [day(2023, 11, 14), day(2023, 11, 13), day(2023, 11, 12)]
        XCTAssertEqual(currentStreak(activeDays: active, today: today, calendar: cal), 3)
    }

    func testCurrentStreakAllowsTodayInactiveAndCountsFromYesterday() {
        let today = day(2023, 11, 14)   // no activity today yet
        let active: Set<Date> = [day(2023, 11, 13), day(2023, 11, 12)]
        XCTAssertEqual(currentStreak(activeDays: active, today: today, calendar: cal), 2)
    }

    func testCurrentStreakBreaksOnGap() {
        let today = day(2023, 11, 14)
        // Gap: nothing on the 13th, so the streak is broken before today/yesterday.
        let active: Set<Date> = [day(2023, 11, 12), day(2023, 11, 11)]
        XCTAssertEqual(currentStreak(activeDays: active, today: today, calendar: cal), 0)
    }

    func testLongestStreakFindsTheBestRun() {
        let active: Set<Date> = [
            day(2023, 11, 1), day(2023, 11, 2),                      // run of 2
            day(2023, 11, 5), day(2023, 11, 6), day(2023, 11, 7),    // run of 3
            day(2023, 11, 10),                                       // run of 1
        ]
        XCTAssertEqual(longestStreak(activeDays: active, calendar: cal), 3)
        XCTAssertEqual(longestStreak(activeDays: [], calendar: cal), 0)
    }

    func testActivityStripScalesToBusiestDayAndMarksIdleDays() {
        let today = day(2023, 11, 14)
        let tokens: [Date: Int] = [
            day(2023, 11, 14): 100,   // busiest → full block
            day(2023, 11, 13): 0,     // idle → "·"
            day(2023, 11, 12): 50,    // mid
        ]
        let strip = activityStrip(dailyTokens: tokens, days: 3, endingAt: today, calendar: cal)
        // Order is oldest→newest: 12th, 13th, 14th.
        XCTAssertEqual(strip.count, 3)
        XCTAssertEqual(Array(strip)[1], "·")          // idle 13th
        XCTAssertEqual(Array(strip)[2], "█")          // busiest 14th
    }

    func testActivityStripAllIdleIsAllDots() {
        XCTAssertEqual(activityStrip(dailyTokens: [:], days: 5, endingAt: day(2023, 11, 14), calendar: cal), "·····")
    }

    func testSparklineScalesToMax() {
        // 0 → lowest block, 50/100 → mid, 100 → full.
        XCTAssertEqual(sparkline([0, 50, 100], maxValue: 100), "▁▄█")
        XCTAssertEqual(sparkline([], maxValue: 100), "")
        // Out-of-range clamps rather than overflowing the level table.
        XCTAssertEqual(sparkline([150, -10], maxValue: 100), "█▁")
    }

    // Nov 14 2023 is a Tuesday → its week starts Sunday Nov 12.
    func testHeatmapGridShapeAndWeekAlignment() {
        let grid = heatmapGrid(dailyTokens: [:], weeks: 2, endingAt: day(2023, 11, 14), calendar: cal)
        XCTAssertEqual(grid.count, 2)                       // two week-columns
        XCTAssertTrue(grid.allSatisfy { $0.count == 7 })    // Sun…Sat rows
        // Oldest column first; its top cell (Sunday) is Nov 5.
        XCTAssertEqual(grid.first?.first?.date, day(2023, 11, 5))
        // Current week's Tuesday row (index 2) is today, Nov 14.
        XCTAssertEqual(grid.last?[2].date, day(2023, 11, 14))
    }

    func testHeatmapGridFlagsFutureDays() {
        let grid = heatmapGrid(dailyTokens: [:], weeks: 1, endingAt: day(2023, 11, 14), calendar: cal)
        XCTAssertFalse(grid[0][2].isFuture)   // Tue Nov 14 (today)
        XCTAssertTrue(grid[0][3].isFuture)    // Wed Nov 15 (future)
        XCTAssertTrue(grid[0][6].isFuture)    // Sat Nov 18 (future)
    }

    func testHeatmapGridFillsTokensFromDailyMap() {
        let tokens = [day(2023, 11, 14): 1234, day(2023, 11, 13): 0]
        let grid = heatmapGrid(dailyTokens: tokens, weeks: 1, endingAt: day(2023, 11, 14), calendar: cal)
        XCTAssertEqual(grid[0][2].tokens, 1234)   // Tue Nov 14
        XCTAssertEqual(grid[0][1].tokens, 0)      // Mon Nov 13 (present, but zero)
        XCTAssertEqual(grid[0][0].tokens, 0)      // Sun Nov 12 (absent → 0)
    }
}

// MARK: - History store (persisted utilization)

final class HistoryStoreTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testPruneDropsOldSamples() {
        let samples = [
            HistorySample(t: now.addingTimeInterval(-3600), h5: 10, h7: 20),
            HistorySample(t: now.addingTimeInterval(-60), h5: 30, h7: 40),
        ]
        let kept = prunedHistory(samples, since: now.addingTimeInterval(-120))
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?.h5, 30)
    }

    func testHistorySampleDecodesLegacyFileWithoutSonnet() throws {
        // Files written before v1.4.1 have no hSonnet — must still decode (nil).
        let legacy = #"{"t":0,"h5":10,"h7":20}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(HistorySample.self, from: legacy)
        XCTAssertEqual(s.h5, 10)
        XCTAssertNil(s.hSonnet)
        let withSonnet = #"{"t":0,"h5":10,"h7":20,"hSonnet":7}"#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(HistorySample.self, from: withSonnet).hSonnet, 7)
    }

    func testRecentFiveHourReturnsValuesInWindow() {
        let samples = [
            HistorySample(t: now.addingTimeInterval(-7200), h5: 5, h7: 0),   // outside 1h window
            HistorySample(t: now.addingTimeInterval(-1800), h5: 12, h7: 0),
            HistorySample(t: now.addingTimeInterval(-60), h5: 18, h7: 0),
        ]
        XCTAssertEqual(recentFiveHour(samples, within: 3600, now: now), [12, 18])
    }
}

// MARK: - Model pricing & cost

final class PricingTests: XCTestCase {

    func testModelRateMatchingBySubstring() {
        XCTAssertEqual(modelRate(for: "claude-opus-4-8"), ModelRate(input: 5, output: 25))
        XCTAssertEqual(modelRate(for: "claude-3-opus-20240229"), ModelRate(input: 15, output: 75))
        XCTAssertEqual(modelRate(for: "claude-sonnet-4-6"), ModelRate(input: 3, output: 15))
        XCTAssertEqual(modelRate(for: "claude-3-5-haiku-20241022"), ModelRate(input: 0.8, output: 4))
        XCTAssertEqual(modelRate(for: "claude-haiku-4-5"), ModelRate(input: 1, output: 5))
        XCTAssertEqual(modelRate(for: "claude-fable-5"), ModelRate(input: 10, output: 50))
        // Unknown model falls back to Sonnet-class rates.
        XCTAssertEqual(modelRate(for: "some-future-model"), ModelRate(input: 3, output: 15))
    }

    func testTokenCostAppliesRatesAndCacheMultipliers() {
        // Opus 4: $5/1M input, $25/1M output, cache-write 1.25× input, cache-read 0.10× input.
        XCTAssertEqual(tokenCostUSD(model: "claude-opus-4-8", input: 1_000_000, output: 0, cacheCreation: 0, cacheRead: 0), 5.0, accuracy: 1e-9)
        XCTAssertEqual(tokenCostUSD(model: "claude-opus-4-8", input: 0, output: 1_000_000, cacheCreation: 0, cacheRead: 0), 25.0, accuracy: 1e-9)
        XCTAssertEqual(tokenCostUSD(model: "claude-opus-4-8", input: 0, output: 0, cacheCreation: 1_000_000, cacheRead: 0), 6.25, accuracy: 1e-9)
        XCTAssertEqual(tokenCostUSD(model: "claude-opus-4-8", input: 0, output: 0, cacheCreation: 0, cacheRead: 1_000_000), 0.50, accuracy: 1e-9)
    }

    func testZeroTokensCostNothing() {
        XCTAssertEqual(tokenCostUSD(model: "claude-sonnet-4-6", input: 0, output: 0, cacheCreation: 0, cacheRead: 0), 0)
    }

    func testUncachedCostBillsCacheTokensAsInput() {
        // Opus 4: 1M cache-read tokens, uncached, = ordinary input = $5
        // (vs the $0.50 cached cost — a $4.50 saving).
        XCTAssertEqual(tokenCostUncachedUSD(model: "claude-opus-4-8", input: 0, output: 0, cacheCreation: 0, cacheRead: 1_000_000), 5.0, accuracy: 1e-9)
        XCTAssertEqual(tokenCostUncachedUSD(model: "claude-opus-4-8", input: 1_000_000, output: 0, cacheCreation: 0, cacheRead: 1_000_000), 10.0, accuracy: 1e-9)
    }

    func testMonthlyProjection() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        // Day 10 of November (30 days), $100 spent → $10/day × 30 = $300 projected.
        let day10 = cal.date(from: DateComponents(year: 2023, month: 11, day: 10))!
        XCTAssertEqual(monthlyProjection(monthCostUSD: 100, now: day10, calendar: cal), 300, accuracy: 1e-6)
    }

    func testDisplayModelNameExtractsOpusMinor() {
        XCTAssertEqual(displayModelName(for: "claude-opus-4-8-2026"), "Opus 4.8")
        XCTAssertEqual(displayModelName(for: "claude-opus-4-1-20250805"), "Opus 4.1")
    }

    func testDisplayModelNameFamilyFallbacks() {
        XCTAssertEqual(displayModelName(for: "claude-fable-5"), "Fable 5")
        XCTAssertEqual(displayModelName(for: "claude-sonnet-4-6"), "Sonnet")
        XCTAssertEqual(displayModelName(for: "claude-3-5-haiku-20241022"), "Haiku")
        XCTAssertEqual(displayModelName(for: "claude-haiku-4-5"), "Haiku 4.5")
        XCTAssertEqual(displayModelName(for: "claude-3-opus-20240229"), "Opus 3")
        XCTAssertEqual(displayModelName(for: ""), "Unknown")
    }
}

// MARK: - Staleness

final class StalenessTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testFreshDataIsNotStale() {
        XCTAssertFalse(isStale(lastUpdated: now, now: now))
        XCTAssertFalse(isStale(lastUpdated: now.addingTimeInterval(-5 * 60), now: now))
    }

    func testOldDataIsStale() {
        XCTAssertTrue(isStale(lastUpdated: now.addingTimeInterval(-13 * 60), now: now))
    }

    func testThresholdBoundaryIsNotStale() {
        // Exactly at the threshold is not yet stale (strictly greater than).
        XCTAssertFalse(isStale(lastUpdated: now.addingTimeInterval(-12 * 60), now: now))
    }

    func testMinutesAgo() {
        XCTAssertEqual(minutesAgo(now, from: now), 0)
        XCTAssertEqual(minutesAgo(now.addingTimeInterval(-90), from: now), 1)
        XCTAssertEqual(minutesAgo(now.addingTimeInterval(-14 * 60), from: now), 14)
        // A future timestamp (clock skew) clamps to 0 rather than going negative.
        XCTAssertEqual(minutesAgo(now.addingTimeInterval(120), from: now), 0)
    }
}

// MARK: - Reset notifications

final class ShouldNotifyResetTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let threshold = 80

    func testFirstRunDoesNotNotify() {
        // No previous reset yet (startup) -> never notify.
        XCTAssertFalse(shouldNotifyReset(previousResetAt: nil, newResetAt: now,
                                         previousUtilization: 95, threshold: threshold))
    }

    func testNilNewResetDoesNotNotify() {
        XCTAssertFalse(shouldNotifyReset(previousResetAt: now, newResetAt: nil,
                                         previousUtilization: 95, threshold: threshold))
    }

    func testSameOrEarlierBoundaryDoesNotNotify() {
        // Same window (reset time unchanged) -> not a reset.
        XCTAssertFalse(shouldNotifyReset(previousResetAt: now, newResetAt: now,
                                         previousUtilization: 95, threshold: threshold))
    }

    func testResetWhileConstrainedNotifies() {
        let later = now.addingTimeInterval(5 * 60 * 60)
        XCTAssertTrue(shouldNotifyReset(previousResetAt: now, newResetAt: later,
                                        previousUtilization: 95, threshold: threshold))
        // Exactly at threshold counts.
        XCTAssertTrue(shouldNotifyReset(previousResetAt: now, newResetAt: later,
                                        previousUtilization: 80, threshold: threshold))
    }

    func testResetWhileNotConstrainedStaysQuiet() {
        // Window rolled over but you weren't near the limit -> no noise.
        let later = now.addingTimeInterval(5 * 60 * 60)
        XCTAssertFalse(shouldNotifyReset(previousResetAt: now, newResetAt: later,
                                         previousUtilization: 12, threshold: threshold))
    }
}

// MARK: - Burn rate & run-out ETA

final class BurnRateTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func samples(_ pairs: [(min: Double, util: Int)]) -> [UsageSample] {
        pairs.map { UsageSample(time: base.addingTimeInterval($0.min * 60), utilization: $0.util) }
    }

    func testTooFewOrTooShortReturnsNil() {
        XCTAssertNil(estimateBurn(from: []))
        XCTAssertNil(estimateBurn(from: samples([(0, 10)])))
        // Two samples only 1 minute apart — below the 4-minute minimum span.
        XCTAssertNil(estimateBurn(from: samples([(0, 10), (1, 20)])))
    }

    func testRisingUsageEstimatesRateAndEta() {
        // 10% -> 40% over 30 minutes = 60%/hour; 60% remaining at 1%/min = 60 min.
        let estimate = estimateBurn(from: samples([(0, 10), (30, 40)]))
        XCTAssertNotNil(estimate)
        XCTAssertEqual(estimate!.percentPerHour, 60, accuracy: 0.001)
        XCTAssertEqual(estimate!.secondsToLimit!, 3600, accuracy: 0.5)
    }

    func testFlatUsageHasNoRunOut() {
        let estimate = estimateBurn(from: samples([(0, 50), (30, 50)]))
        XCTAssertEqual(estimate?.percentPerHour, 0)
        XCTAssertNil(estimate?.secondsToLimit)
    }

    func testHitsLimitBeforeReset() {
        let estimate = BurnEstimate(percentPerHour: 60, secondsToLimit: 3600)
        // Reset is 2h away, run-out is 1h away -> hits the cap first.
        XCTAssertTrue(estimate.hitsLimitBeforeReset(resetAt: base.addingTimeInterval(7200), now: base))
        // Reset is 30m away, run-out is 1h away -> resets before running out.
        XCTAssertFalse(estimate.hitsLimitBeforeReset(resetAt: base.addingTimeInterval(1800), now: base))
        // No estimate / no reset date -> never "before reset".
        XCTAssertFalse(BurnEstimate(percentPerHour: 0, secondsToLimit: nil)
            .hitsLimitBeforeReset(resetAt: base.addingTimeInterval(7200), now: base))
    }
}

final class ElapsedFractionTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let window: TimeInterval = 5 * 60 * 60   // 5 hours

    func testHalfwayThroughWindow() {
        // Resets in 2.5h of a 5h window → 50% elapsed.
        let resetAt = now.addingTimeInterval(2.5 * 60 * 60)
        XCTAssertEqual(elapsedFraction(resetAt: resetAt, windowLength: window, now: now), 0.5, accuracy: 0.0001)
    }

    func testFreshWindowIsZero() {
        // Resets a full window from now → nothing elapsed yet.
        let resetAt = now.addingTimeInterval(window)
        XCTAssertEqual(elapsedFraction(resetAt: resetAt, windowLength: window, now: now), 0.0, accuracy: 0.0001)
    }

    func testAtResetIsOne() {
        XCTAssertEqual(elapsedFraction(resetAt: now, windowLength: window, now: now), 1.0, accuracy: 0.0001)
    }

    func testClampsBeyondBounds() {
        // A reset already in the past clamps to fully elapsed, not >1.
        XCTAssertEqual(elapsedFraction(resetAt: now.addingTimeInterval(-3600), windowLength: window, now: now), 1.0)
        // A reset further out than the window clamps to 0, not negative.
        XCTAssertEqual(elapsedFraction(resetAt: now.addingTimeInterval(window + 3600), windowLength: window, now: now), 0.0)
    }
}

final class AppendingSampleTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    func testAppendsToBuffer() {
        let a = UsageSample(time: base, utilization: 10)
        let b = UsageSample(time: base.addingTimeInterval(300), utilization: 20)
        let result = appendingSample(b, to: [a])
        XCTAssertEqual(result, [a, b])
    }

    func testResetsWhenUtilizationDrops() {
        let a = UsageSample(time: base, utilization: 90)
        // Window reset: utilization fell, so the old high sample is discarded.
        let b = UsageSample(time: base.addingTimeInterval(300), utilization: 5)
        XCTAssertEqual(appendingSample(b, to: [a]), [b])
    }

    func testPrunesSamplesOlderThanWindow() {
        let old = UsageSample(time: base, utilization: 10)
        let recent = UsageSample(time: base.addingTimeInterval(3000), utilization: 20)
        // New sample is >1h after `old`, so `old` is pruned out of the window.
        let new = UsageSample(time: base.addingTimeInterval(3700), utilization: 30)
        XCTAssertEqual(appendingSample(new, to: [old, recent], window: 3600), [recent, new])
    }
}

// MARK: - formatDollars (usage-credits overage line)

final class FormatDollarsTests: XCTestCase {

    func testWholeDollarsDropDecimals() {
        XCTAssertEqual(formatDollars(cents: 5000), "$50")
        XCTAssertEqual(formatDollars(cents: 0), "$0")
    }

    func testFractionalDollarsShowTwoDecimals() {
        XCTAssertEqual(formatDollars(cents: 120), "$1.20")
        XCTAssertEqual(formatDollars(cents: 12050), "$120.50")
        XCTAssertEqual(formatDollars(cents: 7), "$0.07")
    }
}

// MARK: - Build info (Settings footer provenance)

final class BuildInfoTests: XCTestCase {

    private let repo = "https://github.com/broots144/claudeglance"

    func testLabelVersionOnlyWhenNoCommit() {
        XCTAssertEqual(buildInfoLabel(version: "1.1.1", branch: nil, commit: nil), "v1.1.1")
        XCTAssertEqual(buildInfoLabel(version: "1.1.1", branch: "feature/x", commit: nil), "v1.1.1")
    }

    func testLabelCommitOnlyOnMainOrNoBranch() {
        XCTAssertEqual(buildInfoLabel(version: "1.1.1", branch: "main", commit: "abc1234"), "v1.1.1 · abc1234")
        XCTAssertEqual(buildInfoLabel(version: "1.1.1", branch: "HEAD", commit: "abc1234"), "v1.1.1 · abc1234")
        XCTAssertEqual(buildInfoLabel(version: "1.1.1", branch: nil, commit: "abc1234"), "v1.1.1 · abc1234")
    }

    func testLabelShowsBranchOnFeatureBranch() {
        XCTAssertEqual(buildInfoLabel(version: "1.1.1", branch: "feature/v1.1-build-info", commit: "abc1234"),
                       "v1.1.1 · feature/v1.1-build-info@abc1234")
    }

    func testChannelIsProdForReleaseOrMain() {
        XCTAssertEqual(buildChannel(branch: nil), "prod")     // release build (no branch passed)
        XCTAssertEqual(buildChannel(branch: ""), "prod")
        XCTAssertEqual(buildChannel(branch: "main"), "prod")
    }

    func testChannelIsDevForFeatureOrDevelop() {
        XCTAssertEqual(buildChannel(branch: "develop"), "dev")
        XCTAssertEqual(buildChannel(branch: "feature/v1.2-build-channel"), "dev")
    }

    func testURLPrefersCommitThenBranchThenRepo() {
        XCTAssertEqual(buildInfoURL(repo: repo, branch: "feature/x", commit: "abc1234").absoluteString,
                       "\(repo)/commit/abc1234")
        XCTAssertEqual(buildInfoURL(repo: repo, branch: "feature/x", commit: nil).absoluteString,
                       "\(repo)/tree/feature/x")
        XCTAssertEqual(buildInfoURL(repo: repo, branch: nil, commit: nil).absoluteString, repo)
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

    func testEnabledExtraUsageDecodesDollarFields() throws {
        let json = """
        {
          "five_hour": null, "seven_day": null, "seven_day_sonnet": null,
          "extra_usage": { "is_enabled": true, "utilization": 2.0, "used_credits": 120, "monthly_limit": 5000 }
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(OAuthUsageResponse.self, from: json)
        XCTAssertEqual(response.extraUsage?.usedCredits, 120)
        XCTAssertEqual(response.extraUsage?.monthlyLimit, 5000)
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
                      input: Int = 0, output: Int = 0, cacheR: Int = 0, cacheC: Int = 0,
                      model: String? = nil) -> String {
        var msg = "\"usage\":{\"input_tokens\":\(input),\"output_tokens\":\(output),\"cache_read_input_tokens\":\(cacheR),\"cache_creation_input_tokens\":\(cacheC)}"
        if let model { msg = "\"model\":\"\(model)\"," + msg }
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

    func testTodayCostFromModelPricing() {
        // 1M input + 1M output on Opus 4 = $5 + $25 = $30.
        let content = line(ts: todayStamp(36_000), id: "a", reqId: "1",
                           input: 1_000_000, output: 1_000_000, model: "claude-opus-4-8")
        let m = aggregateMetrics(jsonlContents: [content], now: now)
        XCTAssertEqual(m.todayCostUSD, 30.0, accuracy: 1e-6)
    }

    func testMonthCostIncludesEarlierThisMonthNotLastMonth() {
        let today = line(ts: todayStamp(36_000), id: "t", reqId: "1",
                         input: 1_000_000, output: 1_000_000, model: "claude-opus-4-8")   // $30
        let earlier = line(ts: todayStamp(-9 * 86_400), id: "e", reqId: "2",
                           input: 1_000_000, model: "claude-opus-4-8")                    // $5, earlier this month
        let lastMonth = line(ts: todayStamp(-25 * 86_400), id: "l", reqId: "3",
                             input: 1_000_000, model: "claude-opus-4-8")                  // $5, previous month (excluded)
        let m = aggregateMetrics(jsonlContents: ["\(today)\n\(earlier)\n\(lastMonth)"], now: now)
        XCTAssertEqual(m.todayCostUSD, 30, accuracy: 1e-6)
        XCTAssertEqual(m.monthCostUSD, 35, accuracy: 1e-6)
    }

    func testMonthCacheSavings() {
        // Today, Opus 4, 1M cache-read tokens: actual $0.50, uncached $5.00,
        // so caching saved $4.50 (counted into the month).
        let l = line(ts: todayStamp(36_000), id: "c", reqId: "1", cacheR: 1_000_000, model: "claude-opus-4-8")
        let m = aggregateMetrics(jsonlContents: [l], now: now)
        XCTAssertEqual(m.monthSavingsUSD, 4.5, accuracy: 1e-6)
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

    func testCostByModelGroupsMonthToDateByDisplayName() {
        // Opus 4.8 today ($30) + earlier-this-month Opus 4.8 ($5) collapse into one
        // "Opus 4.8" bucket; a Sonnet line lands in its own bucket; last month excluded.
        let opusToday = line(ts: todayStamp(36_000), id: "a", reqId: "1",
                             input: 1_000_000, output: 1_000_000, model: "claude-opus-4-8")   // $30
        let opusEarlier = line(ts: todayStamp(-8 * 86_400), id: "b", reqId: "2",
                               input: 1_000_000, model: "claude-opus-4-8")                     // $5
        let sonnet = line(ts: todayStamp(36_100), id: "c", reqId: "3",
                          input: 1_000_000, model: "claude-sonnet-4-6")                        // $3
        let lastMonth = line(ts: todayStamp(-25 * 86_400), id: "d", reqId: "4",
                             input: 1_000_000, model: "claude-opus-4-8")                       // excluded
        let m = aggregateMetrics(jsonlContents: ["\(opusToday)\n\(opusEarlier)\n\(sonnet)\n\(lastMonth)"], now: now)
        XCTAssertEqual(m.costByModel["Opus 4.8"] ?? 0, 35, accuracy: 1e-6)
        XCTAssertEqual(m.costByModel["Sonnet"] ?? 0, 3, accuracy: 1e-6)
        XCTAssertNil(m.costByModel["Opus 4"])  // nothing leaked from last month
    }

    func testDailyCostBucketsByDayOverLookback() {
        // Two lines today, one ~5 days ago → today's bucket sums both; the older day
        // has its own bucket. Daily cost spans the 30-day window, not just this month.
        let t1 = line(ts: todayStamp(36_000), id: "a", reqId: "1", input: 1_000_000, model: "claude-opus-4-8")  // $5
        let t2 = line(ts: todayStamp(40_000), id: "b", reqId: "2", input: 1_000_000, model: "claude-opus-4-8")  // $5
        let older = line(ts: todayStamp(-5 * 86_400), id: "c", reqId: "3", input: 1_000_000, model: "claude-opus-4-8") // $5
        let m = aggregateMetrics(jsonlContents: ["\(t1)\n\(t2)\n\(older)"], now: now)
        let today = Calendar.current.startOfDay(for: now)
        let olderDay = Calendar.current.date(byAdding: .day, value: -5, to: today)!
        XCTAssertEqual(m.dailyCost[today] ?? 0, 10, accuracy: 1e-6)
        XCTAssertEqual(m.dailyCost[olderDay] ?? 0, 5, accuracy: 1e-6)
    }
}

// MARK: - aggregateContextWindows (jsonl → per-session context fill)

final class AggregateContextWindowsTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    /// A timestamp `seconds` before `now`.
    private func ago(_ seconds: TimeInterval) -> String { iso(now.addingTimeInterval(-seconds)) }

    private func line(session: String, ts: String, role: String = "assistant",
                      model: String? = "claude-opus-4-8",
                      input: Int = 0, cacheR: Int = 0, cacheC: Int = 0, output: Int = 0,
                      sidechain: Bool = false, cwd: String? = "/Users/me/dev/proj",
                      branch: String? = nil) -> String {
        var msg = "\"role\":\"\(role)\",\"usage\":{\"input_tokens\":\(input),\"output_tokens\":\(output),\"cache_read_input_tokens\":\(cacheR),\"cache_creation_input_tokens\":\(cacheC)}"
        if let model { msg = "\"model\":\"\(model)\"," + msg }
        var fields = ["\"sessionId\":\"\(session)\"", "\"timestamp\":\"\(ts)\"",
                      "\"isSidechain\":\(sidechain)", "\"message\":{\(msg)}"]
        if let cwd { fields.append("\"cwd\":\"\(cwd)\"") }
        if let branch { fields.append("\"gitBranch\":\"\(branch)\"") }
        return "{" + fields.joined(separator: ",") + "}"
    }

    func testEmptyInputHasNoSessions() {
        let m = aggregateContextWindows(jsonlContents: [], now: now)
        XCTAssertFalse(m.hasData)
        XCTAssertNil(m.active)
        XCTAssertEqual(m.maxUtilization, 0)
    }

    func testContextIsLatestTurnPromptSize() {
        // input + both cache sides = what was sent to the model = the context fill.
        let l = line(session: "s1", ts: ago(60), input: 2, cacheR: 50_000, cacheC: 8_000, output: 900)
        let m = aggregateContextWindows(jsonlContents: [l], now: now)
        let s = try! XCTUnwrap(m.active)
        XCTAssertEqual(s.contextTokens, 58_002)         // output (900) excluded
        XCTAssertEqual(s.windowLimit, 200_000)
        XCTAssertEqual(s.utilization, 29)               // 58002 / 200000 ≈ 29%
        XCTAssertEqual(s.tokensRemaining, 141_998)
        XCTAssertEqual(s.model, "Opus 4.8")
        XCTAssertEqual(s.project, "proj")
    }

    func testReportsLatestTurnNotPeak() {
        // An auto-compact shrinks context: a big earlier turn then a small later one
        // must report the *latest* (current) fill, not the historical maximum.
        let big = line(session: "s1", ts: ago(600), input: 180_000)
        let small = line(session: "s1", ts: ago(60), input: 20_000)
        let m = aggregateContextWindows(jsonlContents: ["\(big)\n\(small)"], now: now)
        XCTAssertEqual(m.active?.contextTokens, 20_000)
    }

    func testSidechainTurnsExcluded() {
        // Subagent sidechains have their own context window — ignore them.
        let main = line(session: "s1", ts: ago(120), input: 30_000)
        let side = line(session: "s1", ts: ago(60), input: 150_000, sidechain: true)
        let m = aggregateContextWindows(jsonlContents: ["\(main)\n\(side)"], now: now)
        XCTAssertEqual(m.active?.contextTokens, 30_000)
    }

    func testSyntheticModelExcluded() {
        let real = line(session: "s1", ts: ago(120), input: 40_000)
        let synth = line(session: "s1", ts: ago(60), model: "<synthetic>", input: 999_999)
        let m = aggregateContextWindows(jsonlContents: ["\(real)\n\(synth)"], now: now)
        XCTAssertEqual(m.active?.contextTokens, 40_000)
    }

    func testStaleSessionsDropped() {
        // Two days old, outside the 24h "live" window → not reported.
        let old = line(session: "s1", ts: ago(48 * 3600), input: 50_000)
        let m = aggregateContextWindows(jsonlContents: [old], now: now)
        XCTAssertFalse(m.hasData)
    }

    func testMultipleSessionsSortedByRecency() {
        let older = line(session: "s1", ts: ago(600), input: 10_000)   // 5%
        let newer = line(session: "s2", ts: ago(60), input: 90_000)    // 45%
        let m = aggregateContextWindows(jsonlContents: ["\(older)\n\(newer)"], now: now)
        XCTAssertEqual(m.sessions.count, 2)
        XCTAssertEqual(m.active?.sessionId, "s2")           // most recent is the headline
        XCTAssertEqual(m.sessions.last?.sessionId, "s1")
        XCTAssertEqual(m.maxUtilization, 45)
    }

    func testProjectAndBranchFromTopLevelFields() {
        let l = line(session: "s1", ts: ago(60), input: 1_000,
                     cwd: "/Users/me/dev/claudeglance", branch: "feature/x")
        let s = try! XCTUnwrap(aggregateContextWindows(jsonlContents: [l], now: now).active)
        XCTAssertEqual(s.project, "claudeglance")
        XCTAssertEqual(s.gitBranch, "feature/x")
    }

    func testUtilizationCapsAt100() {
        let l = line(session: "s1", ts: ago(60), input: 250_000)   // over the window
        let s = try! XCTUnwrap(aggregateContextWindows(jsonlContents: [l], now: now).active)
        XCTAssertEqual(s.utilization, 100)
        XCTAssertEqual(s.tokensRemaining, 0)
    }

    func testThresholdFlags() {
        let caution = try! XCTUnwrap(aggregateContextWindows(
            jsonlContents: [line(session: "s1", ts: ago(60), input: 150_000)], now: now).active)  // 75%
        XCTAssertTrue(caution.isCaution)
        XCTAssertFalse(caution.isHigh)

        let high = try! XCTUnwrap(aggregateContextWindows(
            jsonlContents: [line(session: "s2", ts: ago(60), input: 190_000)], now: now).active)  // 95%
        XCTAssertTrue(high.isHigh)
        XCTAssertFalse(high.isCaution)
    }

    func testUserTurnsIgnored() {
        // Only assistant turns carry the prompt-size usage we monitor.
        let user = line(session: "s1", ts: ago(60), role: "user", input: 99_999)
        let m = aggregateContextWindows(jsonlContents: [user], now: now)
        XCTAssertFalse(m.hasData)
    }
}

// MARK: - parseOAuthExpiry (Keychain epoch → Date, unit-safe)

final class ParseOAuthExpiryTests: XCTestCase {
    func testMillisecondsEpochInterpretedAsMs() {
        // Claude Code writes ms: 1_700_000_000_000 ms == 1_700_000_000 s.
        XCTAssertEqual(parseOAuthExpiry(1_700_000_000_000).timeIntervalSince1970, 1_700_000_000, accuracy: 0.001)
    }

    func testSecondsEpochInterpretedAsSeconds() {
        // A seconds-format value must not be divided by 1000 (would land in 1970).
        XCTAssertEqual(parseOAuthExpiry(1_700_000_000).timeIntervalSince1970, 1_700_000_000, accuracy: 0.001)
    }
}
