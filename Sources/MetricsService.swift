import Foundation

// MARK: - Local activity metrics (from Claude Code session logs)

/// Today's usage derived purely from `~/.claude/projects/**/*.jsonl` — the local
/// session transcripts Claude Code writes. No Keychain, no network, no token.
struct UsageMetrics {
    let todayTokens: Int
    let todayCachePercent: Int
    let todayActiveSeconds: Int
    let todayMessages: Int
    let yesterdayTokens: Int
    // Today's and this-month's API-equivalent spend (tokens × model price), USD.
    let todayCostUSD: Double
    let monthCostUSD: Double
    // This-month dollars saved by prompt caching (uncached cost − actual cost).
    let monthSavingsUSD: Double
    // Tokens per day over the recent window, for streaks and the activity strip.
    var dailyTokens: [Date: Int]
    // Month-to-date spend grouped by display model name (Cost tab breakdown).
    let costByModel: [String: Double]
    // API-equivalent spend per day over the recent window (Cost tab chart).
    var dailyCost: [Date: Double]
    // Month-to-date token volume by type, for the "where your tokens go" breakdown.
    let monthInputTokens: Int
    let monthOutputTokens: Int
    let monthCacheReadTokens: Int
    let monthCacheCreationTokens: Int
    // Per-day rollups from this scan, keyed "yyyy-MM-dd". Folded into the
    // persisted archive so history outlives Claude Code's log cleanup.
    var dailyDetail: [String: DailyActivity] = [:]
    // All-time tokens per day, from the persisted archive. Empty in the pure
    // aggregation; `MetricsService` fills it in after merging. Streaks read this
    // rather than `dailyTokens`, so a run longer than the 30-day scan window
    // still counts in full.
    var archivedDailyTokens: [Date: Int] = [:]

    static let empty = UsageMetrics(todayTokens: 0, todayCachePercent: 0,
                                    todayActiveSeconds: 0, todayMessages: 0, yesterdayTokens: 0,
                                    todayCostUSD: 0, monthCostUSD: 0, monthSavingsUSD: 0,
                                    dailyTokens: [:], costByModel: [:], dailyCost: [:],
                                    monthInputTokens: 0, monthOutputTokens: 0,
                                    monthCacheReadTokens: 0, monthCacheCreationTokens: 0)

    var hasData: Bool { todayMessages > 0 }
    /// Days with recorded activity, preferring the persisted archive so streaks
    /// span all of history rather than only the 30-day scan window. Falls back to
    /// the scan when the archive is empty (first run, or a pure aggregation).
    var activeDaySet: Set<Date> {
        let source = archivedDailyTokens.isEmpty ? dailyTokens : archivedDailyTokens
        return Set(source.filter { $0.value > 0 }.keys)
    }
    /// Total month-to-date tokens across all types — the denominator for the split.
    var monthTotalTokens: Int { monthInputTokens + monthOutputTokens + monthCacheReadTokens + monthCacheCreationTokens }
}

// MARK: - Formatting helpers (pure, testable)

/// Compact token count: 950 → "950", 1_200 → "1.2K", 44_100_000 → "44.1M".
func formatTokenCount(_ n: Int) -> String {
    let d = Double(n)
    if d >= 1_000_000 { return String(format: "%.1fM", d / 1_000_000) }
    if d >= 1_000 { return String(format: "%.1fK", d / 1_000) }
    return "\(n)"
}

/// Elapsed duration: 2_048 → "34m 8s", 3_900 → "1h 5m", 45 → "45s".
func formatDuration(_ seconds: Int) -> String {
    if seconds <= 0 { return "0m" }
    let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
    if h > 0 { return "\(h)h \(m)m" }
    if m > 0 { return "\(m)m \(s)s" }
    return "\(s)s"
}

// MARK: - Log line shape

/// Minimal shape of a Claude Code transcript line — `Decodable` ignores the
/// dozens of other keys per line. Internal (not private) so the pure aggregation
/// below can be unit-tested.
struct MetricsLogLine: Decodable {
    let timestamp: String?
    let requestId: String?
    let message: Message?

