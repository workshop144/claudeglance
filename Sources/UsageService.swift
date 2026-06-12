import Foundation
import Security

// MARK: - OAuth Keychain

private struct KeychainCredentials: Decodable {
    let claudeAiOauth: OAuthData

    struct OAuthData: Decodable {
        let accessToken: String
        let expiresAt: Double
    }
}

/// The Claude Code OAuth credentials we actually use — the bearer token plus when
/// it expires, so the service can re-read a refreshed token before it goes stale.
struct OAuthToken {
    let accessToken: String
    let expiresAt: Date
}

/// Claude Code stores `expiresAt` as a Unix epoch. It writes milliseconds, but be
/// unit-safe: treat large values as ms and smaller ones as seconds, so a future
/// format change can't silently turn "expires in 8h" into "expired in 1970".
func parseOAuthExpiry(_ raw: Double) -> Date {
    let seconds = raw > 1_000_000_000_000 ? raw / 1000 : raw
    return Date(timeIntervalSince1970: seconds)
}

func readOAuthToken() throws -> OAuthToken {
    var result: AnyObject?
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "Claude Code-credentials",
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne
    ]
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let data = result as? Data else {
        throw NSError(domain: "Keychain", code: Int(status),
                      userInfo: [NSLocalizedDescriptionKey: "Claude Code credentials not found in Keychain. Make sure Claude Code is installed and logged in. (status: \(status))"])
    }
    let creds = try JSONDecoder().decode(KeychainCredentials.self, from: data)
    return OAuthToken(accessToken: creds.claudeAiOauth.accessToken,
                      expiresAt: parseOAuthExpiry(creds.claudeAiOauth.expiresAt))
}

func readOAuthAccessToken() throws -> String { try readOAuthToken().accessToken }

/// Pure throttle decision for a user-initiated refresh: allowed if none has run
/// yet, or the last one was at least `minInterval` ago.
func manualRefreshAllowed(last: Date?, now: Date, minInterval: TimeInterval) -> Bool {
    guard let last else { return true }
    return now.timeIntervalSince(last) >= minInterval
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
    @Published private(set) var weeklySessions: Int = 0
    @Published private(set) var weeklyMessages: Int = 0
    @Published private(set) var weeklyTokens: Int = 0

    // Rolling 5-hour utilization samples (one per poll), used to estimate the
    // burn rate and run-out ETA. In-memory only — rebuilds after a restart.
    private var fiveHourSamples: [UsageSample] = []
    var fiveHourBurn: BurnEstimate? { estimateBurn(from: fiveHourSamples) }

    private var refreshTimer: Timer?
    private let normalInterval: TimeInterval = 5 * 60   // 5 minutes
    private let backoffInterval: TimeInterval = 15 * 60 // 15 minutes after 429

    // Injectable for testing
    var urlSession: URLSession = .shared

    private var cachedToken: String?
    private var cachedTokenExpiresAt: Date?

    private init() {}

    /// Returns the bearer token, re-reading the Keychain when there's no cached
    /// token or the cached one is within a minute of expiry — so a token Claude
    /// Code has already refreshed is picked up before we send a dead one.
    private func accessToken() throws -> String {
        if let token = cachedToken, let exp = cachedTokenExpiresAt,
           exp.timeIntervalSinceNow > 60 {
            return token
        }
        let creds = try readOAuthToken()
        cachedToken = creds.accessToken
        cachedTokenExpiresAt = creds.expiresAt
        return creds.accessToken
    }

    /// Drop the cached token so the next poll re-reads (possibly refreshed)
    /// credentials from the Keychain.
    private func invalidateToken() {
        cachedToken = nil
        cachedTokenExpiresAt = nil
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
                let token = try accessToken()
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
                    self.error = nil
                    self.isLoading = false
                    self.scheduleTimer(interval: self.normalInterval)
                }
            } catch let error as NSError {
                let isRateLimit = error.code == 429
                // A 401/403 means the token we sent is stale or was rotated — the
                // cached copy is now useless, so drop it and re-read next poll.
                let isAuthError = error.code == 401 || error.code == 403
                await MainActor.run {
                    if isRateLimit {
                        // Clear token so next attempt re-reads a potentially refreshed token from Keychain
                        self.invalidateToken()
                        self.error = "Rate limited — retrying in 15 min"
                        self.scheduleTimer(interval: self.backoffInterval)
                    } else if isAuthError {
                        self.invalidateToken()
                        self.error = "Auth token expired — retrying (re-login to Claude Code if this persists)"
                        self.scheduleTimer(interval: self.normalInterval)
                    } else {
                        self.error = error.localizedDescription
                        self.scheduleTimer(interval: self.normalInterval)
                    }
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
            throw NSError(domain: "OAuthUsage", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(body)"])
        }

        return try JSONDecoder().decode(OAuthUsageResponse.self, from: data)
    }
}
