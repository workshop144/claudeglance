import XCTest
@testable import ClaudeGlance

// Coverage for the I/O glue around the pure helpers: durable history files, the
// shared stores, backup restore, the status poller, Retry-After plumbing and the
// statusline installer. Every file lives in a temp folder (HistoryStorage's test
// sandbox or a per-test directory) and every request hits a stub, never the
// network or the developer's real history.

// MARK: - Routing URL stub

/// Answers by URL path, with optional headers, so one session can serve
/// status.json and incidents.json differently.
final class RoutingURLProtocol: URLProtocol {
    struct Stub { var status: Int; var body: Data; var headers: [String: String] = [:] }
    private static let lock = NSLock()
    private static var _stubs: [String: Stub] = [:]
    /// Guarded so URLSession's loader thread never reads while a test writes.
    static var stubs: [String: Stub] {
        get { lock.lock(); defer { lock.unlock() }; return _stubs }
        set { lock.lock(); defer { lock.unlock() }; _stubs = newValue }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let stub = RoutingURLProtocol.stubs[request.url!.path]
            ?? Stub(status: 404, body: Data("not stubbed".utf8))
        let response = HTTPURLResponse(url: request.url!, statusCode: stub.status,
                                       httpVersion: nil, headerFields: stub.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RoutingURLProtocol.self]
        return URLSession(configuration: config)
    }
}

// MARK: - Sandbox cleanup

/// Removes HistoryStorage's per-run temp folder once the whole bundle has run,
/// so test runs don't pile synthetic history up in TMPDIR.
final class TestSandboxCleanup: NSObject, XCTestObservation {
    private static var registered = false
    static func register() {
        guard !registered else { return }
        registered = true
        XCTestObservationCenter.shared.addTestObserver(TestSandboxCleanup())
    }
    func testBundleDidFinish(_ testBundle: Bundle) {
        if let sandbox = HistoryStorage.testSandbox {
            try? FileManager.default.removeItem(at: sandbox)
        }
    }
}

// MARK: - Durable JSON files

final class DurableJSONStorageTests: XCTestCase {
    private var file = ""

    override class func setUp() {
        super.setUp()
        TestSandboxCleanup.register()
    }

    override func setUp() {
        file = "test-\(UUID().uuidString).json"
    }

    override func tearDown() {
        let fm = FileManager.default
        for url in HistoryStorage.locations(for: file) {
            try? fm.removeItem(at: url)
            try? fm.removeItem(at: url.deletingPathExtension().appendingPathExtension("corrupt.json"))
        }
    }

    private func maxMerge(_ a: [String: Int], _ b: [String: Int]) -> [String: Int] {
        a.merging(b) { max($0, $1) }
    }

    private func load() -> [String: Int]? {
        DurableJSON.load(file, as: [String: Int].self, merging: maxMerge)
    }

    func testTestsNeverTouchTheRealHistoryFolders() throws {
        let sandbox = try XCTUnwrap(HistoryStorage.testSandbox, "XCTest host must use the sandbox")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for url in HistoryStorage.locations(for: file) {
            XCTAssertTrue(url.path.hasPrefix(sandbox.path), url.path)
            XCTAssertFalse(url.path.hasPrefix(home + "/.claudeglance"), url.path)
            XCTAssertFalse(url.path.hasPrefix(home + "/Library/Application Support"), url.path)
        }
        let export = try XCTUnwrap(StatusLineExporter.fileURL)
        XCTAssertTrue(export.path.hasPrefix(sandbox.path), "status.json must stay in the sandbox: \(export.path)")
    }

    func testSaveWritesAVersionedEnvelopeToBothCopies() throws {
        DurableJSON.save(["a": 1], to: file)
        let urls = HistoryStorage.locations(for: file)
        XCTAssertEqual(urls.count, 2)
        for url in urls {
            let data = try Data(contentsOf: url)
            let env = try JSONDecoder().decode(HistoryFile<[String: Int]>.self, from: data)
            XCTAssertEqual(env.v, HistoryStorage.currentVersion)
            XCTAssertEqual(env.payload, ["a": 1])
        }
        XCTAssertEqual(load(), ["a": 1])
    }

