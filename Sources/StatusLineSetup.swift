import Foundation
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Statusline setup [#27]

/// Installs the bundled Claude Code statusline script into `~/.claude` and,
/// optionally, wires it into `settings.json`. The JSON merge is a pure
/// bytes→bytes function so it's testable; the file I/O backs up before writing.
enum StatusLineSetup {
    static let scriptResource = "claudeglance-statusline"
    static let scriptFileName = "claudeglance-statusline.sh"

    private static var claudeDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
    }

    /// Where the script is installed — alongside Claude Code's own config.
    static var installURL: URL { claudeDir.appendingPathComponent(scriptFileName) }

    /// Claude Code's settings file we wire the statusLine into.
    static var settingsURL: URL { claudeDir.appendingPathComponent("settings.json") }

    /// The command Claude Code runs — an absolute path so it works regardless of
    /// how the statusline command is invoked (no reliance on `~` expansion).
    static var command: String { installURL.path }

    /// The settings.json fragment shown to the user / copied to the clipboard.
    static var snippet: String {
        """
        "statusLine": {
          "type": "command",
          "command": "\(command)"
        }
        """
    }

    // MARK: - Install the script

    /// Copy the bundled script into `~/.claude` and mark it executable. Returns the
    /// install path. Overwrites any prior copy so re-running picks up updates.
    @discardableResult
    static func installScript() throws -> URL {
        guard let src = Bundle.main.url(forResource: scriptResource, withExtension: "sh") else {
            throw err("The statusline script is missing from the app bundle.")
        }
        let dst = installURL
        let fm = FileManager.default
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
        try fm.copyItem(at: src, to: dst)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst.path)
        return dst
    }

    /// Copy the settings.json snippet to the pasteboard. Split out so the View
    /// stays thin and this is callable from tests/headless if ever needed.
    static func copySnippetToPasteboard() {
        #if canImport(AppKit)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(snippet, forType: .string)
        #endif
    }

    // MARK: - Wire into settings.json

    struct WireResult {
        /// Where the prior settings.json was backed up (nil if none existed).
        let backup: URL?
        /// True when an existing `statusLine` was replaced (worth telling the user).
        let replacedExisting: Bool
    }

    /// Whether `data` already defines a `statusLine`. Pure. Returns false for nil/
    /// empty or non-object content (the caller surfaces the non-object case).
    static func hasStatusLine(_ data: Data?) -> Bool {
        guard let data, !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return false }
        return dict["statusLine"] != nil
    }

    /// Merge a `statusLine` command into existing settings.json bytes, preserving
    /// every other key. Pure (bytes→bytes) so it's unit-testable. Returns nil when
    /// the existing content isn't a JSON object (so we never clobber a non-object).
    static func mergedSettings(existing: Data?, command: String) -> Data? {
        var root: [String: Any] = [:]
        if let existing, !existing.isEmpty {
            guard let obj = try? JSONSerialization.jsonObject(with: existing),
                  let dict = obj as? [String: Any] else { return nil }
            root = dict
        }
        root["statusLine"] = ["type": "command", "command": command]
        return try? JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Back up settings.json (if present) then merge in the statusLine. Throws with
    /// a friendly message when the file isn't a JSON object.
    static func wireIntoSettings(stamp: String = StatusLineSetup.timestamp()) throws -> WireResult {
        let fm = FileManager.default
        let existing = try? Data(contentsOf: settingsURL)
        let replaced = hasStatusLine(existing)

        guard let merged = mergedSettings(existing: existing, command: command) else {
            throw err("Your ~/.claude/settings.json isn't a plain JSON object — add the statusLine snippet manually.")
        }

        try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var backup: URL? = nil
        if fm.fileExists(atPath: settingsURL.path) {
            let b = settingsURL.deletingLastPathComponent()
                .appendingPathComponent("settings.json.claudeglance-backup-\(stamp)")
            try? fm.removeItem(at: b)
            try fm.copyItem(at: settingsURL, to: b)
            backup = b
        }
        try merged.write(to: settingsURL, options: .atomic)
        return WireResult(backup: backup, replacedExisting: replaced)
    }

    // MARK: - Helpers

    static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    private static func err(_ message: String) -> NSError {
        NSError(domain: "StatusLineSetup", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
