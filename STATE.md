# Current Build State

Last updated: 2026-11-10 by Claude: v1.8.4 released, the first Developer ID signed and notarized build. Flake re-pinned to 1.8.4; tap job moved to Linux.

## Phases (release lines)

- [x] v1.1 Sharper glance (v1.1.4)
- [x] v1.2 Foresight (v1.2.2)
- [x] v1.3 Memory (v1.3.4)
- [x] v1.4 Dashboard (v1.4.5), design in docs/plans/v1.4-dashboard.md
- [x] v1.5 Depth (v1.5.6)
- [x] v1.6 Reach (v1.6.5)
- [x] v1.7 Standalone sign-in and hardening (v1.7.0 to v1.7.7)
- [x] v1.8 Signed-out menu bar (v1.8.0, released 2026-10-15)
- [x] v1.8.1 Bug sweep (released 2026-11-06)
- [x] v1.8.2 Security hardening (released 2026-11-07): least-privilege scope, DMG provenance
- [x] v1.8.3 Review fixes (released 2026-11-07): session-generation guards, token error text, reset parsing, context window
- [x] v1.8.4 Signed and notarized [6] (released 2026-11-10), plan in docs/plans/v1.8.4-notarize.md
- [ ] Sparkle auto-update [13], WidgetKit [25]: unblocked once 1.8.4 ships notarized (D-009).
- [ ] Exploratory: real prepaid balance [23], multi-account [24]. Not started, demand unvalidated.

## What is true now

- Shipped version: 1.8.4 (tag v1.8.4 on 4f36d53, released 2026-11-10, release run
  42840745465). First Developer ID signed and notarized release: app and DMG both stapled;
  `spctl` on the downloaded DMG says "Notarized Developer ID", Workshop 144 LLC (Q4PR8D5TG8);
  `gh attestation verify` passes. DMG sha256 228913f8...; flake.nix pins 1.8.4 (this PR).
  The tap job was cancelled (no macOS runner within 15 minutes) and re-run; see Next for
  the cask check. The first notarization took about 35 minutes (new team, in-depth review).
  This Mac was upgraded with `brew upgrade --cask claudeglance` (1.8.1 to 1.8.3); the new build
  raised the usual post-update Keychain "allow access" prompt, which needs the operator's
  login password (see Next).
- CI minutes (2026-11-07): ci.yml skips docs-only changes (`**.md`, `docs/**`). Pushes use
  `paths-ignore`; PRs keep triggering so the STATE.md guard always runs, and a `changes` job
  lets the required macOS checks (Unit tests, Nix flake build) skip, failing closed if it errors.
  Repo is public, so hosted macOS/Linux minutes cost nothing; it stays off self-hosted runners.
- flake.lock (review L4): nixpkgs is locked to one commit of `nixpkgs-26.05-darwin` (moved off
  nixpkgs-unstable, which dropped x86_64-darwin; 26.05 is the last release with it).
  `scripts/check-flake-lock.sh` (CI Unit tests job and `just lint`) fails if the lock is
  missing, not on a 40-char rev with a narHash, or tracks a different branch than flake.nix.
  CI builds with `nix build --no-update-lock-file`. `scripts/update-flake.sh <version>` also
  refreshes the lock (nix if installed, else the digest-pinned nixos/nix:2.28.3 container via
  colima); `--lock-only` refreshes just the lock. Dependabot has no flake support we rely on,
  so the lock moves once per release by hand. Both darwin systems evaluate against the lock
  (checked in the container); the real darwin build is the CI "Nix flake build" job.
- v1.8.1 bug sweep (2026-11-06): token refresh is single-flight (SingleFlight) and a
  rejected refresh signs out only if the stored pair isn't newer; usage fetches run one at
  a time (FetchGate); weekly alerts re-arm after the reset; ResetTracker keeps the 5h
  boundary across null `resets_at`; statusline sidecar never shows placeholder or stale
  numbers as live and the script marks "(stale)"; failed incidents fetch keeps the last
  uptime; backups keep milliseconds and history merges per second; Opus 4/4.1 priced
  $15/$75; tool calls de-duplicated by tool_use id; TranscriptCache reads only appended
  transcript bytes and the context scan runs only while shown; symlinked settings.json
  kept; archive saves ordered; loopback sign-in reserves [::1] on its port and a replaced
  listener no longer hangs. OAuthLoginService has a `CredentialStore` seam for tests.
  Review follow-ups on PR #25: a 429 drops the coalesced fetch (backoff timer retries);
  history merge treats samples under 1s apart as one; a sign-out generation drops a
  refresh that finished after sign-out; TranscriptCache rereads a file whose byte before
  the cached offset changed; context row refreshes when it turns back on; statusline
  stale check uses /usr/bin/stat and digit-checks mtime. Still untested: a real browser
  sign-in with the [::1] reservation (Safari and Chrome) on a dev install; if it fails,
  revert 58dfb8e alone.
