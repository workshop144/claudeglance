import Foundation

// MARK: - Context-window monitor (per-session, from Claude Code session logs)

/// The 200K window — Haiku, and the conservative fallback for anything we don't
/// recognize (so we never overstate headroom).
let standardContextWindow = 200_000
/// The 1M window Opus 4.6+, Sonnet 4.6+ and Fable 5 ship as standard.
let largeContextWindow = 1_000_000

/// The usable context window for a session, from its transcript model id.
/// Version-aware, and never overstating headroom: Opus 4.6+ and Sonnet 4.6+
/// (and Fable 5) ship a 1M-token window as standard; Opus 4, 4.1 and 4.5,
/// Sonnet 4 and 4.5, Haiku, Claude 3 models and anything unrecognised get 200K.
/// (Sonnet 4 / 4.5 offered 1M only as an opt-in beta, so 200K is the safe
/// reading there unless the id carries Claude Code's "[1m]" marker: it can only
/// understate headroom.) [#11]
func contextWindowLimit(forModel model: String) -> Int {
    let id = model.lowercased()
    // Claude Code's explicit 1M marker (e.g. "claude-sonnet-4-5[1m]") always wins.
    if id.hasSuffix("[1m]") { return largeContextWindow }
    if id.contains("haiku") { return standardContextWindow }
    if id.contains("fable") { return largeContextWindow }
    if id.contains("opus"), let minor = opus4MinorVersion(id), minor >= 6 {
        return largeContextWindow
    }
    if id.contains("sonnet"), let minor = sonnet4MinorVersion(id), minor >= 6 {
        return largeContextWindow
    }
    return standardContextWindow
}

/// The minor version of a Sonnet 4.x model id ("claude-sonnet-4-6" → 6), or nil
/// for plain Sonnet 4 ("claude-sonnet-4-20250514", where the next part is a date)
/// and anything that isn't Sonnet 4.x. Same rules as `opus4MinorVersion`.
func sonnet4MinorVersion(_ model: String) -> Int? {
    let m = model.lowercased()
    guard let r = m.range(of: "sonnet-4-") ?? m.range(of: "sonnet4-") else { return nil }
    let rest = m[r.upperBound...]
    guard let first = rest.first, first.isASCII, let digit = first.wholeNumberValue else { return nil }
    let after = rest.dropFirst().first
    guard after == nil || after == "-" else { return nil }
    return digit
}

/// A single Claude Code session and how full its context window currently is.
/// "Current" = the most recent assistant turn's prompt size (input + both cache
/// sides), which is exactly what was sent to the model on that turn and so grows
/// as the conversation does — until an auto-compact shrinks it back down.
struct ContextSession: Identifiable {
    let sessionId: String
    let project: String          // last path component of the session's cwd
    let gitBranch: String?
    let model: String            // display name, e.g. "Opus 4.8"
    let contextTokens: Int       // current prompt size sent to the model
    let windowLimit: Int         // per-model: see contextWindowLimit(forModel:)
    let lastActivity: Date
    let cacheActive: Bool        // the latest turn read or wrote a prompt cache

    var id: String { sessionId }

    /// 0–100; capped at 100 since auto-compact can briefly push the raw figure over.
    var utilization: Int {
        guard windowLimit > 0 else { return 0 }
        return min(100, Int((Double(contextTokens) / Double(windowLimit) * 100).rounded()))
    }

    var tokensRemaining: Int { max(0, windowLimit - contextTokens) }

    /// Compact window label for display, e.g. "1M" or "200K".
    var windowLabel: String {
        windowLimit >= 1_000_000 ? "\(windowLimit / 1_000_000)M" : "\(windowLimit / 1_000)K"
    }
}

/// Caution / high thresholds for the context gauge. High (90%) is the
/// "an auto-compact is near" zone; below caution it's comfortably roomy.
let contextCautionThreshold = 70
let contextHighThreshold = 90

extension ContextSession {
    var isCaution: Bool { utilization >= contextCautionThreshold && utilization < contextHighThreshold }
    var isHigh: Bool { utilization >= contextHighThreshold }
}

/// Anthropic's default prompt-cache TTL: 5 minutes, refreshed on every cache read.
/// Idle longer than this and the next turn re-pays cache-creation (1.25× input)
/// instead of a cheap cache read (0.1×) — the cost the freshness countdown warns of.
let cacheTTLSeconds: TimeInterval = 300

extension ContextSession {
    /// When this session's prompt cache goes cold — `cacheTTLSeconds` after the
    /// latest turn (which read/refreshed the cache).
    var cacheExpiresAt: Date { lastActivity.addingTimeInterval(cacheTTLSeconds) }

    /// Whole seconds of warmth left before the cache expires (0 once cold).
    func cacheFreshSeconds(now: Date) -> Int {
        max(0, Int(cacheExpiresAt.timeIntervalSince(now).rounded()))
    }

    /// Warm = the session uses caching and we're still inside the TTL window.
    func isCacheWarm(now: Date) -> Bool { cacheActive && now < cacheExpiresAt }

    /// Seconds since the last turn — the "idle" figure shown once the cache is cold.
    func idleSeconds(now: Date) -> Int { max(0, Int(now.timeIntervalSince(lastActivity).rounded())) }
}

