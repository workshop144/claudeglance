import Foundation

// MARK: - Persisted daily activity archive

/// One day's rolled-up coding activity. This is the app's *own* record: the
/// numbers originate in the Claude Code transcripts, but Claude Code deletes
/// those after `cleanupPeriodDays` (30 by default), so a streak or heatmap
/// computed straight from the logs quietly collapses as they age out. Recording
/// the daily totals here means history keeps accumulating past that horizon and
/// survives app upgrades untouched.
struct DailyActivity: Codable, Equatable {
    var tokens: Int
    var input: Int
    var output: Int
    var cacheRead: Int
    var cacheCreation: Int
    var cost: Double
    var messages: Int
    var activeSeconds: Int

    static let zero = DailyActivity(tokens: 0, input: 0, output: 0, cacheRead: 0,
                                    cacheCreation: 0, cost: 0, messages: 0, activeSeconds: 0)

    var isEmpty: Bool { tokens == 0 && messages == 0 }
}

/// The whole archive: "yyyy-MM-dd" → that day's totals.
struct ActivityArchive: Codable, Equatable {
    var days: [String: DailyActivity]

    init(days: [String: DailyActivity] = [:]) { self.days = days }
}

// MARK: - Merge (pure)

/// Combines two readings of the same day field-by-field, keeping the larger of
/// each. Deliberately *not* "newest wins": a later recompute sees a shrinking
/// window of transcripts, so it can only ever undercount a day it already
/// recorded in full. Max-wins makes a recorded day a floor that never erodes.
func mergeActivity(_ a: DailyActivity, _ b: DailyActivity) -> DailyActivity {
    DailyActivity(tokens: max(a.tokens, b.tokens),
                  input: max(a.input, b.input),
                  output: max(a.output, b.output),
                  cacheRead: max(a.cacheRead, b.cacheRead),
                  cacheCreation: max(a.cacheCreation, b.cacheCreation),
                  cost: max(a.cost, b.cost),
                  messages: max(a.messages, b.messages),
                  activeSeconds: max(a.activeSeconds, b.activeSeconds))
}

/// Folds fresh per-day readings into an archive, max-wins per day.
func mergedArchive(_ archive: ActivityArchive, adding fresh: [String: DailyActivity]) -> ActivityArchive {
    var days = archive.days
    for (key, value) in fresh where !value.isEmpty {
        days[key] = days[key].map { mergeActivity($0, value) } ?? value
    }
    return ActivityArchive(days: days)
}

/// Unions two archives (used to reconcile the primary and mirror copies on load).
func mergedArchive(_ a: ActivityArchive, _ b: ActivityArchive) -> ActivityArchive {
    mergedArchive(a, adding: b.days)
}

// MARK: - Day keys (pure)

/// Parses a "yyyy-MM-dd" archive key back to that day's start. Nil for garbage
/// keys, so a hand-edited file can't crash the charts.
func dayKeyDate(_ key: String, calendar: Calendar = .current) -> Date? {
    let f = DateFormatter()
    f.calendar = calendar
    f.timeZone = calendar.timeZone
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f.date(from: key)
}

/// The archive as the `[Date: Int]` token map the heatmap, streaks and strip
/// already speak, optionally limited to days on or after `since`.
func archiveDailyTokens(_ archive: ActivityArchive, since: Date? = nil,
                        calendar: Calendar = .current) -> [Date: Int] {
    var out: [Date: Int] = [:]
    for (key, day) in archive.days {
        guard let date = dayKeyDate(key, calendar: calendar) else { continue }
        if let since, date < calendar.startOfDay(for: since) { continue }
        out[date] = day.tokens
    }
    return out
}

/// The archive as the `[Date: Double]` spend map the Cost tab chart speaks.
func archiveDailyCost(_ archive: ActivityArchive, since: Date? = nil,
                      calendar: Calendar = .current) -> [Date: Double] {
    var out: [Date: Double] = [:]
    for (key, day) in archive.days {
        guard let date = dayKeyDate(key, calendar: calendar) else { continue }
        if let since, date < calendar.startOfDay(for: since) { continue }
        out[date] = day.cost
    }
    return out
}

// MARK: - Store

/// Persists the daily rollups to both history locations. `MetricsService` folds
/// each scan in from its background queue, so access is lock-guarded rather than
/// `@Published` — the UI reads the merged result back through `UsageMetrics`.
final class ActivityArchiveStore {
    static let shared = ActivityArchiveStore()

    static let fileName = "daily-activity.json"

    private let lock = NSLock()
    private var storage: ActivityArchive
    private let io = DispatchQueue(label: "io.github.broots144.ClaudeGlance.activity", qos: .utility)

    private init() {
        storage = DurableJSON.load(ActivityArchiveStore.fileName, as: ActivityArchive.self,
                                   merging: mergedArchive) ?? ActivityArchive()
    }

    var archive: ActivityArchive {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    /// Folds a fresh set of per-day readings in, persisting only if something
    /// changed. Returns the merged archive so the caller can chart it immediately.
    @discardableResult
    func record(_ fresh: [String: DailyActivity]) -> ActivityArchive {
        lock.lock()
        let merged = mergedArchive(storage, adding: fresh)
        guard merged != storage else { lock.unlock(); return merged }
        storage = merged
        lock.unlock()
        io.async { DurableJSON.save(merged, to: ActivityArchiveStore.fileName) }
        return merged
    }

    /// Folds another archive in — the import path.
    @discardableResult
    func merge(_ other: ActivityArchive) -> ActivityArchive {
        record(other.days)
    }
}
