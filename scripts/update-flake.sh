#!/usr/bin/env bash
#
# update-flake.sh <version> — point flake.nix at a released ClaudeGlance.dmg.
#
# Downloads the published release artifact, computes its SRI sha256, and rewrites
# the pinned `version` and `dmgHash` lines in flake.nix. Run this once after a
# public release ships (the DMG must already exist on the GitHub release) — it
# keeps the Nix package in step with the Homebrew cask, which CI updates itself.
#
# Done as a manual post-release step (not in CI) on purpose: flake.nix lives in
# this repo, so auto-committing it from the tag-triggered release would create the
# same develop↔main merge conflicts ROADMAP.md does. Bumping it by hand on the
# next develop change keeps history clean.
#
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/update-flake.sh <version, e.g. 1.6.5>}"
VERSION="${VERSION#v}"
URL="https://github.com/broots144/claudeglance/releases/download/v${VERSION}/ClaudeGlance.dmg"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "▸ Downloading $URL"
curl -fsSL -o "$tmp/ClaudeGlance.dmg" "$URL"

hex="$(shasum -a 256 "$tmp/ClaudeGlance.dmg" | awk '{print $1}')"
sri="sha256-$(printf '%s' "$hex" | xxd -r -p | base64)"
echo "▸ sha256 (hex): $hex"
echo "▸ sha256 (SRI): $sri"

# Rewrite the two pinned lines in place (BSD sed — this is a macOS project).
sed -i '' -E "s|^( *version = \").*(\";)|\1${VERSION}\2|" flake.nix
sed -i '' -E "s|^( *dmgHash = \").*(\";)|\1${sri}\2|" flake.nix

echo "▸ flake.nix now pins v${VERSION}. Review & commit:"
echo "    git diff flake.nix"
