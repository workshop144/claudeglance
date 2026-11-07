#!/usr/bin/env bash
# flake.lock guard (review L4, 2026-11-07): the nixpkgs input must be locked to one
# commit, and the lock must match the branch flake.nix asks for, so `nix build`
# (CI and users) never floats to whatever the branch head is that day.
# Runs in CI (Unit tests job) and in `just lint`.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f flake.lock ] || { echo "error: flake.lock is missing; run scripts/update-flake.sh --lock-only" >&2; exit 1; }
want="$(sed -n 's|^ *inputs\.nixpkgs\.url = "github:NixOS/nixpkgs/\(.*\)";|\1|p' flake.nix)"
[ -n "$want" ] || { echo "error: can't read the nixpkgs input from flake.nix" >&2; exit 1; }
/usr/bin/python3 -I - "$want" <<'PY'
import json, re, sys
want = sys.argv[1]
lock = json.load(open("flake.lock"))
node = lock["nodes"].get(lock["nodes"][lock["root"]]["inputs"].get("nixpkgs", ""), {})
locked, original = node.get("locked", {}), node.get("original", {})
errors = []
if original.get("ref") != want:
    errors.append(f"flake.lock tracks {original.get('ref')!r} but flake.nix asks for {want!r}")
if not re.fullmatch(r"[0-9a-f]{40}", locked.get("rev", "")):
    errors.append("nixpkgs is not locked to a 40-char commit")
if not locked.get("narHash", "").startswith("sha256-"):
    errors.append("nixpkgs lock has no narHash")
for e in errors:
    print(f"error: {e}; run scripts/update-flake.sh --lock-only", file=sys.stderr)
if errors:
    sys.exit(1)
print(f"flake.lock pins nixpkgs {want} at {locked['rev'][:12]}")
PY
