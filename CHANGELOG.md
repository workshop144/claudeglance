# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.8.4] — Signed and notarized

### Changed
- **Opens without a warning.** ClaudeGlance is now signed with an Apple
  Developer ID and notarized by Apple, and so is the DMG. macOS no longer says
  it "cannot verify the developer", and the Homebrew cask drops its
  `xattr -dr com.apple.quarantine` step.

### Upgrade note
- **One more sign-in prompt.** The app's signature changed, so on the first
  launch after updating macOS may ask for your login password to let
  ClaudeGlance read its saved sign-in (choose **Always Allow**), or ask you to
  sign in to Claude again from Settings. This happens once.

## [1.8.3] — Review fixes

### Fixed
- **Sign-out always sticks.** A usage check running at the exact moment you
  signed out could write your old tokens back, so you were signed in again at
  the next launch; and a sign-in finishing while an expired session was being
  cleared could lose its new tokens. Sign-out and sign-in now always win.
- **The sign-in code field stays put.** The background usage check no longer
  resets Settings while you are copying the sign-in code from the browser.
- **Short, clean sign-in errors.** A failed sign-in or token refresh now says
  what went wrong in one line instead of showing the server's raw response, and
  a rate-limited token refresh waits as long as the server asks before retrying.
- **Reset countdowns no longer blink out.** A reset time sent without fractional
  seconds (exactly on the second) failed to parse, so the countdown, pace
  marker, run-out estimate and reset alerts vanished for that update.
- **Context gauge sized right for older models.** Opus 4, 4.1 and 4.5 and
  Sonnet 4 and 4.5 have a 200K context window, not 1M, so their sessions showed
  about a fifth of their real fill and the "compact soon" warning never fired.

## [1.8.2] — Security hardening

### Security
- **Sign-in asks for less.** ClaudeGlance now requests only the `user:profile`
  scope, which is all it needs to read your usage. Earlier versions also asked
  for `org:create_api_key` and `user:inference`, so a leaked token could have
  created API keys or run models on your account. Existing sign-ins keep working;
  sign out and back in from Settings to swap your token for a narrower one.
- **Verifiable downloads.** Each release DMG now carries a signed build
  provenance attestation. Run
  `gh attestation verify ClaudeGlance.dmg -R workshop144/claudeglance` to check
  that a DMG came from this repo's release workflow.

## [1.8.1] — Bug sweep

### Fixed
- **Staying signed in when refreshes overlap.** A manual Refresh, the sign-in
  fetch and the timer poll could each refresh the token with the same refresh
  token; the token endpoint rotates it, so the loser was rejected and the app
  signed you out. Refreshes now run one at a time, a refreshed token is kept in
  memory if saving it fails, and only one usage fetch runs at once.
- **Weekly usage warnings fire every week.** The 80% warning and critical alert
  used to fire once per app launch and never again after the week reset.
- **The "5-hour session reset" alert survives an idle gap.** When a window ended
  and no new one had started, the API's empty reset time wiped the record of
  how close you had been, so the alert was skipped.
- **The Claude Code statusline no longer shows placeholder or frozen numbers.**
  Before the first fetch it printed "5h 0% · 7d 0%", and after sign-out or
  failed fetches it kept the old numbers as if live. It now says "ClaudeGlance:
  sign in" or "no data yet", and marks old numbers "(stale)", including when
  the app has quit. Re-copy the script from Settings to get the new marker.
- **A failed status-page fetch no longer shows 100% uptime.** An error or
  challenge page used to read as "no incidents".
- **Importing a history backup no longer doubles recent samples.** Backups now
  keep milliseconds, and older backups merge cleanly too. Backups exported by
  1.8.1 need 1.8.1 or later to import; an older build can't read them.
- **Opus 4 and 4.1 are priced at $15/$75**, not the Opus 4.5+ rate, and
  `claude-opus-4-20250514` is labelled "Opus 4", not "Opus 4.2".
- **Tool and MCP counts no longer double-count resumed sessions.**
- **Wiring the statusline keeps a symlinked `~/.claude/settings.json` a
  symlink**, writing through to your dotfiles instead of replacing the link.
- **An import can no longer be lost on disk** when it races the background
  activity scan.
- **Double-clicking Sign in no longer leaves a hung sign-in attempt behind.**
- **Signing out while a token refresh is running stays signed out.** The
  refreshed tokens used to be saved back afterwards.
- **A Refresh during a throttled check waits for the retry time** instead of
  sending another request straight away.
- **The statusline's "(stale)" check works with GNU `stat` first on PATH**
  (Nix or Homebrew coreutils).

### Changed
- **Much lighter background scanning.** Cost, activity and tool figures used to
  re-read and re-decode every transcript from the last 30 days each minute
  (hundreds of MB to GBs). Decoded entries are now cached per file and only new
  lines are read; one bad byte no longer drops a whole file; the context-window
  scan only runs while the context row, the session grade or the dashboard
  shows it.

