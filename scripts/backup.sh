#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$here/lib.sh"

exec 9>"${BACKUP_LOCK:-${TMPDIR:-/tmp}/claude-backup.lock}"
if ! flock -n 9; then
  log backup "already running, skipping"
  exit 0
fi

check_crypt_access || exit 1
"$here/lease.sh" check || exit 1
[[ -d "$HOME/.claude" ]] || { log backup "no ~/.claude yet, nothing to back up"; exit 0; }

if ! rclone sync "$HOME/.claude" "$BACKUP_REMOTE/claude" "${BACKUP_EXCLUDES[@]}" --quiet 2>&1; then
  log backup "ERROR sync failed"
  exit 1
fi
if [[ -f "$HOME/.claude.json" ]]; then
  # Only the login-related keys: the full file has machine ids, project entries and caches.
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT
  jq '{oauthAccount, hasCompletedOnboarding, userID, theme} | with_entries(select(.value != null))' \
    "$HOME/.claude.json" > "$tmp"
  rclone copyto "$tmp" "$BACKUP_REMOTE/claude.json" --quiet
fi
log backup "done"
