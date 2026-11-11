# ClaudeGlance: agent guide

Every session, before doing anything: read STATE.md, ROADMAP.md, LESSONS.md, then the task or phase prompt.

State is in the repo, not in memory. Update STATE.md when you finish meaningful work. Commit before stopping.

If stuck, write a clear BLOCKED entry in STATE.md with exact next steps.

## What this is

A public, MIT-licensed macOS menu-bar app (Swift, AppKit + SwiftUI) that shows Claude
plan usage (5h / 7d utilization from `/api/oauth/usage`) plus local cost and activity
parsed from `~/.claude/projects/**/*.jsonl`. Released as a DMG on GitHub, a Homebrew cask
and a Nix flake. User-facing docs: README.md, CHANGELOG.md, SECURITY.md, CONTRIBUTING.md.

## Files

- STATE.md: current truth (agent-owned). ROADMAP.md: phase table at the top, then the
  research feature list. LESSONS.md: one line per lesson. docs/DECISIONS.md: D-NNN log,
  superseded never rewritten. docs/plans/: a plan per phase, committed before building.
- CHANGELOG.md is the user-facing release log (Keep a Changelog). STATE.md is not a changelog.

## Build and verify

- `project.yml` is the source of truth; `just gen` (XcodeGen) regenerates
  `ClaudeGlance.xcodeproj`. Never hand-edit the .xcodeproj; commit the regenerated one.
- `just check`: script lint, unit tests, ad-hoc Release build with the hardened-runtime check.
  This is what CI's "Unit tests" job runs.
- `just verify-release`: check plus a CHANGELOG entry for the version in project.yml.
- `just verify-flake`: flake.nix pins the same version as project.yml.
- `scripts/dev-install.sh` builds and swaps the app into /Applications on this Mac for a
  manual try-out. It is not a release.

## Release flow

1. Feature or fix PR to `main` bumps `MARKETING_VERSION` in project.yml and adds a
   CHANGELOG entry; `just verify-release` passes.
2. After merge, push tag `vX.Y.Z` on main. `.github/workflows/release.yml` builds
   (ad-hoc signed until Apple signing secrets exist), publishes the DMG and updates the
   Homebrew tap via the tap deploy key.
3. Follow-up PR: `scripts/update-flake.sh X.Y.Z` re-pins flake.nix; `just verify-flake`.

## Rules

- Work in a git worktree on a branch, open a PR to `main`. There is no `develop` branch;
  betas, when needed, are a Sparkle channel built from `main` (D-013).
- `gh` defaults to the `upstream` remote (adntgv/claude-usage-systray). Always pass
  `-R workshop144/claudeglance` to gh commands.
- Public repo: never write the operator's real name, family, address, location, phone
  numbers or personal emails into files, commits, PR text or issues. Credit other
  projects by project name, not author handle.
- No em dashes or en dashes in STATE.md, ROADMAP.md (new text), LESSONS.md, docs/DECISIONS.md
  or this file.
- Keychain and sign-in code is security-sensitive: read SECURITY.md and the D-003 / D-004
  decisions before touching OAuthLoginService.swift or the Keychain item.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- CI guard: a PR that changes Sources/, Tests/, Resources/, scripts/, project.yml or
  flake.nix must also change STATE.md, unless its title starts with `chore` or `deps`
  (Dependabot titles start with `chore(deps)`).