### Security
- **The sign-in listener also holds the IPv6 loopback port.** The redirect goes
  to `localhost`, which browsers may resolve to `::1` first, and only
  `127.0.0.1` was bound, so another local process could take `::1` and catch
  the redirect (blocking sign-in; PKCE kept the code from being used). The
  `::1` side is now reserved for the duration of sign-in.

## [1.8.0] — Signed-out menu bar

### Added
- **The menu bar says when you need to sign in.** An expired or missing
  session used to leave the last percentages frozen (just dimmed), which looked
  like stalled usage. The item now shows a ring locked by a keyhole and
  "Sign in"; while the browser sign-in is in flight the ring spins and reads
  "Signing in…". Usage returns as soon as you're signed in.

### Changed
- **"Sign in to Claude…" leads the menu when signed out**, instead of sitting
  below the status and credits rows.

## [1.7.7] — No more spurious reset notifications

### Fixed
- **"5-hour session reset" no longer fires while the window is still open.**
  The usage API returns the reset time with a different fraction of a second
  on each request, and any later value counted as a new window, so with usage
  above the warning threshold the notification repeated every few polls. A
  reset now needs the boundary to move by at least an hour. The weekly reset
  notification had the same bug and gets the same fix.

## [1.7.6] — Keychain item re-created on launch

### Security
- **The stored sign-in is re-created under the running build at every launch.**
  An item written by 1.7.4 or earlier kept trusting that non-hardened build
  after an update (approving the update prompt adds the new build without
  removing the old one), so the old binary started with an injected library
  could still read the tokens until the next sign-in or token refresh. Launch
  now deletes and re-adds the item, so only the current build is trusted. An
  item the app is refused access to, or can't decode, is deleted and you sign
  in again.

## [1.7.5] — Hardened runtime

### Security
- **Builds are signed with the hardened runtime.** The app is ad-hoc signed and
  its Keychain item trusts that signature, so without the runtime flag another
  program running as you could start the unmodified app with an injected library
  (`DYLD_INSERT_LIBRARIES`) and read the stored tokens without a prompt. Release
  and CI builds now fail if the flag is missing
  (`scripts/check-hardened-runtime.sh`). After updating, macOS may ask once for
  Keychain access, or you may need to sign in again.

## [1.7.4] — Sign-in hardening

### Security
- **Sign-in only accepts its own browser redirect.** The loopback listener now
  answers only a callback carrying the state of the sign-in in progress. A
  request with a missing or wrong state (for example from another local process
  racing the browser) gets an error page and no longer uses up the one-shot
  listener, and the automatic flow rejects a callback without state.
- **Tokens always go into a Keychain item ClaudeGlance created.** Saving used to
  update any existing item under our service name in place, keeping whatever
  access list it had, so another app could pre-create that item and read the
  tokens back. Saving now deletes and re-adds the item, and saves nothing if the
  old item can't be removed.
- **Release pipeline hardening.** Every action is pinned to a full commit SHA
  (Dependabot keeps them current), workflow tokens are least-privilege per job,
  and the Homebrew tap update runs in its own job that receives the DMG hash
  computed before any third-party action and only accepts plain version tags.

## [1.7.3] — Honest errors

### Fixed
- **No more fake "0%" when usage can't be loaded.** Before the first successful
  fetch the menu bar showed the zeroed placeholder as if it were real usage. It
  now shows a warning glyph (or a plain pie while loading) with `–%`, dimmed, and
  the error as a tooltip; the menu leads with the error and hides the empty rows.
- **Clearer throttling message.** An HTTP 429 from the usage endpoint read as
  "Rate limited", which sounded like your Claude plan limits. It now says
  Anthropic is throttling usage checks, that your limits are unaffected, and the
  clock time of the next retry. Server, offline and auth failures get their own
  short messages, and raw response bodies are never shown.
- **429 backoff honors `Retry-After`** (clamped to 1–60 min; 15 min if absent)
  and no longer discards a perfectly good token, which forced a needless token
  refresh on every throttled poll. Token-endpoint errors are no longer mistaken
  for usage-endpoint throttling.

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
- The Homebrew cask's `zap` list now includes `~/.claudeglance`, so
  `brew uninstall --zap` still means "remove everything". A plain uninstall
  leaves both copies, which is what keeps history across a reinstall.
- The loopback OAuth listener latches its continuation through a lock-guarded box
  instead of a captured `var`, clearing four Swift 6 concurrency warnings
  (mutating a captured `var` from a concurrently-executing closure is an error
  under the Swift 6 language mode). Behaviour is unchanged: still resumes once,
  and a `.ready` without a port still waits for a later one.

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

[1.0.0]: https://github.com/workshop144/claudeglance/releases/tag/v1.0.0
