import Foundation

// MARK: - Session health grade (A–F) [#16]

/// One transparent contributor to today's grade, each scored 0–100 (higher is
/// healthier) with the weight it carries. Surfaced alongside the letter so the
/// grade is explainable, not a black box.
struct HealthFactor {
    let label: String
    let score: Int        // 0–100, higher = healthier
    let weight: Double
    let detail: String
}

/// Today's composite session-health grade: a letter (A+…F) over the weighted mean
/// of whatever factors were available, plus those factors for display.
struct SessionGrade {
    let letter: String
    let score: Int        // 0–100 composite
    let factors: [HealthFactor]
}

/// Standard US letter scale with +/- bands. 0–100 → "A+"…"F".
func letterGrade(for score: Int) -> String {
    switch score {
    case 97...: return "A+"
    case 93...: return "A"
    case 90...: return "A-"
    case 87...: return "B+"
    case 83...: return "B"
    case 80...: return "B-"
    case 77...: return "C+"
    case 73...: return "C"
    case 70...: return "C-"
    case 67...: return "D+"
    case 63...: return "D"
    case 60...: return "D-"
    default:    return "F"
    }
}

/// Grades today's session health from up to three signals, each optional so the
/// grade works with whatever data is present (and renormalizes the weights over
/// the factors actually available):
///   • cache efficiency — % of input-side tokens served from cache (cheap reuse)
///   • limit headroom   — how far below the 5h session limit you are
///   • context headroom — how far the active session is from an auto-compact
/// Returns nil when no signal is available (nothing to grade).
func gradeSession(cachePercent: Int?, limitUtilization: Int?, contextUtilization: Int?) -> SessionGrade? {
    var factors: [HealthFactor] = []

    if let cache = cachePercent {
        let s = clamp(cache)
        factors.append(HealthFactor(label: "Cache efficiency", score: s, weight: 0.4,
                                    detail: "\(s)% of input served from cache"))
    }
    if let limit = limitUtilization {
        let s = clamp(100 - limit)
        factors.append(HealthFactor(label: "Limit headroom", score: s, weight: 0.3,
                                    detail: "\(clamp(limit))% of 5h limit used"))
    }
    if let ctx = contextUtilization {
        let s = clamp(100 - ctx)
        factors.append(HealthFactor(label: "Context headroom", score: s, weight: 0.3,
                                    detail: "\(clamp(ctx))% of context window used"))
    }

    guard !factors.isEmpty else { return nil }

    let totalWeight = factors.reduce(0) { $0 + $1.weight }
    let weighted = factors.reduce(0.0) { $0 + Double($1.score) * $1.weight }
    let composite = Int((weighted / totalWeight).rounded())
    return SessionGrade(letter: letterGrade(for: composite), score: composite, factors: factors)
}

private func clamp(_ n: Int) -> Int { min(100, max(0, n)) }
