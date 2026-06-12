import Foundation

// MARK: - Context-window monitor (per-session, from Claude Code session logs)

/// The usable context window for a standard Claude model. The 1M-token beta isn't
/// distinguishable from the transcript (the model string carries no `[1m]` marker),
/// so we report against the default 200K window every subscription session uses.
let standardContextWindow = 200_000

/// Tokens that make up the current context for `model`. A hook for the day the
/// 1M-context beta becomes detectable; today everything is the 200K window.
func contextWindowLimit(forModel model: String) -> Int { standardContextWindow }

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
    let windowLimit: Int         // 200_000 for standard models
    let lastActivity: Date
    let cacheActive: Bool        // the latest turn read or wrote a prompt cache

    var id: String { sessionId }

    /// 0–100; capped at 100 since auto-compact can briefly push the raw figure over.
    var utilization: Int {
        guard windowLimit > 0 else { return 0 }
        return min(100, Int((Double(contextTokens) / Double(windowLimit) * 100).rounded()))
    }

    var tokensRemaining: Int { max(0, windowLimit - contextTokens) }
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

/// Minimal transcript shape for context monitoring — top-level `sessionId`/`cwd`/
/// `isSidechain` plus the assistant message's model and usage. Reuses
/// `MetricsLogLine.Usage` for the token fields. Internal so the pure aggregation
/// below is unit-testable.
struct ContextLogLine: Decodable {
    let sessionId: String?
    let timestamp: String?
    let isSidechain: Bool?
    let cwd: String?
    let gitBranch: String?
    let message: Message?

    struct Message: Decodable {
        let role: String?
        let model: String?
        let usage: MetricsLogLine.Usage?
    }
}

// MARK: - Pure aggregation (testable, no I/O)

/// Builds per-session context state from raw `.jsonl` contents relative to `now`.
/// For each session it keeps the *latest* assistant turn that carried usage — that
/// turn's prompt size is the live context fill (taking the latest, not the max, so
/// the figure drops correctly right after an auto-compact). Subagent sidechains and
/// synthetic entries are skipped (they run in their own, separate context windows).
/// Sessions untouched within `recentWithin` are dropped so only live work shows.
func aggregateContextWindows(jsonlContents: [String], now: Date,
                             recentWithin: TimeInterval = 24 * 3600) -> ContextWindowMetrics {
    let isoFrac = ISO8601DateFormatter(); isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime]
    let decoder = JSONDecoder()

    // Per session: the latest assistant-usage line seen so far.
    struct Latest { var date: Date; var tokens: Int; var cached: Bool; var model: String; var cwd: String?; var branch: String? }
    var latestBySession: [String: Latest] = [:]

    for content in jsonlContents {
        for line in content.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let entry = try? decoder.decode(ContextLogLine.self, from: data),
                  let sessionId = entry.sessionId,
                  let msg = entry.message, msg.role == "assistant",
                  let usage = msg.usage,
                  let ts = entry.timestamp,
                  let date = isoFrac.date(from: ts) ?? iso.date(from: ts) else { continue }

            // Subagent sidechains have their own context window; synthetic entries
            // (compaction markers, etc.) aren't real model turns.
            if entry.isSidechain == true { continue }
            let model = msg.model ?? ""
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

    /// Reads only transcripts touched within `recentWithin` (a much smaller set
    /// than the cost/activity window), then defers to the pure aggregation.
    private func computeMetrics() -> ContextWindowMetrics {
        let now = Date()
        let fm = FileManager.default
        let projects = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        guard let enumerator = fm.enumerator(
            at: projects,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return .empty }

        let cutoff = now.addingTimeInterval(-recentWithin)
        var contents: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if mod < cutoff { continue }
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            contents.append(content)
        }

        return aggregateContextWindows(jsonlContents: contents, now: now, recentWithin: recentWithin)
    }
}
