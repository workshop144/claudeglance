# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- **Renamed the app from `claude-usage-systray` to ClaudeGlance.** New bundle
  identifier `io.github.broots144.ClaudeGlance`; Homebrew cask token is now
  `claudeglance` (`brew install --cask broots144/tap/claudeglance`).
- Flattened the repository layout — the Xcode project now lives at the repo
  root instead of a nested subfolder.

### Added
- `CONTRIBUTING.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md`, issue/PR templates,
  and this changelog.

## [1.1.2]

### Added
- Today's activity metrics (tokens, active time, message count, cache %, and a
  vs-yesterday delta) parsed from local Claude Code session logs.
- Claude service-health badge sourced from the public status page, shown in the
  menu bar and the pop-up.
- Clickable status row in the pop-up linking to `status.claude.com`.
- Usage-credits on/off status row in the pop-up.

### Changed
- Bundle version is now wired to `MARKETING_VERSION`.

## [1.0.4] and earlier

Fork of [adntgv/claude-usage-systray](https://github.com/adntgv/claude-usage-systray)
with reset countdowns, granular per-element menu-bar toggles, a redesigned
settings window, a universal (Intel + Apple Silicon) build, and a fix for the
`resets_at: null` decoding crash. See the
[GitHub releases](https://github.com/broots144/claudeglance/releases) for the
full history of earlier versions.

[Unreleased]: https://github.com/broots144/claudeglance/compare/v1.1.2...HEAD
[1.1.2]: https://github.com/broots144/claudeglance/releases/tag/v1.1.2
[1.0.4]: https://github.com/broots144/claudeglance/releases/tag/v1.0.4
