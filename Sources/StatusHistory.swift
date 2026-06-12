import Foundation

// MARK: - Service-status uptime history [#29]

/// Persisted day-by-day record of the worst Claude service status we've seen, so
/// the menu can show a 30-day uptime bar. The OAuth/usage numbers aren't involved
/// — this is purely the public status page, recorded over time (like HistoryStore
/// does for usage) and seeded once from the incident feed so it isn't empty on day
/// one.
struct StatusHistory: Codable, Equatable {
    /// "yyyy-MM-dd" → the worst `ServiceStatusIndicator.rawValue` seen that day.
    var days: [String: String]

    init(days: [String: String] = [:]) { self.days = days }
}

/// A reported incident reduced to what the uptime math needs: its impact and the
/// window it was active. `end == nil` means still ongoing.
struct StatusIncident: Equatable {
    let impact: ServiceStatusIndicator
    let start: Date
    let end: Date?
}

// MARK: - Severity ordering (pure)

/// Orders indicators worst-wins. `unknown` is "no data" (sorts below operational),
/// so a real reading always replaces it and two unknowns stay unknown.
func statusSeverity(_ i: ServiceStatusIndicator) -> Int {
    switch i {
    case .unknown:     return -1
    case .none:        return 0
    case .maintenance: return 1
    case .minor:       return 2
    case .major:       return 3
    case .critical:    return 4
    }
}

/// The worse (more severe) of two indicators.
func worseStatus(_ a: ServiceStatusIndicator, _ b: ServiceStatusIndicator) -> ServiceStatusIndicator {
    statusSeverity(a) >= statusSeverity(b) ? a : b
}

// MARK: - Day keys (pure)

/// A stable "yyyy-MM-dd" key in the calendar's own time zone, so days line up with
/// the rest of the app's day boundaries. Sortable as a plain string.
func statusDayKey(_ date: Date, calendar: Calendar = .current) -> String {
    var f = DateFormatter()
    f.calendar = calendar
    f.timeZone = calendar.timeZone
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: date)
}

/// Merge an indicator into a day map, keeping the worse of old/new (a day can only
/// get worse — incidents don't un-happen).
func mergeStatus(into days: inout [String: String], key: String, indicator: ServiceStatusIndicator) {
    let existing = days[key].flatMap { ServiceStatusIndicator(rawValue: $0) } ?? .unknown
    days[key] = worseStatus(existing, indicator).rawValue
}

/// Drop days older than `keepDays`. Pure; string comparison works because the keys
/// are zero-padded ISO dates.
func prunedStatus(_ days: [String: String], now: Date, keepDays: Int, calendar: Calendar = .current) -> [String: String] {
    let floorDate = calendar.date(byAdding: .day, value: -keepDays, to: calendar.startOfDay(for: now)) ?? now
    let floor = statusDayKey(floorDate, calendar: calendar)
    return days.filter { $0.key >= floor }
}

/// The last `count` days (oldest → newest) as (day, indicator); missing days come
/// back `.unknown` so the bar can render them as "no data".
func recentStatusDays(_ history: StatusHistory, count: Int, endingAt now: Date,
                      calendar: Calendar = .current) -> [(date: Date, indicator: ServiceStatusIndicator)] {
    let today = calendar.startOfDay(for: now)
    return stride(from: count - 1, through: 0, by: -1).compactMap { back in
        guard let day = calendar.date(byAdding: .day, value: -back, to: today) else { return nil }
        let indicator = history.days[statusDayKey(day, calendar: calendar)]
            .flatMap { ServiceStatusIndicator(rawValue: $0) } ?? .unknown
        return (day, indicator)
    }
}

// MARK: - Uptime % from incidents (pure)

/// Time-based uptime over a trailing `window`, computed from incidents: union the
/// down-impact intervals (clamped to the window, overlaps merged so they're not
/// double-counted) and report the operational fraction. Defaults to counting only
/// major/critical as downtime — minor incidents are "degraded but up". Reliable
/// only as far back as the incident feed reaches (~30d on a busy page), which is
/// why the menu shows the 30-day figure.
func uptimePercent(incidents: [StatusIncident], window: TimeInterval, now: Date,
                   downImpacts: Set<ServiceStatusIndicator> = [.major, .critical]) -> Double {
    guard window > 0 else { return 100 }
    let windowStart = now.addingTimeInterval(-window)

    var intervals: [(start: Date, end: Date)] = []
    for inc in incidents where downImpacts.contains(inc.impact) {
        let s = max(inc.start, windowStart)
        let e = min(inc.end ?? now, now)
        if e > s { intervals.append((s, e)) }
    }
    intervals.sort { $0.start < $1.start }

    var merged: [(start: Date, end: Date)] = []
    for iv in intervals {
        if let last = merged.last, iv.start <= last.end {
            merged[merged.count - 1].end = max(last.end, iv.end)
        } else {
            merged.append(iv)
        }
    }

    let down = merged.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
    return max(0, min(100, (window - down) / window * 100))
}