/// The recently-active sessions, most-recent first. `active` is the session you're
/// most likely sitting in right now (the headline the menu glances at).
struct ContextWindowMetrics {
    let sessions: [ContextSession]

    var active: ContextSession? { sessions.first }
    var hasData: Bool { !sessions.isEmpty }
    var maxUtilization: Int { sessions.map(\.utilization).max() ?? 0 }

    static let empty = ContextWindowMetrics(sessions: [])
}

// MARK: - Log line shape

// MARK: - Pure aggregation (testable, no I/O)

/// Builds per-session context state from raw `.jsonl` contents relative to `now`.
/// For each session it keeps the *latest* assistant turn that carried usage — that
/// turn's prompt size is the live context fill (taking the latest, not the max, so
/// the figure drops correctly right after an auto-compact). Subagent sidechains and
/// synthetic entries are skipped (they run in their own, separate context windows).
/// Sessions untouched within `recentWithin` are dropped so only live work shows.
func aggregateContextWindows(jsonlContents: [String], now: Date,
                             recentWithin: TimeInterval = 24 * 3600) -> ContextWindowMetrics {
    aggregateContextWindows(entries: TranscriptParser().entries(in: jsonlContents),
                            now: now, recentWithin: recentWithin)
}

/// The aggregation proper, over already-decoded transcript entries (the cached path).
func aggregateContextWindows(entries: [TranscriptEntry], now: Date,
                             recentWithin: TimeInterval = 24 * 3600) -> ContextWindowMetrics {
    // Per session: the latest assistant-usage line seen so far.
    struct Latest { var date: Date; var tokens: Int; var cached: Bool; var model: String; var cwd: String?; var branch: String? }
    var latestBySession: [String: Latest] = [:]

    for entry in entries {
        guard let sessionId = entry.sessionId, entry.role == "assistant",
              let usage = entry.usage else { continue }
        let date = entry.date

        // Subagent sidechains have their own context window; synthetic entries
        // (compaction markers, etc.) aren't real model turns.
        if entry.isSidechain { continue }
        let model = entry.model
        if model.isEmpty || model == "<synthetic>" { continue }

        // The prompt size sent to the model = input + both cache sides. Output
        // tokens are the response, not part of the context that was sent.
        let cacheR = usage.cache_read_input_tokens ?? 0
        let cacheC = usage.cache_creation_input_tokens ?? 0
        let tokens = (usage.input_tokens ?? 0) + cacheR + cacheC
        if tokens <= 0 { continue }

        // Keep the latest turn by timestamp (ties keep the larger context).
        if let prev = latestBySession[sessionId],
           (prev.date > date || (prev.date == date && prev.tokens >= tokens)) { continue }
        latestBySession[sessionId] = Latest(date: date, tokens: tokens, cached: cacheR + cacheC > 0,
                                            model: model, cwd: entry.cwd, branch: entry.gitBranch)
    }

    let cutoff = now.addingTimeInterval(-recentWithin)
    let sessions = latestBySession.compactMap { id, l -> ContextSession? in
        guard l.date >= cutoff else { return nil }
        let project = l.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "session"
        return ContextSession(
            sessionId: id,
            project: project.isEmpty ? "session" : project,
            gitBranch: l.branch,
            model: displayModelName(for: l.model),
            contextTokens: l.tokens,
            windowLimit: contextWindowLimit(forModel: l.model),
            lastActivity: l.date,
            cacheActive: l.cached
        )
    }
    .sorted { $0.lastActivity > $1.lastActivity }

    return ContextWindowMetrics(sessions: sessions)
}

// MARK: - ContextWindowService

/// Polls the local Claude Code transcripts for per-session context-window fill.
/// Opt-in (off by default) — a "second glance" that reuses the jsonl we already
/// read, with no Keychain or network. Mirrors `MetricsService`: a thin I/O layer
/// over the pure `aggregateContextWindows`.
final class ContextWindowService: ObservableObject {
    static let shared = ContextWindowService()

    @Published private(set) var metrics: ContextWindowMetrics = .empty

    private var timer: Timer?
    private let interval: TimeInterval = 30
    /// How recently a session must have been touched to count as "live".
    private let recentWithin: TimeInterval = 24 * 3600
    private let queue = DispatchQueue(label: "io.github.broots144.ClaudeGlance.context", qos: .utility)
    private let cache = TranscriptCache()   // touched only on `queue`
    private let gate = ScanGate()

    /// Whether anything shows the result right now (see `shouldScanContextWindows`).
    /// Read on the main thread at each tick; the scan is skipped when false.
    var isNeeded: () -> Bool = { true }

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
        guard isNeeded(), gate.tryBegin() else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let result = self.computeMetrics()
            self.gate.end()
            DispatchQueue.main.async { self.metrics = result }
        }
    }

    /// Reads only transcripts touched within `recentWithin` (a much smaller set
    /// than the cost/activity window), and of those only the bytes appended since
    /// the last scan, then defers to the pure aggregation.
    private func computeMetrics() -> ContextWindowMetrics {
        let now = Date()
        // Scan every configured Claude config dir [#22], not just ~/.claude.
        let entries = cache.entries(in: claudeProjectsDirectories(),
                                    modifiedSince: now.addingTimeInterval(-recentWithin))
        return aggregateContextWindows(entries: entries, now: now, recentWithin: recentWithin)
    }
}
