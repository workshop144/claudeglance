import Foundation

// MARK: - Claude Code config discovery [#22]

/// All `projects` directories to scan for Claude Code transcripts. Honors
/// `CLAUDE_CONFIG_DIR` (a single path, or several separated by `:` or `,`) for
/// users who relocate or run multiple Claude configs, and always includes the
/// default `~/.claude` so the common case needs no configuration. De-duplicated,
/// order-stable (configured paths first, default last).
func claudeProjectsDirectories(env: [String: String], home: URL) -> [URL] {
    var bases: [URL] = []

    if let raw = env["CLAUDE_CONFIG_DIR"], !raw.isEmpty {
        for part in raw.split(whereSeparator: { $0 == ":" || $0 == "," }) {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let expanded = (trimmed as NSString).expandingTildeInPath
            bases.append(URL(fileURLWithPath: expanded, isDirectory: true))
        }
    }

    // Always include the default config dir unless a configured path already is it.
    let fallback = home.appendingPathComponent(".claude", isDirectory: true)
    if !bases.contains(where: { $0.standardizedFileURL == fallback.standardizedFileURL }) {
        bases.append(fallback)
    }

    // Map each config dir → its projects/ subdir, de-duplicated by resolved path.
    var seen = Set<String>()
    var dirs: [URL] = []
    for base in bases {
        let projects = base.appendingPathComponent("projects", isDirectory: true)
        if seen.insert(projects.standardizedFileURL.path).inserted {
            dirs.append(projects)
        }
    }
    return dirs
}

/// Live variant reading the current process environment and home directory.
func claudeProjectsDirectories() -> [URL] {
    claudeProjectsDirectories(env: ProcessInfo.processInfo.environment,
                              home: FileManager.default.homeDirectoryForCurrentUser)
}
