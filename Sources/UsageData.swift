import Foundation

struct AppSettings: Codable {
    var warningThreshold: Double = 80.0
    var criticalThreshold: Double = 90.0
    var notificationsEnabled: Bool = true

    // Dual-ring usage gauge in the menu bar (outer = 5h, inner = 7d). Off by
    // default so the clean text display stays the out-of-box look.
    var showRingIcon: Bool = false

    // Granular menu-bar element toggles. Defaults preserve the previous
    // "compact" behavior: two percentages + the 5h reset countdown.
    var showFiveHour: Bool = true
    var showSevenDay: Bool = true
    var showSonnet: Bool = false
    var showFiveHourReset: Bool = true
    var showSevenDayReset: Bool = false

    // Colored Claude service-health dot in the menu bar (status.claude.com).
    var showHealth: Bool = true

    // "Today" activity section in the menu, from local Claude Code logs.
    var showActivity: Bool = true

    // "Usage credits" on/off status row in the menu (extra_usage from OAuth).
    var showUsageCredits: Bool = true

    var isConfigured: Bool { true }

    init() {}

    // Custom decoding so older saved settings (which lacked these keys, or had
    // the removed `compactDisplay` key) migrate gracefully to the defaults
    // above instead of failing to decode and wiping all other settings.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        warningThreshold = try c.decodeIfPresent(Double.self, forKey: .warningThreshold) ?? 80.0
        criticalThreshold = try c.decodeIfPresent(Double.self, forKey: .criticalThreshold) ?? 90.0
        notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? true
        showRingIcon = try c.decodeIfPresent(Bool.self, forKey: .showRingIcon) ?? false
        showFiveHour = try c.decodeIfPresent(Bool.self, forKey: .showFiveHour) ?? true
        showSevenDay = try c.decodeIfPresent(Bool.self, forKey: .showSevenDay) ?? true
        showSonnet = try c.decodeIfPresent(Bool.self, forKey: .showSonnet) ?? false
        showFiveHourReset = try c.decodeIfPresent(Bool.self, forKey: .showFiveHourReset) ?? true
        showSevenDayReset = try c.decodeIfPresent(Bool.self, forKey: .showSevenDayReset) ?? false
        showHealth = try c.decodeIfPresent(Bool.self, forKey: .showHealth) ?? true
        showActivity = try c.decodeIfPresent(Bool.self, forKey: .showActivity) ?? true
        showUsageCredits = try c.decodeIfPresent(Bool.self, forKey: .showUsageCredits) ?? true
    }
}

struct UsageSnapshot {
    let fiveHourUtilization: Int
    let sevenDayUtilization: Int
    let sevenDaySonnetUtilization: Int?
    let fiveHourResetIn: String?
    let sevenDayResetIn: String?
    let fiveHourResetAt: Date?
    let sevenDayResetAt: Date?
    let lastUpdated: Date
    let weeklySessions: Int
    let weeklyMessages: Int
    let weeklyTokens: Int

    // "Usage credits" (extra_usage) state from the OAuth usage endpoint.
    // nil = the response carried no extra_usage object (state unknown → hide row).
    let extraUsageEnabled: Bool?
    // Percent of the monthly credit limit used, when enabled and reported.
    let extraUsageUtilization: Int?
    // Overage spend so far, and the monthly cap, in cents (when enabled/reported).
    let extraUsageUsedCents: Int?
    let extraUsageLimitCents: Int?

    var displayText: String { "\(sevenDayUtilization)%" }
    var menuBarPrimaryText: String { "5hr: \(fiveHourUtilization)%" }
    var menuBarSecondaryText: String { "Week: \(sevenDayUtilization)%" }

    static var placeholder: UsageSnapshot {
        UsageSnapshot(
            fiveHourUtilization: 0,
            sevenDayUtilization: 0,
            sevenDaySonnetUtilization: nil,
            fiveHourResetIn: nil,
            sevenDayResetIn: nil,
            fiveHourResetAt: nil,
            sevenDayResetAt: nil,
            lastUpdated: Date(),
            weeklySessions: 0,
            weeklyMessages: 0,
            weeklyTokens: 0,
            extraUsageEnabled: nil,
            extraUsageUtilization: nil,
            extraUsageUsedCents: nil,
            extraUsageLimitCents: nil
        )
    }
}
