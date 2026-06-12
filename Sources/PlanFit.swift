import Foundation

// MARK: - Plan-fit recommendation [#28]

/// How well the current plan seems to fit, inferred only from what we can actually
/// observe — utilization history and any pay-as-you-go overage. We deliberately
/// don't claim to know the user's tier (the API only exposes utilization %, not
/// the plan), so the copy never names "you're on Pro"; it speaks in headroom.
enum PlanFit: String {
    case overage       // paying for usage credits past the plan
    case constrained   // frequently near the limits → a higher tier would help
    case balanced      // a good fit
    case comfortable   // lots of headroom → a lower tier might do
}

struct PlanRecommendation: Equatable {
    let fit: PlanFit
    let headline: String
    let detail: String
}

/// Recommend (or not) a plan change from utilization history + overage. Pure.
/// Returns nil when there isn't enough history yet to judge limit-pressure (and no
/// overage to report), so the UI can stay quiet rather than guess.
func planRecommendation(samples: [HistorySample], overageEnabled: Bool?, overageUsedCents: Int?,
                        now: Date, calendar: Calendar = .current) -> PlanRecommendation? {
    // Overage is the most concrete signal there is — surface it first.
    if overageEnabled == true, let cents = overageUsedCents, cents > 0 {
        return PlanRecommendation(
            fit: .overage,
            headline: "Paying for overage",
            detail: "You've used \(formatDollars(cents: cents)) in usage credits this month. "
                + "If that's a regular pattern, the next plan up may cost less than the overage.")
    }

    // Limit-pressure needs at least a little history (≈ an hour of 5-min polls).
    guard samples.count >= 12 else { return nil }

    let peak5h = samples.map(\.h5).max() ?? 0
    let peak7d = samples.map(\.h7).max() ?? 0

    // Distinct days where the weekly window peaked near its cap.
    var dayMaxWeekly: [String: Int] = [:]
    for s in samples {
        let key = statusDayKey(s.t, calendar: calendar)
        dayMaxWeekly[key] = max(dayMaxWeekly[key] ?? 0, s.h7)
    }
    let daysNearWeekly = dayMaxWeekly.values.filter { $0 >= 90 }.count
    let daysObserved = dayMaxWeekly.count

    if peak7d >= 90 || daysNearWeekly >= 2 {
        let note = daysNearWeekly >= 2
            ? "You were near your weekly limit on \(daysNearWeekly) of the last \(daysObserved) days. "
            : ""
        return PlanRecommendation(
            fit: .constrained,
            headline: "Often near your limits",
            detail: note + "A higher plan tier would give you more headroom before you're capped.")
    }

    if peak7d <= 50 && peak5h <= 60 {
        return PlanRecommendation(
            fit: .comfortable,
            headline: "Comfortable headroom",
            detail: "You rarely pass about half your limits (peak \(peak7d)% weekly, \(peak5h)% session). "
                + "A lower tier might be enough.")
    }

    return PlanRecommendation(
        fit: .balanced,
        headline: "Good fit",
        detail: "Your usage sits within your limits (peak \(peak7d)% weekly, \(peak5h)% session) "
            + "without much waste.")
}
