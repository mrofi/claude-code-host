#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$here/lib.sh"

mkdir -p "$HOME/.claude"

check_crypt_access || exit 1

# stdout only: rclone writes notices to stderr, which must not count as "remote has files".
if ! listing="$(rclone lsf "$BACKUP_REMOTE" 2>/dev/null)"; then
  log restore "ERROR cannot reach backup remote (continuing without restore)"
  exit 1
fi
# The lease object (see lease.sh) is not backup content.
listing="$(grep -vx 'lease' <<<"$listing" || true)"
if [[ -z "$listing" ]]; then
  log restore "nothing to restore (empty remote)"
  exit 0
fi

rclone copy "$BACKUP_REMOTE/claude" "$HOME/.claude" --quiet
if rclone lsf "$BACKUP_REMOTE/claude.json" >/dev/null 2>&1; then
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT
  rclone copyto "$BACKUP_REMOTE/claude.json" "$tmp" --quiet
  if [[ -f "$HOME/.claude.json" ]]; then
    # Keep local machine-specific keys; restored login keys win.
    jq -s '.[0] * .[1]' "$HOME/.claude.json" "$tmp" > "$tmp.merged"
    mv "$tmp.merged" "$HOME/.claude.json"
  else
    cp "$tmp" "$HOME/.claude.json"
  fi
fi

chmod 700 "$HOME/.claude"
[[ -f "$HOME/.claude/.credentials.json" ]] && chmod 600 "$HOME/.claude/.credentials.json"
[[ -f "$HOME/.claude.json" ]] && chmod 600 "$HOME/.claude.json"
log restore "done"
