import SwiftUI
import Charts

/// The three sections of the dashboard window. Menu rows deep-link to one of
/// these, and `DashboardModel.selectedTab` drives the segmented switcher.
enum DashboardTab: String, CaseIterable, Identifiable {
    case activity = "Activity"
    case cost = "Cost"
    case tokens = "Tokens"
    case context = "Context"
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
    @ObservedObject var context: ContextWindowService

    /// Today's grade, recomputed from the three live services for the Activity tab.
    private var sessionGrade: SessionGrade? {
        gradeSession(
            cachePercent: metrics.metrics.hasData ? metrics.metrics.todayCachePercent : nil,
            limitUtilization: usage.hasLoaded ? usage.currentUsage.fiveHourUtilization : nil,
            contextUtilization: context.metrics.active?.utilization)
    }

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
                        ActivityTabView(metrics: metrics, grade: sessionGrade)
                    case .cost:
                        CostTabView(metrics: metrics)
                    case .tokens:
                        TokensTabView(metrics: metrics)
                    case .context:
                        ContextTabView(context: context)
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

// MARK: - Tokens tab

/// "Where your tokens go" [#17] + top tools / MCP breakdown [#18], month to date.
/// Composition reveals how much of your volume is cheap cache reads (0.1×) vs the
/// 1.25× cache writes and full-price input; the tool list shows what's driving it.
/// Fed by `MetricsService.metrics` (token splits) and `.tools` (tool_use counts).
struct TokensTabView: View {
    @ObservedObject var metrics: MetricsService

    // Token-type display: label, value selector, color, and a billing note.
    private struct TokenType { let label: String; let value: Int; let color: Color; let note: String }

    var body: some View {
        let m = metrics.metrics
        let tools = metrics.tools
        if m.monthTotalTokens == 0 && !tools.hasData {
            empty
        } else {
            VStack(alignment: .leading, spacing: 20) {
                Text("Where your tokens go · month to date").font(.system(size: 13, weight: .semibold))
                composition(m)

                Divider()

                Text("Top tools · month to date").font(.system(size: 13, weight: .semibold))
                if tools.hasData {
                    breakdown(tools.toolCounts, total: tools.totalCalls, tint: .blue, unit: "calls")
                } else {
                    Text("No tool calls recorded yet.").font(.system(size: 11)).foregroundColor(.secondary)
                }

                if !tools.mcpServerCounts.isEmpty {
                    Divider()
                    Text("MCP servers · month to date").font(.system(size: 13, weight: .semibold))
                    breakdown(tools.mcpServerCounts, total: tools.totalCalls, tint: .purple, unit: "calls")
                }
            }
        }
    }

    // MARK: Pieces

