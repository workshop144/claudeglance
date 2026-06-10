import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var settingsManager: SettingsManager
    @ObservedObject var usageService: UsageService
    @Environment(\.dismiss) private var dismiss

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
            header

            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("Auth")
                authRow

                sectionHeader("Menu Bar")
                Toggle("Show 5h session %", isOn: $showFiveHour)
                    .onChange(of: showFiveHour) { settingsManager.setShowFiveHour($0) }
                Toggle("Show 7d weekly %", isOn: $showSevenDay)
                    .onChange(of: showSevenDay) { settingsManager.setShowSevenDay($0) }
                Toggle("Show Sonnet %", isOn: $showSonnet)
                    .onChange(of: showSonnet) { settingsManager.setShowSonnet($0) }
                Toggle("Show 5h reset countdown", isOn: $showFiveHourReset)
                    .onChange(of: showFiveHourReset) { settingsManager.setShowFiveHourReset($0) }
                Toggle("Show 7d reset countdown", isOn: $showSevenDayReset)
                    .onChange(of: showSevenDayReset) { settingsManager.setShowSevenDayReset($0) }
                Toggle("Show API credit balance", isOn: $showCreditBalance)
                    .onChange(of: showCreditBalance) { settingsManager.setShowCreditBalance($0) }

                sectionHeader("Notifications")
                Toggle("Enable usage alerts", isOn: $notificationsEnabled)
                    .onChange(of: notificationsEnabled) { settingsManager.setNotificationsEnabled($0) }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Warning threshold: \(Int(warningThreshold))%")
                    Slider(value: $warningThreshold, in: 50...95, step: 5)
                        .onChange(of: warningThreshold) { settingsManager.setWarningThreshold($0) }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Critical threshold: \(Int(criticalThreshold))%")
                    Slider(value: $criticalThreshold, in: 60...100, step: 5)
                        .onChange(of: criticalThreshold) { settingsManager.setCriticalThreshold($0) }
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)

            Spacer(minLength: 0)

            footer
        }
        .frame(width: 360, height: 420)
        .onAppear { loadSettings() }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundColor(.secondary)
            .padding(.top, 8)
    }

    private var authRow: some View {
        HStack {
            Image(systemName: "lock.fill")
                .foregroundColor(.green)
            Text("Using Claude Code OAuth token")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Text("Auto")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.2))
                .cornerRadius(4)
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "chart.pie.fill")
                .font(.title)
                .foregroundColor(.blue)
            Text("Claude Usage Settings")
                .font(.headline)
            Spacer()
            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var footer: some View {
        HStack {
            Text("Data from claude.ai OAuth")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Button("Reset to Defaults") { resetToDefaults() }
                .buttonStyle(.borderless)
                .foregroundColor(.red)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
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
