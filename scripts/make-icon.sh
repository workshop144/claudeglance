#!/usr/bin/env bash
#
# Regenerate the app icon from scripts/make-icon.swift: populates the
# AppIcon.appiconset (all 10 macOS slots) and builds AppIcon.icns (used as the
# DMG volume icon). Re-run after editing make-icon.swift.
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
RES="$ROOT/claude-usage-systray/Resources"
APPICON="$RES/Assets.xcassets/AppIcon.appiconset"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Render each unique pixel size natively (crisper than downscaling one image).
for s in 16 32 64 128 256 512 1024; do
  swift "$HERE/make-icon.swift" "$s" "$TMP/$s.png"
done

# --- AppIcon.appiconset (one PNG per slot) ---
cp "$TMP/16.png"   "$APPICON/icon_16.png"
cp "$TMP/32.png"   "$APPICON/icon_16@2x.png"
cp "$TMP/32.png"   "$APPICON/icon_32.png"
cp "$TMP/64.png"   "$APPICON/icon_32@2x.png"
cp "$TMP/128.png"  "$APPICON/icon_128.png"
cp "$TMP/256.png"  "$APPICON/icon_128@2x.png"
cp "$TMP/256.png"  "$APPICON/icon_256.png"
cp "$TMP/512.png"  "$APPICON/icon_256@2x.png"
cp "$TMP/512.png"  "$APPICON/icon_512.png"
cp "$TMP/1024.png" "$APPICON/icon_512@2x.png"

cat > "$APPICON/Contents.json" <<'JSON'
{
  "images" : [
    { "idiom" : "mac", "scale" : "1x", "size" : "16x16",   "filename" : "icon_16.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "16x16",   "filename" : "icon_16@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "32x32",   "filename" : "icon_32.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "32x32",   "filename" : "icon_32@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "128x128", "filename" : "icon_128.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "128x128", "filename" : "icon_128@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "256x256", "filename" : "icon_256.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "256x256", "filename" : "icon_256@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "512x512", "filename" : "icon_512.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "512x512", "filename" : "icon_512@2x.png" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

# --- AppIcon.icns (DMG volume icon) ---
ISET="$TMP/AppIcon.iconset"
mkdir -p "$ISET"
cp "$TMP/16.png"   "$ISET/icon_16x16.png"
cp "$TMP/32.png"   "$ISET/icon_16x16@2x.png"
cp "$TMP/32.png"   "$ISET/icon_32x32.png"
cp "$TMP/64.png"   "$ISET/icon_32x32@2x.png"
cp "$TMP/128.png"  "$ISET/icon_128x128.png"
cp "$TMP/256.png"  "$ISET/icon_128x128@2x.png"
cp "$TMP/256.png"  "$ISET/icon_256x256.png"
cp "$TMP/512.png"  "$ISET/icon_256x256@2x.png"
cp "$TMP/512.png"  "$ISET/icon_512x512.png"
cp "$TMP/1024.png" "$ISET/icon_512x512@2x.png"
iconutil -c icns "$ISET" -o "$RES/AppIcon.icns"

echo "Populated AppIcon.appiconset and wrote $RES/AppIcon.icns"
