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
    @ObservedObject var metrics: MetricsService

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
                        ActivityTabView(metrics: metrics)
                    case .cost:
                        CostTabView(metrics: metrics)
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

// MARK: - Cost tab

/// API-equivalent spend (tokens × model price) from the local Claude Code logs:
/// today / month-to-date / projection cards, a per-model breakdown, and a
/// daily-spend bar chart. All figures come from `MetricsService.metrics`.
struct CostTabView: View {
    @ObservedObject var metrics: MetricsService

    var body: some View {
        let m = metrics.metrics
        if m.monthCostUSD <= 0 {
            empty
        } else {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    statCard("Today", m.todayCostUSD)
                    statCard("Month to date", m.monthCostUSD)
                    statCard("Projected", monthlyProjection(monthCostUSD: m.monthCostUSD), faded: true)
                }
                if m.monthSavingsUSD >= 0.01 {
                    Text("Prompt caching saved \(usd(m.monthSavingsUSD)) this month")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }

                Divider()

                Text("By model · month to date").font(.system(size: 13, weight: .semibold))
                modelBreakdown(m.costByModel)

                Divider()

                Text("Daily spend · last 30 days").font(.system(size: 13, weight: .semibold))
                dailySpend(m.dailyCost)
            }
        }
    }

    // MARK: Pieces

    private func statCard(_ title: String, _ amount: Double, faded: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11)).foregroundColor(.secondary)
            Text(usd(amount)).font(.system(size: 24, weight: .semibold)).monospacedDigit()
                .opacity(faded ? 0.55 : 1)
            Text(faded ? "at current pace" : "API-equivalent")
                .font(.system(size: 10)).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
    }

    @ViewBuilder
    private func modelBreakdown(_ costByModel: [String: Double]) -> some View {
        let rows = costByModel.sorted { $0.value > $1.value }
        let total = rows.reduce(0) { $0 + $1.value }
        VStack(spacing: 8) {
            ForEach(rows, id: \.key) { name, cost in
                HStack(spacing: 10) {
                    Text(name).font(.system(size: 12)).frame(width: 90, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.12))
                            Capsule().fill(Color.blue.opacity(0.55))
                                .frame(width: max(2, geo.size.width * CGFloat(total > 0 ? cost / total : 0)))
                        }
                    }
                    .frame(height: 14)
                    Text(usd(cost)).font(.system(size: 12)).monospacedDigit()
                        .frame(width: 70, alignment: .trailing)
                }
            }
        }
    }

    @ViewBuilder
    private func dailySpend(_ dailyCost: [Date: Double]) -> some View {
        let points = dailyCost.sorted { $0.key < $1.key }
        if points.count >= 2 {
            Chart {
                ForEach(points, id: \.key) { day, cost in
                    BarMark(x: .value("Day", day, unit: .day), y: .value("USD", cost))
                        .foregroundStyle(Color.blue.opacity(0.6))
                }
            }
            .chartYAxis {
                AxisMarks(format: Decimal.FormatStyle.Currency(code: "USD").precision(.fractionLength(0)))
            }
            .frame(height: 200)
        } else {
            Text("Not enough daily history yet — spend appears here as logs accumulate.")
                .font(.system(size: 11)).foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Text("No spend recorded this month").font(.system(size: 14, weight: .semibold))
            Text("Cost is computed from your local Claude Code logs (tokens × model price). Use Claude Code and figures appear here.")
                .font(.system(size: 11)).foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
    }

    private func usd(_ amount: Double) -> String {
        formatDollars(cents: Int((amount * 100).rounded()))
    }
}

// MARK: - Activity tab

/// Coding activity from the local Claude Code logs: streak stat cards, a
/// GitHub-style contribution heatmap, and a daily-token bar chart. Fed by
/// `MetricsService.metrics.dailyTokens` (a rolling 30-day window).
struct ActivityTabView: View {
    @ObservedObject var metrics: MetricsService

    private let weeks = 5   // ~35 days, matching the 30-day metrics window

    var body: some View {
        let m = metrics.metrics
        let daily = m.dailyTokens
        if daily.allSatisfy({ $0.value == 0 }) {
            empty
        } else {
            let active = Set(daily.filter { $0.value > 0 }.keys)
            let today = Date()
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    statCard("Current streak", "\(currentStreak(activeDays: active, today: today))d")
                    statCard("Longest streak", "\(longestStreak(activeDays: active))d")
                    statCard("Active days", "\(active.count)", caption: "last 30 days")
                }

                Divider()

                Text("Contribution heatmap").font(.system(size: 13, weight: .semibold))
                heatmap(daily, endingAt: today)

                Divider()

                Text("Daily tokens · last 30 days").font(.system(size: 13, weight: .semibold))
                dailyTokensChart(daily)
            }
        }
    }

    // MARK: Pieces

    private func statCard(_ title: String, _ value: String, caption: String = " ") -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11)).foregroundColor(.secondary)
            Text(value).font(.system(size: 24, weight: .semibold)).monospacedDigit()
            Text(caption).font(.system(size: 10)).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
    }

    @ViewBuilder
    private func heatmap(_ daily: [Date: Int], endingAt: Date) -> some View {
        let grid = heatmapGrid(dailyTokens: daily, weeks: weeks, endingAt: endingAt)
        let maxTokens = grid.flatMap { $0 }.filter { !$0.isFuture }.map { $0.tokens }.max() ?? 0
        HStack(alignment: .top, spacing: 4) {
            // Weekday labels (Mon/Wed/Fri, GitHub-style — sparse to stay tidy).
            VStack(alignment: .leading, spacing: 4) {
                ForEach(0..<7, id: \.self) { row in
                    Text(["", "Mon", "", "Wed", "", "Fri", ""][row])
                        .font(.system(size: 8)).foregroundColor(.secondary)
                        .frame(height: 14, alignment: .center)
                }
            }
            .frame(width: 24)

            ForEach(Array(grid.enumerated()), id: \.offset) { _, week in
                VStack(spacing: 4) {
                    ForEach(Array(week.enumerated()), id: \.offset) { _, cell in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(cellColor(cell, maxTokens: maxTokens))
                            .frame(width: 14, height: 14)
                    }
                }
            }
        }
    }

    /// Green intensity bucket (GitHub-like): empty days a faint gray, busier days
    /// deeper green; future cells are invisible placeholders that keep the grid square.
    private func cellColor(_ cell: HeatCell, maxTokens: Int) -> Color {
        if cell.isFuture { return Color.clear }
        guard cell.tokens > 0, maxTokens > 0 else { return Color.secondary.opacity(0.12) }
        let frac = Double(cell.tokens) / Double(maxTokens)
        let level = min(4, 1 + Int(frac * 3.999))   // 1…4
        return Color.green.opacity([0.25, 0.45, 0.7, 0.95][level - 1])
    }

    @ViewBuilder
    private func dailyTokensChart(_ daily: [Date: Int]) -> some View {
        let points = daily.sorted { $0.key < $1.key }
        if points.count >= 2 {
            Chart {
                ForEach(points, id: \.key) { day, tokens in
                    BarMark(x: .value("Day", day, unit: .day), y: .value("Tokens", tokens))
                        .foregroundStyle(Color.green.opacity(0.6))
                }
            }
            .frame(height: 200)
        } else {
            Text("Not enough daily history yet — activity appears here as logs accumulate.")
                .font(.system(size: 11)).foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Text("No coding activity recorded").font(.system(size: 14, weight: .semibold))
            Text("Activity is read from your local Claude Code logs. Use Claude Code and your streaks and heatmap appear here.")
                .font(.system(size: 11)).foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
    }
}
