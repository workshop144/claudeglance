#!/usr/bin/env bash
#
# claudeglance-statusline.sh — a Claude Code statusline that reuses ClaudeGlance's
# numbers. ClaudeGlance writes its current usage to a small JSON sidecar on each
# poll; this script just reads that file, so it's instant on every render — no API
# calls, no log parsing.
#
# Wire it up in ~/.claude/settings.json (the app's Settings can do this for you):
#   "statusLine": { "type": "command", "command": "~/.claude/claudeglance-statusline.sh" }
#
# Claude Code pipes a JSON context on stdin (model, cwd, …). We use the model's
# display name as a prefix when jq is available; the usage segment comes entirely
# from the sidecar. Deliberately defensive (no `set -e`) so a statusline never
# blanks out on a transient hiccup.

SIDECAR="$HOME/Library/Application Support/ClaudeGlance/status.json"

# Claude Code's stdin context — optional, only used as a prefix, only with jq.
stdin_json="$(cat 2>/dev/null)"
model=""
if command -v jq >/dev/null 2>&1 && [ -n "$stdin_json" ]; then
  model="$(printf '%s' "$stdin_json" | jq -r '.model.display_name // empty' 2>/dev/null)"
fi

# The ClaudeGlance usage segment. Prefer jq (reads the structured `line`); fall
# back to a quote-safe sed extraction so it still works without jq installed.
usage=""
if [ -f "$SIDECAR" ]; then
  if command -v jq >/dev/null 2>&1; then
    usage="$(jq -r '.line // empty' "$SIDECAR" 2>/dev/null)"
  else
    usage="$(sed -n 's/.*"line"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$SIDECAR" | head -n 1)"
  fi
fi

# Compose "<model>  <usage>" when both exist, else whichever we have. If the
# sidecar is missing (app not running / hasn't polled yet), fall back to the model
# alone so the statusline still shows something useful.
if [ -n "$model" ] && [ -n "$usage" ]; then
  printf '%s  %s\n' "$model" "$usage"
elif [ -n "$usage" ]; then
  printf '%s\n' "$usage"
elif [ -n "$model" ]; then
  printf '%s\n' "$model"
else
  printf 'ClaudeGlance: no data yet\n'
fi
