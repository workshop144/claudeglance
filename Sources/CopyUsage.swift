import Foundation

// MARK: - Copy usage to clipboard [31]

/// One pasteable line with the current plan usage, e.g.
/// "Claude usage: 5h 35% (resets 3:40 PM) · 7d 71% (resets Thu 9:00 AM)".
/// Always "used" (not the remaining toggle): the reader of a pasted line can't see
/// that setting. Reset times are clock times, not countdowns, so the line stays
/// true after it's pasted.
func usageClipboardText(fiveHour: Int, sevenDay: Int, sonnet: Int?,
                        fiveHourResetAt: Date?, sevenDayResetAt: Date?,
                        now: Date = Date(),
                        calendar: Calendar = .current,
                        locale: Locale = .current) -> String {
    var parts = ["5h \(fiveHour)%" + resetSuffix(fiveHourResetAt, now: now, calendar: calendar, locale: locale),
                 "7d \(sevenDay)%" + resetSuffix(sevenDayResetAt, now: now, calendar: calendar, locale: locale)]
    if let sonnet { parts.append("Sonnet \(sonnet)%") }
    return "Claude usage: " + parts.joined(separator: " · ")
}

/// " (resets 3:40 PM)" today, " (resets Thu 9:00 AM)" on a later day, "" when unknown
/// or already past.
private func resetSuffix(_ resetAt: Date?, now: Date, calendar: Calendar, locale: Locale) -> String {
    guard let resetAt, resetAt > now else { return "" }
    let f = DateFormatter()
    f.locale = locale
    f.timeZone = calendar.timeZone
    f.setLocalizedDateFormatFromTemplate(calendar.isDate(resetAt, inSameDayAs: now) ? "jmm" : "EEEjmm")
    // ICU puts a narrow no-break space before AM/PM; plain spaces paste cleanly
    // into terminals and plain-text fields.
    let time = f.string(from: resetAt)
        .replacingOccurrences(of: "\u{202F}", with: " ")
        .replacingOccurrences(of: "\u{00A0}", with: " ")
    return " (resets \(time))"
}
