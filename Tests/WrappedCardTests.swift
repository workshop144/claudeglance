import XCTest
@testable import ClaudeGlance

// MARK: - Wrapped card stats [#26]

final class WrappedCardTests: XCTestCase {

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }

    private func metrics(dailyTokens: [Date: Int] = [:]) -> UsageMetrics {
        UsageMetrics(
            todayTokens: 0, todayCachePercent: 0, todayActiveSeconds: 0, todayMessages: 1,
            yesterdayTokens: 0, todayCostUSD: 0, monthCostUSD: 88.0, monthSavingsUSD: 213.0,
            dailyTokens: dailyTokens,
            costByModel: ["Opus 4.8": 80.0, "Sonnet 4.6": 8.0],
            dailyCost: [:],
            monthInputTokens: 10, monthOutputTokens: 5,
            monthCacheReadTokens: 70, monthCacheCreationTokens: 20)
    }

    private let tools = ToolBreakdown(toolCounts: ["Bash": 1200, "Edit": 300],
                                      mcpServerCounts: ["Gmail": 40, "Slack": 10],
                                      totalCalls: 1550)

    func testBuildMapsHeadlineStats() {
        let now = date("2026-06-12T12:00:00Z")
        let s = buildWrappedStats(metrics: metrics(), tools: tools, now: now, calendar: utc)
        XCTAssertEqual(s.period, "June 2026")
        XCTAssertEqual(s.totalTokens, 105)          // 10+5+70+20
        XCTAssertEqual(s.cachePercent, 70)          // 70 / (10+70+20)
        XCTAssertEqual(s.spentUSD, 88.0, accuracy: 0.0001)
        XCTAssertEqual(s.savedUSD, 213.0, accuracy: 0.0001)
        XCTAssertEqual(s.topModel, "Opus 4.8")
        XCTAssertEqual(s.topTool, "Bash")
        XCTAssertEqual(s.topMcp, "Gmail")
        XCTAssertEqual(s.toolCalls, 1550)
        XCTAssertTrue(s.hasData)
    }

    func testStreakAndActiveDays() {
        let now = date("2026-06-12T12:00:00Z")
        let d = { (s: String) in self.utc.startOfDay(for: self.date(s)) }
        let daily: [Date: Int] = [
            d("2026-06-12T00:00:00Z"): 100,   // today
            d("2026-06-11T00:00:00Z"): 100,   // yesterday → streak 2
            d("2026-06-09T00:00:00Z"): 100    // gap before → still active day
        ]
        let s = buildWrappedStats(metrics: metrics(dailyTokens: daily), tools: tools, now: now, calendar: utc)
        XCTAssertEqual(s.streakDays, 2)
        XCTAssertEqual(s.activeDays, 3)        // all three are in June
    }

    func testEmptyMonthHasNoData() {
        let now = date("2026-06-12T12:00:00Z")
        let empty = UsageMetrics.empty
        let s = buildWrappedStats(metrics: empty, tools: .empty, now: now, calendar: utc)
        XCTAssertFalse(s.hasData)
        XCTAssertEqual(s.cachePercent, 0)
        XCTAssertNil(s.topModel)
        XCTAssertNil(s.topTool)
    }

    @MainActor
    func testRendersToPNG() {
        let now = date("2026-06-12T12:00:00Z")
        let s = buildWrappedStats(metrics: metrics(), tools: tools, now: now, calendar: utc)
        let png = renderWrappedPNG(stats: s, scale: 1)
        XCTAssertNotNil(png)
        // PNG magic number, so we know it's a real image, not empty bytes.
        XCTAssertEqual(png?.prefix(4).map { $0 }, [0x89, 0x50, 0x4E, 0x47])
    }
}
