import Foundation

// MARK: - Statusline sidecar [#27]

/// The data ClaudeGlance writes for its bundled Claude Code statusline script to
/// read — a small sidecar so the CLI line reuses the exact numbers the menu bar
/// already computed, with no extra API calls or jsonl parsing per render.
///
/// `schema` is versioned so the script can refuse a format it doesn't understand.
struct StatusExport: Codable, Equatable {
    /// Bumped on any breaking field change; the script checks it.
    var schema: Int = 1
    /// When these numbers were produced (ISO 8601), so a reader can spot stale data.
    let updated: String
    /// True when the app already considers its own numbers stale (no recent poll).
    let stale: Bool

    // OAuth limit gauges.
    let fiveHourPct: Int
    let sevenDayPct: Int
    let sonnetPct: Int?
    let fiveHourResetIn: String?
    let sevenDayResetIn: String?

    // 5h burn / run-out, when a trend is established (else nil).
    let burnPerHour: Int?
    let etaClock: String?

    // Local activity (today / month-to-date), API-equivalent USD.
    let todayCostUSD: Double
    let monthCostUSD: Double
    let todayTokens: Int

    /// The ready-to-print default line (usage only) — so the shell script needs no
    /// formatting logic and stays consistent with the app. Never contains a double
    /// quote, so a jq-less reader can extract it with a simple sed.
    let line: String
}

/// The default statusline string — usage only [#27], in the app's quiet voice:
/// "5h 35% · 7d 71%", with "· Sonnet 40%" appended only when Sonnet has weekly
/// usage (mirroring the menu, which hides a zero Sonnet row). Pure/testable.
func statusLineText(fiveHourPct: Int, sevenDayPct: Int, sonnetPct: Int?) -> String {
    var parts = ["5h \(fiveHourPct)%", "7d \(sevenDayPct)%"]
    if let sonnetPct, sonnetPct > 0 { parts.append("Sonnet \(sonnetPct)%") }
    return parts.joined(separator: " · ")
}

/// Assembles the sidecar payload from the same snapshots the menu reads. Pure
/// (no I/O) so the field mapping and the ETA/burn gating are unit-testable.
func buildStatusExport(usage: UsageSnapshot, burn: BurnEstimate?, metrics: UsageMetrics,
                       now: Date = Date()) -> StatusExport {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]

    // ETA only when on pace to hit the 5h cap before it resets (same rule the menu
    // uses for its "On pace for 100% by …" row).
    var etaClock: String? = nil
    if let burn, let secs = burn.secondsToLimit,
       burn.hitsLimitBeforeReset(resetAt: usage.fiveHourResetAt, now: now) {
        etaClock = formatClockTime(now.addingTimeInterval(secs))
    }
    // Surface the burn only once it's a meaningful ≥1%/hr (matching the menu).
    let burnPerHour = burn.map { Int($0.percentPerHour.rounded()) }.flatMap { $0 >= 1 ? $0 : nil }

    return StatusExport(
        updated: iso.string(from: now),
        stale: isStale(lastUpdated: usage.lastUpdated, now: now),
        fiveHourPct: usage.fiveHourUtilization,
        sevenDayPct: usage.sevenDayUtilization,
        sonnetPct: usage.sevenDaySonnetUtilization,
        fiveHourResetIn: usage.fiveHourResetIn,
        sevenDayResetIn: usage.sevenDayResetIn,
        burnPerHour: burnPerHour,
        etaClock: etaClock,
        todayCostUSD: metrics.todayCostUSD,
        monthCostUSD: metrics.monthCostUSD,
        todayTokens: metrics.todayTokens,
        line: statusLineText(fiveHourPct: usage.fiveHourUtilization,
                             sevenDayPct: usage.sevenDayUtilization,
                             sonnetPct: usage.sevenDaySonnetUtilization)
    )
}

/// Writes the statusline sidecar to Application Support on each poll, so the
/// bundled CLI script always reads current numbers. Snapshotting happens on the
/// main thread (like the menu); the disk write is async + atomic.
final class StatusLineExporter {
    static let shared = StatusLineExporter()
    private let io = DispatchQueue(label: "io.github.broots144.ClaudeGlance.statusline", qos: .utility)
    private init() {}

    /// Snapshot current state from the services and persist it async.
    func export(now: Date = Date()) {
        let payload = buildStatusExport(
            usage: UsageService.shared.currentUsage,
            burn: UsageService.shared.fiveHourBurn,
            metrics: MetricsService.shared.metrics,
            now: now)
        io.async { StatusLineExporter.write(payload, to: StatusLineExporter.fileURL) }
    }

    // MARK: - Disk

    static var fileURL: URL? {
        let fm = FileManager.default
        guard let base = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true) else { return nil }
        let dir = base.appendingPathComponent("ClaudeGlance", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("status.json")
    }

    static func write(_ export: StatusExport, to url: URL?) {
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(export) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