    struct Message: Decodable {
        let id: String?
        let model: String?
        let usage: Usage?
    }
    struct Usage: Decodable {
        let input_tokens: Int?
        let output_tokens: Int?
        let cache_read_input_tokens: Int?
        let cache_creation_input_tokens: Int?
    }
}

// MARK: - Pure aggregation (testable, no I/O)

/// "Active" time = sum of gaps between consecutive messages, ignoring idle gaps
/// longer than 5 minutes (so breaks don't count as working time).
func activeSeconds(_ times: [Date]) -> Int {
    guard times.count > 1 else { return 0 }
    let sorted = times.sorted()
    var total: TimeInterval = 0
    for i in 1..<sorted.count {
        let gap = sorted[i].timeIntervalSince(sorted[i - 1])
        if gap > 0 && gap <= 300 { total += gap }
    }
    return Int(total)
}

/// Aggregates today/yesterday usage from raw `.jsonl` file contents, relative to
/// `now`. Pure — feed it strings and a clock and it returns a `UsageMetrics`,
/// with no filesystem access. This is the heart of the "Today" section and the
/// part most worth testing (dedup, token sums, cache %, the day boundary).
func aggregateMetrics(jsonlContents: [String], now: Date) -> UsageMetrics {
    aggregateMetrics(entries: TranscriptParser().entries(in: jsonlContents), now: now)
}

/// The aggregation proper, over already-decoded transcript entries (the cached path).
func aggregateMetrics(entries: [TranscriptEntry], now: Date) -> UsageMetrics {
    let cal = Calendar.current
    let startToday = cal.startOfDay(for: now)
    guard let startYesterday = cal.date(byAdding: .day, value: -1, to: startToday) else { return .empty }
    let startMonth = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? startToday
    // Per-day window for streaks / the activity strip (last 30 days incl. today).
    let lookbackStart = cal.date(byAdding: .day, value: -29, to: startToday) ?? startToday

    var seen = Set<String>()
    var tIn = 0, tOut = 0, tCacheR = 0, tCacheC = 0, tMsgs = 0
    var mIn = 0, mOut = 0, mCacheR = 0, mCacheC = 0   // month-to-date, by type
    var todayCost = 0.0, monthCost = 0.0, monthSavings = 0.0
    var todayTimes: [Date] = []
    var yesterdayTokens = 0
    var dailyTokens: [Date: Int] = [:]
    var costByModel: [String: Double] = [:]
    var dailyCost: [Date: Double] = [:]
    // Per-day rollups for the persisted archive, plus the message timestamps each
    // day needs to get its own active-time figure (not just today's).
    var detail: [String: DailyActivity] = [:]
    var timesByDay: [String: [Date]] = [:]

    for entry in entries {
        guard let usage = entry.usage else { continue }
        let date = entry.date

        // Dedupe resumed/duplicated entries the way ccusage does.
        let key = "\(entry.messageId ?? ""):\(entry.requestId ?? "")"
        if key != ":" {
            if seen.contains(key) { continue }
            seen.insert(key)
        }

        let total = (usage.input_tokens ?? 0) + (usage.output_tokens ?? 0)
            + (usage.cache_read_input_tokens ?? 0) + (usage.cache_creation_input_tokens ?? 0)

        let model = entry.model
        let input = usage.input_tokens ?? 0
        let output = usage.output_tokens ?? 0
        let cacheC = usage.cache_creation_input_tokens ?? 0
        let cacheR = usage.cache_read_input_tokens ?? 0

        if date >= lookbackStart {
            let day = cal.startOfDay(for: date)
            let dayCost = tokenCostUSD(model: model, input: input,
                output: output, cacheCreation: cacheC, cacheRead: cacheR)
            dailyTokens[day, default: 0] += total
            dailyCost[day, default: 0] += dayCost

            let key = statusDayKey(day, calendar: cal)
            var roll = detail[key] ?? .zero
            roll.tokens += total
            roll.input += input
            roll.output += output
            roll.cacheRead += cacheR
            roll.cacheCreation += cacheC
            roll.cost += dayCost
            roll.messages += 1
            detail[key] = roll
            timesByDay[key, default: []].append(date)
        }

        if date >= startMonth {
            let cost = tokenCostUSD(model: model, input: input, output: output,
                                    cacheCreation: cacheC, cacheRead: cacheR)
            monthCost += cost
            mIn += input; mOut += output; mCacheR += cacheR; mCacheC += cacheC
            costByModel[displayModelName(for: model), default: 0] += cost
            monthSavings += tokenCostUncachedUSD(model: model, input: input, output: output,
                cacheCreation: cacheC, cacheRead: cacheR) - cost
            if date >= startToday {
                tIn += input
                tOut += output
                tCacheR += cacheR
                tCacheC += cacheC
                tMsgs += 1
                todayCost += cost
                todayTimes.append(date)
            }
        }
        if date >= startYesterday && date < startToday {
            yesterdayTokens += total
        }
    }

    for (key, times) in timesByDay {
        detail[key]?.activeSeconds = activeSeconds(times)
    }

    let inputSide = tIn + tCacheR + tCacheC
    let cachePct = inputSide > 0 ? Int((Double(tCacheR) / Double(inputSide)) * 100.0) : 0

    return UsageMetrics(
        todayTokens: tIn + tOut + tCacheR + tCacheC,
        todayCachePercent: cachePct,
        todayActiveSeconds: activeSeconds(todayTimes),
        todayMessages: tMsgs,
        yesterdayTokens: yesterdayTokens,
        todayCostUSD: todayCost,
        monthCostUSD: monthCost,
        monthSavingsUSD: monthSavings,
        dailyTokens: dailyTokens,
        costByModel: costByModel,
        dailyCost: dailyCost,
        monthInputTokens: mIn,
        monthOutputTokens: mOut,
        monthCacheReadTokens: mCacheR,
        monthCacheCreationTokens: mCacheC,
        dailyDetail: detail
    )
}

