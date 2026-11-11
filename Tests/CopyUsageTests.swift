import XCTest
@testable import ClaudeGlance

final class CopyUsageTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private let en = Locale(identifier: "en_US")
    // Tuesday 2026-11-10 12:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_794_312_000)

    func testBothResetsTodayAndLaterDay() {
        let text = usageClipboardText(fiveHour: 35, sevenDay: 71, sonnet: nil,
                                      fiveHourResetAt: now.addingTimeInterval(2 * 3600 + 40 * 60),
                                      sevenDayResetAt: now.addingTimeInterval(2 * 86400 - 3 * 3600),
                                      now: now, calendar: cal, locale: en)
        XCTAssertEqual(text, "Claude usage: 5h 35% (resets 2:40 PM) · 7d 71% (resets Thu 9:00 AM)")
    }

    func testSonnetAppendedWhenReported() {
        let text = usageClipboardText(fiveHour: 0, sevenDay: 4, sonnet: 12,
                                      fiveHourResetAt: nil, sevenDayResetAt: nil,
                                      now: now, calendar: cal, locale: en)
        XCTAssertEqual(text, "Claude usage: 5h 0% · 7d 4% · Sonnet 12%")
    }

    func testPastResetIsOmitted() {
        let text = usageClipboardText(fiveHour: 10, sevenDay: 20, sonnet: nil,
                                      fiveHourResetAt: now.addingTimeInterval(-60), sevenDayResetAt: nil,
                                      now: now, calendar: cal, locale: en)
        XCTAssertEqual(text, "Claude usage: 5h 10% · 7d 20%")
    }
}
