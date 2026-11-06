# Current Build State

Last updated: 2026-11-06 by Claude: retrofit of the repo-state pattern (STATE, LESSONS, DECISIONS, justfile, CI guard).

## Phases (release lines)

- [x] v1.1 Sharper glance (v1.1.4)
- [x] v1.2 Foresight (v1.2.2)
- [x] v1.3 Memory (v1.3.4)
- [x] v1.4 Dashboard (v1.4.5), design in docs/plans/v1.4-dashboard.md
- [x] v1.5 Depth (v1.5.6)
- [x] v1.6 Reach (v1.6.5)
- [x] v1.7 Standalone sign-in and hardening (v1.7.0 to v1.7.7)
- [x] v1.8 Signed-out menu bar (v1.8.0, released 2026-10-15)
- [ ] Signing cluster: notarize [6], Sparkle auto-update [13], WidgetKit [25]. BLOCKED, see below.
- [ ] Exploratory: real prepaid balance [23], multi-account [24]. Not started, demand unvalidated.

## What is true now

- Shipped version: 1.8.0 (project.yml `MARKETING_VERSION`, tag v1.8.0, GitHub release
  "Latest" on workshop144/claudeglance). flake.nix pins 1.8.0 (PR #17).
- Sign-in: own OAuth 2.0 PKCE browser flow with a loopback listener bound to the
  request state (v1.7.4, PR #1 / #5). Tokens live in the app's own Keychain item
  `ClaudeGlance-credentials`, re-created under the running build at each launch (v1.7.6, PR #11).
  Signed out, the menu bar shows a locked ring and "Sign in" (v1.8.0, PR #16).
- Builds are ad-hoc signed with the hardened runtime; CI and release fail without it
  (`scripts/check-hardened-runtime.sh`, v1.7.5, PR #9). Not notarized.
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

Verified 2026-11-06 on this Mac, `just verify-release` at 85a2b0e plus this change:

```
Executed 243 tests, with 0 failures (0 unexpected)
** TEST SUCCEEDED **
build/dd/Build/Products/Release/ClaudeGlance.app: flags=0x10002(adhoc,runtime)
release 1.8.0: check passed, CHANGELOG entry present
```

`just verify-flake`: `flake pinned to 1.8.0`.

## Open / BLOCKED

- BLOCKED: notarization [6], and with it Sparkle [13] and WidgetKit [25], need an Apple
  Developer account. Next step for the operator: enroll, then add repo secrets
  `APPLE_CERTIFICATE_1`, `APPLE_CERTIFICATE_2`, `APPLE_CERTIFICATE_PASSWORD`, `APPLE_ID`,
  `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`. release.yml switches to Developer ID + notarize
  automatically once all are present. Then write docs/plans/signing.md before building Sparkle.
- `develop` is stale. Decide whether to delete it and drop it from ci.yml `push.branches`
  (scripts/dev-install.sh comments still describe the develop to main flow).
- One Swift 6 concurrency note (`ImplicitStrongCapture`) appears in the Release build; not a failure.

## Next

1. Delete or retire `develop` and update the dev-install.sh comment (small chore PR).
2. Roadmap [31] copy-usage-to-clipboard is the only small unbuilt item that fits the aesthetic.
3. Hardening list in ROADMAP.md (timezone correctness, multi-monitor placement, big-jsonl
   streaming) has no tests yet; pick one and add a test first.
