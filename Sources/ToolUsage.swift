import Foundation

// MARK: - Tool / MCP usage breakdown (from Claude Code session logs)

/// Which tools and MCP servers are driving your sessions, by call count over the
/// month to date. Parsed from the `tool_use` blocks Claude Code writes into each
/// assistant turn — the "what's spending my context" companion to where-tokens-go.
struct ToolBreakdown {
    /// Built-in tool name (e.g. "Bash", "Edit") → calls this month.
    let toolCounts: [String: Int]
    /// MCP server (e.g. "Gmail", from `mcp__Gmail__search`) → calls this month.
    let mcpServerCounts: [String: Int]
    let totalCalls: Int

    static let empty = ToolBreakdown(toolCounts: [:], mcpServerCounts: [:], totalCalls: 0)
    var hasData: Bool { totalCalls > 0 }
}

/// A tool name is an MCP tool when Claude Code namespaces it `mcp__server__tool`.
/// Returns the server segment ("Gmail") for `mcp__Gmail__search_threads`, else nil.
func mcpServerName(from toolName: String) -> String? {
    guard toolName.hasPrefix("mcp__") else { return nil }
    let parts = toolName.dropFirst("mcp__".count).components(separatedBy: "__")
    guard let server = parts.first, !server.isEmpty else { return nil }
    return server.replacingOccurrences(of: "_", with: " ")
}

// MARK: - Log line shape (tolerant)

/// Minimal transcript shape for tool counting. `content` is decoded leniently:
/// user turns store it as a plain string, assistant turns as an array of blocks —
/// the custom decoder yields the array when present and `nil` otherwise, so a
/// string value never fails the whole line.
struct ToolLogLine: Decodable {
    let timestamp: String?
    let message: Message?

    struct Message: Decodable {
        let role: String?
        let content: [Block]?

        struct Block: Decodable {
            let type: String?
            let name: String?
            /// The tool_use id ("toolu_…"), unique per call.
            let id: String?
        }

        private enum CodingKeys: String, CodingKey { case role, content }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            role = try? c.decodeIfPresent(String.self, forKey: .role)
            // Array when the turn carries blocks; a string (user text) decodes to nil.
            content = try? c.decodeIfPresent([Block].self, forKey: .content)
        }
    }
}

// MARK: - Pure aggregation (testable, no I/O)

/// Counts `tool_use` calls in assistant turns from this calendar month, split into
/// built-in tools and MCP servers. Pure — feed it strings and a clock.
///
/// Resumed and forked sessions copy earlier lines into a new jsonl file, so the
/// same call can appear in several files. Calls are counted once per tool_use id,
/// the way `aggregateMetrics` counts usage once per message/request.
func aggregateToolUsage(jsonlContents: [String], now: Date) -> ToolBreakdown {
    aggregateToolUsage(entries: TranscriptParser().entries(in: jsonlContents), now: now)
}

/// The aggregation proper, over already-decoded transcript entries (the cached path).
func aggregateToolUsage(entries: [TranscriptEntry], now: Date) -> ToolBreakdown {
    let cal = Calendar.current
    let startMonth = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? cal.startOfDay(for: now)

    var toolCounts: [String: Int] = [:]
    var mcpServerCounts: [String: Int] = [:]
    var total = 0
    var seen = Set<String>()

    for entry in entries where entry.role == "assistant" && entry.date >= startMonth {
        for call in entry.toolUses {
            if let id = call.id, !id.isEmpty {
                guard seen.insert(id).inserted else { continue }
            }
            total += 1
            if let server = mcpServerName(from: call.name) {
                mcpServerCounts[server, default: 0] += 1
            } else {
                toolCounts[call.name, default: 0] += 1
            }
        }
    }

    return ToolBreakdown(toolCounts: toolCounts, mcpServerCounts: mcpServerCounts, totalCalls: total)
}
