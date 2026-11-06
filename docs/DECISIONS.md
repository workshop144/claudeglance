# Decisions

Short ADR log. Entries are never rewritten, only superseded by a later entry.
Decisions D-001 to D-008 were recorded retroactively on 2026-11-06 from the code,
ROADMAP.md and git history.

## D-001: Claude-only, glance-first scope (2026-06)
Stay a quiet menu-bar glance for Claude only. No multi-tool aggregation, leaderboards,
agent approve/deny, proxies, OpenTelemetry. Power features are opt-in so the default
view stays minimal. See ROADMAP.md "Deliberately NOT doing".

## D-002: Official OAuth usage endpoint, not web-session scraping (2026-06)
Utilization comes from `/api/oauth/usage` with an OAuth token, and local cost/activity
from `~/.claude/projects` jsonl. Scraping claude.ai cookies through a WebView breaks on
rotation, sleep and Google sign-in in competing apps.

## D-003: Own PKCE browser sign-in and own Keychain item (2026-06-16, v1.7.0)
Supersedes reading Claude Code's `Claude Code-credentials` item. The app runs its own
OAuth 2.0 PKCE flow with Claude's public client id, stores tokens in
`ClaudeGlance-credentials`, and refreshes them itself. Claude Code is no longer required.
Hardened in v1.7.4 (state-bound loopback) and v1.7.6 (item re-created at launch).

## D-004: Ad-hoc signing with hardened runtime until an Apple Developer account exists (2026-09-28, v1.7.5)
Releases are ad-hoc signed and must carry the hardened runtime. release.yml already
contains the Developer ID, notarize and staple steps, gated on secrets, so enrolling
flips releases to notarized with no workflow change.

## D-005: Notarization, Sparkle and WidgetKit ship together (2026-06-12)
Sparkle's value is seamless updates, which ad-hoc builds cannot give past Gatekeeper,
and widgets need an App Group and a real signature. All three wait on D-004's account.

## D-006: project.yml is the project source; XcodeGen generates the .xcodeproj (2026-06)
Edit project.yml and regenerate; the generated project is committed so a plain Xcode
open works.

## D-007: Nix flake tracks public releases and is re-pinned by hand (2026-06-12, v1.6.1)
flake.nix fetches the release DMG. `scripts/update-flake.sh` re-pins it in a follow-up
PR after each release; CI runs `nix build` on every push so the formula cannot rot.

## D-008: Trunk flow on main with Dependabot auto-merge (2026-09-26 onward)
Since the move to workshop144/claudeglance, changes land by PR to `main` and releases
are tagged from main. Dependabot runs weekly and n0's merger squash-merges green PRs
(ADR-089 in workshop144/sublevel).
