import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Shareable "Wrapped" card [#26]

/// The handful of month-to-date highlights the Wrapped card shows. Built purely
/// from the metrics/tools we already compute, so it's testable without rendering.
struct WrappedStats: Equatable {
    let period: String          // "June 2026"
    let totalTokens: Int
    let cachePercent: Int
    let spentUSD: Double
    let savedUSD: Double
    let streakDays: Int
    let activeDays: Int
    let topModel: String?
    let topTool: String?
    let topMcp: String?
    let toolCalls: Int

    /// True when there's enough activity to bother sharing.
    var hasData: Bool { totalTokens > 0 }
}

/// Assemble the card stats from this month's metrics + tool breakdown. Pure.
func buildWrappedStats(metrics: UsageMetrics, tools: ToolBreakdown, now: Date,
                       calendar: Calendar = .current) -> WrappedStats {
    let f = DateFormatter()
    f.calendar = calendar
    f.locale = Locale.current
    f.dateFormat = "LLLL yyyy"

    let inputSide = metrics.monthInputTokens + metrics.monthCacheReadTokens + metrics.monthCacheCreationTokens
    let cachePct = inputSide > 0 ? Int(Double(metrics.monthCacheReadTokens) / Double(inputSide) * 100) : 0

    let startMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now))
        ?? calendar.startOfDay(for: now)
    let activeDays = metrics.dailyTokens.filter { $0.value > 0 && $0.key >= startMonth }.count
    let activeSet = Set(metrics.dailyTokens.filter { $0.value > 0 }.keys)
    let streak = currentStreak(activeDays: activeSet, today: now, calendar: calendar)

    return WrappedStats(
        period: f.string(from: now),
        totalTokens: metrics.monthTotalTokens,
        cachePercent: cachePct,
        spentUSD: metrics.monthCostUSD,
        savedUSD: metrics.monthSavingsUSD,
        streakDays: streak,
        activeDays: activeDays,
        topModel: metrics.costByModel.max { $0.value < $1.value }?.key,
        topTool: tools.toolCounts.max { $0.value < $1.value }?.key,
        topMcp: tools.mcpServerCounts.max { $0.value < $1.value }?.key,
        toolCalls: tools.totalCalls
    )
}

// MARK: - The card view (rendered to PNG)

/// The colorful, shareable card. A fixed 540×675 (4:5) canvas so the rendered PNG
/// is a predictable, social-friendly size.
struct WrappedCardView: View {
    let stats: WrappedStats
    static let size = CGSize(width: 540, height: 675)

    private var dollars: (Double) -> String { { formatDollars(cents: Int(($0 * 100).rounded())) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("✦ MY CLAUDE WRAPPED ✦")
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .tracking(1.5)
            Text(stats.period)
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .opacity(0.85)

            Spacer(minLength: 24)

            // Hero: total tokens.
            VStack(alignment: .leading, spacing: 2) {
                Text(formatTokenCount(stats.totalTokens))
                    .font(.system(size: 72, weight: .black, design: .rounded))
                Text("tokens this month")
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .opacity(0.85)
            }

            Spacer(minLength: 20)

            // Cache efficiency bar.
            VStack(alignment: .leading, spacing: 6) {
                cacheBar
                Text("\(stats.cachePercent)% served from cache")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .opacity(0.9)
            }

            Spacer(minLength: 24)

            statRow("💸", "\(dollars(stats.spentUSD)) spent · \(dollars(stats.savedUSD)) saved by caching")
            statRow("🔥", streakLine)
            statRow("⚡️", superlativeLine)

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Text("ClaudeGlance")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .opacity(0.8)
            }
        }
        .padding(36)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .foregroundColor(.white)
        .background(
            LinearGradient(
                colors: [Color(red: 0.17, green: 0.11, blue: 0.29),
                         Color(red: 0.55, green: 0.22, blue: 0.42),
                         Color(red: 0.85, green: 0.46, blue: 0.34)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        )
    }

    private var cacheBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.22))
                Capsule().fill(Color.white)
                    .frame(width: max(0, min(1, Double(stats.cachePercent) / 100)) * geo.size.width)
            }
        }
        .frame(height: 14)
    }

    private func statRow(_ emoji: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(emoji).font(.system(size: 18))
            Text(text)
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 5)
    }

    private var streakLine: String {
        let streak = stats.streakDays > 0 ? "\(stats.streakDays)-day streak" : "no active streak"
        return "\(streak) · \(stats.activeDays) active days"
    }

    private var superlativeLine: String {
        var parts: [String] = []
        if let m = stats.topModel { parts.append(m) }
        if let t = stats.topTool { parts.append(t) }
        if stats.toolCalls > 0 { parts.append("\(formatTokenCount(stats.toolCalls)) tool calls") }
        return parts.isEmpty ? "your month with Claude" : parts.joined(separator: " · ")
    }
}

// MARK: - Rendering

/// Render the card to PNG bytes at `scale` (2× → 1080×1350). Main-actor because
/// `ImageRenderer` rasterizes on the main thread.
@MainActor
func renderWrappedPNG(stats: WrappedStats, scale: CGFloat = 2) -> Data? {
    let renderer = ImageRenderer(content: WrappedCardView(stats: stats))
    renderer.scale = scale
    guard let cg = renderer.cgImage else { return nil }
    let rep = NSBitmapImageRep(cgImage: cg)
    rep.size = WrappedCardView.size
    return rep.representation(using: .png, properties: [:])
}

// MARK: - The preview window content (card + Save / Copy / Share)

struct WrappedView: View {
    let stats: WrappedStats
    @State private var copied = false

    var body: some View {
        VStack(spacing: 16) {
            WrappedCardView(stats: stats)
                .frame(width: WrappedCardView.size.width, height: WrappedCardView.size.height)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.primary.opacity(0.08)))
                .shadow(color: .black.opacity(0.18), radius: 12, y: 4)

            HStack(spacing: 10) {
                WrappedButton(title: "Save…", action: save)
                WrappedButton(title: copied ? "Copied!" : "Copy", action: copy)
                WrappedButton(title: "Share", action: share)
            }
        }
        .padding(24)
        .frame(width: WrappedCardView.size.width + 48)
    }

    @MainActor private func save() {
        guard let png = renderWrappedPNG(stats: stats) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ClaudeGlance-Wrapped.png"
        panel.allowedContentTypes = [.png]
        if panel.runModal() == .OK, let url = panel.url {
            try? png.write(to: url)
        }
    }

    @MainActor private func copy() {
        guard let png = renderWrappedPNG(stats: stats), let image = NSImage(data: png) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }

    @MainActor private func share() {
        guard let url = writeTempPNG() else { return }
        let picker = NSSharingServicePicker(items: [url])
        if let view = NSApp.keyWindow?.contentView {
            picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        }
    }

    /// Write the card to a temp PNG (nice filename for share targets), returning its URL.
    @MainActor private func writeTempPNG() -> URL? {
        guard let png = renderWrappedPNG(stats: stats) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeGlance-Wrapped.png")
        try? png.write(to: url)
        return url
    }
}

/// A small pill button matching the Settings hover affordance (blue on hover).
private struct WrappedButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(hovering ? .white : .primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(hovering ? Color.blue : Color(NSColor.controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.gray.opacity(0.35), lineWidth: hovering ? 0 : 1))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

extension Notification.Name {
    /// Posted by the dashboard's "Share Wrapped" button; AppDelegate opens the window.
    static let claudeGlanceShareWrapped = Notification.Name("ClaudeGlanceShareWrapped")
}