    func testLoadReturnsNilWhenNothingWasSaved() {
        XCTAssertNil(load())
    }

    func testLoadMergesDivergentCopies() throws {
        let urls = HistoryStorage.locations(for: file)
        try JSONEncoder().encode(HistoryFile(payload: ["a": 5, "b": 1])).write(to: urls[0])
        try JSONEncoder().encode(HistoryFile(payload: ["a": 2, "c": 7])).write(to: urls[1])
        XCTAssertEqual(load(), ["a": 5, "b": 1, "c": 7])
    }

    func testAWipedPrimaryIsRestoredFromTheMirrorOnTheNextSave() throws {
        DurableJSON.save(["kept": 3], to: file)
        let urls = HistoryStorage.locations(for: file)
        try FileManager.default.removeItem(at: urls[0])   // e.g. an uninstaller swept App Support

        let survived = try XCTUnwrap(load())
        XCTAssertEqual(survived, ["kept": 3])
        DurableJSON.save(survived, to: file)
        XCTAssertTrue(FileManager.default.fileExists(atPath: urls[0].path))
    }

    func testCorruptCopyIsSetAsideNotOverwrittenAndTheOtherStillLoads() throws {
        let urls = HistoryStorage.locations(for: file)
        let garbage = Data("{ not json".utf8)
        try garbage.write(to: urls[0])
        try JSONEncoder().encode(HistoryFile(payload: ["ok": 1])).write(to: urls[1])

        XCTAssertEqual(load(), ["ok": 1])
        let quarantined = urls[0].deletingPathExtension().appendingPathExtension("corrupt.json")
        XCTAssertEqual(try Data(contentsOf: quarantined), garbage, "the bad bytes are kept for recovery")
        XCTAssertFalse(FileManager.default.fileExists(atPath: urls[0].path))
    }

    func testEmptyFileIsSkippedWithoutQuarantine() throws {
        let urls = HistoryStorage.locations(for: file)
        try Data().write(to: urls[0])
        XCTAssertNil(load())
        let quarantined = urls[0].deletingPathExtension().appendingPathExtension("corrupt.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantined.path))
    }
}

// MARK: - Shared stores (sandboxed under XCTest)

final class SharedHistoryStoreTests: XCTestCase {

    func testRecordPersistsTheSampleToDisk() throws {
        let store = HistoryStore.shared
        let now = Date()
        store.record(fiveHour: 87, sevenDay: 43, sonnet: 9, at: now)
        XCTAssertEqual(store.samples.last?.h5, 87)
        store.waitForPendingSaves()

        let onDisk = try XCTUnwrap(DurableJSON.load(HistoryStore.fileName, as: [HistorySample].self,
                                                    merging: mergedHistory))
        XCTAssertTrue(onDisk.contains { $0.h5 == 87 && $0.h7 == 43 && $0.hSonnet == 9 })
    }

    func testMergeAddsImportedSamplesAndRecentWindowsThem() {
        let store = HistoryStore.shared
        let now = Date()
        let old = HistorySample(t: now.addingTimeInterval(-20 * 24 * 3600), h5: 11, h7: 22, hSonnet: nil)
        let fresh = HistorySample(t: now.addingTimeInterval(-60), h5: 33, h7: 44, hSonnet: nil)
        store.merge([old, fresh], now: now)
        store.waitForPendingSaves()

        XCTAssertTrue(store.recent(days: 30, now: now).contains { $0.h7 == 22 })
        XCTAssertFalse(store.recent(days: 7, now: now).contains { $0.h7 == 22 },
                       "a 7 day window must not see a 20 day old sample")
        XCTAssertTrue(store.fiveHourTrend(within: 3600, now: now).contains(33))
    }

