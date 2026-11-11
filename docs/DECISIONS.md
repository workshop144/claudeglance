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

## D-009: Developer ID signing and notarization in 1.8.4 (2026-11-08)
Partly supersedes D-004 and D-005. The Workshop 144 LLC Apple Developer account exists,
so 1.8.4 ships Developer ID signed and notarized (app and DMG) for the DMG, cask and flake.
Notarization ships alone, ahead of Sparkle and WidgetKit, because it removes the Gatekeeper
step for every install today. CI signs manually (temp keychain, no Xcode account) and the
release fails if `stapler validate` or `spctl` rejects the build. Notarization authenticates
with a team App Store Connect API key, not an Apple ID app-specific password.
Mac App Store distribution is a separate track and is not covered here: it needs the App
Sandbox (folder access grants for ~/.claude), a sanctioned OAuth client, and a name cleared
for the Claude trademark.

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

## D-010: Sparkle and WidgetKit ship as separate releases (2026-11-10)
Supersedes D-005. Sparkle ships first as 1.9.0 and widgets follow as 1.10.0. D-005 bundled
them so signing was set up once; 1.8.4 already did that (D-009). Shipping Sparkle first
means the widget release reaches DMG users by auto-update, and each release changes one
risky thing (the update path, then the App Group and sandboxed extension).

## D-011: Sparkle feed as a signed release asset; updates off for Nix and unsigned builds (2026-11-10, v1.9.0)
Sparkle 2 with EdDSA. appcast.xml is generated and signed by release.yml and uploaded to
each GitHub release; the app reads `releases/latest/download/appcast.xml`, so there is no
Pages site and CI never commits. The app requires a signed feed. The private key lives in
the n0 login Keychain, ~/.config/claudeglance-signing and LastPass; CI gets it as
SPARKLE_ED_PRIVATE_KEY. The updater is off inside /nix/store (read-only) and for builds
not signed by team Q4PR8D5TG8. The Homebrew cask declares `auto_updates true`.

## D-012: Widgets parked until a user asks (2026-11-11)
Partly supersedes D-010, which planned widgets as 1.10.0. WidgetKit [25] is not built: the
operator would not look at a widget instead of the menu bar, it was the lowest rated item
(one star), and it adds a sandboxed extension and an App Group to maintain for a second
glance surface. A spike showed it is cheap to revive: a Developer ID widget with a
team-prefixed App Group needs no provisioning profile or new secret (STATE.md, Next).
Revisit on a user request.
