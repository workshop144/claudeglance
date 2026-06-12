import XCTest
@testable import ClaudeGlance

// MARK: - Plan-fit recommendation [#28]

final class PlanFitTests: XCTestCase {

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }

    /// `count` samples one minute apart starting at `start`, all at h5/h7.
    private func samples(count: Int, h5: Int, h7: Int, start: Date) -> [HistorySample] {
        (0..<count).map { HistorySample(t: start.addingTimeInterval(Double($0) * 60), h5: h5, h7: h7) }
    }

    private let now = "2026-06-12T18:00:00Z"

    func testOverageTakesPriority() {
        // Even with low utilization, an active overage is the headline.
        let s = samples(count: 20, h5: 10, h7: 10, start: date("2026-06-12T00:00:00Z"))
        let rec = planRecommendation(samples: s, overageEnabled: true, overageUsedCents: 1234,
                                     now: date(now), calendar: utc)
        XCTAssertEqual(rec?.fit, .overage)
        XCTAssertTrue(rec?.detail.contains("$12.34") ?? false)
    }

    func testOverageIgnoredWhenDisabledOrZero() {
        let s = samples(count: 20, h5: 10, h7: 10, start: date("2026-06-12T00:00:00Z"))
        XCTAssertEqual(planRecommendation(samples: s, overageEnabled: false, overageUsedCents: 1234,
                                          now: date(now), calendar: utc)?.fit, .comfortable)
        XCTAssertEqual(planRecommendation(samples: s, overageEnabled: true, overageUsedCents: 0,
                                          now: date(now), calendar: utc)?.fit, .comfortable)
    }

    func testConstrainedWhenNearWeeklyLimit() {
        let s = samples(count: 20, h5: 80, h7: 96, start: date("2026-06-12T00:00:00Z"))
        let rec = planRecommendation(samples: s, overageEnabled: false, overageUsedCents: nil,
                                     now: date(now), calendar: utc)
        XCTAssertEqual(rec?.fit, .constrained)
    }

    func testConstrainedNoteCountsDaysNearLimit() {
        // Two distinct days each peaking ≥90 → the detail names "2 of 2 days".
        var s = samples(count: 12, h5: 80, h7: 95, start: date("2026-06-11T08:00:00Z"))
        s += samples(count: 12, h5: 80, h7: 95, start: date("2026-06-12T08:00:00Z"))
        let rec = planRecommendation(samples: s, overageEnabled: false, overageUsedCents: nil,
                                     now: date(now), calendar: utc)
        XCTAssertEqual(rec?.fit, .constrained)
        XCTAssertTrue(rec?.detail.contains("2 of the last 2 days") ?? false)
    }

    func testComfortableWhenLowUtilization() {
        let s = samples(count: 20, h5: 30, h7: 35, start: date("2026-06-12T00:00:00Z"))
        XCTAssertEqual(planRecommendation(samples: s, overageEnabled: false, overageUsedCents: nil,
                                          now: date(now), calendar: utc)?.fit, .comfortable)
    }

    func testBalancedInTheMiddle() {
        let s = samples(count: 20, h5: 65, h7: 72, start: date("2026-06-12T00:00:00Z"))
        XCTAssertEqual(planRecommendation(samples: s, overageEnabled: false, overageUsedCents: nil,
                                          now: date(now), calendar: utc)?.fit, .balanced)
    }

    func testNilWhenTooLittleHistoryAndNoOverage() {
        let s = samples(count: 5, h5: 95, h7: 95, start: date("2026-06-12T00:00:00Z"))
        XCTAssertNil(planRecommendation(samples: s, overageEnabled: false, overageUsedCents: nil,
                                        now: date(now), calendar: utc))
    }
}
