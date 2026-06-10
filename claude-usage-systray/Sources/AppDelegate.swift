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

    /// A read-only header row (e.g. "5hr: 12%"). Uses a custom view so the text is
    /// solid black and the row never gets the blue hover highlight (a standard
    /// disabled item dims to gray; a standard enabled item highlights).
    private func infoItem(title: String, symbol: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.isEnabled = false
        item.view = readonlyRowView(symbol: symbol, text: title, font: .menuFont(ofSize: 0))
        return item
    }

    /// A smaller, indented detail row (e.g. "Resets in: 2h 19m") — same black text,
    /// no highlight, aligned under the header title.
    private func secondaryItem(_ text: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.isEnabled = false
        item.view = readonlyRowView(symbol: nil, text: text, font: .systemFont(ofSize: 11))
        return item
    }

    /// Black, non-highlighting row (optional icon + label), sized to its content.
    private func readonlyRowView(symbol: String?, text: String, font: NSFont) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        var constraints = [
            container.heightAnchor.constraint(equalToConstant: 22),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            // Container hugs the label so the menu can size the row to its content.
            container.trailingAnchor.constraint(equalTo: label.trailingAnchor, constant: 14)
        ]

        if let symbol = symbol, let image = menuSymbol(symbol) {
            let icon = NSImageView(image: image)
            icon.contentTintColor = .secondaryLabelColor
            icon.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(icon)
            constraints += [
                icon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
                icon.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8)
            ]
        } else {
            // Align the label under where a header row's title starts (14 + 16 + 8).
            constraints.append(label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 38))
        }

        NSLayoutConstraint.activate(constraints)
        return container
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
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 560),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(
                rootView: SettingsView(settingsManager: settingsManager, usageService: usageService)
            )
            // "Settings" and a close "X" live in the title bar itself, beside the
            // traffic lights. The 38pt-tall accessories raise the title bar so the
            // lights center vertically. Content sits below — no scroll bleed.
            window.addTitlebarAccessoryViewController(settingsTitleAccessory())
            window.addTitlebarAccessoryViewController(settingsCloseAccessory(for: window))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func settingsTitleAccessory() -> NSTitlebarAccessoryViewController {
        let label = NSTextField(labelWithString: "Settings")
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.sizeToFit()
        let height: CGFloat = 38
        let container = NSView(frame: NSRect(x: 0, y: 0, width: label.frame.width + 12, height: height))
        label.setFrameOrigin(NSPoint(x: 6, y: (height - label.frame.height) / 2))
        container.addSubview(label)
        let vc = NSTitlebarAccessoryViewController()
        vc.view = container
        vc.layoutAttribute = .leading
        return vc
    }

    private func settingsCloseAccessory(for window: NSWindow) -> NSTitlebarAccessoryViewController {
        let image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        let button = NSButton(image: image ?? NSImage(), target: window,
                              action: #selector(NSWindow.performClose(_:)))
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.frame = NSRect(x: 0, y: 0, width: 22, height: 22)
        let height: CGFloat = 38
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: height))
        button.setFrameOrigin(NSPoint(x: 8, y: (height - 22) / 2))
        container.addSubview(button)
        let vc = NSTitlebarAccessoryViewController()
        vc.view = container
        vc.layoutAttribute = .trailing
        return vc
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
