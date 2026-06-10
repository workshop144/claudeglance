import Foundation
import ServiceManagement

final class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    @Published var settings: AppSettings {
        didSet { saveSettings() }
    }

    private let defaults = UserDefaults.standard
    private let settingsKey = "ClaudeUsageSettings"

    private init() {
        if let data = defaults.data(forKey: settingsKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        } else {
            settings = AppSettings()
        }
    }

    private func saveSettings() {
        if let encoded = try? JSONEncoder().encode(settings) {
            defaults.set(encoded, forKey: settingsKey)
        }
    }

    func setWarningThreshold(_ value: Double) { settings.warningThreshold = value }
    func setCriticalThreshold(_ value: Double) { settings.criticalThreshold = value }
    func setNotificationsEnabled(_ enabled: Bool) { settings.notificationsEnabled = enabled }
    func setShowFiveHour(_ enabled: Bool) { settings.showFiveHour = enabled }
    func setShowSevenDay(_ enabled: Bool) { settings.showSevenDay = enabled }
    func setShowSonnet(_ enabled: Bool) { settings.showSonnet = enabled }
    func setShowFiveHourReset(_ enabled: Bool) { settings.showFiveHourReset = enabled }
    func setShowSevenDayReset(_ enabled: Bool) { settings.showSevenDayReset = enabled }
    func setShowHealth(_ enabled: Bool) { settings.showHealth = enabled }
    func resetToDefaults() { settings = AppSettings() }

    // MARK: - Launch at login

    // Login-item state is owned by the system (SMAppService), not persisted in
    // AppSettings — so the toggle always reflects reality even if the user
    // changes it in System Settings › General › Login Items.
    var isLaunchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
