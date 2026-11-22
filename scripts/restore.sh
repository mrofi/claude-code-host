#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$here/lib.sh"

check_crypt_access || exit 1

# --extra: the directories of BACKUP_EXTRA_DIRS, run on its own so a large one cannot hold up the rest.
if [[ "${1:-}" == --extra ]]; then
  rm -rf "$RESTORED_MARKS"; mkdir -p "$RESTORED_MARKS"
  (( ${#EXTRA_NAMES[@]} )) || exit 0
  if ! top="$(rclone lsf "$BACKUP_REMOTE" 2>/dev/null)"; then
    log restore "ERROR cannot reach backup remote: BACKUP_EXTRA_DIRS not restored, and not backed up until the next boot"
    exit 1
  fi
  saved=""
  grep -qx 'extra/' <<<"$top" && saved="$(rclone lsf "$BACKUP_REMOTE/extra" 2>/dev/null || true)"
  failed=0
  for n in "${EXTRA_NAMES[@]}"; do
    d="${EXTRA_DIRS[$n]}"
    if grep -qx "$n/" <<<"$saved"; then
      mkdir -p "$d"
      if ! rclone copy "$BACKUP_REMOTE/extra/$n" "$d" --quiet 2>&1; then
        log restore "ERROR $n could not be restored, and is not backed up until the next boot"
        failed=1
        continue
      fi
      log restore "$n restored into $d"
    fi
    touch "$RESTORED_MARKS/$n"
  done
  exit "$failed"
fi

mkdir -p "$HOME/.claude"

# stdout only: rclone writes notices to stderr, which must not count as "remote has files".
if ! listing="$(rclone lsf "$BACKUP_REMOTE" 2>/dev/null)"; then
  log restore "ERROR cannot reach backup remote (continuing without restore)"
  exit 1
fi
# The lease object (see lease.sh) is not backup content, and extra/ is restored by --extra.
listing="$(grep -vx 'lease\|extra/' <<<"$listing" || true)"
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
