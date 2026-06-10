# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] — ClaudeGlance

First release under the **ClaudeGlance** name. This project began as a fork of
[adntgv/claude-usage-systray](https://github.com/adntgv/claude-usage-systray)
(MIT) and was renamed and versioned fresh at 1.0.0. The bundle identifier is
`io.github.broots144.ClaudeGlance` and the Homebrew cask token is `claudeglance`.

### Features
- Menu bar display of Claude.ai plan usage, assembled from any combination of:
  5h session %, 7d weekly %, weekly Sonnet %, and compact reset countdowns
  (`4h12m`) for the session and weekly limits.
- **Today's activity** — tokens, active time, message count, cache %, and a
  vs-yesterday delta, parsed from local Claude Code session logs
  (`~/.claude/projects`). No auth, no Keychain, no network.
- **Service-health badge** — a colored dot sourced from the public Claude status
  page, in the menu bar and the pop-up; the status row links to
  `status.claude.com`.
- **Usage-credits on/off** status row in the pop-up.
- **Launch at login** toggle using the modern `SMAppService` API.
- Configurable warning/critical thresholds with macOS notifications.
- Universal binary (Intel + Apple Silicon), macOS 13+.

### Notes
- Reads the Claude Code OAuth token from the macOS Keychain
  (`Claude Code-credentials`) and calls Anthropic's usage endpoint over HTTPS;
  the token stays in memory and is never written to disk or sent elsewhere.
- The release build is ad-hoc signed (not notarized) — clear quarantine on
  first launch with `xattr -dr com.apple.quarantine /Applications/ClaudeGlance.app`.

[1.0.0]: https://github.com/broots144/claudeglance/releases/tag/v1.0.0
