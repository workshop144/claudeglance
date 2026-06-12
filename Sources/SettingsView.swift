import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var settingsManager: SettingsManager
    @ObservedObject var usageService: UsageService

    @State private var warningThreshold: Double = 80
    @State private var criticalThreshold: Double = 90
    @State private var notificationsEnabled: Bool = true
    @State private var resetNotificationsEnabled: Bool = true

    @State private var showRingIcon: Bool = false
    @State private var showFiveHour: Bool = true
    @State private var showSevenDay: Bool = true
    @State private var showSonnet: Bool = false
    @State private var showFiveHourReset: Bool = true
    @State private var showSevenDayReset: Bool = false
    @State private var showHealth: Bool = true
    @State private var showActivity: Bool = true
    @State private var showUsageCredits: Bool = true
    @State private var showContextWindow: Bool = false
    @State private var showSessionGrade: Bool = false

    @State private var launchAtLogin: Bool = false
    @State private var launchAtLoginError: String? = nil

    @State private var resetHovering = false
    @State private var versionHovering = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    authRow
                    rowDivider

                    // The binding's setter performs the register/unregister so
                    // there's no onChange observer to recurse when we re-sync the
                    // toggle to the real system status below.
                    toggleRow(icon: "power", title: "Launch at login",
                              description: "Start ClaudeGlance automatically when you log in.",
                              isOn: Binding(get: { launchAtLogin },
                                            set: { applyLaunchAtLogin($0) })) { _ in }
                    if let launchAtLoginError {
                        Text(launchAtLoginError)
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                            .padding(.leading, 38)
                            .padding(.bottom, 4)
                    }
                    rowDivider

                    toggleRow(icon: "circle.circle", title: "Show ring gauge",
                              description: "Show a dual-ring usage gauge (outer 5h, inner 7d) in the menu bar.",
                              isOn: $showRingIcon) { settingsManager.setShowRingIcon($0) }
                    toggleRow(icon: "clock", title: "Show 5h session %",
                              description: "Display 5-hour session usage in the menu bar.",
                              isOn: $showFiveHour) { settingsManager.setShowFiveHour($0) }
                    toggleRow(icon: "calendar", title: "Show 7d weekly %",
                              description: "Display 7-day weekly usage in the menu bar.",
                              isOn: $showSevenDay) { settingsManager.setShowSevenDay($0) }
                    toggleRow(icon: "cpu", title: "Show Sonnet %",
                              description: "Display Sonnet model usage in the menu bar.",
                              isOn: $showSonnet) { settingsManager.setShowSonnet($0) }
                    toggleRow(icon: "timer", title: "Show 5h reset countdown",
                              description: "Show time remaining until the 5-hour limit resets.",
                              isOn: $showFiveHourReset) { settingsManager.setShowFiveHourReset($0) }
                    toggleRow(icon: "timer", title: "Show 7d reset countdown",
                              description: "Show time remaining until the weekly limit resets.",
                              isOn: $showSevenDayReset) { settingsManager.setShowSevenDayReset($0) }
                    toggleRow(icon: "waveform.path.ecg", title: "Show service health",
                              description: "Show a colored Claude service-status dot in the menu bar.",
                              isOn: $showHealth) { settingsManager.setShowHealth($0) }
                    toggleRow(icon: "chart.line.uptrend.xyaxis", title: "Show today's activity",
                              description: "Show today's tokens, active time, and messages from local Claude Code logs.",
                              isOn: $showActivity) { settingsManager.setShowActivity($0) }
                    toggleRow(icon: "creditcard", title: "Show usage credits",
                              description: "Show whether usage credits are on, with a link to manage them.",
                              isOn: $showUsageCredits) { settingsManager.setShowUsageCredits($0) }
                    toggleRow(icon: "memorychip", title: "Show context window",
                              description: "Show how full your active Claude Code session's context window is (of 200K).",
                              isOn: $showContextWindow) { settingsManager.setShowContextWindow($0) }
                    toggleRow(icon: "checkmark.seal", title: "Show session grade",
                              description: "Show today's composite health grade (A–F) from cache efficiency, limit headroom, and context.",
                              isOn: $showSessionGrade) { settingsManager.setShowSessionGrade($0) }
                    rowDivider

                    toggleRow(icon: "bell", title: "Enable usage alerts",
                              description: "Notify you when usage crosses your thresholds.",
                              isOn: $notificationsEnabled) { settingsManager.setNotificationsEnabled($0) }
                    toggleRow(icon: "arrow.clockwise.circle", title: "Reset notifications",
                              description: "Notify you when a limit resets after you were near it.",
                              isOn: $resetNotificationsEnabled) { settingsManager.setResetNotificationsEnabled($0) }

                    sliderRow(icon: "exclamationmark.triangle", title: "Warning threshold",
                              description: "Warn at \(Int(warningThreshold))% of weekly usage.",
                              value: $warningThreshold) { settingsManager.setWarningThreshold($0) }
                    sliderRow(icon: "exclamationmark.octagon", title: "Critical threshold",
                              description: "Alert at \(Int(criticalThreshold))% of weekly usage.",
                              value: $criticalThreshold) { settingsManager.setCriticalThreshold($0) }

                    HStack {
                        Spacer()
                        Button(action: resetToDefaults) {
                            Text("Reset to Defaults")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(resetHovering ? .white : .primary)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(resetHovering ? Color.blue : Color(NSColor.controlBackgroundColor))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.gray.opacity(0.35), lineWidth: resetHovering ? 0 : 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .onHover { resetHovering = $0 }
                    }
                    .padding(.top, 28)
                    .padding(.bottom, 4)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }

            Divider()
            footer
        }
        .frame(width: 440, height: 560)
        .onAppear { loadSettings() }
    }

    // MARK: - Rows

    private var authRow: some View {
        HStack(spacing: 14) {
            rowIcon("lock.fill", color: .green)
            VStack(alignment: .leading, spacing: 2) {
                Text("Claude Code OAuth")
                    .font(.system(size: 13, weight: .medium))
                Text("Using your local Claude Code credentials.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text("Auto")
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.green.opacity(0.18))
                .clipShape(Capsule())
        }
        .padding(.vertical, 8)
    }

    private func toggleRow(icon: String, title: String, description: String,
                           isOn: Binding<Bool>, onChange: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: 14) {
            rowIcon(icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(description)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .onChange(of: isOn.wrappedValue) { onChange($0) }
        }
        .padding(.vertical, 8)
    }

    private func sliderRow(icon: String, title: String, description: String,
                           value: Binding<Double>, onChange: @escaping (Double) -> Void) -> some View {
        HStack(alignment: .top, spacing: 14) {
            rowIcon(icon)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(description)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Slider(value: value, in: 0...100, step: 5)
                    .onChange(of: value.wrappedValue) { onChange($0) }
                    .padding(.top, 2)
                // Labeled ticks every 20% so the thumb position reads cleanly.
                HStack(spacing: 0) {
                    ForEach(Array(stride(from: 0, through: 100, by: 20)), id: \.self) { n in
                        Text("\(n)")
                        if n != 100 { Spacer() }
                    }
                }
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 8)
    }

    private func rowIcon(_ name: String, color: Color = .secondary) -> some View {
        Image(systemName: name)
            .font(.system(size: 16))
            .foregroundColor(color)
            .frame(width: 24, alignment: .center)
    }

    private var rowDivider: some View {
        Divider().padding(.vertical, 4)
    }

    private var footer: some View {
        HStack {
            Text("Data from claude.ai OAuth")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
            // Small, unobtrusive build provenance so it's clear which build is
            // running while testing; links to the exact commit/branch on GitHub.
            // Darkens on hover (secondary → primary) to read as a link — the same
            // subtle affordance as the version signature in the menu footer.
            Link(destination: BuildInfo.current.url) {
                Text(BuildInfo.current.label)
                    .font(.system(size: 10))
                    .foregroundColor(versionHovering ? .primary : .secondary)
            }
            .buttonStyle(.plain)
            .onHover { versionHovering = $0 }
            .help(BuildInfo.current.helpText)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func loadSettings() {
        warningThreshold = settingsManager.settings.warningThreshold
        criticalThreshold = settingsManager.settings.criticalThreshold
        notificationsEnabled = settingsManager.settings.notificationsEnabled
        resetNotificationsEnabled = settingsManager.settings.resetNotificationsEnabled
        showRingIcon = settingsManager.settings.showRingIcon
        showFiveHour = settingsManager.settings.showFiveHour
        showSevenDay = settingsManager.settings.showSevenDay
        showSonnet = settingsManager.settings.showSonnet
        showFiveHourReset = settingsManager.settings.showFiveHourReset
        showSevenDayReset = settingsManager.settings.showSevenDayReset
        showHealth = settingsManager.settings.showHealth
        showActivity = settingsManager.settings.showActivity
        showUsageCredits = settingsManager.settings.showUsageCredits
        showContextWindow = settingsManager.settings.showContextWindow
        showSessionGrade = settingsManager.settings.showSessionGrade
        launchAtLogin = settingsManager.isLaunchAtLoginEnabled
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            try settingsManager.setLaunchAtLogin(enabled)
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = "Couldn't \(enabled ? "enable" : "disable") launch at login: \(error.localizedDescription)"
        }
        // Re-sync to the actual system state — on success this is a no-op; on
        // failure it snaps the toggle back to reality.
        launchAtLogin = settingsManager.isLaunchAtLoginEnabled
    }

    private func resetToDefaults() {
        settingsManager.resetToDefaults()
        loadSettings()
    }
}
