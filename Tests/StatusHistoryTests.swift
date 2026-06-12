import XCTest
@testable import ClaudeGlance

// MARK: - Service-status uptime history [#29]

final class StatusHistoryTests: XCTestCase {

    /// Fixed UTC calendar so day-key tests don't depend on the runner's timezone.
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

    // MARK: Severity ordering

    func testSeverityOrdering() {
        XCTAssertLessThan(statusSeverity(.unknown), statusSeverity(.none))
        XCTAssertLessThan(statusSeverity(.none), statusSeverity(.minor))
        XCTAssertLessThan(statusSeverity(.minor), statusSeverity(.major))
        XCTAssertLessThan(statusSeverity(.major), statusSeverity(.critical))
    }

    func testWorseStatusPicksMoreSevere() {
        XCTAssertEqual(worseStatus(.none, .major), .major)
        XCTAssertEqual(worseStatus(.critical, .minor), .critical)
        // A real reading always beats "no data".
        XCTAssertEqual(worseStatus(.unknown, .none), .none)
        XCTAssertEqual(worseStatus(.unknown, .unknown), .unknown)
    }

    func testMergeStatusKeepsWorst() {
        var days: [String: String] = ["2026-06-10": "none"]
        mergeStatus(into: &days, key: "2026-06-10", indicator: .major)
        XCTAssertEqual(days["2026-06-10"], "major")
        // A lesser later reading doesn't downgrade the day.
        mergeStatus(into: &days, key: "2026-06-10", indicator: .minor)
        XCTAssertEqual(days["2026-06-10"], "major")
    }

    // MARK: Pruning & recent days

    func testPrunedStatusDropsOldDays() {
        let now = date("2026-06-12T12:00:00Z")
        let days = ["2026-06-11": "none", "2026-03-01": "major"]
        let kept = prunedStatus(days, now: now, keepDays: 30, calendar: utc)
        XCTAssertNotNil(kept["2026-06-11"])
        XCTAssertNil(kept["2026-03-01"])
    }

    func testRecentStatusDaysFillsMissingAsUnknown() {
        let now = date("2026-06-12T12:00:00Z")
        let history = StatusHistory(days: ["2026-06-12": "none", "2026-06-10": "major"])
        let days = recentStatusDays(history, count: 3, endingAt: now, calendar: utc)
        XCTAssertEqual(days.map { $0.indicator }, [.major, .unknown, .none]) // 10th, 11th, 12th
    }

    // MARK: Uptime %

    func testUptimeFullyOperationalWhenNoIncidents() {
        XCTAssertEqual(uptimePercent(incidents: [], window: 30 * 24 * 3600,
                                     now: date("2026-06-12T00:00:00Z")), 100, accuracy: 0.0001)
    }

    func testUptimeSubtractsMajorDowntime() {
        let now = date("2026-06-12T00:00:00Z")
        let inc = StatusIncident(impact: .major,
                                 start: date("2026-06-11T00:00:00Z"),
                                 end: date("2026-06-11T01:00:00Z")) // 1h
        let window = 30.0 * 24 * 3600
        let expected = (window - 3600) / window * 100
        XCTAssertEqual(uptimePercent(incidents: [inc], window: window, now: now),
                       expected, accuracy: 0.0001)
    }

    func testUptimeIgnoresMinorIncidents() {
        let now = date("2026-06-12T00:00:00Z")
        let inc = StatusIncident(impact: .minor,
                                 start: date("2026-06-11T00:00:00Z"),
                                 end: date("2026-06-11T06:00:00Z"))
        XCTAssertEqual(uptimePercent(incidents: [inc], window: 30 * 24 * 3600, now: now),
                       100, accuracy: 0.0001)
    }

    func testUptimeMergesOverlappingIncidents() {
        let now = date("2026-06-12T00:00:00Z")
        let a = StatusIncident(impact: .major, start: date("2026-06-11T00:00:00Z"),
                               end: date("2026-06-11T02:00:00Z"))
        let b = StatusIncident(impact: .critical, start: date("2026-06-11T01:00:00Z"),
                               end: date("2026-06-11T03:00:00Z"))
        // Union is 00:00–03:00 = 3h, not 4h.
        let window = 30.0 * 24 * 3600
        let expected = (window - 3 * 3600) / window * 100
        XCTAssertEqual(uptimePercent(incidents: [a, b], window: window, now: now),
                       expected, accuracy: 0.0001)
    }

    func testUptimeClampsIncidentToWindow() {
        let now = date("2026-06-12T00:00:00Z")
        // Started 40 days ago, resolved 20 days ago → only the in-window slice counts.
        let inc = StatusIncident(impact: .critical,
                                 start: now.addingTimeInterval(-40 * 24 * 3600),
                                 end: now.addingTimeInterval(-20 * 24 * 3600))
        let window = 30.0 * 24 * 3600
        // In-window downtime = from windowStart (-30d) to -20d = 10 days.
        let expected = (window - 10 * 24 * 3600) / window * 100
        XCTAssertEqual(uptimePercent(incidents: [inc], window: window, now: now),
                       expected, accuracy: 0.0001)
    }

    func testUptimeCountsOngoingIncidentUntilNow() {
        let now = date("2026-06-12T12:00:00Z")
        let inc = StatusIncident(impact: .major, start: now.addingTimeInterval(-3600), end: nil)
        let window = 30.0 * 24 * 3600
        let expected = (window - 3600) / window * 100
        XCTAssertEqual(uptimePercent(incidents: [inc], window: window, now: now),
                       expected, accuracy: 0.0001)
    }

    // MARK: Incident seed

    func testIncidentSeedBaselinesOperationalAndOverlaysIncidents() {
        let now = date("2026-06-12T12:00:00Z")
        let incidents = [
            StatusIncident(impact: .none, start: date("2026-06-10T00:00:00Z"),
                           end: date("2026-06-10T01:00:00Z")),   // oldest → sets horizon
            StatusIncident(impact: .major, start: date("2026-06-11T08:00:00Z"),
                           end: date("2026-06-11T09:00:00Z"))
        ]
        let seed = incidentSeed(incidents: incidents, now: now, maxDays: 90, calendar: utc)
        XCTAssertEqual(seed["2026-06-10"], "none")  // operational baseline
        XCTAssertEqual(seed["2026-06-11"], "major") // incident overlay
        XCTAssertEqual(seed["2026-06-12"], "none")  // today, operational
        XCTAssertNil(seed["2026-06-09"])            // before the feed's reach → no data
    }

    func testIncidentSeedEmptyWhenNoIncidents() {
        XCTAssertTrue(incidentSeed(incidents: [], now: date("2026-06-12T00:00:00Z"),
                                   maxDays: 90, calendar: utc).isEmpty)
    }

    // MARK: Parsing the real feed shape

    func testParseIncidents() {
        let json = """
        { "incidents": [
          { "impact": "major", "started_at": "2026-06-11T16:54:52.467Z",
            "created_at": "2026-06-11T16:54:52.458Z", "resolved_at": "2026-06-11T17:56:08.221Z" },
          { "impact": "minor", "started_at": "2026-06-01T10:00:00.000Z",
            "created_at": "2026-06-01T10:00:00.000Z", "resolved_at": null }
        ] }
        """.data(using: .utf8)!
        let incidents = parseIncidents(json)
        XCTAssertEqual(incidents.count, 2)
        XCTAssertEqual(incidents[0].impact, .major)
        XCTAssertNotNil(incidents[0].end)
        XCTAssertEqual(incidents[1].impact, .minor)
        XCTAssertNil(incidents[1].end)   // unresolved → ongoing
    }
}
