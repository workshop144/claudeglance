import SwiftUI
import Charts

/// The three sections of the dashboard window. Menu rows deep-link to one of
/// these, and `DashboardModel.selectedTab` drives the segmented switcher.
enum DashboardTab: String, CaseIterable, Identifiable {
    case activity = "Activity"
    case cost = "Cost"
    case usage = "Usage"
    var id: String { rawValue }
}

/// Shared state for the single reusable dashboard window — set `selectedTab` from
/// `AppDelegate.showDashboard(_:)` to deep-link to a tab.
final class DashboardModel: ObservableObject {
    @Published var selectedTab: DashboardTab = .activity
}

/// One tabbed window (same shell as Settings) surfacing the richer views of the
/// data we glance at in the menu.
struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    @ObservedObject var usage: UsageService
    @ObservedObject var history: HistoryStore

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $model.selectedTab) {
                ForEach(DashboardTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider()

            ScrollView {
                Group {
                    switch model.selectedTab {
                    case .activity:
                        placeholder("Activity", "Contribution heatmap, streaks & daily-token bars")
                    case .cost:
                        placeholder("Cost", "Today / month / projection, per-model breakdown & spend chart")
                    case .usage:
                        UsageTabView(usage: usage, history: history)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(24)
            }
        }
        .frame(minWidth: 560, minHeight: 460)
    }

    private func placeholder(_ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.system(size: 16, weight: .semibold))
            Text(subtitle).font(.system(size: 12)).foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Text("Coming in v1.4").font(.system(size: 11)).foregroundColor(.secondary).opacity(0.6)
                .padding(.top, 4)
        }
        .padding(.vertical, 64)
    }
}

// MARK: - Usage tab

/// Current 5h/7d/Sonnet state plus a monochrome line chart of the recorded
/// utilization history (from HistoryStore).
struct UsageTabView: View {
    @ObservedObject var usage: UsageService
    @ObservedObject var history: HistoryStore

    var body: some View {
        let snap = usage.currentUsage
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                statCard("Session · 5h", snap.fiveHourUtilization, snap.fiveHourResetIn)
                statCard("Weekly · 7d", snap.sevenDayUtilization, snap.sevenDayResetIn)
                if let sonnet = snap.sevenDaySonnetUtilization {
                    statCard("Sonnet · 7d", sonnet, nil)
                }
            }

            Divider()

            Text("Utilization history").font(.system(size: 13, weight: .semibold))
            if history.samples.count >= 2 {
                Chart {
                    ForEach(history.samples, id: \.t) { s in
                        LineMark(x: .value("Time", s.t), y: .value("%", s.h5))
                            .foregroundStyle(by: .value("Window", "5h"))
                    }
                    ForEach(history.samples, id: \.t) { s in
                        LineMark(x: .value("Time", s.t), y: .value("%", s.h7))
                            .foregroundStyle(by: .value("Window", "7d"))
                    }
                }
                .chartYScale(domain: 0...100)
                .chartForegroundStyleScale(["5h": Color.orange, "7d": Color.blue])
                .frame(height: 200)
            } else {
                collecting
            }
        }
    }

    private func statCard(_ title: String, _ pct: Int, _ resetIn: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11)).foregroundColor(.secondary)
            Text("\(pct)%").font(.system(size: 24, weight: .semibold)).monospacedDigit()
            Text(resetIn.map { "resets in \($0)" } ?? " ")
                .font(.system(size: 10)).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
    }

    private var collecting: some View {
        VStack(spacing: 6) {
            Text("Collecting usage history…").font(.system(size: 12)).foregroundColor(.secondary)
            Text("The chart fills in as ClaudeGlance records each poll (every ~5 min). History is kept for a week.")
                .font(.system(size: 11)).foregroundColor(.secondary).opacity(0.7)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
    }
}
