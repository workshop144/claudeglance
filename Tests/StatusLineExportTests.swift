import XCTest
@testable import ClaudeGlance

// MARK: - Statusline export + setup [#27]

final class StatusLineExportTests: XCTestCase {

    // MARK: Default line formatting

    func testStatusLineUsageOnly() {
        XCTAssertEqual(statusLineText(fiveHourPct: 35, sevenDayPct: 71, sonnetPct: nil),
                       "5h 35% · 7d 71%")
    }

    func testStatusLineAppendsSonnetWhenNonzero() {
        XCTAssertEqual(statusLineText(fiveHourPct: 12, sevenDayPct: 40, sonnetPct: 8),
                       "5h 12% · 7d 40% · Sonnet 8%")
    }

    func testStatusLineHidesZeroOrNilSonnet() {
        XCTAssertEqual(statusLineText(fiveHourPct: 1, sevenDayPct: 2, sonnetPct: 0),
                       "5h 1% · 7d 2%")
        XCTAssertEqual(statusLineText(fiveHourPct: 1, sevenDayPct: 2, sonnetPct: nil),
                       "5h 1% · 7d 2%")
    }

    // MARK: buildStatusExport field mapping + gating

    private func snapshot(fiveHour: Int = 35, sevenDay: Int = 71, sonnet: Int? = nil,
                          fiveHourResetAt: Date? = nil, lastUpdated: Date) -> UsageSnapshot {
        UsageSnapshot(
            fiveHourUtilization: fiveHour, sevenDayUtilization: sevenDay,
            sevenDaySonnetUtilization: sonnet,
            fiveHourResetIn: "2h 0m", sevenDayResetIn: "3d 0h",
            fiveHourResetAt: fiveHourResetAt, sevenDayResetAt: nil,
            lastUpdated: lastUpdated, weeklySessions: 0, weeklyMessages: 0, weeklyTokens: 0,
            extraUsageEnabled: nil, extraUsageUtilization: nil,
            extraUsageUsedCents: nil, extraUsageLimitCents: nil)
    }

    private func metrics(today: Double = 4.21, month: Double = 88.1, tokens: Int = 1_234_567) -> UsageMetrics {
        UsageMetrics(todayTokens: tokens, todayCachePercent: 0, todayActiveSeconds: 0,
                     todayMessages: 1, yesterdayTokens: 0, todayCostUSD: today, monthCostUSD: month,
                     monthSavingsUSD: 0, dailyTokens: [:], costByModel: [:], dailyCost: [:],
                     monthInputTokens: 0, monthOutputTokens: 0, monthCacheReadTokens: 0,
                     monthCacheCreationTokens: 0)
    }

    func testBuildExportMapsCoreFields() {
        let now = Date()
        let export = buildStatusExport(usage: snapshot(lastUpdated: now),
                                       burn: nil, metrics: metrics(), now: now)
        XCTAssertEqual(export.schema, 1)
        XCTAssertEqual(export.fiveHourPct, 35)
        XCTAssertEqual(export.sevenDayPct, 71)
        XCTAssertEqual(export.todayCostUSD, 4.21, accuracy: 0.0001)
        XCTAssertEqual(export.monthCostUSD, 88.1, accuracy: 0.0001)
        XCTAssertEqual(export.todayTokens, 1_234_567)
        XCTAssertEqual(export.line, "5h 35% · 7d 71%")
        XCTAssertFalse(export.stale)
    }

    func testBuildExportFlagsStaleWhenOld() {
        let now = Date()
        let old = now.addingTimeInterval(-20 * 60)   // 20 min ago > 12-min threshold
        let export = buildStatusExport(usage: snapshot(lastUpdated: old),
                                       burn: nil, metrics: metrics(), now: now)
        XCTAssertTrue(export.stale)
    }

