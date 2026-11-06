# Lessons

One line per lesson, newest first.

- 2026-11-06: `gh pr list` / `gh issue list` in this checkout listed the upstream fork (adntgv/claude-usage-systray) because the `upstream` remote is gh's default. Rule: always pass `-R workshop144/claudeglance`.
- 2026-10-31: Dependabot rejected the whole config because `semver-major-days` is not supported for github-actions, docker and pre-commit (PR #19). Rule: those ecosystems use `default-days` only; check Dependabot's run log after editing dependabot.yml.
- 2026-09-29: The usage API returns `resets_at` with a different sub-second fraction each request, so "session reset" notifications repeated every few polls (v1.7.7). Rule: compare reset boundaries with a tolerance (now at least one hour), never by exact timestamp.
- 2026-09-28: Updating the app added the new build to the Keychain item's trust list without removing the old one, so an older non-hardened binary could still read tokens (v1.7.6). Rule: re-create the Keychain item under the running build at launch.
- 2026-09-28: Builds lacked the hardened runtime, so a same-user process could start the ad-hoc signed app with `DYLD_INSERT_LIBRARIES` and read its Keychain tokens (v1.7.5). Rule: CI and release run `scripts/check-hardened-runtime.sh`; a build without the flag fails.
- 2026-09-26: The loopback sign-in listener accepted any callback, so a local process could race the browser and burn the one-shot listener (v1.7.4). Rule: bind the listener to the in-flight `state` and reject anything else without consuming it.
- 2026-09-17: Before the first successful fetch the zeroed placeholder rendered as a real "0%", so a broken connection looked like no usage, and a 429 read as the user's plan being limited (v1.7.3). Rule: show errors as errors, never as data.
- 2026-09-13: Streaks were recomputed from transcripts that Claude Code deletes after 30 days, so history quietly eroded (v1.7.2). Rule: persist rollups in the app's own store and merge max-wins.
- 2026-06-16: Reading Claude Code's Keychain item cross-app re-prompted for the password about daily, because the CLI deletes and re-creates it on token refresh, wiping the ACL (v1.7.0). Rule: the app owns its own Keychain item and updates it in place.
- 2026-06-12: Context-window fill hardcoded 200K and read about 5x too full for 1M-context models (v1.6.5). Rule: derive per-model limits from the model id; do not hardcode one model's numbers.
- 2026-06-12: Auto-committing flake.nix from the tag-triggered release would have caused develop/main merge conflicts. Rule: re-pin the flake by hand in a follow-up PR (`scripts/update-flake.sh`).
- 2026-06-11: The manual Refresh button could hammer the usage endpoint into a self-inflicted 429 (v1.5.3). Rule: throttle user-triggered refreshes.
- 2026-06-10: CI ran `xcodebuild test | grep`, which returned grep's exit code, so failing tests passed CI. Rule: `set -o pipefail` and no output-swallowing pipes in CI steps.
