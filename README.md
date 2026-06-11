# ClaudeGlance

A lightweight macOS menu bar app that shows your [Claude.ai](https://claude.ai)
plan usage in real time — session %, weekly %, Sonnet %, and time-until-reset —
without opening a browser.

> Fork of [adntgv/claude-usage-systray](https://github.com/adntgv/claude-usage-systray)
> with reset countdowns, granular menu-bar toggles, a redesigned settings
> window, a universal (Intel + Apple Silicon) build, and a fix for the
> `resets_at: null` crash. See [Differences from upstream](#differences-from-upstream).

## What it shows

The menu bar title is assembled from any combination of these elements, in a
fixed order, separated by `·`:

| Element | Default | Description |
|--------------|---------|-------------|
| **Ring gauge** | off | Dual-ring icon — outer = 5h session, inner = 7d weekly, with a pace notch on the 5h ring (fill past it = ahead of pace) |
| **5h %** | on | Current session usage (resets ~every 5 hours) |
| **7d %** | on | Weekly all-models usage |
| **Sonnet %** | off | Weekly Sonnet-only usage |
| **5h reset** | on | Countdown to the session reset (e.g. `4h12m`) |
| **7d reset** | off | Countdown to the weekly reset |

With the defaults you'll see something like `35% · 71% · 4h12m`, followed by a
colored **service-health dot** (🟢 operational → 🔴 outage) sourced from the
public Claude status page. The whole status item **dims when the data goes
stale** (no refresh in 12+ minutes), so old numbers never read as current.

Open the menu for the glance:

- Each period's exact reset time and the current service status.
- **Burn rate & run-out ETA** — when your 5h usage is climbing, a line like
  `On pace for 100% by 3:47 PM` (or `Using ~12%/hr`) projected from the trend.
- **Usage credits in dollars** — when pay-as-you-go credits are on, your overage
  spend against the monthly cap (e.g. `$1.20 / $50 (2%)`).
- **A two-line "Today" glance** from local Claude Code logs — `Today: 1.2M tokens
  · 5d streak` and `≈ $3.40 today · $42 this month`. Each row (and the 5h/7d rows)
  **deep-links into the dashboard** on the matching tab — they bold on hover.

Mirrors the data on `claude.ai/settings/usage`.

## Dashboard

Click any usage/cost/activity row in the menu — or pick **Dashboard** — to open a
single tabbed window (built with SwiftUI + Swift Charts) that holds the richer
detail the menu deliberately leaves out:

- **Usage** — a 5h/7d utilization **history chart** recorded over time, plus the
  current session/weekly/Sonnet cards and reset countdowns.
- **Cost** — today / month-to-date / projected **spend cards**, a **per-model
  breakdown** (e.g. Opus 4.8 vs Sonnet), and a daily-spend chart. All
  API-equivalent (tokens × model price; a flat plan isn't billed per token).
- **Activity** — a **GitHub-style contribution heatmap**, current/longest streak
  and active-day stats, and a daily-token chart.

Everything in the dashboard is computed locally — the cost/activity tabs from your
`~/.claude/projects` logs, the usage history from ClaudeGlance's own recordings.

## Requirements

- macOS 13+ (universal — runs on both Apple Silicon and Intel)
- [Claude Code](https://claude.ai/code) installed and logged in (the app reads
  its OAuth token from your Keychain — no separate credentials needed)

## Install

**Homebrew:**

```bash
brew install --cask broots144/tap/claudeglance
```

Because the build is ad-hoc signed (not notarized), macOS quarantines it. Clear
that once after installing — either way:

- Right-click the app in `/Applications` › **Open** › **Open**, or
- `xattr -dr com.apple.quarantine /Applications/ClaudeGlance.app`

(Homebrew removed its `--no-quarantine` flag, so this is a one-time manual step
until the app is notarized.)

**Or download the DMG** from the [Releases page](https://github.com/broots144/claudeglance/releases),
open it, and drag **ClaudeGlance** onto the **Applications** folder in the same
window.

> The release build is ad-hoc signed, not notarized — on first launch macOS may
> say it "cannot verify the developer." Right-click the app › **Open** (once), or
> remove the quarantine flag: `xattr -dr com.apple.quarantine /Applications/ClaudeGlance.app`.

## Build from source

```bash
git clone https://github.com/broots144/claudeglance
cd claudeglance
xcodebuild -scheme ClaudeGlance -configuration Release build
open ~/Library/Developer/Xcode/DerivedData/ClaudeGlance-*/Build/Products/Release/ClaudeGlance.app
```

Or open `ClaudeGlance.xcodeproj` in Xcode and run with ⌘R.

To produce a drag-to-Applications disk image from a built app:

```bash
scripts/make-dmg.sh path/to/ClaudeGlance.app ClaudeGlance.dmg
```

## Settings

Open **Settings** from the app's menu. The window uses a clean, native layout
(Ollama-style), and every menu-bar element toggles independently — so you can
show just a countdown, just percentages, or any mix.

| Setting | Default | Description |
|---------|---------|-------------|
| Launch at login | Off | Start the app automatically when you log in |
| Show ring gauge | Off | Dual-ring usage gauge (outer 5h, inner 7d) in the menu bar |
| Show 5h % | On | Session usage in the menu bar |
| Show 7d % | On | Weekly usage in the menu bar |
| Show Sonnet % | Off | Weekly Sonnet usage in the menu bar |
| Show 5h reset countdown | On | Time until the session resets |
| Show 7d reset countdown | Off | Time until the weekly limit resets |
| Show service health | On | Colored Claude service-status dot in the menu bar |
| Show today's activity | On | Today's tokens, active time & messages (from local logs) |
| Warning threshold | 80% | Usage % that triggers a warning notification |
| Critical threshold | 90% | Usage % that triggers a critical notification |
| Usage alerts | On | macOS notification when a threshold is crossed |
| Reset notifications | On | Notify when a limit resets after you were near it |

> Thresholds drive **notifications** — the menu bar text itself stays a single
> neutral color for legibility across light and dark menu bars.

## How it works

The app reads your Claude Code OAuth token from the macOS Keychain
(`Claude Code-credentials`) and calls the same internal endpoint that powers
`claude.ai/settings/usage`:

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <oauth_token>
anthropic-beta: oauth-2025-04-20
```

The token is read once at startup and cached in memory. It refreshes
automatically when you restart the app (Claude Code keeps it current in the
Keychain).

> **Note:** This endpoint is undocumented and may change. It requires Claude
> Code to be installed and logged in.

## Running tests

```bash
cd claudeglance
xcodebuild test -scheme ClaudeGlance -destination 'platform=macOS'
```

## Differences from upstream

This fork diverges from [adntgv/claude-usage-systray](https://github.com/adntgv/claude-usage-systray):

- **Today's activity + dashboard** — a two-line "Today" glance in the menu
  (tokens · streak; cost today · this month), backed by a full **dashboard window**
  (Activity / Cost / Usage tabs with charts, a heatmap, and a per-model cost
  breakdown), all parsed from the local Claude Code session logs
  (`~/.claude/projects`). No auth, no Keychain, no network.
- **Service-health badge** — a colored dot from the public Claude status page
  (`status.claude.com`), in the menu bar and menu. No auth, no Keychain.
- **Launch at login** toggle in Settings, using the modern `SMAppService` API
  (no helper bundle, reflects the real system login-item state).
- **Reset countdowns** in the menu bar (5h and 7d) in compact `4h12m` form.
- **Granular per-element toggles** replacing the single "compact display"
  switch — show any mix of 5h %, 7d %, Sonnet %, and the two countdowns.
- **Redesigned settings window** with a clean, native (Ollama-style) layout and
  non-highlighting read-only rows.
- **Universal binary** — Release builds are pinned to `x86_64 arm64`, so the app
  keeps running on Intel Macs even as future toolchains drop x86_64 by default.
- **`resets_at: null` fix** — the usage endpoint returns a `null` reset time for
  any period with nothing to reset (e.g. Sonnet at 0%). Upstream's non-optional
  decoding threw on the `null`, collapsing the whole response into a blank
  `0% / 0%` widget. Now handled gracefully, with a regression test.

## License

[MIT](LICENSE) — © 2026 adntgv (original author) and contributors to this fork.

## Disclaimer

ClaudeGlance is an independent, community-built project. It is not affiliated
with, endorsed by, or sponsored by Anthropic. "Claude" is a trademark of
Anthropic; it is used here only to describe what the app reads. The app relies
on an undocumented endpoint that may change or break at any time.
