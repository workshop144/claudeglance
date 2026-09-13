import Foundation

// MARK: - Persisted utilization history

/// One persisted utilization reading — the OAuth 5h/7d percentages aren't in the
/// local jsonl, so we record them ourselves to chart their trend over time.
struct HistorySample: Codable, Equatable {
    let t: Date
    let h5: Int
    let h7: Int
    // Sonnet-weekly %, optional so files written before this field still decode.
    let hSonnet: Int?

    init(t: Date, h5: Int, h7: Int, hSonnet: Int? = nil) {
        self.t = t; self.h5 = h5; self.h7 = h7; self.hSonnet = hSonnet
    }
}

/// Drops samples older than `cutoff` — pure, testable.
func prunedHistory(_ samples: [HistorySample], since cutoff: Date) -> [HistorySample] {
    samples.filter { $0.t >= cutoff }
}

/// Recent 5h-utilization values (oldest → newest) within `window` of `now`. Pure.
func recentFiveHour(_ samples: [HistorySample], within window: TimeInterval, now: Date) -> [Int] {
    prunedHistory(samples, since: now.addingTimeInterval(-window)).map { $0.h5 }
}

/// Rolls samples older than `rawWindow` down to one per hour, keeping that hour's
/// *worst* 5h reading (ties go to the later sample, so the 7d/Sonnet figures
/// alongside it stay the freshest of the hour). Full 5-minute resolution is what
/// the sparkline and "what happened just now" need; a year of it is 100k samples
/// for a chart that can't render them, so older history is thinned instead of
/// thrown away. Pure, testable.
func downsampledHistory(_ samples: [HistorySample], now: Date,
                        rawWindow: TimeInterval = 48 * 3600) -> [HistorySample] {
    let cutoff = now.addingTimeInterval(-rawWindow)
    var hourly: [Int: HistorySample] = [:]
    var recent: [HistorySample] = []

    for s in samples {
        guard s.t < cutoff else { recent.append(s); continue }
        let hour = Int(floor(s.t.timeIntervalSinceReferenceDate / 3600))
        if let kept = hourly[hour] {
            if s.h5 > kept.h5 || (s.h5 == kept.h5 && s.t >= kept.t) { hourly[hour] = s }
        } else {
            hourly[hour] = s
        }
    }
    return (Array(hourly.values) + recent).sorted { $0.t < $1.t }
}

/// Unions two readings of the history, de-duplicated by timestamp. Used to
/// reconcile the primary and mirror copies on load — whichever survived an
/// uninstall restores what the other lost.
func mergedHistory(_ a: [HistorySample], _ b: [HistorySample]) -> [HistorySample] {
    var byTime: [Date: HistorySample] = [:]
    for s in a { byTime[s.t] = s }
    for s in b where byTime[s.t] == nil { byTime[s.t] = s }
    return byTime.values.sorted { $0.t < $1.t }
}

/// Records the OAuth 5h/7d utilization on each poll and persists it to both
/// history locations, thinned and pruned to a rolling year. The in-memory
/// `samples` is the read path (touched only on the main thread, like the menu);
/// disk writes are async.
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    static let fileName = "usage-history.json"

    @Published private(set) var samples: [HistorySample] = []
    /// Keep a year. Beyond ~48h the samples are hourly, so a full year is roughly
    /// 9k rows — small enough to load eagerly, long enough to show a real trend.
    private let retention: TimeInterval = 365 * 24 * 3600
    private let io = DispatchQueue(label: "io.github.broots144.ClaudeGlance.history", qos: .utility)

    private init() {
        samples = DurableJSON.load(HistoryStore.fileName, as: [HistorySample].self,
                                   merging: mergedHistory) ?? []
    }

    /// Append a reading (main thread), thin + prune the in-memory window, persist async.
    func record(fiveHour: Int, sevenDay: Int, sonnet: Int? = nil, at date: Date = Date()) {
        samples.append(HistorySample(t: date, h5: fiveHour, h7: sevenDay, hSonnet: sonnet))
        samples = downsampledHistory(prunedHistory(samples, since: date.addingTimeInterval(-retention)),
                                     now: date)
        let snapshot = samples
        io.async { DurableJSON.save(snapshot, to: HistoryStore.fileName) }
    }

    /// Recent 5h values for the in-menu sparkline (default: last 2 hours).
    func fiveHourTrend(within window: TimeInterval = 2 * 3600, now: Date = Date()) -> [Int] {
        recentFiveHour(samples, within: window, now: now)
    }

    /// The last `days` of samples. Callers that reason about "recent" pressure —
    /// the plan-fit nudge, the default chart range — must window explicitly now
    /// that the store keeps a year; an all-time peak would pin those to whatever
    /// the worst week of the year was.
    func recent(days: Int, now: Date = Date()) -> [HistorySample] {
        prunedHistory(samples, since: now.addingTimeInterval(-Double(days) * 24 * 3600))
    }

    /// Folds an imported history in — the restore path.
    func merge(_ imported: [HistorySample], now: Date = Date()) {
        let union = mergedHistory(samples, imported)
        samples = downsampledHistory(prunedHistory(union, since: now.addingTimeInterval(-retention)),
                                     now: now)
        let snapshot = samples
        io.async { DurableJSON.save(snapshot, to: HistoryStore.fileName) }
    }
}