    func testStatusStoreIgnoresUnknownAndKeepsTheWorstOfTheDay() throws {
        let store = StatusHistoryStore.shared
        let day = Date()
        let key = statusDayKey(day)
        store.record(indicator: .major, at: day)
        store.record(indicator: .minor, at: day)
        store.record(indicator: .unknown, at: day)
        XCTAssertEqual(store.history.days[key], ServiceStatusIndicator.major.rawValue)
        XCTAssertEqual(store.recentDays(count: 1, now: day).last?.indicator, .major)
        store.waitForPendingSaves()

        let onDisk = try XCTUnwrap(DurableJSON.load(StatusHistoryStore.fileName, as: StatusHistory.self,
                                                    merging: mergedStatusHistory))
        XCTAssertEqual(onDisk.days[key], ServiceStatusIndicator.major.rawValue)
    }

    func testStatusStoreSeedOverlaysIncidents() {
        let store = StatusHistoryStore.shared
        let now = Date()
        let twoDaysAgo = now.addingTimeInterval(-2 * 24 * 3600)
        store.seed(incidents: [StatusIncident(impact: .critical, start: twoDaysAgo,
                                              end: twoDaysAgo.addingTimeInterval(600))], now: now)
        XCTAssertEqual(store.history.days[statusDayKey(twoDaysAgo)], ServiceStatusIndicator.critical.rawValue)
    }
}

// MARK: - Backup restore

final class HistoryBackupRestoreTests: XCTestCase {

    func testRestoreRejectsGarbage() {
        XCTAssertNil(HistoryBackupService.restore(from: Data("nope".utf8)))
    }

    func testRestoreMergesEveryStoreFromAnExport() throws {
        let now = Date()
        let sample = HistorySample(t: now.addingTimeInterval(-3600), h5: 61, h7: 62, hSonnet: nil)
        let dayKey = statusDayKey(now.addingTimeInterval(-3 * 24 * 3600))
        let activityKey = "2026-01-02"
        let activity = DailyActivity(tokens: 1234, input: 1000, output: 234, cacheRead: 0,
                                     cacheCreation: 0, cost: 1.5, messages: 7, activeSeconds: 60)
        let backup = HistoryBackup(usage: [sample],
                                   status: StatusHistory(days: [dayKey: "maintenance"]),
                                   activity: ActivityArchive(days: [activityKey: activity]))
        let data = try HistoryBackupService.encoder().encode(backup)

        let restored = try XCTUnwrap(HistoryBackupService.restore(from: data))
        XCTAssertEqual(HistoryBackupService.summary(restored),
                       "Imported 1 activity days, 1 status days, 1 usage samples.")
        XCTAssertTrue(HistoryStore.shared.samples.contains { $0.h5 == 61 && $0.h7 == 62 })
        XCTAssertNotNil(StatusHistoryStore.shared.history.days[dayKey])
        XCTAssertEqual(ActivityArchiveStore.shared.archive.days[activityKey], activity)

        // And the live snapshot now exports what was imported.
        let exported = try XCTUnwrap(HistoryBackupService.exportData())
        let reread = try HistoryBackupService.decoder().decode(HistoryBackup.self, from: exported)
        XCTAssertEqual(reread.activity.days[activityKey], activity)
        XCTAssertTrue(HistoryBackupService.suggestedFileName.hasPrefix("ClaudeGlance-history-"))
        XCTAssertTrue(HistoryBackupService.suggestedFileName.hasSuffix(".json"))
    }
}

// MARK: - Status poller

final class StatusServicePollTests: XCTestCase {
    private let statusPath = "/api/v2/status.json"
    private let incidentsPath = "/api/v2/incidents.json"

    private var originalSession: URLSession!

    override func setUp() {
        RoutingURLProtocol.stubs = [:]
        originalSession = StatusService.shared.urlSession
        StatusService.shared.urlSession = RoutingURLProtocol.session()
    }

    override func tearDown() {
        StatusService.shared.urlSession = originalSession
        RoutingURLProtocol.stubs = [:]
    }

