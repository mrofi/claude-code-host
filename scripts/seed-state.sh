#!/usr/bin/env bash
# Seed ~/.claude.json so Claude Code starts headless: workspace trusted, Remote Control
# dialog already answered. Existing keys are kept. See docs/spike-remote-control.md.
set -euo pipefail

workdir="${1:?usage: seed-state.sh <workdir>}"
file="$HOME/.claude.json"
[[ -s "$file" ]] || echo '{}' > "$file"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
jq --arg w "$workdir" \
  '.projects[$w].hasTrustDialogAccepted = true | .remoteDialogSeen = true' \
  "$file" > "$tmp"
mv "$tmp" "$file"
chmod 600 "$file"
