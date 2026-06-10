import Foundation

struct AppSettings: Codable {
    var warningThreshold: Double = 80.0
    var criticalThreshold: Double = 90.0
    var notificationsEnabled: Bool = true

    // Granular menu-bar element toggles. Defaults preserve the previous
    // "compact" behavior: two percentages + the 5h reset countdown.
    var showFiveHour: Bool = true
    var showSevenDay: Bool = true
    var showSonnet: Bool = false
    var showFiveHourReset: Bool = true
    var showSevenDayReset: Bool = false
    var showCreditBalance: Bool = false

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
        showFiveHour = try c.decodeIfPresent(Bool.self, forKey: .showFiveHour) ?? true
        showSevenDay = try c.decodeIfPresent(Bool.self, forKey: .showSevenDay) ?? true
        showSonnet = try c.decodeIfPresent(Bool.self, forKey: .showSonnet) ?? false
        showFiveHourReset = try c.decodeIfPresent(Bool.self, forKey: .showFiveHourReset) ?? true
        showSevenDayReset = try c.decodeIfPresent(Bool.self, forKey: .showSevenDayReset) ?? false
        showCreditBalance = try c.decodeIfPresent(Bool.self, forKey: .showCreditBalance) ?? false
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
    let creditBalance: String?
    let lastUpdated: Date
    let weeklySessions: Int
    let weeklyMessages: Int
    let weeklyTokens: Int

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
            creditBalance: nil,
            lastUpdated: Date(),
            weeklySessions: 0,
            weeklyMessages: 0,
            weeklyTokens: 0
        )
    }
}
