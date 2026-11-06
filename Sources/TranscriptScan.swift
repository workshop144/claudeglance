import Foundation

// MARK: - Incremental transcript scanning

/// One transcript line reduced to what the metrics, tool counts and context fill
/// need. A file's lines are decoded once into these and cached, so a 60s/30s
/// refresh no longer re-reads and re-decodes every transcript in the window; it
/// reads only bytes appended since the last scan. The raw text is not kept.
struct TranscriptEntry {
    struct ToolUse {
        let id: String?
        let name: String
    }

    let date: Date
    let role: String?
    let messageId: String?
    let requestId: String?
    let model: String
    let usage: MetricsLogLine.Usage?
    let toolUses: [ToolUse]
    let sessionId: String?
    let isSidechain: Bool
    let cwd: String?
    let gitBranch: String?
}

/// Tolerant shape of a transcript line covering every field the aggregations use.
/// Each field decodes with `try?`, so an odd value in one never drops the line
/// (e.g. user turns store `content` as a string, assistant turns as blocks).
private struct TranscriptLine: Decodable {
    let timestamp: String?
    let requestId: String?
    let sessionId: String?
    let isSidechain: Bool?
    let cwd: String?
    let gitBranch: String?
    let message: Message?

    struct Message: Decodable {
        let id: String?
        let role: String?
        let model: String?
        let usage: MetricsLogLine.Usage?
        let content: [ToolLogLine.Message.Block]?

        private enum CodingKeys: String, CodingKey { case id, role, model, usage, content }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try? c.decodeIfPresent(String.self, forKey: .id)
            role = try? c.decodeIfPresent(String.self, forKey: .role)
            model = try? c.decodeIfPresent(String.self, forKey: .model)
            usage = try? c.decodeIfPresent(MetricsLogLine.Usage.self, forKey: .usage)
            content = try? c.decodeIfPresent([ToolLogLine.Message.Block].self, forKey: .content)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case timestamp, requestId, sessionId, isSidechain, cwd, gitBranch, message
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try? c.decodeIfPresent(String.self, forKey: .timestamp)
        requestId = try? c.decodeIfPresent(String.self, forKey: .requestId)
        sessionId = try? c.decodeIfPresent(String.self, forKey: .sessionId)
        isSidechain = try? c.decodeIfPresent(Bool.self, forKey: .isSidechain)
        cwd = try? c.decodeIfPresent(String.self, forKey: .cwd)
        gitBranch = try? c.decodeIfPresent(String.self, forKey: .gitBranch)
        message = try? c.decodeIfPresent(Message.self, forKey: .message)
    }
}

/// Decodes transcript lines into entries. Works on bytes, line by line, so an
/// invalid UTF-8 byte (say, a multi-byte character cut mid-append) costs only its
/// own line rather than the whole file, as `String(contentsOf:encoding:)` did.
struct TranscriptParser {
    private let decoder = JSONDecoder()
    private let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()

    /// Nil when the bytes aren't a JSON object line; otherwise the entry, if the
    /// line carries anything the aggregations count (usage or tool calls).
    func decode(_ line: Data) -> TranscriptEntry?? {
        guard let parsed = try? decoder.decode(TranscriptLine.self, from: line) else { return nil }
        guard let ts = parsed.timestamp, let date = isoFrac.date(from: ts) ?? iso.date(from: ts),
              let msg = parsed.message else { return .some(nil) }
        let tools: [TranscriptEntry.ToolUse] = (msg.content ?? []).compactMap { block in
            guard block.type == "tool_use", let name = block.name, !name.isEmpty else { return nil }
            return TranscriptEntry.ToolUse(id: block.id, name: name)
        }
        guard msg.usage != nil || !tools.isEmpty else { return .some(nil) }
        return TranscriptEntry(date: date, role: msg.role, messageId: msg.id, requestId: parsed.requestId,
                               model: msg.model ?? "", usage: msg.usage, toolUses: tools,
                               sessionId: parsed.sessionId, isSidechain: parsed.isSidechain == true,
                               cwd: parsed.cwd, gitBranch: parsed.gitBranch)
    }

    /// Every entry in a chunk of complete lines.
    func entries(in data: Data) -> [TranscriptEntry] {
        data.split(separator: 0x0A).compactMap { decode(Data($0)) ?? nil }
    }

    /// Every entry in whole-file strings (the pure aggregations' test path).
    func entries(in contents: [String]) -> [TranscriptEntry] {
        contents.flatMap { entries(in: Data($0.utf8)) }
    }
}

