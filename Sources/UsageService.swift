import Foundation

// MARK: - Manual-refresh throttle

/// Pure throttle decision for a user-initiated refresh: allowed if none has run
/// yet, or the last one was at least `minInterval` ago.
func manualRefreshAllowed(last: Date?, now: Date, minInterval: TimeInterval) -> Bool {
    guard let last else { return true }
    return now.timeIntervalSince(last) >= minInterval
}

// MARK: - Fetch error presentation

/// How long to wait after a 429 from the usage endpoint. Honors a numeric
/// `Retry-After` (seconds) when the server sends one, clamped to 1–60 min so a
/// bogus value can neither hammer the endpoint nor stall updates for hours.
func usageRetryDelay(retryAfter: String?, fallback: TimeInterval = 15 * 60) -> TimeInterval {
    guard let raw = retryAfter?.trimmingCharacters(in: .whitespaces),
          let seconds = TimeInterval(raw) else { return fallback }
    return min(max(seconds, 60), 60 * 60)
}

/// A short, human message for a failed usage fetch. A 429 here is Anthropic
/// throttling the *usage lookup* — not the user's Claude plan limits — so say
/// that plainly instead of a bare "Rate limited", which reads like the latter.
/// Never includes the raw response body.
func usageErrorMessage(for error: NSError, retryAt: Date) -> String {
    let when = formatClockTime(retryAt)
    if error.domain == "OAuthUsage" {
        switch error.code {
        case 429:
            return "Anthropic is throttling usage checks (your Claude limits are unaffected) — retrying at \(when)"
        case 401, 403:
            return "Auth token expired — refreshing (sign in to Claude in Settings if this persists)"
        case 500...599:
            return "Anthropic's usage API is having trouble (HTTP \(error.code)) — retrying at \(when)"
        default:
            return "Couldn't load usage (HTTP \(error.code)) — retrying at \(when)"
        }
    }
    if error.domain == NSURLErrorDomain {
        return "Can't reach Anthropic — check your connection. Retrying at \(when)"
    }
    if error.domain == "OAuth" {
        // Sign-in errors already carry a user-facing message.
        return error.localizedDescription
    }
    return "Couldn't load usage: \(error.localizedDescription) — retrying at \(when)"
}

// MARK: - API Response Model

struct OAuthUsageResponse: Decodable {
    let fiveHour: UsagePeriod?
    let sevenDay: UsagePeriod?
    let sevenDaySonnet: UsagePeriod?
    let extraUsage: ExtraUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDaySonnet = "seven_day_sonnet"
        case extraUsage = "extra_usage"
    }

    /// "Usage credits" — pay-as-you-go overage that keeps Claude working past a
    /// plan limit. `isEnabled` mirrors the claude.ai "Usage credits" toggle; the
    /// remaining fields are null until credits are enabled and used.
    struct ExtraUsage: Decodable {
        let isEnabled: Bool
        let utilization: Double?
        // Dollar amounts in cents; null until credits are enabled and used.
        let usedCredits: Int?
        let monthlyLimit: Int?

        enum CodingKeys: String, CodingKey {
            case isEnabled = "is_enabled"
            case utilization
            case usedCredits = "used_credits"
            case monthlyLimit = "monthly_limit"
        }
    }

    struct UsagePeriod: Decodable {
        let utilization: Double
        // The API returns `resets_at: null` when a period has nothing to reset
        // (most commonly `seven_day_sonnet` when Sonnet is unused that week), so
        // this must be optional or the whole response fails to decode.
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }

        var resetsAtDate: Date? {
            guard let resetsAt else { return nil }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: resetsAt)
        }
    }
}

// MARK: - Utilization helpers (pure, testable)

/// Returns utilization percentage (0–100) given token count and limit.
func calculateUtilization(tokens: Int, limit: Int) -> Int {
    guard limit > 0 else { return 0 }
    return min(100, tokens * 100 / limit)
}

/// Formats a cents amount as dollars, dropping the decimals when it's a whole
/// dollar: 120 → "$1.20", 5000 → "$50", 12050 → "$120.50".
func formatDollars(cents: Int) -> String {
    let dollars = Double(cents) / 100.0
    return cents % 100 == 0 ? String(format: "$%.0f", dollars) : String(format: "$%.2f", dollars)
}

/// Formats a future date as a human-readable countdown string.
func formatTimeRemaining(until date: Date, from now: Date = Date()) -> String {
    let interval = date.timeIntervalSince(now)
    if interval <= 0 { return "now" }
    let hours = Int(interval) / 3600
    let minutes = (Int(interval) % 3600) / 60
    return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
}