    @ViewBuilder
    private func composition(_ m: UsageMetrics) -> some View {
        let types = [
            TokenType(label: "Cache read",  value: m.monthCacheReadTokens,     color: .green,  note: "0.1× — cheap"),
            TokenType(label: "Cache write", value: m.monthCacheCreationTokens, color: .orange, note: "1.25×"),
            TokenType(label: "Input",       value: m.monthInputTokens,         color: .blue,   note: "1×"),
            TokenType(label: "Output",      value: m.monthOutputTokens,        color: .purple, note: "billed at output rate"),
        ].sorted { $0.value > $1.value }
        let total = max(1, m.monthTotalTokens)

        VStack(spacing: 10) {
            // One stacked bar of the whole month's volume.
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(types, id: \.label) { t in
                        Rectangle().fill(t.color.opacity(0.75))
                            .frame(width: geo.size.width * CGFloat(t.value) / CGFloat(total))
                    }
                }
            }
            .frame(height: 14)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            ForEach(types, id: \.label) { t in
                HStack(spacing: 10) {
                    Circle().fill(t.color.opacity(0.75)).frame(width: 9, height: 9)
                    Text(t.label).font(.system(size: 12)).frame(width: 90, alignment: .leading)
                    Text(t.note).font(.system(size: 10)).foregroundColor(.secondary)
                    Spacer()
                    Text("\(formatTokenCount(t.value)) · \(pct(t.value, total))%")
                        .font(.system(size: 12)).monospacedDigit().foregroundColor(.secondary)
                }
            }
        }
    }

    /// Sorted horizontal-bar list (tools or MCP servers), top 8 by count.
    @ViewBuilder
    private func breakdown(_ counts: [String: Int], total: Int, tint: Color, unit: String) -> some View {
        let rows = counts.sorted { $0.value > $1.value }.prefix(8)
        let maxCount = rows.map(\.value).max() ?? 1
        VStack(spacing: 8) {
            ForEach(Array(rows), id: \.key) { name, count in
                HStack(spacing: 10) {
                    Text(name).font(.system(size: 12)).lineLimit(1).frame(width: 120, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.12))
                            Capsule().fill(tint.opacity(0.55))
                                .frame(width: max(2, geo.size.width * CGFloat(count) / CGFloat(maxCount)))
                        }
                    }
                    .frame(height: 14)
                    Text("\(count)").font(.system(size: 12)).monospacedDigit().frame(width: 48, alignment: .trailing)
                }
            }
        }
    }

    private func pct(_ value: Int, _ total: Int) -> Int {
        total > 0 ? Int((Double(value) / Double(total) * 100).rounded()) : 0
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Text("No token activity this month").font(.system(size: 14, weight: .semibold))
            Text("Token composition and tool usage are read from your local Claude Code logs. Use Claude Code and the breakdown appears here.")
                .font(.system(size: 11)).foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
    }
}

// MARK: - Activity tab

/// Coding activity from the local Claude Code logs: streak stat cards, a
/// GitHub-style contribution heatmap, and a daily-token bar chart. Fed by
/// `MetricsService.metrics.dailyTokens` (a rolling 30-day window).
struct ActivityTabView: View {
    @ObservedObject var metrics: MetricsService
    /// Today's composite health grade [#16], computed by the dashboard. nil → hidden.
    var grade: SessionGrade? = nil

    private let weeks = 5   // ~35 days, matching the 30-day metrics window

    var body: some View {
        let m = metrics.metrics
        let daily = m.dailyTokens
        let hasActivity = !daily.allSatisfy { $0.value == 0 }
        let active = Set(daily.filter { $0.value > 0 }.keys)
        let today = Date()

        VStack(alignment: .leading, spacing: 20) {
            if let grade {
                gradeCard(grade)
                if hasActivity { Divider() }
            }

            if hasActivity {
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

                Divider()

                HStack {
                    Spacer()
                    shareWrappedButton
                }
            } else if grade == nil {
                empty
            }
        }
    }

    /// Opens the shareable Wrapped card [#26] via a notification AppDelegate observes.
    private var shareWrappedButton: some View {
        Button {
            NotificationCenter.default.post(name: .claudeGlanceShareWrapped, object: nil)
        } label: {
            Label("Share Wrapped", systemImage: "sparkles")
                .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(.borderless)
        .help("Generate a shareable image of this month's highlights")
    }

    // MARK: Pieces

    /// "Today" grade: a large letter colored by health, plus the transparent
    /// factor breakdown so the grade is explainable.
    private func gradeCard(_ grade: SessionGrade) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 2) {
                Text(grade.letter).font(.system(size: 40, weight: .bold)).monospacedDigit()
                    .foregroundColor(gradeColor(grade.score))
                Text("Today").font(.system(size: 11)).foregroundColor(.secondary)
            }
            .frame(width: 86)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(grade.factors, id: \.label) { f in
                    HStack(spacing: 10) {
                        Text(f.label).font(.system(size: 11)).frame(width: 110, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.secondary.opacity(0.12))
                                Capsule().fill(gradeColor(f.score).opacity(0.6))
                                    .frame(width: max(2, geo.size.width * CGFloat(f.score) / 100))
                            }
                        }
                        .frame(height: 8)
                        Text(f.detail).font(.system(size: 10)).foregroundColor(.secondary)
                            .frame(width: 150, alignment: .leading)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
    }

    private func gradeColor(_ score: Int) -> Color {
        switch score {
        case 90...: return .green
        case 80...: return .blue
        case 70...: return .yellow
        case 60...: return .orange
        default:    return .red
        }
    }

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

