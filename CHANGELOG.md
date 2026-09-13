# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.7.2] — History that sticks around

### Fixed
- **Streaks and the contribution heatmap no longer reset.** They were recomputed
  on every poll straight from `~/.claude/projects/**/*.jsonl`, and Claude Code
  deletes those transcripts after `cleanupPeriodDays` (30 by default) — so history
  quietly collapsed as the logs aged out, with nothing on disk to recover. Daily
  totals are now rolled up into ClaudeGlance's own `daily-activity.json` and
  merged max-wins, making a recorded day a floor that can't erode. Streaks read
  the archive, so a run longer than the 30-day scan window counts in full.
- **A gap in polling no longer wipes the utilization chart.** Retention was 7
  days and the prune ran on the first write after a gap, so signing back in after
  a week discarded everything older. Retention is now a rolling year.
- **A future format change can no longer destroy history silently.** Every store
  treated *any* decode failure as "no history" and overwrote the file on the next
  write. Payloads are now wrapped in a versioned envelope (older top-level files
  still load), and an undecodable file is set aside as `*.corrupt.json` instead
  of being overwritten.

### Added
- **History survives uninstall/reinstall.** Every history file is written to both
  `~/Library/Application Support/ClaudeGlance/` and a mirror in `~/.claudeglance/`,
  and unioned on load — third-party uninstallers sweep Application Support by
  bundle id but don't know about the home dot-directory, so whichever copy
  survives restores the other.
- **Settings › History backup** — Export / Import / Reveal in Finder, for moving
  history to another Mac. Import merges; it only ever adds days back.
- **Range picker on the utilization chart** (7d / 30d / 90d / All), now that
  there's more than a week to look at. Samples older than 48h are thinned to
  hourly peaks, so a year of history stays a few thousand rows.

### Changed
- The plan-fit nudge is pinned to the last 7 days regardless of the chart range —
  an all-time peak would otherwise pin it to the worst week of the year forever.

## [1.7.1] — Seamless sign-in

### Changed
- **Sign-in no longer needs copy/paste.** ClaudeGlance runs a one-shot loopback
  listener on 127.0.0.1 and claude.ai redirects straight back to it (the same
  mechanism the Claude Code CLI uses). Authorize in the browser and the app
  finishes on its own. The console-code paste flow remains as a fallback
  ("Browser didn't come back?").
- Menu-bar **Sign in to Claude…** opens Settings and starts the browser flow in
  one tap; Settings opens automatically on launch when signed out.

### Fixed
- **⌘V / ⌘C / ⌘X / ⌘A / ⌘Z now work in text fields.** As a menu-bar-only app
  ClaudeGlance had no main menu, so AppKit had nothing to route standard edit
  key equivalents to. ⌘W closes windows too.

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