/// Like `formatTimeRemaining` but space-free (e.g. "4h12m"), suited to the menu bar title.
func formatTimeRemainingCompact(until date: Date, from now: Date = Date()) -> String {
    let interval = date.timeIntervalSince(now)
    if interval <= 0 { return "now" }
    let hours = Int(interval) / 3600
    let minutes = (Int(interval) % 3600) / 60
    return hours > 0 ? "\(hours)h\(minutes)m" : "\(minutes)m"
}

/// Whether a snapshot is stale — no successful refresh within `threshold`
/// (default 12 min, i.e. more than two missed 5-minute polls). Used to dim the
/// menu bar so stale numbers don't read as current.
func isStale(lastUpdated: Date, now: Date = Date(), threshold: TimeInterval = 12 * 60) -> Bool {
    now.timeIntervalSince(lastUpdated) > threshold
}

/// Whole minutes since `date`, for an "updated Nm ago" note.
func minutesAgo(_ date: Date, from now: Date = Date()) -> Int {
    max(0, Int(now.timeIntervalSince(date) / 60))
}

/// Whether a window that just rolled over is worth a "reset" notification. A
/// reset = the reset time advanced to a new, later boundary; we only ping if you
/// were actually constrained beforehand (≥ threshold), which keeps it from firing
/// every window regardless of usage. Returns false on first run (no prior reset).
func shouldNotifyReset(previousResetAt: Date?, newResetAt: Date?,
                       previousUtilization: Int, threshold: Int) -> Bool {
    guard let previousResetAt, let newResetAt else { return false }
    guard newResetAt > previousResetAt else { return false }
    return previousUtilization >= threshold
}

// MARK: - UsageService

final class UsageService: ObservableObject {
    static let shared = UsageService()

    @Published private(set) var currentUsage: UsageSnapshot = .placeholder
    @Published private(set) var error: String?
    @Published private(set) var isLoading: Bool = false
    /// True once a real usage snapshot has landed — so consumers (e.g. the session
    /// grade) can tell a fetched 0% from the initial placeholder.
    @Published private(set) var hasLoaded: Bool = false
    @Published private(set) var weeklySessions: Int = 0
    @Published private(set) var weeklyMessages: Int = 0
    @Published private(set) var weeklyTokens: Int = 0

    // Rolling 5-hour utilization samples (one per poll), used to estimate the
    // burn rate and run-out ETA. In-memory only — rebuilds after a restart.
    private var fiveHourSamples: [UsageSample] = []
    var fiveHourBurn: BurnEstimate? { estimateBurn(from: fiveHourSamples) }

    private var refreshTimer: Timer?
    // User-configurable poll cadence [#22], clamped to 1–30 min; re-read on each
    // (re)schedule so a settings change takes effect from the next cycle.
    private var normalInterval: TimeInterval {
        TimeInterval(clampedRefreshMinutes(SettingsManager.shared.settings.usageRefreshMinutes) * 60)
    }
    private let backoffInterval: TimeInterval = 15 * 60 // after a 429 with no Retry-After

    // Injectable for testing
    var urlSession: URLSession = .shared

    private init() {}

    /// Returns a valid bearer token from our own OAuth session, refreshing it
    /// first if it's near expiry. Throws if the user hasn't signed in (or the
    /// session expired), which surfaces as a "sign in" prompt in the UI.
    private func accessToken() async throws -> String {
        try await OAuthLoginService.shared.validAccessToken()
    }

    /// Drop the cached token so the next poll forces a refresh — used after a
    /// 401/403, where the token we sent was rotated or rejected.
    private func invalidateToken() {
        OAuthLoginService.shared.invalidateCache()
    }

    // Manual-refresh throttle. The OAuth usage endpoint rate-limits, so rapidly
    // tapping Refresh (e.g. to watch context fill) used to fire a request per tap
    // and trip a 429 → 15-min backoff. We let a manual refresh through at most once
    // every `minManualRefresh` seconds; auto-polling is unaffected.
    private var lastManualRefresh: Date?
    private let minManualRefresh: TimeInterval = 10

    /// Whether a manual refresh would be allowed right now (false if one ran within
    /// the throttle window).
    func canRefreshNow(_ now: Date = Date()) -> Bool {
        manualRefreshAllowed(last: lastManualRefresh, now: now, minInterval: minManualRefresh)
    }

    func startPolling() {
        fetchUsage()
        scheduleTimer(interval: normalInterval)
    }