    func testBuildExportSetsEtaWhenOnPaceToHitLimit() {
        let now = Date()
        // Reset is an hour out; at this burn we'd hit 100% in 30 min — before reset.
        let burn = BurnEstimate(percentPerHour: 20, secondsToLimit: 1800)
        let export = buildStatusExport(
            usage: snapshot(fiveHourResetAt: now.addingTimeInterval(3600), lastUpdated: now),
            burn: burn, metrics: metrics(), now: now)
        XCTAssertNotNil(export.etaClock)
        XCTAssertEqual(export.burnPerHour, 20)
    }

    func testBuildExportNoEtaWhenResetComesFirst() {
        let now = Date()
        // Reset in 10 min, run-out not for 30 min → no ETA shown.
        let burn = BurnEstimate(percentPerHour: 20, secondsToLimit: 1800)
        let export = buildStatusExport(
            usage: snapshot(fiveHourResetAt: now.addingTimeInterval(600), lastUpdated: now),
            burn: burn, metrics: metrics(), now: now)
        XCTAssertNil(export.etaClock)
    }

    func testBuildExportDropsSubOnePercentBurn() {
        let now = Date()
        let burn = BurnEstimate(percentPerHour: 0.4, secondsToLimit: nil)
        let export = buildStatusExport(usage: snapshot(lastUpdated: now),
                                       burn: burn, metrics: metrics(), now: now)
        XCTAssertNil(export.burnPerHour)
    }

    // MARK: Round-trips through JSON (the sidecar the script reads)

    func testExportEncodesLineWithoutDoubleQuotes() throws {
        let now = Date()
        let export = buildStatusExport(usage: snapshot(lastUpdated: now),
                                       burn: nil, metrics: metrics(), now: now)
        // The script's jq-less fallback extracts `line` with a simple sed, so the
        // line itself must never contain a double quote.
        XCTAssertFalse(export.line.contains("\""))
        let data = try JSONEncoder().encode(export)
        let decoded = try JSONDecoder().decode(StatusExport.self, from: data)
        XCTAssertEqual(decoded, export)
    }

    // MARK: settings.json merge (pure)

    func testMergedSettingsIntoEmptyCreatesStatusLine() throws {
        let merged = StatusLineSetup.mergedSettings(existing: nil, command: "/x/y.sh")
        let obj = try XCTUnwrap(merged.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])
        let sl = try XCTUnwrap(obj["statusLine"] as? [String: Any])
        XCTAssertEqual(sl["type"] as? String, "command")
        XCTAssertEqual(sl["command"] as? String, "/x/y.sh")
    }

    func testMergedSettingsPreservesOtherKeys() throws {
        let existing = #"{"theme":"auto","hooks":{"Stop":[]}}"#.data(using: .utf8)!
        let merged = StatusLineSetup.mergedSettings(existing: existing, command: "/x/y.sh")
        let obj = try XCTUnwrap(merged.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])
        XCTAssertEqual(obj["theme"] as? String, "auto")
        XCTAssertNotNil(obj["hooks"])
        XCTAssertNotNil(obj["statusLine"])
    }

    func testMergedSettingsReplacesExistingStatusLine() throws {
        let existing = #"{"statusLine":{"type":"command","command":"/old.sh"}}"#.data(using: .utf8)!
        let merged = StatusLineSetup.mergedSettings(existing: existing, command: "/new.sh")
        let obj = try XCTUnwrap(merged.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])
        let sl = try XCTUnwrap(obj["statusLine"] as? [String: Any])
        XCTAssertEqual(sl["command"] as? String, "/new.sh")
    }

    func testMergedSettingsRejectsNonObject() {
        let arr = "[1,2,3]".data(using: .utf8)!
        XCTAssertNil(StatusLineSetup.mergedSettings(existing: arr, command: "/x/y.sh"))
    }

    func testHasStatusLineDetection() {
        XCTAssertFalse(StatusLineSetup.hasStatusLine(nil))
        XCTAssertFalse(StatusLineSetup.hasStatusLine("{}".data(using: .utf8)))
        XCTAssertTrue(StatusLineSetup.hasStatusLine(#"{"statusLine":{}}"#.data(using: .utf8)))
    }
}
