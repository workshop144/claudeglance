import Foundation

// MARK: - Model pricing (for computing $ cost from local Claude Code logs)

/// Per-1M-token USD rates for a model.
struct ModelRate: Equatable {
    let input: Double
    let output: Double
}

/// Per-1M-token pricing for a model name as it appears in the Claude Code logs.
/// Matched by substring so it tolerates the dated/suffixed ids in the jsonl
/// (e.g. "claude-opus-4-8", "claude-3-5-haiku-20241022"). Rates verified against
/// the claude-api reference (June 2026); order matters — current/more-specific
/// ids are checked before the legacy fallbacks.
func modelRate(for model: String) -> ModelRate {
    let m = model.lowercased()
    if m.contains("fable")                            { return ModelRate(input: 10, output: 50) }
    if m.contains("opus-4") || m.contains("opus4")    { return ModelRate(input: 5, output: 25) }
    if m.contains("opus")                             { return ModelRate(input: 15, output: 75) }   // Opus 3 (legacy)
    if m.contains("sonnet")                           { return ModelRate(input: 3, output: 15) }    // Sonnet 3.5–4.x
    if m.contains("haiku-4") || m.contains("haiku4")  { return ModelRate(input: 1, output: 5) }     // Haiku 4.5
    if m.contains("haiku")                            { return ModelRate(input: 0.8, output: 4) }   // Haiku 3.5 (legacy)
    return ModelRate(input: 3, output: 15)                                                          // unknown → Sonnet-class
}

/// USD cost for one usage record. Cache-creation (write) tokens bill at 1.25× the
/// input rate and cache-read at 0.10× — Anthropic's standard cache multipliers.
/// This is the "API-equivalent" value: what the usage would cost at pay-as-you-go
/// rates (a flat subscription doesn't bill per token).
func tokenCostUSD(model: String, input: Int, output: Int, cacheCreation: Int, cacheRead: Int) -> Double {
    let rate = modelRate(for: model)
    let inPerToken = rate.input / 1_000_000
    let outPerToken = rate.output / 1_000_000
    return Double(input) * inPerToken
        + Double(output) * outPerToken
        + Double(cacheCreation) * inPerToken * 1.25
        + Double(cacheRead) * inPerToken * 0.10
}

/// Projects a full month's spend from the month-to-date total: the daily average
/// so far (`monthCost / day-of-month`) extrapolated across every day in the month.
func monthlyProjection(monthCostUSD: Double, now: Date = Date(), calendar: Calendar = .current) -> Double {
    let day = calendar.component(.day, from: now)
    guard day > 0 else { return monthCostUSD }
    let daysInMonth = calendar.range(of: .day, in: .month, for: now)?.count ?? 30
    return (monthCostUSD / Double(day)) * Double(daysInMonth)
}
