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
    let dailyTokens: [Date: Int]

    static let empty = UsageMetrics(todayTokens: 0, todayCachePercent: 0,
                                    todayActiveSeconds: 0, todayMessages: 0, yesterdayTokens: 0,
                                    todayCostUSD: 0, monthCostUSD: 0, monthSavingsUSD: 0,
                                    dailyTokens: [:])

    var hasData: Bool { todayMessages > 0 }
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
    let cal = Calendar.current
    let startToday = cal.startOfDay(for: now)
    guard let startYesterday = cal.date(byAdding: .day, value: -1, to: startToday) else { return .empty }
    let startMonth = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? startToday
    // Per-day window for streaks / the activity strip (last 30 days incl. today).
    let lookbackStart = cal.date(byAdding: .day, value: -29, to: startToday) ?? startToday

    let isoFrac = ISO8601DateFormatter(); isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime]

    var seen = Set<String>()
    var tIn = 0, tOut = 0, tCacheR = 0, tCacheC = 0, tMsgs = 0
    var todayCost = 0.0, monthCost = 0.0, monthSavings = 0.0
    var todayTimes: [Date] = []
    var yesterdayTokens = 0
    var dailyTokens: [Date: Int] = [:]
    let decoder = JSONDecoder()

    for content in jsonlContents {
        for line in content.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let entry = try? decoder.decode(MetricsLogLine.self, from: data),
                  let usage = entry.message?.usage,
                  let ts = entry.timestamp,
                  let date = isoFrac.date(from: ts) ?? iso.date(from: ts) else { continue }

            // Dedupe resumed/duplicated entries the way ccusage does.
            let key = "\(entry.message?.id ?? ""):\(entry.requestId ?? "")"
            if key != ":" {
                if seen.contains(key) { continue }
                seen.insert(key)
            }

            let total = (usage.input_tokens ?? 0) + (usage.output_tokens ?? 0)
                + (usage.cache_read_input_tokens ?? 0) + (usage.cache_creation_input_tokens ?? 0)

            if date >= lookbackStart {
                dailyTokens[cal.startOfDay(for: date), default: 0] += total
            }

            if date >= startMonth {
                let cost = tokenCostUSD(
                    model: entry.message?.model ?? "",
                    input: usage.input_tokens ?? 0,
                    output: usage.output_tokens ?? 0,
                    cacheCreation: usage.cache_creation_input_tokens ?? 0,
                    cacheRead: usage.cache_read_input_tokens ?? 0)
                monthCost += cost
                monthSavings += tokenCostUncachedUSD(
                    model: entry.message?.model ?? "",
                    input: usage.input_tokens ?? 0,
                    output: usage.output_tokens ?? 0,
                    cacheCreation: usage.cache_creation_input_tokens ?? 0,
                    cacheRead: usage.cache_read_input_tokens ?? 0) - cost
                if date >= startToday {
                    tIn += usage.input_tokens ?? 0
                    tOut += usage.output_tokens ?? 0
                    tCacheR += usage.cache_read_input_tokens ?? 0
                    tCacheC += usage.cache_creation_input_tokens ?? 0
                    tMsgs += 1
                    todayCost += cost
                    todayTimes.append(date)
                }
            }
            if date >= startYesterday && date < startToday {
                yesterdayTokens += total
            }
        }
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
        dailyTokens: dailyTokens
    )
}

// MARK: - MetricsService

final class MetricsService: ObservableObject {
    static let shared = MetricsService()

    @Published private(set) var metrics: UsageMetrics = .empty

    private var timer: Timer?
    private let interval: TimeInterval = 60
    private let queue = DispatchQueue(label: "io.github.broots144.ClaudeGlance.metrics", qos: .utility)

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
        queue.async { [weak self] in
            guard let self else { return }
            let result = self.computeMetrics()
            DispatchQueue.main.async { self.metrics = result }
        }
    }

    /// Gathers the relevant transcript file contents (the only I/O), then defers
    /// all parsing/aggregation to the pure `aggregateMetrics`.
    private func computeMetrics() -> UsageMetrics {
        let now = Date()
        let fm = FileManager.default
        let projects = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        guard let enumerator = fm.enumerator(
            at: projects,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return .empty }

        let cal = Calendar.current
        let startToday = cal.startOfDay(for: now)
        guard let startYesterday = cal.date(byAdding: .day, value: -1, to: startToday) else { return .empty }
        let startMonth = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? startToday
        let lookbackStart = cal.date(byAdding: .day, value: -29, to: startToday) ?? startToday
        // Read files touched since the earliest window we report on (30-day strip,
        // month-to-date, or yesterday) so every figure is complete.
        let cutoff = min(startMonth, startYesterday, lookbackStart)

        var contents: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if mod < cutoff { continue }
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            contents.append(content)
        }

        return aggregateMetrics(jsonlContents: contents, now: now)
    }
}
