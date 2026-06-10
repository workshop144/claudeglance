import AppKit
import SwiftUI
import UserNotifications
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private let usageService = UsageService.shared
    private let settingsManager = SettingsManager.shared

    private var lastWarningNotified: Int = 0
    private var lastCriticalNotified: Int = 0

    // Keep Combine subscriptions alive
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupNotifications()
        startUsagePolling()

        // Observe usage changes to keep the menu bar numbers up to date
        usageService.$currentUsage
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusItemAppearance()
                self?.checkForNotifications()
            }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        usageService.stopPolling()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "chart.pie.fill", accessibilityDescription: "Claude Usage")
        }

        // A native NSMenu (like other menu-bar apps) drops down flush under the
        // status item. It's rebuilt on each open via menuNeedsUpdate so it always
        // reflects current usage. autoenablesItems = false lets the read-only info
        // rows render in normal (non-greyed) text.
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        updateStatusItemAppearance()
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let snapshot = usageService.currentUsage

        menu.addItem(infoItem(title: "5hr: \(snapshot.fiveHourUtilization)%",
                              symbol: usageSymbolName(for: snapshot.fiveHourUtilization)))
        if let resetIn = snapshot.fiveHourResetIn {
            menu.addItem(secondaryItem("Resets in: \(resetIn)"))
        }

        menu.addItem(infoItem(title: "Week: \(snapshot.sevenDayUtilization)%", symbol: "calendar"))
        if let resetIn = snapshot.sevenDayResetIn {
            menu.addItem(secondaryItem("Resets in: \(resetIn)"))
        }

        if let sonnet = snapshot.sevenDaySonnetUtilization {
            menu.addItem(infoItem(title: "Sonnet: \(sonnet)%", symbol: "cpu"))
        }

        if let error = usageService.error {
            menu.addItem(secondaryItem(error))
        }

        menu.addItem(.separator())

        menu.addItem(actionItem(title: "Open Dashboard", symbol: "chart.bar",
                                action: #selector(openDashboard)))
        menu.addItem(actionItem(title: "Refresh", symbol: "arrow.clockwise",
                                action: #selector(refreshUsage)))
        let settingsItem = actionItem(title: "Settings", symbol: "gear",
                                      action: #selector(openSettings))
        settingsItem.keyEquivalent = ","
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quit = actionItem(title: "Quit", symbol: "power", action: #selector(quitApp))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    /// A read-only header row (e.g. "5hr: 12%"). Disabled so it never highlights
    /// on hover; the explicit attributedTitle keeps the text full-color, since
    /// AppKit honors an attributedTitle's colors instead of dimming a disabled item.
    private func infoItem(title: String, symbol: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: NSColor.labelColor
        ])
        item.image = menuSymbol(symbol)
        item.isEnabled = false
        return item
    }

    /// A smaller, secondary-colored, indented detail row (e.g. "Resets in: 2h 19m").
    /// Also disabled so it doesn't highlight on hover.
    private func secondaryItem(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
        item.indentationLevel = 1
        item.isEnabled = false
        return item
    }

    private func actionItem(title: String, symbol: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = menuSymbol(symbol)
        item.isEnabled = true
        return item
    }

    private func menuSymbol(_ name: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    private func usageSymbolName(for usage: Int) -> String {
        if usage >= 80 { return "exclamationmark.triangle.fill" }
        if usage >= 50 { return "chart.pie.fill" }
        return "chart.pie"
    }

    private func setupNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                print("Notification authorization error: \(error)")
            }
        }
    }

    private func startUsagePolling() {
        if settingsManager.settings.isConfigured {
            usageService.startPolling()
        }
        
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.checkForNotifications()
        }
    }

    // MARK: - Menu actions

    @objc private func openDashboard() {
        if let url = URL(string: "https://console.anthropic.com/settings/usage") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func refreshUsage() {
        usageService.fetchUsage()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingController(
                rootView: SettingsView(settingsManager: settingsManager, usageService: usageService)
            )
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable]
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.title = "Claude Usage Settings"
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func settingsDidChange() {
        updateStatusItemAppearance()
    }

    private func updateStatusItemAppearance() {
        guard let button = statusItem.button else { return }

        let snapshot = usageService.currentUsage
        let settings = settingsManager.settings

        // Build the title from each enabled element in a fixed order:
        // 5h%, 7d%, sonnet%, 5h reset, 7d reset, credit balance.
        var segments: [String] = []

        if settings.showFiveHour {
            segments.append("\(snapshot.fiveHourUtilization)%")
        }
        if settings.showSevenDay {
            segments.append("\(snapshot.sevenDayUtilization)%")
        }
        if settings.showSonnet, let sonnet = snapshot.sevenDaySonnetUtilization {
            segments.append("\(sonnet)%")
        }
        if settings.showFiveHourReset, let resetAt = snapshot.fiveHourResetAt {
            segments.append(formatTimeRemainingCompact(until: resetAt))
        }
        if settings.showSevenDayReset, let resetAt = snapshot.sevenDayResetAt {
            segments.append(formatTimeRemainingCompact(until: resetAt))
        }
        if settings.showCreditBalance {
            segments.append(snapshot.creditBalance ?? "N/A")
        }

        // Nothing to show — fall back to a plain icon so the status item stays visible.
        guard !segments.isEmpty else {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            button.attributedTitle = NSAttributedString(string: "")
            button.image = NSImage(systemSymbolName: "chart.pie.fill", accessibilityDescription: "Claude Usage")?
                .withSymbolConfiguration(config)
            return
        }

        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        // All segments render white (.labelColor) in the menu bar, regardless of appearance.
        button.image = nil
        button.attributedTitle = NSAttributedString(
            string: segments.joined(separator: " · "),
            attributes: [.font: font, .foregroundColor: NSColor.labelColor]
        )
    }

    private func checkForNotifications() {
        guard settingsManager.settings.notificationsEnabled else { return }
        
        let usage = usageService.currentUsage.sevenDayUtilization
        let warningThreshold = Int(settingsManager.settings.warningThreshold)
        let criticalThreshold = Int(settingsManager.settings.criticalThreshold)

        if usage >= criticalThreshold && lastCriticalNotified < criticalThreshold {
            sendNotification(
                title: "Critical: Claude Usage",
                body: "You've used \(usage)% of your weekly quota. Consider pausing non-essential tasks.",
                isCritical: true
            )
            lastCriticalNotified = criticalThreshold
        } else if usage >= warningThreshold && lastWarningNotified < warningThreshold && usage < criticalThreshold {
            sendNotification(
                title: "Warning: Claude Usage",
                body: "You've used \(usage)% of your weekly quota.",
                isCritical: false
            )
            lastWarningNotified = warningThreshold
        }
    }

    private func sendNotification(title: String, body: String, isCritical: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = isCritical ? .defaultCritical : .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Notification error: \(error)")
            }
        }
    }
}
