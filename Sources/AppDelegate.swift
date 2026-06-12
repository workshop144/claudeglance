import AppKit
import SwiftUI
import UserNotifications
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var dashboardWindow: NSWindow?
    private let dashboardModel = DashboardModel()
    private let usageService = UsageService.shared
    private let statusService = StatusService.shared
    private let metricsService = MetricsService.shared
    private let contextService = ContextWindowService.shared
    private let settingsManager = SettingsManager.shared

    private var lastWarningNotified: Int = 0
    private var lastCriticalNotified: Int = 0

    // Previous window state, to detect a reset (reset time advanced) and how
    // constrained we were just before it. nil until the first snapshot arrives.
    private var lastFiveHourReset: Date?
    private var lastFiveHourUtil: Int = 0
    private var lastSevenDayReset: Date?
    private var lastSevenDayUtil: Int = 0

    // Keep Combine subscriptions alive
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Under XCTest the app is launched only as a test host. Skip all UI /
        // notification / polling bootstrap: the suite tests pure logic and the
        // network seam directly, and this setup aborts in a headless CI runner
        // (no window server / notification center) — "Early unexpected exit".
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }

        setupStatusItem()
        setupNotifications()
        startUsagePolling()

        // Observe usage changes to keep the menu bar numbers up to date
        usageService.$currentUsage
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusItemAppearance()
                self?.checkForNotifications()
                self?.checkForResets()
            }
            .store(in: &cancellables)

        // Refresh the menu-bar health dot whenever the service status changes.
        statusService.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItemAppearance() }
            .store(in: &cancellables)

        // The activity section is rebuilt on each menu open from the latest
        // metrics; no menu-bar refresh needed when they change.

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        usageService.stopPolling()
        statusService.stopPolling()
        metricsService.stopPolling()
        contextService.stopPolling()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "chart.pie.fill", accessibilityDescription: "ClaudeGlance")
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

        // Top "status" cluster: clickable rows with a colored dot that deep-link
        // out to the relevant page (status page / usage-credits settings).
        var addedStatusRow = false

        if settingsManager.settings.showHealth {
            let st = statusService.status
            menu.addItem(linkItem(title: st.description,
                                  dotColor: healthColor(for: st.indicator),
                                  action: #selector(openStatusPage)))
            addedStatusRow = true
        }

        // "Usage credits" on/off — read-only state from the OAuth usage endpoint
        // (Anthropic exposes no API to toggle it), so the row links to the
        // claude.ai setting where it's actually flipped. Hidden until the state
        // is known to avoid flashing a wrong color on first launch.
        if settingsManager.settings.showUsageCredits, let enabled = snapshot.extraUsageEnabled {
            menu.addItem(linkItem(title: "Usage credits: \(enabled ? "On" : "Off")",
                                  dotColor: enabled ? .systemGreen : .systemRed,
                                  action: #selector(openUsageCredits)))
            if enabled {
                // Prefer the dollar figure ("$1.20 / $50 (2%)") when the endpoint
                // reports it; fall back to the percentage-only line otherwise.
                if let used = snapshot.extraUsageUsedCents, let limit = snapshot.extraUsageLimitCents {
                    var line = "\(formatDollars(cents: used)) / \(formatDollars(cents: limit))"
                    if let util = snapshot.extraUsageUtilization { line += " (\(util)%)" }
                    menu.addItem(secondaryItem(line))
                } else if let util = snapshot.extraUsageUtilization {
                    menu.addItem(secondaryItem("\(util)% of credit limit used"))
                }
            }
            addedStatusRow = true
        }

        if addedStatusRow {
            menu.addItem(.separator())
        }

        // The OAuth usage rows deep-link to the dashboard's Usage tab (they dim
        // slightly and brighten on hover — no blue highlight).
        menu.addItem(linkInfoItem(title: "5hr: \(snapshot.fiveHourUtilization)%",
                                  symbol: usageSymbolName(for: snapshot.fiveHourUtilization), tab: .usage))
        if let resetIn = snapshot.fiveHourResetIn {
            menu.addItem(linkSecondaryItem("Resets in: \(resetIn)", tab: .usage))
        }
        // Burn rate / run-out ETA, once a few polls have established a trend.
        if let burn = usageService.fiveHourBurn, let secs = burn.secondsToLimit {
            let now = Date()
            if burn.hitsLimitBeforeReset(resetAt: snapshot.fiveHourResetAt, now: now) {
                menu.addItem(linkSecondaryItem("On pace for 100% by \(formatClockTime(now.addingTimeInterval(secs)))", tab: .usage))
            } else if burn.percentPerHour >= 1 {
                menu.addItem(linkSecondaryItem("Using ~\(Int(burn.percentPerHour.rounded()))%/hr", tab: .usage))
            }
        }
        // Recent 5h-usage trend from persisted history (survives restarts).
        let trend = HistoryStore.shared.fiveHourTrend()
        if trend.count >= 2 {
            menu.addItem(linkSecondaryItem("Trend: \(sparkline(trend, maxValue: 100))", tab: .usage))
        }

        menu.addItem(linkInfoItem(title: "Week: \(snapshot.sevenDayUtilization)%", symbol: "calendar", tab: .usage))
        if let resetIn = snapshot.sevenDayResetIn {
            menu.addItem(linkSecondaryItem("Resets in: \(resetIn)", tab: .usage))
        }

        if let sonnet = snapshot.sevenDaySonnetUtilization {
            menu.addItem(linkInfoItem(title: "Sonnet: \(sonnet)%", symbol: "cpu", tab: .usage))
        }

        // "Today" glance from the local Claude Code logs (no Keychain / network).
        // Deliberately slim — a calm one/two-line summary that deep-links into the
        // dashboard, which now holds the detail (token chart, per-model cost,
        // contribution heatmap, streak & spend history).
        if settingsManager.settings.showActivity {
            let m = metricsService.metrics
            if m.hasData {
                menu.addItem(.separator())

                let active = Set(m.dailyTokens.filter { $0.value > 0 }.keys)
                let streak = currentStreak(activeDays: active, today: Date())
                let streakSuffix = streak > 0 ? " · \(streak)d streak" : ""
                menu.addItem(linkInfoItem(title: "Today: \(formatTokenCount(m.todayTokens)) tokens\(streakSuffix)",
                                          symbol: "number", tab: .activity))

                if m.todayCostUSD > 0 {
                    let today = formatDollars(cents: Int((m.todayCostUSD * 100).rounded()))
                    let month = formatDollars(cents: Int((m.monthCostUSD * 100).rounded()))
                    menu.addItem(linkSecondaryItem("≈ \(today) today · \(month) this month", tab: .cost))
                }
            }
        }

        // Context-window glance for the session you're most likely in, from the
        // local logs. Off by default (opt-in) so the menu stays a quick glance.
        if settingsManager.settings.showContextWindow, let s = contextService.metrics.active {
            menu.addItem(.separator())
            let suffix = s.isHigh ? " · compact soon" : ""
            menu.addItem(linkInfoItem(title: "Context: \(s.utilization)%\(suffix)",
                                      symbol: "memorychip", tab: .context))
            menu.addItem(linkSecondaryItem("\(formatTokenCount(s.contextTokens)) of 200K · \(s.project)", tab: .context))
            // Prompt-cache freshness: warm means the next message hits a cheap cache
            // read; cold means it re-pays cache creation. (5-min TTL from the last turn.)
            if s.cacheActive {
                let now = Date()
                if s.isCacheWarm(now: now) {
                    menu.addItem(linkSecondaryItem("Cache warm · \(formatDuration(s.cacheFreshSeconds(now: now))) left", tab: .context))
                } else {
                    menu.addItem(linkSecondaryItem("Cache cold · next message re-caches", tab: .context))
                }
            }
        }

        // Today's composite health grade (opt-in). Deep-links to the Activity tab,
        // which shows the contributing factors.
        if settingsManager.settings.showSessionGrade, let grade = currentSessionGrade() {
            menu.addItem(.separator())
            menu.addItem(linkInfoItem(title: "Today's health: \(grade.letter)",
                                      symbol: "checkmark.seal", tab: .activity))
        }

        if let error = usageService.error {
            menu.addItem(secondaryItem(error))
        }

        // When the numbers are stale, say how old they are (the menu bar is also
        // dimmed). Only shown while stale, so it stays out of the way normally.
        if isStale(lastUpdated: snapshot.lastUpdated) {
            menu.addItem(secondaryItem("Updated \(minutesAgo(snapshot.lastUpdated))m ago"))
        }

        menu.addItem(.separator())

        menu.addItem(actionItem(title: "Dashboard", symbol: "chart.bar",
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

        menu.addItem(.separator())
        menu.addItem(versionItem())
    }

    /// A smaller, indented detail row (e.g. "Resets in: 2h 19m") — same black text,
    /// no highlight, aligned under the header title.
    private func secondaryItem(_ text: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.isEnabled = false
        item.view = readonlyRowView(symbol: nil, text: text, font: .systemFont(ofSize: 11))
        return item
    }

    // MARK: - Deep-link rows (open a dashboard tab)

    /// A non-highlighting deep-link row: full-black label at rest, **bolded** on
    /// hover (plus a pointer cursor) so the affordance reads as a link without a
    /// blue highlight or any color. Builds its own icon + label so it can hold the
    /// label reference and swap its font weight on enter/exit.
    private final class LinkRowView: NSView {
        var onClick: (() -> Void)?
        private let label: NSTextField
        private let baseFont: NSFont
        private let boldFont: NSFont
        private var tracking: NSTrackingArea?

        init(image: NSImage?, text: String, font: NSFont, symbolColor: NSColor) {
            self.baseFont = font
            self.boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            self.label = NSTextField(labelWithString: text)
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false

            label.font = baseFont
            label.textColor = .labelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)

            var constraints = [
                heightAnchor.constraint(equalToConstant: 22),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
                trailingAnchor.constraint(equalTo: label.trailingAnchor, constant: 14)
            ]

            if let image {
                let icon = NSImageView(image: image)
                icon.contentTintColor = symbolColor
                icon.translatesAutoresizingMaskIntoConstraints = false
                addSubview(icon)
                constraints += [
                    icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
                    icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                    icon.widthAnchor.constraint(equalToConstant: 16),
                    label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8)
                ]
            } else {
                // Align the label under where a header row's title starts (14 + 16 + 8).
                constraints.append(label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 38))
            }
            NSLayoutConstraint.activate(constraints)
        }
        required init?(coder: NSCoder) { fatalError() }

        // Route clicks anywhere in the row to this view, not the inner label.
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(convert(point, from: superview)) ? self : nil
        }
        override func mouseUp(with event: NSEvent) { onClick?() }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let t = NSTrackingArea(rect: bounds,
                                   options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                   owner: self)
            addTrackingArea(t); tracking = t
        }
        override func mouseEntered(with event: NSEvent) { label.font = boldFont }
        override func mouseExited(with event: NSEvent) { label.font = baseFont }
    }

    private func linkItem(symbol: String?, title: String, font: NSFont, tab: DashboardTab) -> NSMenuItem {
        let item = NSMenuItem()
        item.isEnabled = true
        let row = LinkRowView(image: symbol.flatMap { menuSymbol($0) },
                              text: title, font: font, symbolColor: .secondaryLabelColor)
        row.onClick = { [weak self] in self?.showDashboard(tab) }
        item.view = row
        return item
    }

    /// Header-weight deep-link row (e.g. "5hr: 12%").
    private func linkInfoItem(title: String, symbol: String, tab: DashboardTab) -> NSMenuItem {
        linkItem(symbol: symbol, title: title, font: .menuFont(ofSize: 0), tab: tab)
    }

    /// Detail-weight deep-link row (e.g. "Resets in: 2h 19m").
    private func linkSecondaryItem(_ text: String, tab: DashboardTab) -> NSMenuItem {
        linkItem(symbol: nil, title: text, font: .systemFont(ofSize: 11), tab: tab)
    }

    /// A clickable menu-row view that opens a URL without the standard blue menu
    /// highlight — just a pointer cursor on hover, so the version signature reads
    /// like the link in the Settings footer rather than a normal menu command.
    /// On hover it darkens `hoverLabel` from `restColor` to `hoverColor` — the same
    /// subtle "this is a link" affordance the deep-link rows get (here a darken
    /// rather than a bold, since the footer text is intentionally tiny and washed).
    private final class ClickableMenuRowView: NSView {
        var onClick: (() -> Void)?
        weak var hoverLabel: NSTextField?
        var restColor: NSColor = .tertiaryLabelColor
        var hoverColor: NSColor = .secondaryLabelColor
        private var tracking: NSTrackingArea?

        // Route every click in the row to this view (not the inner label).
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(convert(point, from: superview)) ? self : nil
        }
        override func mouseUp(with event: NSEvent) { onClick?() }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let t = NSTrackingArea(rect: bounds,
                                   options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                   owner: self)
            addTrackingArea(t); tracking = t
        }
        override func mouseEntered(with event: NSEvent) { hoverLabel?.textColor = hoverColor }
        override func mouseExited(with event: NSEvent) { hoverLabel?.textColor = restColor }
    }

    /// A tiny, washed-out version signature for the foot of the menu —
    /// right-aligned, just `v1.1.1`, clickable to the running build on GitHub
    /// (the full branch@commit provenance lives in the Settings window footer).
    private func versionItem() -> NSMenuItem {
        let item = NSMenuItem()
        item.isEnabled = true

        let container = ClickableMenuRowView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.onClick = { [weak container] in
            NSWorkspace.shared.open(BuildInfo.current.url)
            container?.enclosingMenuItem?.menu?.cancelTracking()
        }

        let info = BuildInfo.current
        let label = NSTextField(labelWithString: "v\(info.version) (\(info.channel))")
        label.font = .systemFont(ofSize: 9)
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        // Darken the signature on hover (tertiary → secondary) so it reads as the
        // link it is, matching the deep-link rows' bold-on-hover affordance.
        container.hoverLabel = label

        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 20),
            // The menu stretches this view to its full width; pinning the label to
            // the trailing edge right-aligns it. The min-width keeps it sane if it
            // were ever the widest row (it won't be).
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14)
        ])

        item.view = container
        return item
    }

    /// Black, non-highlighting row (optional icon + label), sized to its content.
    private func readonlyRowView(symbol: String?, text: String, font: NSFont, symbolColor: NSColor = .secondaryLabelColor) -> NSView {
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
            icon.contentTintColor = symbolColor
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

    /// A clickable status row with a colored dot (service health, usage credits).
    /// Unlike `infoItem`, this is a standard enabled item so it gets the native
    /// blue hover highlight; the dot is a non-template image so it keeps its color.
    private func linkItem(title: String, dotColor: NSColor, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = coloredDot(dotColor)
        item.isEnabled = true
        return item
    }

    /// A filled circle baked into a non-template image so the menu renders it in
    /// the given color rather than tinting it like a template symbol.
    private func coloredDot(_ color: NSColor, diameter: CGFloat = 10) -> NSImage {
        let image = NSImage(size: NSSize(width: diameter + 2, height: diameter + 2))
        image.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: diameter, height: diameter)).fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
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
            #if DEBUG
            if let error = error {
                print("Notification authorization error: \(error)")
            }
            #endif
        }
    }

    private func startUsagePolling() {
        if settingsManager.settings.isConfigured {
            usageService.startPolling()
        }
        statusService.startPolling()
        metricsService.startPolling()
        contextService.startPolling()

        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.checkForNotifications()
            // Re-evaluate staleness even when no new data has arrived, so the
            // menu bar dims once refreshes stop landing.
            self?.updateStatusItemAppearance()
        }
    }

    // MARK: - Menu actions

    @objc private func openDashboard() {
        showDashboard(.activity)
    }

    /// Open (or focus) the single dashboard window on a specific tab — the
    /// deep-link entry point menu rows call.
    func showDashboard(_ tab: DashboardTab) {
        dashboardModel.selectedTab = tab
        if dashboardWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(
                rootView: DashboardView(model: dashboardModel, usage: usageService,
                                        history: HistoryStore.shared, metrics: metricsService,
                                        context: contextService))
            window.addTitlebarAccessoryViewController(titleAccessory("Dashboard"))
            window.addTitlebarAccessoryViewController(closeAccessory(for: window))
            window.setFrameAutosaveName("ClaudeGlanceDashboard")
            window.center()
            dashboardWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        dashboardWindow?.makeKeyAndOrderFront(nil)
    }

    /// Today's session grade from the signals we currently have — cache efficiency
    /// (local), 5h limit headroom (OAuth, once loaded), and active-session context
    /// headroom (local). nil when none are available yet.
    private func currentSessionGrade() -> SessionGrade? {
        let m = metricsService.metrics
        return gradeSession(
            cachePercent: m.hasData ? m.todayCachePercent : nil,
            limitUtilization: usageService.hasLoaded ? usageService.currentUsage.fiveHourUtilization : nil,
            contextUtilization: contextService.metrics.active?.utilization
        )
    }

    @objc private func refreshUsage() {
        // Manual refresh is throttled in the service so rapid taps can't trip the
        // usage endpoint's rate limit; a too-soon tap is simply ignored.
        usageService.fetchUsage(manual: true)
    }

    @objc private func openStatusPage() {
        if let url = URL(string: "https://status.claude.com") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openUsageCredits() {
        if let url = URL(string: "https://claude.ai/settings/usage") {
            NSWorkspace.shared.open(url)
        }
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
            window.addTitlebarAccessoryViewController(titleAccessory("Settings"))
            window.addTitlebarAccessoryViewController(closeAccessory(for: window))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func titleAccessory(_ title: String) -> NSTitlebarAccessoryViewController {
        let label = NSTextField(labelWithString: title)
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

    private func closeAccessory(for window: NSWindow) -> NSTitlebarAccessoryViewController {
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

        // Dim the entire status item (ring, text, and health dot) when the data
        // is stale, so old numbers never read as current. Applies to every render
        // path below; re-evaluated by the 60s tick even when no new data arrives.
        button.appearsDisabled = isStale(lastUpdated: snapshot.lastUpdated)

        // Build the title from each enabled element in a fixed order:
        // 5h%, 7d%, sonnet%, 5h reset, 7d reset.
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

        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)

        // Usage segments render in the neutral label color; the optional health
        // dot is the one colored element (its color carries the information).
        let title = NSMutableAttributedString()
        if !segments.isEmpty {
            title.append(NSAttributedString(
                string: segments.joined(separator: " · "),
                attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
        }
        if settings.showHealth {
            let prefix = title.length > 0 ? " " : ""
            title.append(NSAttributedString(
                string: "\(prefix)\u{25CF}",
                attributes: [.font: font, .foregroundColor: healthColor(for: statusService.status.indicator)]))
        }

        // Pace marker position: how far through the 5-hour window we are.
        let pace = snapshot.fiveHourResetAt.map {
            elapsedFraction(resetAt: $0, windowLength: 5 * 60 * 60)
        }
        let ringImage: NSImage? = settings.showRingIcon
            ? menuBarRingImage(fiveHourPercent: snapshot.fiveHourUtilization,
                               sevenDayPercent: snapshot.sevenDayUtilization,
                               fiveHourPaceFraction: pace)
            : nil

        // With the ring enabled it leads the title — or stands alone if every
        // text element (and the health dot) is turned off.
        if let ringImage {
            button.image = ringImage
            button.imagePosition = title.length > 0 ? .imageLeading : .imageOnly
            button.attributedTitle = title
            return
        }

        // No ring: fall back to a plain icon only when there's also no text.
        guard title.length > 0 else {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
            button.image = NSImage(systemSymbolName: "chart.pie.fill", accessibilityDescription: "ClaudeGlance")?
                .withSymbolConfiguration(config)
            return
        }

        button.image = nil
        button.attributedTitle = title
    }

    /// Maps a Statuspage indicator to the menu-bar / menu dot color.
    private func healthColor(for indicator: ServiceStatusIndicator) -> NSColor {
        switch indicator {
        case .none:        return .systemGreen
        case .minor:       return .systemYellow
        case .major:       return .systemOrange
        case .critical:    return .systemRed
        case .maintenance: return .systemBlue
        case .unknown:     return .systemGray
        }
    }

    /// Fire a one-shot "reset" notification when a 5h/7d window rolls over after
    /// we were near its limit. Comparison/dedup lives in `shouldNotifyReset`; we
    /// always update the stored previous-state so each boundary pings at most once.
    private func checkForResets() {
        let snapshot = usageService.currentUsage
        let threshold = Int(settingsManager.settings.warningThreshold)
        let enabled = settingsManager.settings.resetNotificationsEnabled

        if enabled, shouldNotifyReset(previousResetAt: lastFiveHourReset,
                                      newResetAt: snapshot.fiveHourResetAt,
                                      previousUtilization: lastFiveHourUtil,
                                      threshold: threshold) {
            sendNotification(title: "5-hour session reset",
                             body: "Your session limit just reset — full quota available again.",
                             isCritical: false)
        }
        lastFiveHourReset = snapshot.fiveHourResetAt
        lastFiveHourUtil = snapshot.fiveHourUtilization

        if enabled, shouldNotifyReset(previousResetAt: lastSevenDayReset,
                                      newResetAt: snapshot.sevenDayResetAt,
                                      previousUtilization: lastSevenDayUtil,
                                      threshold: threshold) {
            sendNotification(title: "Weekly limit reset",
                             body: "Your weekly limit just reset — full quota available again.",
                             isCritical: false)
        }
        lastSevenDayReset = snapshot.sevenDayResetAt
        lastSevenDayUtil = snapshot.sevenDayUtilization
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
            #if DEBUG
            if let error = error {
                print("Notification error: \(error)")
            }
            #endif
        }
    }
}
