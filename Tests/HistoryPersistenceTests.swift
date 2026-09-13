import XCTest
@testable import ClaudeGlance

// MARK: - History that survives upgrades, log cleanup and reinstalls

final class HistoryPersistenceTests: XCTestCase {

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }

    // MARK: Versioned envelope

    /// The pre-versioning files wrote the payload at the top level. They have to
    /// keep decoding, or an upgrade silently starts from zero.
    func testDecodeReadsLegacyTopLevelPayload() throws {
        let legacy = try JSONEncoder().encode([HistorySample(t: date("2026-09-01T00:00:00Z"), h5: 40, h7: 12)])
        let decoded = DurableJSON.decode(legacy, as: [HistorySample].self)
        XCTAssertEqual(decoded?.count, 1)
        XCTAssertEqual(decoded?.first?.h5, 40)
    }

    func testDecodeReadsVersionedEnvelope() throws {
        let samples = [HistorySample(t: date("2026-09-01T00:00:00Z"), h5: 40, h7: 12)]
        let wrapped = try JSONEncoder().encode(HistoryFile(payload: samples))
        XCTAssertEqual(DurableJSON.decode(wrapped, as: [HistorySample].self)?.first?.h5, 40)
    }

    func testDecodeReturnsNilForGarbageRatherThanEmpty() {
        // nil is the signal to quarantine; an empty array would look like "no
        // history" and get overwritten on the next write.
        XCTAssertNil(DurableJSON.decode(Data("not json".utf8), as: [HistorySample].self))
    }

    // MARK: Utilization history

    func testDownsamplingKeepsRecentSamplesAtFullResolution() {
        let now = date("2026-09-13T12:00:00Z")
        let samples = (0..<6).map {
            HistorySample(t: now.addingTimeInterval(Double(-$0) * 300), h5: 10, h7: 5)
        }
        XCTAssertEqual(downsampledHistory(samples, now: now).count, 6)
    }

    func testDownsamplingRollsOldSamplesToHourlyPeaks() {
        let now = date("2026-09-13T12:00:00Z")
        // Four readings inside one hour, a week back — well past the 48h raw window.
        let hour = date("2026-09-06T03:00:00Z")
        let samples = [
            HistorySample(t: hour, h5: 10, h7: 4),
            HistorySample(t: hour.addingTimeInterval(900), h5: 71, h7: 5),
            HistorySample(t: hour.addingTimeInterval(1800), h5: 30, h7: 6),
            HistorySample(t: hour.addingTimeInterval(2700), h5: 12, h7: 7),
        ]
        let out = downsampledHistory(samples, now: now)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.h5, 71, "the hour should keep its worst 5h reading")
    }

    func testDownsamplingIsStableUnderRepeatedApplication() {
        let now = date("2026-09-13T12:00:00Z")
        let old = date("2026-08-01T03:00:00Z")
        let samples = (0..<12).map { HistorySample(t: old.addingTimeInterval(Double($0) * 300), h5: $0, h7: 1) }
        let once = downsampledHistory(samples, now: now)
        XCTAssertEqual(downsampledHistory(once, now: now), once)
    }

    func testMergedHistoryUnionsBothCopiesByTimestamp() {
        let a = [HistorySample(t: date("2026-09-01T00:00:00Z"), h5: 1, h7: 1)]
        let b = [HistorySample(t: date("2026-09-02T00:00:00Z"), h5: 2, h7: 2)]
        let merged = mergedHistory(a, b)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.map(\.h5), [1, 2], "oldest first")
    }

    /// The mirror copy is the whole point of surviving an uninstall: if Application
    /// Support is wiped, unioning with `~/.claudeglance` has to bring history back.
    func testMergedHistoryRecoversFromAWipedPrimary() {
        let mirror = (0..<5).map { HistorySample(t: date("2026-09-0\($0 + 1)T00:00:00Z"), h5: $0, h7: $0) }
        XCTAssertEqual(mergedHistory([], mirror).count, 5)
    }

    func testMergedHistoryPrefersTheFirstCopyOnADuplicateTimestamp() {
        let t = date("2026-09-01T00:00:00Z")
        let merged = mergedHistory([HistorySample(t: t, h5: 9, h7: 9)], [HistorySample(t: t, h5: 1, h7: 1)])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.h5, 9)
    }

    // MARK: Daily activity archive

    private func day(_ tokens: Int, cost: Double = 1, messages: Int = 1) -> DailyActivity {
        DailyActivity(tokens: tokens, input: tokens, output: 0, cacheRead: 0,
                      cacheCreation: 0, cost: cost, messages: messages, activeSeconds: 60)
    }

    /// The regression this whole store exists for: Claude Code deletes transcripts
    /// after ~30 days, so a later scan sees *less* of a day than the first one did.
    /// Merging must not let a recorded day shrink.
    func testArchiveNeverErodesADayWhenLogsAgeOut() {
        let full = ActivityArchive(days: ["2026-08-01": day(1_000_000)])
        let afterCleanup = mergedArchive(full, adding: ["2026-08-01": day(0, cost: 0, messages: 0)])
        XCTAssertEqual(afterCleanup.days["2026-08-01"]?.tokens, 1_000_000)
    }

    func testArchiveGrowsWhenADaySeesMoreActivity() {
        let morning = ActivityArchive(days: ["2026-09-13": day(100)])
        let evening = mergedArchive(morning, adding: ["2026-09-13": day(900, cost: 4)])
        XCTAssertEqual(evening.days["2026-09-13"]?.tokens, 900)
        XCTAssertEqual(evening.days["2026-09-13"]?.cost, 4)
    }

    func testArchiveAccumulatesDaysBeyondTheScanWindow() {
        var archive = ActivityArchive()
        for d in 1...45 {
            archive = mergedArchive(archive, adding: [String(format: "2026-07-%02d", d % 31 + 1): day(10)])
        }
        XCTAssertGreaterThan(archive.days.count, 30, "history should outlive the 30-day scan window")
    }

    func testEmptyDaysAreNotRecorded() {
        let archive = mergedArchive(ActivityArchive(), adding: ["2026-09-13": .zero])
        XCTAssertTrue(archive.days.isEmpty, "an idle day shouldn't create a row")
    }

    func testMergeActivityTakesTheMaxOfEveryField() {
        let a = DailyActivity(tokens: 5, input: 1, output: 9, cacheRead: 2, cacheCreation: 0,
                              cost: 3, messages: 7, activeSeconds: 10)
        let b = DailyActivity(tokens: 9, input: 4, output: 2, cacheRead: 0, cacheCreation: 6,
                              cost: 1, messages: 2, activeSeconds: 90)
        XCTAssertEqual(mergeActivity(a, b),
                       DailyActivity(tokens: 9, input: 4, output: 9, cacheRead: 2, cacheCreation: 6,
                                     cost: 3, messages: 7, activeSeconds: 90))
    }

    // MARK: Day keys

    func testDayKeyRoundTrips() {
        let d = utc.startOfDay(for: date("2026-09-13T15:04:05Z"))
        XCTAssertEqual(dayKeyDate(statusDayKey(d, calendar: utc), calendar: utc), d)
    }

    func testDayKeyDateRejectsGarbage() {
        XCTAssertNil(dayKeyDate("not-a-date", calendar: utc))
    }

    func testArchiveDailyTokensSkipsUnparseableKeysInsteadOfCrashing() {
        let archive = ActivityArchive(days: ["2026-09-13": day(50), "garbage": day(99)])
        let tokens = archiveDailyTokens(archive, calendar: utc)
        XCTAssertEqual(tokens.count, 1)
        XCTAssertEqual(tokens.values.first, 50)
    }

    func testArchiveDailyTokensHonorsTheSinceWindow() {
        let archive = ActivityArchive(days: ["2026-08-01": day(10), "2026-09-13": day(20)])
        let windowed = archiveDailyTokens(archive, since: date("2026-09-01T00:00:00Z"), calendar: utc)
        XCTAssertEqual(windowed.count, 1)
        XCTAssertEqual(windowed.values.first, 20)
    }

    // MARK: Streaks over archived history

    /// A 40-day streak used to read as 30, because the only source was the 30-day
    /// scan window. Reading the archive instead has to report the real run.
    func testStreakSpansBeyondTheThirtyDayScanWindow() {
        let today = utc.startOfDay(for: date("2026-09-13T09:00:00Z"))
        var archive = ActivityArchive()
        for back in 0..<40 {
            let d = utc.date(byAdding: .day, value: -back, to: today)!
            archive = mergedArchive(archive, adding: [statusDayKey(d, calendar: utc): day(1000)])
        }
        let active = Set(archiveDailyTokens(archive, calendar: utc).filter { $0.value > 0 }.keys)
        XCTAssertEqual(currentStreak(activeDays: active, today: today, calendar: utc), 40)
    }

    // MARK: Backup round-trip

    func testBackupEncodesAndDecodesEveryStore() throws {
        let backup = HistoryBackup(
            usage: [HistorySample(t: date("2026-09-01T00:00:00Z"), h5: 40, h7: 12, hSonnet: 7)],
            status: StatusHistory(days: ["2026-09-01": "minor"]),
            activity: ActivityArchive(days: ["2026-09-01": day(123)]))

        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(HistoryBackup.self, from: encoder.encode(backup))

        XCTAssertEqual(restored.usage, backup.usage)
        XCTAssertEqual(restored.status, backup.status)
        XCTAssertEqual(restored.activity, backup.activity)
    }

    func testBackupSummaryCountsWhatCameBack() {
        let backup = HistoryBackup(usage: [], status: StatusHistory(days: ["2026-09-01": "none"]),
                                   activity: ActivityArchive(days: ["2026-09-01": day(1)]))
        XCTAssertEqual(HistoryBackupService.summary(backup),
                       "Imported 1 activity days, 1 status days, 0 usage samples.")
    }

    // MARK: Status history merge

    func testMergedStatusHistoryKeepsTheWorseDay() {
        let a = StatusHistory(days: ["2026-09-01": "none", "2026-09-02": "major"])
        let b = StatusHistory(days: ["2026-09-01": "critical", "2026-09-03": "minor"])
        let merged = mergedStatusHistory(a, b)
        XCTAssertEqual(merged.days["2026-09-01"], "critical")
        XCTAssertEqual(merged.days["2026-09-02"], "major")
        XCTAssertEqual(merged.days["2026-09-03"], "minor")
    }

    // MARK: Storage locations

    /// Two copies, in two places an uninstaller is unlikely to hit together.
    func testStorageWritesToBothApplicationSupportAndTheHomeMirror() {
        let paths = HistoryStorage.locations(for: "usage-history.json").map(\.path)
        XCTAssertEqual(paths.count, 2)
        XCTAssertTrue(paths.contains { $0.contains("Application Support/ClaudeGlance") }, "\(paths)")
        XCTAssertTrue(paths.contains { $0.contains("/.claudeglance/") }, "\(paths)")
    }
}
