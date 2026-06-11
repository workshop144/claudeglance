import Foundation

// MARK: - Persisted utilization history

/// One persisted utilization reading — the OAuth 5h/7d percentages aren't in the
/// local jsonl, so we record them ourselves to chart their trend over time.
struct HistorySample: Codable, Equatable {
    let t: Date
    let h5: Int
    let h7: Int
}

/// Drops samples older than `cutoff` — pure, testable.
func prunedHistory(_ samples: [HistorySample], since cutoff: Date) -> [HistorySample] {
    samples.filter { $0.t >= cutoff }
}

/// Recent 5h-utilization values (oldest → newest) within `window` of `now`. Pure.
func recentFiveHour(_ samples: [HistorySample], within window: TimeInterval, now: Date) -> [Int] {
    prunedHistory(samples, since: now.addingTimeInterval(-window)).map { $0.h5 }
}

/// Records the OAuth 5h/7d utilization on each poll and persists it to Application
/// Support, pruned to a rolling window. The in-memory `samples` is the read path
/// (touched only on the main thread, like the menu); disk writes are async.
final class HistoryStore {
    static let shared = HistoryStore()

    private(set) var samples: [HistorySample] = []
    private let retention: TimeInterval = 7 * 24 * 3600   // keep a week
    private let io = DispatchQueue(label: "io.github.broots144.ClaudeGlance.history", qos: .utility)

    private init() { samples = HistoryStore.load(from: HistoryStore.fileURL) }

    /// Append a reading (main thread), prune the in-memory window, persist async.
    func record(fiveHour: Int, sevenDay: Int, at date: Date = Date()) {
        samples.append(HistorySample(t: date, h5: fiveHour, h7: sevenDay))
        samples = prunedHistory(samples, since: date.addingTimeInterval(-retention))
        let snapshot = samples
        io.async { HistoryStore.save(snapshot, to: HistoryStore.fileURL) }
    }

    /// Recent 5h values for the in-menu sparkline (default: last 2 hours).
    func fiveHourTrend(within window: TimeInterval = 2 * 3600, now: Date = Date()) -> [Int] {
        recentFiveHour(samples, within: window, now: now)
    }

    // MARK: - Disk (static so init can call before `self` is ready)

    private static var fileURL: URL? {
        let fm = FileManager.default
        guard let base = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true) else { return nil }
        let dir = base.appendingPathComponent("ClaudeGlance", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("usage-history.json")
    }

    private static func load(from url: URL?) -> [HistorySample] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([HistorySample].self, from: data)) ?? []
    }

    private static func save(_ samples: [HistorySample], to url: URL?) {
        guard let url, let data = try? JSONEncoder().encode(samples) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