- Tests (2026-11-06 coverage pass): 310 tests. App line coverage 32.45% to 35.46%; excluding
  the AppKit/SwiftUI files (AppDelegate, SettingsView, DashboardView, main) 66.96% to 73.41%.
  Under XCTest (Debug builds only), HistoryStorage reads and writes a per-run temp folder
  (`HistoryStorage.testSandbox`, PID plus UUID, removed by a test observer when the bundle
  finishes), never ~/Library/Application Support/ClaudeGlance or ~/.claudeglance, so tests of
  the shared stores and the restore path cannot touch real history. StatusLineExporter.fileURL
  is built on `HistoryStorage.primaryDirectory`, so status.json follows the same rule.
  StatusService exposes awaitable `refreshStatus()` / `refreshIncidents()`;
  `StatusLineSetup.installScript(to:bundle:)` takes a destination. Still untested: UsageService
  `fetchUsage` end to end (needs a token seam on OAuthLoginService.shared), SettingsManager
  (writes the host app's real UserDefaults domain), MetricsService / ContextWindowService
  refresh (read real ~/.claude/projects), and the UI files.
- Sign-in scope (1.8.2, security L1): requests `user:profile` only (was `org:create_api_key
  user:profile user:inference`). Evidence it works: Claude Code's own `setup-token` asks this
  client for a single scope, and its strings name `user:profile` as the profile-endpoint scope.
  Fallback: a 403 from /api/oauth/usage whose body names a scope sets UserDefaults
  `oauthScopeFallback`, signs out and asks for one more sign-in, which then requests
  `user:profile user:inference`. Never org:create_api_key (unit-tested). Not yet verified by a
  real browser sign-in (an agent may not grant OAuth consent unasked): first sign-in after
  updating to 1.8.2 is the live check. Existing sessions keep their old broad-scope tokens
  until the user signs out and in (no forced re-login, documented as accepted Low).
- Session generation (1.8.3, review L1): every Keychain and cache write on the token slow path
  (`loadOrRefresh`) runs under `cacheLock` and checks the generation captured at entry
  (`persistIfCurrent`, `cacheIfCurrent`, `commitRefreshed`, `endRejectedSession`); a sign-in
  commits through `startSession` (bump, save, cache in one critical section). Tests park a
  `CredentialStore` call and race signOut / sign-in against it (SessionGenerationRaceTests).
- Background state (1.8.3, review L2): polls and refreshes change `state` through
  `backgroundAuthTransition`, which never leaves `.awaitingBrowser` or `.awaitingCode`.
- Token errors (1.8.3, review L6): `oauthTokenHTTPError` keeps only "HTTP <code>" in the
  description (body only under DEBUG); `signInFailureMessage` and `usageErrorMessage` give
  OAuthToken errors their own short text; a token 429 backs off by Retry-After like a usage 429.
- Reset times (1.8.3, review L7): `parseResetTimestamp` accepts `resets_at` with or without
  fractional seconds (Python isoformat drops a zero fraction).
- Context window (1.8.3, review L8): `contextWindowLimit` is version-aware. 1M for Opus 4.6+,
  Sonnet 4.6+ (`sonnet4MinorVersion`), Fable and ids ending "[1m]"; 200K for Opus 4/4.1/4.5,
  Sonnet 4/4.5, Haiku, Claude 3 and anything unrecognised (never overstate headroom).
- Sign-in: own OAuth 2.0 PKCE browser flow with a loopback listener bound to the
  request state (v1.7.4, PR #1 / #5). Tokens live in the app's own Keychain item
  `ClaudeGlance-credentials`, re-created under the running build at each launch (v1.7.6, PR #11).
  Signed out, the menu bar shows a locked ring and "Sign in" (v1.8.0, PR #16).
- Builds are ad-hoc signed with the hardened runtime; CI and release fail without it
  (`scripts/check-hardened-runtime.sh`, v1.7.5, PR #9). Not notarized.
- Release provenance (security L2): release.yml attests ClaudeGlance.dmg with
  actions/attest-build-provenance (SHA-pinned v4.2.2; job has id-token and attestations write).
  README documents `gh attestation verify ClaudeGlance.dmg -R workshop144/claudeglance`.
  `scripts/check-workflows.sh` (CI Unit tests job and `just lint`) fails on any `uses:` not
  pinned to a 40-char SHA, or if the attestation step or its permissions go missing.
- Release workflow publishes the DMG and updates the Homebrew tap with a tap-scoped
  deploy key (PR #8). Developer ID signing and notarization steps exist but are skipped
  until the Apple secrets are set.
- CI (`.github/workflows/ci.yml`): unit tests, hardened Release build, `nix build` of the
  flake, and (from this change) the STATE.md guard on PRs.
- CI and release run on the `macos-26` runner (Xcode 26.6 default) since 2026-11-06; they were
  on `macos-15` (Xcode 16). Swift language mode stays 5.9 (Swift 6 strict concurrency not adopted).
  release.yml has not yet run on macos-26 (first run is the next `v*` tag). make-dmg.sh bounds
  the Finder osascript with a watchdog (OSA_TIMEOUT, default 120s) and the Build DMG step has
  timeout-minutes: 15, so an Apple Events hang falls back to an unstyled DMG. If the tagged
  release fails on macos-26, set runs-on back to macos-15 and re-tag (it fails before publishing).
- Dependabot: weekly, grouped minor+patch and majors per ecosystem with a 3 day cooldown;
  n0's hourly merger squash-merges green PRs (ADR-089 in workshop144/sublevel, PRs #18 to #20).
- Local history persists in the app's own stores (daily-activity.json and utilization
  history), so streaks survive Claude Code's 30 day transcript cleanup (v1.7.2).
- No open issues or PRs on workshop144/claudeglance as of 2026-11-06. `gh` without `-R`
  lists the upstream fork's issues instead (see LESSONS.md).
- Branch `develop` (last commit 2026-09-28) has no diff against main; all work since
  v1.7.4 lands by PR to main.

Verified 2026-11-06 on this Mac, `just verify-release` on fix/bugs-2026-11-06:

```
Executed 282 tests, with 0 failures (0 unexpected)
** TEST SUCCEEDED **
build/dd/Build/Products/Release/ClaudeGlance.app: flags=0x10002(adhoc,runtime)
release 1.8.1: check passed, CHANGELOG entry present
```

Not verified by hand: a real browser sign-in against claude.ai after the loopback change
(tests cover `localhost` reaching the listener via the ::1 fallback). Try one sign-in
with `scripts/dev-install.sh` before or right after tagging.

`just verify-flake`: `flake pinned to 1.8.0`.

## Security

Grade: **A** (2026-11-07 rubric: no open Medium or higher; every open Low below is documented
with a reason). Not A+: the accepted and blocked Lows below stay open.

Round r2 (2026-11-07 review), all fixed:
- L1 (Low) sign-out/sign-in race on the token slow path: fixed, PR #30, v1.8.3.
- L2 (Info) signed-out poll wiped an in-flight sign-in state: fixed, PR #30, v1.8.3.
- L4 (Low) flake.nix had no flake.lock: fixed, PR #32.
- L6 (Info) raw token-endpoint bodies in the UI, no token 429 backoff: fixed, PR #30, v1.8.3.
- L7 (Info) whole-second `resets_at` parsed to nil: fixed, PR #31, v1.8.3.
- L8 (Info) context window overstated for older Opus/Sonnet: fixed, PR #31, v1.8.3.

Round r1 findings: L1 fixed (PR #27, v1.8.2), L2 fixed (PR #28, v1.8.2), L3 fixed (GitHub
ruleset change, no repo diff).

- L3 (2026-11-07): ruleset `protect-main` (id 24057473) now also has a `pull_request` rule
  (0 approvals, so autonomous squash-merges still work) and `required_status_checks`
  "Unit tests" and "Nix flake build" (GitHub Actions app, not strict), with no bypass actors.
  `gh api repos/workshop144/claudeglance/rules/branches/main` lists all four rules. n0's dependabot-merge.py merges with
  `gh pr merge --squash` after green checks, which the rule allows (dry run 2026-11-07: exit 0).
  To undo: `gh api -X PUT repos/workshop144/claudeglance/rulesets/24057473` with only the
  deletion and non_fast_forward rules.

Open Lows (documented, count toward A):
- Accepted: sessions signed in before 1.8.2 keep their broad-scope tokens
  (`org:create_api_key user:profile user:inference`) until the user signs out and back in.
  No forced re-login on upgrade: it would sign every user out for a risk that needs a
  prior token theft. The CHANGELOG tells users to re-sign-in to narrow their token.
- Blocked on the operator: the `user:profile`-only sign-in has not had a live browser sign-in
  yet (an agent does not grant OAuth consent unasked). Next step: on 1.8.3, sign out,
  sign in, check that usage loads. If the server refuses it for scope, the app falls back on
  its own (one extra sign-in). If the authorize page itself errors, revert the scope line.
- Blocked on money: DMG not notarized (Apple Developer account, see below). Provenance
  attestation and the brew/nix sha256 pins cover tampering in the meantime.
- Accepted: `pull_request` rule needs 0 approvals (single maintainer; autonomous merges).
  Required CI checks are the enforced gate.

Informational: the sign-in reuses Claude Code's public OAuth client (SECURITY.md). Defense in
depth already in place: least-privilege scope, SHA-pinned actions plus check-workflows.sh,
locked flake inputs plus check-flake-lock.sh, DMG provenance attestation, hardened runtime
check in CI, Keychain item re-created per build, PKCE plus loopback state binding.

## Open / BLOCKED

- Signing (done 2026-11-10): Developer ID Application certificate for team Q4PR8D5TG8,
  expires 2027-12-08; renew before then or releases fall back to failing the Gatekeeper check.
  Key, cert, .p12, the `claudeglance-ci` team API key (.p8, Developer role) and `set-secrets.sh`
  live in ~/.config/claudeglance-signing on n0, not in the repo; the operator should keep a
  backup. Repo secrets: `APPLE_CERTIFICATE_1`, `APPLE_CERTIFICATE_PASSWORD`, `APPLE_TEAM_ID`,
  `APPLE_API_KEY`, `APPLE_API_KEY_ID`, `APPLE_API_ISSUER`. The certificate is shared by every
  app the team ships; each repo should get its own `<repo>-ci` API key.
- Sparkle [13] and WidgetKit [25] are unblocked now that releases are signed (D-009).
- Mac App Store (reviewed 2026-11-08, not started): not viable as built. Blockers are the
  App Sandbox (off; ~/.claude reads and settings.json writes need folder grants), the reused
  Claude Code OAuth client id, and the "Claude" name (guideline 5.2). Needs Anthropic's
  answer on the last two before any code. Also missing for MAS: PrivacyInfo.xcprivacy,
  CURRENT_PROJECT_VERSION, LSApplicationCategoryType, ITSAppUsesNonExemptEncryption.
- `develop` is stale. Decide whether to delete it and drop it from ci.yml `push.branches`
  (scripts/dev-install.sh comments still describe the develop to main flow).
- One Swift 6 concurrency note (`ImplicitStrongCapture`) appears in the Release build; not a failure.

## Next

First: confirm broots144/homebrew-tap Casks/claudeglance.rb is at 1.8.4 with no caveats block
   (re-run the release's homebrew-tap job if not), then `brew upgrade --cask claudeglance` on
   this Mac and expect one Keychain prompt or a fresh sign-in (signature changed).
0. Operator: approve the Keychain prompt 1.8.3 raised on this Mac (Always Allow), check the
   menu bar shows usage, then sign out and in once to confirm the `user:profile` scope
   (see Security). If 1.8.3 misbehaves: `brew reinstall --cask claudeglance` after reverting
   PR #30 or #31 and tagging v1.8.4.
1. Delete or retire `develop` and update the dev-install.sh comment (small chore PR).
2. Roadmap [31] copy-usage-to-clipboard is the only small unbuilt item that fits the aesthetic.
3. Hardening list in ROADMAP.md (timezone correctness, multi-monitor placement) has no
   tests yet; pick one and add a test first. Big-jsonl streaming is done (TranscriptCache).
