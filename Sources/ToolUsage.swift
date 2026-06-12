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
func aggregateToolUsage(jsonlContents: [String], now: Date) -> ToolBreakdown {
    let cal = Calendar.current
    let startMonth = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? cal.startOfDay(for: now)
    let isoFrac = ISO8601DateFormatter(); isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime]
    let decoder = JSONDecoder()

    var toolCounts: [String: Int] = [:]
    var mcpServerCounts: [String: Int] = [:]
    var total = 0

    for content in jsonlContents {
        for line in content.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let entry = try? decoder.decode(ToolLogLine.self, from: data),
                  let msg = entry.message, msg.role == "assistant",
                  let blocks = msg.content,
                  let ts = entry.timestamp,
                  let date = isoFrac.date(from: ts) ?? iso.date(from: ts),
                  date >= startMonth else { continue }

            for block in blocks where block.type == "tool_use" {
                guard let name = block.name, !name.isEmpty else { continue }
                total += 1
                if let server = mcpServerName(from: name) {
                    mcpServerCounts[server, default: 0] += 1
                } else {
                    toolCounts[name, default: 0] += 1
                }
            }
        }
    }

    return ToolBreakdown(toolCounts: toolCounts, mcpServerCounts: mcpServerCounts, totalCalls: total)
}
