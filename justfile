# ClaudeGlance tasks. `just check` is what CI runs; `just verify-release` gates a release PR.
# The Xcode project is generated: edit project.yml, then `just gen`.

dd := "build/dd"

default:
    @just --list

# Regenerate ClaudeGlance.xcodeproj from project.yml (commit the result).
gen:
    xcodegen generate

# Unit tests (same flags as CI).
test:
    #!/usr/bin/env bash
    set -euo pipefail
    xcodebuild test \
      -project ClaudeGlance.xcodeproj \
      -scheme ClaudeGlanceTests \
      -destination 'platform=macOS' \
      -derivedDataPath {{dd}} \
      CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
      -quiet

# Ad-hoc Release build, then fail unless it carries the hardened runtime (see LESSONS.md).
build-release:
    #!/usr/bin/env bash
    set -euo pipefail
    xcodebuild build \
      -project ClaudeGlance.xcodeproj \
      -scheme ClaudeGlance \
      -configuration Release \
      -derivedDataPath {{dd}} \
      CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
      -quiet
    scripts/check-hardened-runtime.sh {{dd}}/Build/Products/Release/ClaudeGlance.app

# Shell scripts parse (no enforced linter for Swift; see CONTRIBUTING.md).
lint:
    #!/usr/bin/env bash
    set -euo pipefail
    for f in scripts/*.sh; do bash -n "$f"; done
    echo "scripts parse"
    scripts/check-workflows.sh

# validate + lint + test + hardened release build. Mirrors the CI "Unit tests" job.
check: lint test build-release

# After the tag's DMG is published: scripts/update-flake.sh <version>, then `just verify-flake`.
# Release gate: check passes and project.yml's version has a CHANGELOG entry.
verify-release: check
    #!/usr/bin/env bash
    set -euo pipefail
    v="$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml)"
    grep -q "^## \[$v\]" CHANGELOG.md || { echo "error: CHANGELOG.md has no ## [$v] entry" >&2; exit 1; }
    echo "release $v: check passed, CHANGELOG entry present"

# flake.nix is pinned to the version in project.yml (true once the post-release pin PR lands).
verify-flake:
    #!/usr/bin/env bash
    set -euo pipefail
    v="$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml)"
    f="$(sed -n 's/^ *version = "\(.*\)";/\1/p' flake.nix)"
    [ "$v" = "$f" ] || { echo "error: flake.nix pins $f but project.yml is $v; run scripts/update-flake.sh $v" >&2; exit 1; }
    echo "flake pinned to $f"
