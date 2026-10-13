#!/usr/bin/env bash
# Install image-managed config: ~/work/CLAUDE.md (always refreshed) and the settings keys headless
# sessions need (merged into ~/.claude/settings.json, keeping everything else).
# Derived images extend both without touching this script:
#   config/CLAUDE.d/*.md    appended to ~/work/CLAUDE.md, in name order
#   config/settings.d/*.json  merged into settings.json, in name order (later files win)
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
config="${CONFIG_DIR:-$here/../config}"

mkdir -p "$HOME/work" "$HOME/.claude"
cp "$config/CLAUDE.md" "$HOME/work/CLAUDE.md"
for f in "${CLAUDE_D:-$config/CLAUDE.d}"/*.md; do
  [[ -f "$f" ]] || continue
  { echo; cat "$f"; } >> "$HOME/work/CLAUDE.md"
done

settings="$HOME/.claude/settings.json"
[[ -s "$settings" ]] || echo '{}' > "$settings"
if ! jq empty "$settings" 2>/dev/null; then
  echo "[seed-config] ERROR $settings is not valid JSON; leaving it untouched" >&2
  exit 1
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
# Without this key, `claude --dangerously-skip-permissions` waits on a confirmation dialog nobody can answer.
fragments=("$config/settings.json")
for f in "${SETTINGS_D:-$config/settings.d}"/*.json; do [[ -f "$f" ]] && fragments+=("$f"); done
jq -s 'reduce .[] as $x ({}; . * $x)' "$settings" "${fragments[@]}" > "$tmp"
mv "$tmp" "$settings"