// MARK: - MetricsService

final class MetricsService: ObservableObject {
    static let shared = MetricsService()

    @Published private(set) var metrics: UsageMetrics = .empty
    /// Tool / MCP call breakdown, month to date — computed from the same transcripts.
    @Published private(set) var tools: ToolBreakdown = .empty

    private var timer: Timer?
    private let interval: TimeInterval = 60
    private let queue = DispatchQueue(label: "io.github.broots144.ClaudeGlance.metrics", qos: .utility)
    private let cache = TranscriptCache()   // touched only on `queue`
    private let gate = ScanGate()

    private init() {}

    func startPolling() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        // A scan still running from the last tick: skip rather than queue another.
        guard gate.tryBegin() else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let (metrics, tools) = self.computeMetrics()
            self.gate.end()
            DispatchQueue.main.async {
                self.metrics = metrics
                self.tools = tools
            }
        }
    }

    /// Brings the cached transcript entries up to date (the only I/O: new bytes
    /// of changed files), then defers all aggregation to the pure functions.
    private func computeMetrics() -> (UsageMetrics, ToolBreakdown) {
        let now = Date()

        let cal = Calendar.current
        let startToday = cal.startOfDay(for: now)
        guard let startYesterday = cal.date(byAdding: .day, value: -1, to: startToday) else { return (.empty, .empty) }
        let startMonth = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? startToday
        let lookbackStart = cal.date(byAdding: .day, value: -29, to: startToday) ?? startToday
        // Read files touched since the earliest window we report on (30-day strip,
        // month-to-date, or yesterday) so every figure is complete.
        let cutoff = min(startMonth, startYesterday, lookbackStart)

        // Scan every configured Claude config dir [#22], not just ~/.claude.
        let entries = cache.entries(in: claudeProjectsDirectories(), modifiedSince: cutoff)

        var metrics = aggregateMetrics(entries: entries, now: now)

        // Fold this scan into the persisted archive and read the charts back out
        // of it. Claude Code deletes transcripts after `cleanupPeriodDays` (30 by
        // default), so charting the scan alone makes history visibly shrink as
        // logs age out; the archive keeps the days we've already seen.
        let archive = ActivityArchiveStore.shared.record(metrics.dailyDetail)
        metrics.dailyTokens = archiveDailyTokens(archive, since: lookbackStart, calendar: cal)
        metrics.dailyCost = archiveDailyCost(archive, since: lookbackStart, calendar: cal)
        metrics.archivedDailyTokens = archiveDailyTokens(archive, calendar: cal)

        return (metrics, aggregateToolUsage(entries: entries, now: now))
    }
}
