import Foundation

// MARK: - Build provenance (shown in the Settings footer)

/// The version + git provenance of the running build, read from Info.plist
/// (GitBranch/GitCommit are substituted at build time from the xcodebuild
/// command line — empty for plain Xcode builds).
struct BuildInfo {
    let version: String
    let branch: String?
    let commit: String?

    static let repoURL = "https://github.com/broots144/claudeglance"

    static var current: BuildInfo {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let branch = (info?["GitBranch"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let commit = (info?["GitCommit"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return BuildInfo(version: version, branch: branch, commit: commit)
    }

    var label: String { buildInfoLabel(version: version, branch: branch, commit: commit) }
    var url: URL { buildInfoURL(repo: Self.repoURL, branch: branch, commit: commit) }
    /// "prod" for release/main builds, "dev" for feature/develop dev builds.
    var channel: String { buildChannel(branch: branch) }
    var helpText: String {
        if let branch, let commit { return "Built from \(branch) @ \(commit) — open on GitHub" }
        if let commit { return "Built from commit \(commit) — open on GitHub" }
        return "Open the ClaudeGlance repository on GitHub"
    }
}

// MARK: - Pure formatting (testable)

/// Footer label: `v1.1.1` for a release/plain build, `v1.1.1 · <commit>` on the
/// default branch, or `v1.1.1 · <branch>@<commit>` on a feature branch — so it's
/// obvious which dev build is running.
func buildInfoLabel(version: String, branch: String?, commit: String?) -> String {
    guard let commit, !commit.isEmpty else { return "v\(version)" }
    if let branch, !branch.isEmpty, branch != "main", branch != "HEAD" {
        return "v\(version) · \(branch)@\(commit)"
    }
    return "v\(version) · \(commit)"
}

/// The release channel from the build's branch: release builds (tagged on `main`,
/// which pass no branch) and `main` itself are "prod"; everything else — a
/// dev-install from a `feature/*` or `develop` branch — is "dev".
func buildChannel(branch: String?) -> String {
    guard let branch, !branch.isEmpty, branch != "main" else { return "prod" }
    return "dev"
}

/// Links to the exact commit when known, else the branch tree, else the repo.
func buildInfoURL(repo: String, branch: String?, commit: String?) -> URL {
    if let commit, !commit.isEmpty { return URL(string: "\(repo)/commit/\(commit)")! }
    if let branch, !branch.isEmpty { return URL(string: "\(repo)/tree/\(branch)")! }
    return URL(string: repo)!
}