    func stopPolling() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func scheduleTimer(interval: TimeInterval) {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.fetchUsage()
        }
    }

    /// Fetch current usage. `manual` marks a user-initiated Refresh, which is
    /// throttled to `minManualRefresh`; the returned Bool says whether the request
    /// was actually started (false = ignored as a too-soon repeat tap).
    @discardableResult
    func fetchUsage(manual: Bool = false) -> Bool {
        if manual {
            guard canRefreshNow() else { return false }
            lastManualRefresh = Date()
        }
        DispatchQueue.main.async { self.isLoading = true }

        Task {
            do {
                let token = try await accessToken()
                let response = try await fetchOAuthUsage(accessToken: token)

                let fiveHourUtil = Int(response.fiveHour?.utilization ?? 0)
                let sevenDayUtil = Int(response.sevenDay?.utilization ?? 0)
                let sonnetUtil: Int? = response.sevenDaySonnet.map { Int($0.utilization) }

                let fiveHourReset = response.fiveHour?.resetsAtDate
                let sevenDayReset = response.sevenDay?.resetsAtDate

                let snapshot = UsageSnapshot(
                    fiveHourUtilization: fiveHourUtil,
                    sevenDayUtilization: sevenDayUtil,
                    sevenDaySonnetUtilization: sonnetUtil,
                    fiveHourResetIn: fiveHourReset.map { formatTimeRemaining(until: $0) },
                    sevenDayResetIn: sevenDayReset.map { formatTimeRemaining(until: $0) },
                    fiveHourResetAt: fiveHourReset,
                    sevenDayResetAt: sevenDayReset,
                    lastUpdated: Date(),
                    weeklySessions: 0,
                    weeklyMessages: 0,
                    weeklyTokens: 0,
                    extraUsageEnabled: response.extraUsage?.isEnabled,
                    extraUsageUtilization: response.extraUsage?.utilization.map { Int($0) },
                    extraUsageUsedCents: response.extraUsage?.usedCredits,
                    extraUsageLimitCents: response.extraUsage?.monthlyLimit
                )

                await MainActor.run {
                    self.fiveHourSamples = appendingSample(
                        UsageSample(time: Date(), utilization: fiveHourUtil),
                        to: self.fiveHourSamples)
                    HistoryStore.shared.record(fiveHour: fiveHourUtil, sevenDay: sevenDayUtil, sonnet: sonnetUtil)
                    self.currentUsage = snapshot
                    self.hasLoaded = true
                    self.error = nil
                    self.isLoading = false
                    self.scheduleTimer(interval: self.normalInterval)
                }
            } catch let error as NSError {
                let isUsageHTTP = error.domain == "OAuthUsage"
                let isRateLimit = isUsageHTTP && error.code == 429
                // A 401/403 means the token we sent is stale or was rotated — the
                // cached copy is now useless, so drop it and re-read next poll.
                // (A 429 says nothing about the token, so it's left alone.)
                let isAuthError = isUsageHTTP && (error.code == 401 || error.code == 403)
                await MainActor.run {
                    if isAuthError { self.invalidateToken() }
                    let delay = isRateLimit
                        ? usageRetryDelay(retryAfter: error.userInfo["Retry-After"] as? String,
                                          fallback: self.backoffInterval)
                        : self.normalInterval
                    self.error = usageErrorMessage(for: error, retryAt: Date().addingTimeInterval(delay))
                    self.scheduleTimer(interval: delay)
                    self.isLoading = false
                }
            }
        }
        return true
    }

    func fetchOAuthUsage(accessToken: String) async throws -> OAuthUsageResponse {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        #if DEBUG
        print("[UsageService] GET /api/oauth/usage")
        #endif

        let (data, response) = try await urlSession.data(for: request)
        let body = String(data: data, encoding: .utf8) ?? "<binary>"

        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        // Response/error bodies are only logged in DEBUG builds — they contain
        // usage data (and, on errors, backend detail) that should not be written
        // to the unified log in a shipped build.
        #if DEBUG
        print("[UsageService] HTTP \(http.statusCode) — \(body.prefix(300))")
        #endif

        guard http.statusCode == 200 else {
            var info: [String: Any] = [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(body)"]
            if let retryAfter = http.value(forHTTPHeaderField: "Retry-After") {
                info["Retry-After"] = retryAfter
            }
            throw NSError(domain: "OAuthUsage", code: http.statusCode, userInfo: info)
        }

        return try JSONDecoder().decode(OAuthUsageResponse.self, from: data)
    }
}