// MARK: - Context tab

/// Per-session context-window fill from the local Claude Code logs: a headline
/// gauge for the session you're most likely in, plus any other live sessions.
/// "Current" context = the latest assistant turn's prompt size (input + cache),
/// which is what was actually sent to the model — so it climbs toward the 200K
/// window until an auto-compact shrinks it back. Fed by `ContextWindowService`.
struct ContextTabView: View {
    @ObservedObject var context: ContextWindowService

    var body: some View {
        let m = context.metrics
        if let active = m.active {
            VStack(alignment: .leading, spacing: 20) {
                headline(active)

                let others = Array(m.sessions.dropFirst())
                if !others.isEmpty {
                    Divider()
                    Text("Other live sessions · last 24h").font(.system(size: 13, weight: .semibold))
                    VStack(spacing: 10) {
                        ForEach(others) { sessionRow($0) }
                    }
                }
            }
        } else {
            empty
        }
    }

    // MARK: Pieces

    /// The active session as a big gauge: % full, a colored bar, and the headroom
    /// remaining before auto-compact.
    private func headline(_ s: ContextSession) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(s.utilization)%").font(.system(size: 40, weight: .semibold)).monospacedDigit()
                    .foregroundColor(color(s.utilization))
                Text("of 200K context").font(.system(size: 13)).foregroundColor(.secondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(s.project).font(.system(size: 12, weight: .medium))
                    Text(s.model + (s.gitBranch.map { " · \($0)" } ?? ""))
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
            }

            bar(s.utilization, height: 12)

            Text("\(formatTokenCount(s.contextTokens)) used · \(formatTokenCount(s.tokensRemaining)) of headroom left")
                .font(.system(size: 11)).foregroundColor(.secondary)

            if s.cacheActive { cacheRow(s) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
    }

    /// Prompt-cache freshness, ticking live: a green dot + countdown while warm,
    /// fading to a hollow dot + "re-caches next message" once the 5-min TTL lapses.
    /// Warm = the next turn hits a cheap cache read; cold = it re-pays cache creation.
    private func cacheRow(_ s: ContextSession) -> some View {
        TimelineView(.periodic(from: Date(), by: 1)) { ctx in
            let now = ctx.date
            let warm = s.isCacheWarm(now: now)
            HStack(spacing: 6) {
                Circle().fill(warm ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 7, height: 7)
                Text(warm
                     ? "Prompt cache warm · \(formatDuration(s.cacheFreshSeconds(now: now))) until cold"
                     : "Prompt cache cold · next message re-caches (idle \(formatDuration(s.idleSeconds(now: now))))")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
    }

    private func sessionRow(_ s: ContextSession) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(s.project).font(.system(size: 12)).lineLimit(1)
                Text(s.model).font(.system(size: 10)).foregroundColor(.secondary)
            }
            .frame(width: 120, alignment: .leading)
            bar(s.utilization, height: 10)
            Text("\(s.utilization)%").font(.system(size: 12)).monospacedDigit()
                .foregroundColor(color(s.utilization))
                .frame(width: 40, alignment: .trailing)
        }
    }

    private func bar(_ util: Int, height: CGFloat) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.12))
                Capsule().fill(color(util).opacity(0.7))
                    .frame(width: max(2, geo.size.width * CGFloat(util) / 100))
            }
        }
        .frame(height: height)
    }

    /// Green when roomy, orange in the caution band, red once an auto-compact is near.
    private func color(_ util: Int) -> Color {
        if util >= contextHighThreshold { return .red }
        if util >= contextCautionThreshold { return .orange }
        return .green
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Text("No active session").font(.system(size: 14, weight: .semibold))
            Text("Context fill is read from your local Claude Code logs. Start a session and its context-window usage appears here.")
                .font(.system(size: 11)).foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
    }
}
