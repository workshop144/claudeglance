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
# It also refreshes flake.lock (the nixpkgs commit the build tooling comes from,
# review L4) so the lock moves forward once per release instead of floating.
# `scripts/update-flake.sh --lock-only` refreshes just the lock. Uses `nix` when
# installed, otherwise a digest-pinned nixos/nix container (Docker or colima;
# the temp folder sits under $HOME because colima shares only that).
#
set -euo pipefail
cd "$(dirname "$0")/.."

NIX_IMAGE="nixos/nix:2.28.3@sha256:e623d73af9cac82d1b50784c83e0cf2a4b83bfd2cfe8d5b67809a2fc94e043ac"
NIXFLAGS=(--extra-experimental-features "nix-command flakes")

refresh_lock() {
  echo "▸ Refreshing flake.lock"
  if command -v nix >/dev/null 2>&1; then
    nix "${NIXFLAGS[@]}" flake update
  elif command -v docker >/dev/null 2>&1; then
    local work
    work="$(mktemp -d "$HOME/.claudeglance-flake-lock.XXXXXX")"
    cp flake.nix "$work/"
    (cd "$work" && git init -q && git add flake.nix)
    docker run --rm -v "$work:/src" -w /src "$NIX_IMAGE" sh -c \
      "git config --global --add safe.directory '*' && nix --extra-experimental-features 'nix-command flakes' flake lock" \
      || { rm -rf "$work"; echo "error: nix flake lock failed in the container" >&2; return 1; }
    cp "$work/flake.lock" flake.lock
    rm -rf "$work"
  else
    echo "error: refreshing flake.lock needs nix or docker" >&2
    return 1
  fi
  scripts/check-flake-lock.sh
}

if [ "${1:-}" = "--lock-only" ]; then
  refresh_lock
  exit 0
fi

VERSION="${1:?usage: scripts/update-flake.sh <version, e.g. 1.6.5> | --lock-only}"
VERSION="${VERSION#v}"
URL="https://github.com/workshop144/claudeglance/releases/download/v${VERSION}/ClaudeGlance.dmg"

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

refresh_lock

echo "▸ flake.nix now pins v${VERSION}. Review & commit:"
echo "    git diff flake.nix flake.lock"
