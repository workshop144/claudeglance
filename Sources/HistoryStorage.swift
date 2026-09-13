import Foundation

// MARK: - Durable history storage

/// Where persisted history lives. Every history file is kept in **two** places,
/// written in lockstep and unioned on read:
///
/// * **primary** — `~/Library/Application Support/ClaudeGlance/`, the normal home
///   for app state. It sits outside the `.app`, so it already survives every
///   in-place upgrade and a drag-to-Trash uninstall.
/// * **mirror** — `~/.claudeglance/`, a hidden dot-directory in the home folder.
///   Third-party uninstallers (AppCleaner and friends) sweep Application Support
///   by bundle id but don't know about this one, so a wipe-and-reinstall still
///   finds its history here.
///
/// Neither copy is authoritative: on load we decode both and merge, so whichever
/// survived a wipe restores the other on the next write.
enum HistoryStorage {
    /// Bumped only when a payload changes shape in a way older builds can't read.
    static let currentVersion = 1

    static var primaryDirectory: URL? {
        let fm = FileManager.default
        guard let base = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true) else { return nil }
        let dir = base.appendingPathComponent("ClaudeGlance", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var mirrorDirectory: URL? {
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claudeglance", isDirectory: true)
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { return nil }
        return dir
    }

    /// Both locations for `file`, primary first. Empty only if the home folder and
    /// Application Support are both unreachable.
    static func locations(for file: String) -> [URL] {
        [primaryDirectory, mirrorDirectory].compactMap { $0?.appendingPathComponent(file) }
    }
}

// MARK: - Versioned envelope

/// The wrapper written around every history payload. `v` lets a future release
/// recognise an older layout and migrate it rather than failing to decode — the
/// previous stores treated *any* decode error as "no history" and overwrote the
/// file on the next write, which silently destroyed it for good.
struct HistoryFile<Payload: Codable>: Codable {
    var v: Int
    var written: Date
    var payload: Payload

    init(payload: Payload, v: Int = HistoryStorage.currentVersion, written: Date = Date()) {
        self.v = v; self.written = written; self.payload = payload
    }
}

// MARK: - Load / save

enum DurableJSON {
    /// Decodes `data` as an envelope, falling back to the bare pre-envelope layout
    /// that shipped before versioning. Pure, so both paths are testable.
    static func decode<Payload: Codable>(_ data: Data, as type: Payload.Type) -> Payload? {
        let d = JSONDecoder()
        if let file = try? d.decode(HistoryFile<Payload>.self, from: data) { return file.payload }
        // Legacy: the payload was written at the top level, with no version.
        return try? d.decode(Payload.self, from: data)
    }

    /// Reads every location for `file` and merges what decodes. A file that is
    /// present but undecodable is set aside as `<name>.corrupt` rather than
    /// overwritten, so a bad upgrade is recoverable instead of terminal.
    static func load<Payload: Codable>(_ file: String, as type: Payload.Type,
                                       merging merge: (Payload, Payload) -> Payload) -> Payload? {
        var result: Payload?
        for url in HistoryStorage.locations(for: file) {
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { continue }
            guard let payload = decode(data, as: Payload.self) else {
                quarantine(url)
                continue
            }
            result = result.map { merge($0, payload) } ?? payload
        }
        return result
    }

    /// Writes `payload` atomically to both locations. A failure on one (a
    /// read-only home, say) never stops the other.
    static func save<Payload: Codable>(_ payload: Payload, to file: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(HistoryFile(payload: payload)) else { return }
        for url in HistoryStorage.locations(for: file) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Moves an undecodable file aside so the next write doesn't clobber it. Kept
    /// at a fixed name so repeated failures can't fill the disk.
    private static func quarantine(_ url: URL) {
        let fm = FileManager.default
        let dst = url.deletingPathExtension().appendingPathExtension("corrupt.json")
        try? fm.removeItem(at: dst)
        try? fm.moveItem(at: url, to: dst)
    }
}
