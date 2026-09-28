#!/usr/bin/env bash
# Fail unless the given app's code signature carries the hardened runtime flag.
# Without it, a same-user process can launch the signed binary with
# DYLD_INSERT_LIBRARIES and read the keychain item that trusts that binary.
set -euo pipefail
app="${1:?usage: check-hardened-runtime.sh path/to/ClaudeGlance.app}"
flags="$(codesign -dv --verbose=4 "$app" 2>&1 | sed -n 's/^CodeDirectory .*flags=\([^ ]*\).*/\1/p')"
echo "$app: flags=$flags"
case "$flags" in
  *runtime*) ;;
  *) echo "error: $app is not signed with the hardened runtime" >&2; exit 1 ;;
esac
