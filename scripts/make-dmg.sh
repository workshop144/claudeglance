#!/usr/bin/env bash
#
# Build a drag-to-Applications .dmg from a built .app bundle — the classic
# window with the app icon on the left and an Applications-folder alias on the
# right. Uses only hdiutil + Finder scripting (no create-dmg dependency).
#
# Usage:
#   scripts/make-dmg.sh <path/to/App.app> [output.dmg]
#
# Env:
#   VOL_NAME   Volume / window title (default: the app's base name)
#
set -euo pipefail

APP_PATH="${1:?usage: make-dmg.sh <App.app> [output.dmg]}"
[ -d "$APP_PATH" ] || { echo "error: '$APP_PATH' is not an .app bundle"; exit 1; }

APP_NAME="$(basename "$APP_PATH" .app)"
VOL_NAME="${VOL_NAME:-$APP_NAME}"
OUT_DMG="${2:-$APP_NAME.dmg}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/stage"
mkdir -p "$STAGE"

# Stage the app + a symlink to /Applications so the user can drag across.
cp -R "$APP_PATH" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# Read-write image sized to the staged content.
TMP_DMG="$WORK/rw.dmg"
hdiutil create -srcfolder "$STAGE" -volname "$VOL_NAME" -fs HFS+ \
  -format UDRW -ov "$TMP_DMG" >/dev/null

# Mount at the default /Volumes/<VOL_NAME> location (NOT a custom mountpoint) so
# Finder can address the disk by name for the icon layout. Finder scripting is
# best-effort: if Apple Events aren't authorized (e.g. headless CI) the DMG still
# ships, just without the custom positioning — both icons are present and
# draggable either way.
hdiutil attach "$TMP_DMG" -noverify -noautoopen >/dev/null
MOUNT_POINT="/Volumes/$VOL_NAME"
for _ in $(seq 1 10); do [ -d "$MOUNT_POINT" ] && break; sleep 0.5; done

osascript <<OSA || echo "warning: could not set DMG window layout (Apple Events not authorized?) — shipping unstyled"
tell application "Finder"
  tell disk "$VOL_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 740, 470}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 120
    set position of item "$APP_NAME.app" of container window to {150, 175}
    set position of item "Applications" of container window to {390, 175}
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA

sync
hdiutil detach "$MOUNT_POINT" >/dev/null

# Compress to a distributable read-only image.
rm -f "$OUT_DMG"
hdiutil convert "$TMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$OUT_DMG" >/dev/null

echo "Created $OUT_DMG"
