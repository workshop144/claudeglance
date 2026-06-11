import Foundation

// MARK: - Daily activity: streaks & a compact heatmap strip

/// Current run of consecutive active days ending today (or yesterday, if today
/// has no activity yet — so the streak doesn't read as "broken" mid-morning).
func currentStreak(activeDays: Set<Date>, today: Date, calendar: Calendar = .current) -> Int {
    var day = calendar.startOfDay(for: today)
    if !activeDays.contains(day) {
        day = calendar.date(byAdding: .day, value: -1, to: day) ?? day
    }
    var streak = 0
    while activeDays.contains(day) {
        streak += 1
        guard let prev = calendar.date(byAdding: .day, value: -1, to: day) else { break }
        day = prev
    }
    return streak
}

/// Longest run of consecutive active days in the set (the visible window).
func longestStreak(activeDays: Set<Date>, calendar: Calendar = .current) -> Int {
    guard !activeDays.isEmpty else { return 0 }
    let sorted = activeDays.map { calendar.startOfDay(for: $0) }.sorted()
    var best = 1, run = 1
    for i in 1..<sorted.count {
        if calendar.date(byAdding: .day, value: 1, to: sorted[i - 1]) == sorted[i] {
            run += 1
        } else {
            run = 1
        }
        best = max(best, run)
    }
    return best
}

/// A block-element sparkline of `values` scaled to `maxValue` (e.g. 100 for a
/// utilization %). Unlike the activity strip, 0 maps to the lowest block (a 0%
/// reading is a real level, not an idle gap). Pure, testable.
func sparkline(_ values: [Int], maxValue: Int) -> String {
    guard !values.isEmpty, maxValue > 0 else { return "" }
    let levels = Array("▁▂▃▄▅▆▇█")   // 8 heights, index 0...7
    return String(values.map { v -> Character in
        let clamped = max(0, min(maxValue, v))
        let idx = Int((Double(clamped) / Double(maxValue)) * 7.0)
        return levels[min(7, idx)]
    })
}

/// A compact `days`-wide activity strip ending today, drawn with block elements
/// scaled to the busiest day in the window (`·` = a day with no activity). Reads
/// like a tiny GitHub contribution row in a single menu line.
func activityStrip(dailyTokens: [Date: Int], days: Int, endingAt: Date, calendar: Calendar = .current) -> String {
    let startToday = calendar.startOfDay(for: endingAt)
    let counts: [Int] = (0..<days).reversed().map { offset in
        let day = calendar.date(byAdding: .day, value: -offset, to: startToday) ?? startToday
        return dailyTokens[day] ?? 0
    }
    let maxV = counts.max() ?? 0
    guard maxV > 0 else { return String(repeating: "·", count: days) }

    let levels = Array(" ▁▂▃▄▅▆▇█")   // index 0 unused; 1...8 are the heights
    return String(counts.map { v -> Character in
        guard v > 0 else { return "·" }
        let lvl = 1 + Int((Double(v) / Double(maxV)) * 7.0)   // 1...8
        return levels[min(8, lvl)]
    })
}
