import SwiftUI

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
/// data we glance at in the menu. Tabs are placeholders in v1.4.0 — each fills in
/// with its charts in the following increments (Usage → Cost → Activity).
struct DashboardView: View {
    @ObservedObject var model: DashboardModel

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
                        placeholder("Usage", "5h / 7d / Sonnet utilization history & current state")
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
