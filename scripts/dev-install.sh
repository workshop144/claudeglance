#!/usr/bin/env bash
#
# dev-install.sh — the local "test this feature" loop.
#
# Runs the tests, builds an ad-hoc Release, swaps the app into /Applications,
# relaunches it, and posts a notification so you can try the change immediately.
#
# This is NOT a release: no Developer ID signing, no notarization, no git tag,
# no Homebrew update. Those happen only when `develop` merges to `main` and a
# `vX.Y.Z` tag fires .github/workflows/release.yml.
#
# Note: this overwrites /Applications/ClaudeGlance.app even if Homebrew installed
# it — brew will still think the cask version is installed until the next
# `brew upgrade`/reinstall. That's expected for local dev builds.
#
set -euo pipefail
cd "$(dirname "$0")/.."

echo "▸ Running tests…"
xcodebuild test \
  -project ClaudeGlance.xcodeproj \
  -scheme ClaudeGlanceTests \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  -quiet

echo "▸ Building Release (ad-hoc)…"
xcodebuild \
  -project ClaudeGlance.xcodeproj \
  -scheme ClaudeGlance \
  -configuration Release \
  -derivedDataPath build/dd \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=YES \
  build -quiet

APP="build/dd/Build/Products/Release/ClaudeGlance.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")

echo "▸ Installing v$VERSION to /Applications…"
osascript -e 'quit app "ClaudeGlance"' >/dev/null 2>&1 || true
pkill -x ClaudeGlance >/dev/null 2>&1 || true
sleep 1
rm -rf /Applications/ClaudeGlance.app
cp -R "$APP" /Applications/ClaudeGlance.app
xattr -dr com.apple.quarantine /Applications/ClaudeGlance.app 2>/dev/null || true
open /Applications/ClaudeGlance.app

osascript -e "display notification \"v$VERSION is live in your menu bar — test it and let me know.\" with title \"ClaudeGlance dev build installed\"" >/dev/null 2>&1 || true
echo "▸ Done — v$VERSION installed and launched."