    private func status(_ indicator: String, _ text: String) -> Data {
        Data(#"{"status":{"indicator":"\#(indicator)","description":"\#(text)"}}"#.utf8)
    }

    func testStatusUpdatesAndSurvivesAFailedPoll() async {
        let svc = StatusService.shared
        RoutingURLProtocol.stubs[statusPath] = .init(status: 200, body: status("minor", "Partial outage"))
        await svc.refreshStatus()
        XCTAssertEqual(svc.status.indicator, .minor)
        XCTAssertEqual(svc.status.description, "Partial outage")
        let today = StatusHistoryStore.shared.history.days[statusDayKey(Date())]
            .flatMap(ServiceStatusIndicator.init(rawValue:)) ?? .unknown
        XCTAssertGreaterThanOrEqual(statusSeverity(today), statusSeverity(.minor),
                                    "today's cell records at least the polled status")

        // An error page (even a JSON one) keeps the last known status.
        RoutingURLProtocol.stubs[statusPath] = .init(status: 503, body: status("none", "ok"))
        await svc.refreshStatus()
        XCTAssertEqual(svc.status.indicator, .minor)

        RoutingURLProtocol.stubs[statusPath] = .init(status: 200, body: Data("<html>".utf8))
        await svc.refreshStatus()
        XCTAssertEqual(svc.status.indicator, .minor)
    }

    func testUnrecognisedIndicatorReadsAsUnknown() async {
        RoutingURLProtocol.stubs[statusPath] = .init(status: 200, body: status("apocalyptic", "??"))
        await StatusService.shared.refreshStatus()
        XCTAssertEqual(StatusService.shared.status.indicator, .unknown)
    }

    func testUptimePublishesAndAFailedFeedKeepsTheLastFigure() async throws {
        let svc = StatusService.shared
        let fmt = ISO8601DateFormatter()
        let start = Date().addingTimeInterval(-2 * 24 * 3600)
        let end = start.addingTimeInterval(3 * 3600)
        let feed = """
        {"incidents":[{"impact":"major","started_at":"\(fmt.string(from: start))",
          "created_at":"\(fmt.string(from: start))","resolved_at":"\(fmt.string(from: end))"}]}
        """
        RoutingURLProtocol.stubs[incidentsPath] = .init(status: 200, body: Data(feed.utf8))
        await svc.refreshIncidents()
        let pct = try XCTUnwrap(svc.uptime30dPercent)
        XCTAssertEqual(pct, 100 * (1 - 3.0 / (30 * 24)), accuracy: 0.05)
        // Worst-wins: another test may already have marked that day critical.
        let seeded = StatusHistoryStore.shared.history.days[statusDayKey(start)]
            .flatMap(ServiceStatusIndicator.init(rawValue:)) ?? .unknown
        XCTAssertGreaterThanOrEqual(statusSeverity(seeded), statusSeverity(.major))

        // A challenge page during an outage must not publish 100%.
        RoutingURLProtocol.stubs[incidentsPath] = .init(status: 200, body: Data("<html>wait</html>".utf8))
        await svc.refreshIncidents()
        XCTAssertEqual(svc.uptime30dPercent, pct)

        RoutingURLProtocol.stubs[incidentsPath] = .init(status: 500, body: Data(#"{"incidents":[]}"#.utf8))
        await svc.refreshIncidents()
        XCTAssertEqual(svc.uptime30dPercent, pct)
    }
}

// MARK: - Usage fetch: Retry-After reaches the backoff

final class UsageRetryAfterTests: XCTestCase {
    private var originalSession: URLSession!

    override func setUp() {
        originalSession = UsageService.shared.urlSession
    }

    override func tearDown() {
        UsageService.shared.urlSession = originalSession
        RoutingURLProtocol.stubs = [:]
    }

    func testRetryAfterHeaderIsCarriedOnThe429Error() async {
        RoutingURLProtocol.stubs = ["/api/oauth/usage": .init(status: 429, body: Data("slow down".utf8),
                                                              headers: ["Retry-After": "120"])]
        UsageService.shared.urlSession = RoutingURLProtocol.session()
        do {
            _ = try await UsageService.shared.fetchOAuthUsage(accessToken: "synthetic-token")
            XCTFail("expected a throw on 429")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, "OAuthUsage")
            XCTAssertEqual(error.code, 429)
            let header = error.userInfo["Retry-After"] as? String
            XCTAssertEqual(header, "120")
            XCTAssertEqual(usageRetryDelay(retryAfter: header), 120)
        }
    }

    func testNoRetryAfterHeaderLeavesItOut() async {
        RoutingURLProtocol.stubs = ["/api/oauth/usage": .init(status: 503, body: Data())]
        UsageService.shared.urlSession = RoutingURLProtocol.session()
        do {
            _ = try await UsageService.shared.fetchOAuthUsage(accessToken: "synthetic-token")
            XCTFail("expected a throw on 503")
        } catch let error as NSError {
            XCTAssertEqual(error.code, 503)
            XCTAssertNil(error.userInfo["Retry-After"])
        }
    }

    func testMalformedSuccessBodyThrowsADecodingError() async {
        RoutingURLProtocol.stubs = ["/api/oauth/usage": .init(status: 200, body: Data("[]".utf8))]
        UsageService.shared.urlSession = RoutingURLProtocol.session()
        do {
            _ = try await UsageService.shared.fetchOAuthUsage(accessToken: "synthetic-token")
            XCTFail("expected a decoding error")
        } catch {
            XCTAssertTrue(error is DecodingError, "\(error)")
        }
    }
}

// MARK: - Statusline installer and settings wiring

final class StatusLineInstallTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("cg-install-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? fm.removeItem(at: root)
    }

    func testInstallCopiesTheBundledScriptExecutableAndOverwritesAStaleCopy() throws {
        let dst = root.appendingPathComponent("sub/claudeglance-statusline.sh")
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: dst)

        let installed = try StatusLineSetup.installScript(to: dst)
        XCTAssertEqual(installed, dst)
        let bundled = try XCTUnwrap(Bundle.main.url(forResource: StatusLineSetup.scriptResource,
                                                    withExtension: "sh"))
        XCTAssertEqual(try Data(contentsOf: dst), try Data(contentsOf: bundled))
        let perms = try fm.attributesOfItem(atPath: dst.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o755)
    }

