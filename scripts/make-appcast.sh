#!/usr/bin/env bash
# Writes the one-item Sparkle appcast for a release to stdout (D-011). release.yml signs
# the DMG first, passes the signature here, then signs the feed itself with sign_update.
# The app reads releases/latest/download/appcast.xml, so each release's feed only needs
# its own item. Release notes are this version's CHANGELOG section, as Markdown.
#
# usage: make-appcast.sh <version> <dmg-length> <ed-signature> <minimum-macos> [CHANGELOG.md]
set -euo pipefail

version=${1:?version}; length=${2:?dmg length}; sig=${3:?ed signature}; minos=${4:?minimum macOS}
changelog=${5:-CHANGELOG.md}

[[ "$version" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]] || { echo "error: bad version '$version'" >&2; exit 1; }
[[ "$length" =~ ^[0-9]+$ ]] || { echo "error: bad length '$length'" >&2; exit 1; }
[[ "$sig" =~ ^[A-Za-z0-9+/]{86}==$ ]] || { echo "error: not an EdDSA signature" >&2; exit 1; }
[[ "$minos" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || { echo "error: bad minimum macOS '$minos'" >&2; exit 1; }

# This version's section: from "## [x.y.z]" up to the next "## [".
notes=$(awk -v h="## [$version]" '
  index($0, h) == 1 { on = 1; next }
  on && /^## \[/ { exit }
  on { print }' "$changelog")
[ -n "$(printf '%s' "$notes" | tr -d '[:space:]')" ] \
  || { echo "error: $changelog has no ## [$version] section" >&2; exit 1; }
case "$notes" in *']]>'*) echo "error: release notes contain ]]>" >&2; exit 1 ;; esac

url="https://github.com/workshop144/claudeglance/releases/download/v$version/ClaudeGlance.dmg"
date=$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')

cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>ClaudeGlance</title>
    <link>https://github.com/workshop144/claudeglance</link>
    <item>
      <title>$version</title>
      <pubDate>$date</pubDate>
      <sparkle:version>$version</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$minos</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/workshop144/claudeglance/releases/tag/v$version</sparkle:fullReleaseNotesLink>
      <description sparkle:format="markdown"><![CDATA[
$notes
]]></description>
      <enclosure url="$url" length="$length" type="application/octet-stream" sparkle:edSignature="$sig"/>
    </item>
  </channel>
</rss>
XML
