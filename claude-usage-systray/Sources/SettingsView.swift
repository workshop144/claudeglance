import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var settingsManager: SettingsManager
    @ObservedObject var usageService: UsageService

    /// Closes the hosting window. Set by AppDelegate when the window is created.
    var onClose: () -> Void = {}

    @State private var warningThreshold: Double = 80
    @State private var criticalThreshold: Double = 90
    @State private var notificationsEnabled: Bool = true

    @State private var showFiveHour: Bool = true
    @State private var showSevenDay: Bool = true
    @State private var showSonnet: Bool = false
    @State private var showFiveHourReset: Bool = true
    @State private var showSevenDayReset: Bool = false
    @State private var showCreditBalance: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    authRow
                    rowDivider

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
                    toggleRow(icon: "dollarsign.circle", title: "Show API credit balance",
                              description: "Show your remaining API credit balance.",
                              isOn: $showCreditBalance) { settingsManager.setShowCreditBalance($0) }
                    rowDivider

                    toggleRow(icon: "bell", title: "Enable usage alerts",
                              description: "Notify you when usage crosses your thresholds.",
                              isOn: $notificationsEnabled) { settingsManager.setNotificationsEnabled($0) }

                    sliderRow(icon: "exclamationmark.triangle", title: "Warning threshold",
                              description: "Warn at \(Int(warningThreshold))% of weekly usage.",
                              value: $warningThreshold, range: 50...95) {
                        settingsManager.setWarningThreshold($0)
                    }
                    sliderRow(icon: "exclamationmark.octagon", title: "Critical threshold",
                              description: "Alert at \(Int(criticalThreshold))% of weekly usage.",
                              value: $criticalThreshold, range: 60...100) {
                        settingsManager.setCriticalThreshold($0)
                    }
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

    // MARK: - Title bar

    private var titleBar: some View {
        HStack {
            Text("Settings")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        // Leading inset clears the window's traffic-light controls.
        .padding(.leading, 78)
        .padding(.trailing, 18)
        .frame(height: 48)
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
                .labelsHidden()
                .onChange(of: isOn.wrappedValue) { onChange($0) }
        }
        .padding(.vertical, 8)
    }

    private func sliderRow(icon: String, title: String, description: String,
                           value: Binding<Double>, range: ClosedRange<Double>,
                           onChange: @escaping (Double) -> Void) -> some View {
        HStack(alignment: .top, spacing: 14) {
            rowIcon(icon)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(description)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Slider(value: value, in: range, step: 5)
                    .onChange(of: value.wrappedValue) { onChange($0) }
                    .padding(.top, 2)
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
            Button("Reset to Defaults") { resetToDefaults() }
                .buttonStyle(.link)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func loadSettings() {
        warningThreshold = settingsManager.settings.warningThreshold
        criticalThreshold = settingsManager.settings.criticalThreshold
        notificationsEnabled = settingsManager.settings.notificationsEnabled
        showFiveHour = settingsManager.settings.showFiveHour
        showSevenDay = settingsManager.settings.showSevenDay
        showSonnet = settingsManager.settings.showSonnet
        showFiveHourReset = settingsManager.settings.showFiveHourReset
        showSevenDayReset = settingsManager.settings.showSevenDayReset
        showCreditBalance = settingsManager.settings.showCreditBalance
    }

    private func resetToDefaults() {
        settingsManager.resetToDefaults()
        loadSettings()
    }
}