    func testInstallFailsCleanlyWhenTheScriptIsMissing() {
        let dst = root.appendingPathComponent("claudeglance-statusline.sh")
        // The test bundle does not carry the script resource.
        XCTAssertThrowsError(try StatusLineSetup.installScript(to: dst, bundle: Bundle(for: Self.self)))
        XCTAssertFalse(fm.fileExists(atPath: dst.path))
    }

    func testWiringRefusesANonObjectAndLeavesTheFileUntouched() throws {
        let settings = root.appendingPathComponent("settings.json")
        let original = Data(#"["not", "an", "object"]"#.utf8)
        try original.write(to: settings)

        XCTAssertThrowsError(try StatusLineSetup.wireIntoSettings(stamp: "t", settingsURL: settings))
        XCTAssertEqual(try Data(contentsOf: settings), original)
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("settings.json.claudeglance-backup-t").path))
    }

    func testWiringBacksUpAndReportsAReplacedStatusLine() throws {
        let settings = root.appendingPathComponent("settings.json")
        let original = Data(#"{"model":"x","statusLine":{"type":"command","command":"/bin/other"}}"#.utf8)
        try original.write(to: settings)

        let result = try StatusLineSetup.wireIntoSettings(stamp: "t", settingsURL: settings)
        XCTAssertTrue(result.replacedExisting)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.backup)), original)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        XCTAssertEqual(obj["model"] as? String, "x")
        let line = try XCTUnwrap(obj["statusLine"] as? [String: String])
        XCTAssertEqual(line["command"], StatusLineSetup.command)
    }

    func testWiringCreatesSettingsWhenNoneExists() throws {
        let settings = root.appendingPathComponent("fresh/settings.json")
        let result = try StatusLineSetup.wireIntoSettings(stamp: "t", settingsURL: settings)
        XCTAssertNil(result.backup)
        XCTAssertFalse(result.replacedExisting)
        XCTAssertTrue(StatusLineSetup.hasStatusLine(try Data(contentsOf: settings)))
        XCTAssertTrue(StatusLineSetup.snippet.contains(StatusLineSetup.command))
    }
}