/// Seed a day map from the incident feed: an "operational" baseline for every day
/// from the oldest incident (capped to `maxDays`) up to today, with minor/major/
/// critical incidents overlaid worst-wins. Days before the feed's reach are left
/// out (they stay "no data"). Pure.
func incidentSeed(incidents: [StatusIncident], now: Date, maxDays: Int,
                  calendar: Calendar = .current) -> [String: String] {
    guard let oldest = incidents.map({ $0.start }).min() else { return [:] }
    let today = calendar.startOfDay(for: now)
    let floor = calendar.date(byAdding: .day, value: -maxDays, to: today) ?? today
    let start = max(calendar.startOfDay(for: oldest), floor)

    var days: [String: String] = [:]
    var d = start
    while d <= today {
        days[statusDayKey(d, calendar: calendar)] = ServiceStatusIndicator.none.rawValue
        guard let next = calendar.date(byAdding: .day, value: 1, to: d) else { break }
        d = next
    }

    for inc in incidents where statusSeverity(inc.impact) >= statusSeverity(.minor) {
        let end = inc.end ?? now
        var day = calendar.startOfDay(for: max(inc.start, start))
        let lastDay = calendar.startOfDay(for: min(end, now))
        while day <= lastDay {
            mergeStatus(into: &days, key: statusDayKey(day, calendar: calendar), indicator: inc.impact)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
    }
    return days
}

// MARK: - Incident feed parsing (pure)

/// Parse Statuspage `incidents.json` into the minimal `StatusIncident` shape.
/// Tolerates missing fields and either fractional or whole-second timestamps.
func parseIncidents(_ data: Data) -> [StatusIncident] {
    struct Response: Decodable {
        let incidents: [Incident]
        struct Incident: Decodable {
            let impact: String?
            let started_at: String?
            let created_at: String?
            let resolved_at: String?
        }
    }
    guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else { return [] }

    let isoFrac = ISO8601DateFormatter(); isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime]
    func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        return isoFrac.date(from: s) ?? iso.date(from: s)
    }

    return decoded.incidents.compactMap { inc in
        guard let start = date(inc.started_at) ?? date(inc.created_at) else { return nil }
        let impact = ServiceStatusIndicator(rawValue: inc.impact ?? "none") ?? .none
        return StatusIncident(impact: impact, start: start, end: date(inc.resolved_at))
    }
}

// MARK: - Store

/// Records the worst service status per day and persists it to Application Support
/// (rolling 90-day window). Reads happen on the main thread (like the menu); disk
/// writes are async + atomic — same shape as `HistoryStore`.
final class StatusHistoryStore: ObservableObject {
    static let shared = StatusHistoryStore()

    @Published private(set) var history: StatusHistory
    private let retentionDays = 90
    private let io = DispatchQueue(label: "io.github.broots144.ClaudeGlance.statushistory", qos: .utility)

    private init() { history = StatusHistoryStore.load(from: StatusHistoryStore.fileURL) }

    /// Record the current indicator into today's cell (worst-wins). Ignores
    /// `.unknown` (a failed/parse-less poll shouldn't overwrite real data).
    func record(indicator: ServiceStatusIndicator, at date: Date = Date(), calendar: Calendar = .current) {
        guard statusSeverity(indicator) >= 0 else { return }
        var days = history.days
        mergeStatus(into: &days, key: statusDayKey(date, calendar: calendar), indicator: indicator)
        commit(days, now: date, calendar: calendar)
    }

    /// Merge an incident-derived seed (operational baseline + incident overlays).
    func seed(incidents: [StatusIncident], now: Date = Date(), calendar: Calendar = .current) {
        let seed = incidentSeed(incidents: incidents, now: now, maxDays: retentionDays, calendar: calendar)
        guard !seed.isEmpty else { return }
        var days = history.days
        for (key, raw) in seed {
            mergeStatus(into: &days, key: key, indicator: ServiceStatusIndicator(rawValue: raw) ?? .unknown)
        }
        commit(days, now: now, calendar: calendar)
    }

    /// Last `count` days (oldest → newest) for the bar.
    func recentDays(count: Int = 30, now: Date = Date()) -> [(date: Date, indicator: ServiceStatusIndicator)] {
        recentStatusDays(history, count: count, endingAt: now)
    }

    private func commit(_ days: [String: String], now: Date, calendar: Calendar) {
        history = StatusHistory(days: prunedStatus(days, now: now, keepDays: retentionDays, calendar: calendar))
        let snapshot = history
        io.async { StatusHistoryStore.save(snapshot, to: StatusHistoryStore.fileURL) }
    }

    // MARK: - Disk

    private static var fileURL: URL? {
        let fm = FileManager.default
        guard let base = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true) else { return nil }
        let dir = base.appendingPathComponent("ClaudeGlance", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("status-history.json")
    }

    private static func load(from url: URL?) -> StatusHistory {
        guard let url, let data = try? Data(contentsOf: url) else { return StatusHistory() }
        return (try? JSONDecoder().decode(StatusHistory.self, from: data)) ?? StatusHistory()
    }

    private static func save(_ history: StatusHistory, to url: URL?) {
        guard let url, let data = try? JSONEncoder().encode(history) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