/// Per-file cache of decoded entries, keyed by path and invalidated by size and
/// modification date. A file that grew is read from where the last scan stopped;
/// one that shrank or was rewritten is read again in full. Not thread-safe: each
/// service owns one and uses it only from its own serial queue.
final class TranscriptCache {
    private struct File {
        var size: UInt64
        var modified: Date
        /// Bytes consumed so far (through the last complete line).
        var offset: UInt64
        /// The byte at `offset - 1` when it was read. If it differs on the next
        /// scan, the file was rewritten rather than appended to.
        var lastByte: UInt8?
        var entries: [TranscriptEntry]
    }

    private var files: [String: File] = [:]
    private let parser = TranscriptParser()

    /// Entries from every `.jsonl` under `directories` modified at or after `cutoff`.
    func entries(in directories: [URL], modifiedSince cutoff: Date) -> [TranscriptEntry] {
        let fm = FileManager.default
        var live = Set<String>()
        var out: [TranscriptEntry] = []
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        for dir in directories {
            guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: keys,
                                                 options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                let values = try? url.resourceValues(forKeys: Set(keys))
                let modified = values?.contentModificationDate ?? .distantPast
                if modified < cutoff { continue }
                let size = UInt64(values?.fileSize ?? 0)
                live.insert(url.path)
                out.append(contentsOf: refreshed(url, size: size, modified: modified))
            }
        }
        // Forget files that aged out of the window or were deleted.
        files = files.filter { live.contains($0.key) }
        return out
    }

    private func refreshed(_ url: URL, size: UInt64, modified: Date) -> [TranscriptEntry] {
        let key = url.path
        if let cached = files[key], cached.size == size, cached.modified == modified {
            return cached.entries
        }
        var file = files[key]
        // Grew: append from the last complete line. Otherwise start over.
        if file == nil || size < file!.size || size == file!.size {
            file = File(size: 0, modified: .distantPast, offset: 0, lastByte: nil, entries: [])
        }
        guard var current = file, let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        do {
            // A file truncated and rewritten past its old size also "grew"; Claude
            // Code only appends, but if the byte before the offset changed, reread.
            if current.offset > 0 {
                try handle.seek(toOffset: current.offset - 1)
                if try handle.read(upToCount: 1)?.first != current.lastByte {
                    current = File(size: 0, modified: .distantPast, offset: 0, lastByte: nil, entries: [])
                }
            }
            try handle.seek(toOffset: current.offset)
            let data = try handle.readToEnd() ?? Data()
            let before = current.offset
            if let lastNewline = data.lastIndex(of: 0x0A) {
                current.entries += parser.entries(in: data[data.startIndex..<lastNewline])
                current.offset += UInt64(data.distance(from: data.startIndex, to: lastNewline) + 1)
                let rest = data[data.index(after: lastNewline)...]
                current.offset += consumeTrailingLine(rest, into: &current.entries)
            } else {
                current.offset += consumeTrailingLine(data[...], into: &current.entries)
            }
            if current.offset > before {
                current.lastByte = data[data.startIndex + Int(current.offset - before) - 1]
            }
        } catch {
            return file?.entries ?? []
        }
        current.size = size
        current.modified = modified
        files[key] = current
        return current.entries
    }

    /// A last line without a newline is either still being written (truncated JSON:
    /// leave it for the next scan) or a finished line in a file that doesn't end in
    /// one (decodes: count it now). Returns the bytes consumed.
    private func consumeTrailingLine(_ tail: Data, into entries: inout [TranscriptEntry]) -> UInt64 {
        guard !tail.isEmpty, let decoded = parser.decode(Data(tail)) else { return 0 }
        if let entry = decoded { entries.append(entry) }
        return UInt64(tail.count)
    }
}

/// Skips a scan while the previous one is still running, so a slow scan can't
/// queue a backlog of full scans behind it on the serial queue.
final class ScanGate: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false

    func tryBegin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if running { return false }
        running = true
        return true
    }

    func end() {
        lock.lock(); running = false; lock.unlock()
    }
}

/// Whether the context-window scan has anyone to show its result to: the menu's
/// context row, the session grade (which reads context headroom), or an open
/// dashboard. Both menu options are opt-in and off by default.
func shouldScanContextWindows(showContextWindow: Bool, showSessionGrade: Bool,
                              dashboardVisible: Bool) -> Bool {
    showContextWindow || showSessionGrade || dashboardVisible
}
