# Contributing to ClaudeGlance

Thanks for your interest in improving ClaudeGlance! This is a small MIT-licensed
project and contributions are welcome — bug reports, fixes, and features alike.

## Reporting bugs / requesting features

Open an [issue](https://github.com/broots144/claudeglance/issues). For bugs,
please include your macOS version, what you expected, what happened, and steps
to reproduce.

## Submitting a pull request

1. Fork the repo and create a branch off `main` (e.g. `fix/reset-countdown`).
2. Make your change. Keep it focused — one logical change per PR.
3. Make sure it builds and the tests pass (see below).
4. Push your branch and open a PR against `main` with a short description of
   what changed and why.

By submitting a PR you agree to license your contribution under the project's
[MIT License](LICENSE).

## Building and testing

ClaudeGlance is a Swift macOS menu bar app. The Xcode project is generated from
`project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen   # once
xcodegen generate       # regenerate ClaudeGlance.xcodeproj after editing project.yml

# Build
xcodebuild -scheme ClaudeGlance -configuration Release build

# Test
xcodebuild test -scheme ClaudeGlance -destination 'platform=macOS'
```

Or just open `ClaudeGlance.xcodeproj` in Xcode and run with ⌘R.

> **Note:** edit `project.yml`, not the generated `.xcodeproj` — the project file
> is regenerated and your manual edits there will be lost.

## Style

Match the surrounding code — naming, formatting, and comment density. No
enforced linter; keep diffs minimal and readable.
