#!/usr/bin/env bash
# Supply-chain guard for .github/workflows (security round 2026-11-07):
#  - every third-party `uses:` is pinned to a full 40-char commit SHA;
#  - the release job attests the DMG's build provenance with the permissions it needs.
# Runs in CI (Unit tests job) and in `just lint`.
set -euo pipefail
cd "$(dirname "$0")/.."
fail=0
while IFS= read -r line; do
  ref="${line#*uses:}"; ref="${ref%%#*}"; ref="$(echo "$ref" | tr -d ' "'"'")"
  case "$ref" in ./*|docker://*) continue ;; esac
  if ! [[ "$ref" =~ @[0-9a-f]{40}$ ]]; then
    echo "error: not pinned to a commit SHA: $ref ($line)" >&2; fail=1
  fi
done < <(grep -hE '^[[:space:]]*-?[[:space:]]*uses:' .github/workflows/*.yml)

rel=.github/workflows/release.yml
grep -qE 'uses: actions/attest-build-provenance@[0-9a-f]{40}' "$rel" \
  || { echo "error: $rel does not attest build provenance" >&2; fail=1; }
grep -qE '^[[:space:]]+subject-path: ClaudeGlance\.dmg$' "$rel" \
  || { echo "error: provenance subject is not ClaudeGlance.dmg" >&2; fail=1; }
for perm in 'id-token: write' 'attestations: write'; do
  grep -qE "^[[:space:]]+$perm\$" "$rel" || { echo "error: $rel release job lacks '$perm'" >&2; fail=1; }
done
# Workflow-level token stays read-only / empty by default.
grep -qE '^permissions: \{\}$' "$rel" || { echo "error: $rel must default to 'permissions: {}'" >&2; fail=1; }
grep -qE '^permissions:$' .github/workflows/ci.yml || { echo "error: ci.yml has no top-level permissions" >&2; fail=1; }

[ "$fail" = 0 ] && echo "workflows pinned; release attests provenance"
exit "$fail"
