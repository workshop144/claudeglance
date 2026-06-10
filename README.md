# Claude Usage Systray

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
| **5h %** | on | Current session usage (resets ~every 5 hours) |
| **7d %** | on | Weekly all-models usage |
| **Sonnet %** | off | Weekly Sonnet-only usage |
| **5h reset** | on | Countdown to the session reset (e.g. `4h12m`) |
| **7d reset** | off | Countdown to the weekly reset |

With the defaults you'll see something like `35% · 71% · 4h12m`. Open the menu
for the full breakdown, including each period's exact reset time.

Mirrors the data on `claude.ai/settings/usage`.

## Requirements

- macOS 13+ (universal — runs on both Apple Silicon and Intel)
- [Claude Code](https://claude.ai/code) installed and logged in (the app reads
  its OAuth token from your Keychain — no separate credentials needed)

## Build from source

```bash
git clone https://github.com/broots144/claude-usage-systray
cd claude-usage-systray/claude-usage-systray
xcodebuild -scheme ClaudeUsageSystray -configuration Release build
open ~/Library/Developer/Xcode/DerivedData/ClaudeUsageSystray-*/Build/Products/Release/ClaudeUsageSystray.app
```

Or open `ClaudeUsageSystray.xcodeproj` in Xcode and run with ⌘R.

> Prebuilt releases and a Homebrew cask aren't published for this fork yet —
> build from source for now.

## Settings

Open **Settings** from the app's menu. The window uses a clean, native layout
(Ollama-style), and every menu-bar element toggles independently — so you can
show just a countdown, just percentages, or any mix.

| Setting | Default | Description |
|---------|---------|-------------|
| Show 5h % | On | Session usage in the menu bar |
| Show 7d % | On | Weekly usage in the menu bar |
| Show Sonnet % | Off | Weekly Sonnet usage in the menu bar |
| Show 5h reset countdown | On | Time until the session resets |
| Show 7d reset countdown | Off | Time until the weekly limit resets |
| Warning threshold | 80% | Usage % that triggers a warning notification |
| Critical threshold | 90% | Usage % that triggers a critical notification |
| Usage alerts | On | macOS notification when a threshold is crossed |

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
cd claude-usage-systray
xcodebuild test -scheme ClaudeUsageSystray -destination 'platform=macOS'
```

## Differences from upstream

This fork diverges from [adntgv/claude-usage-systray](https://github.com/adntgv/claude-usage-systray):

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
