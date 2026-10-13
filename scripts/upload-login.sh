#!/usr/bin/env bash
# One-time (or on re-login) upload of the Claude login to the backup remote. Run it from your own
# machine, not inside the container. Copies only two files and never deletes anything on the remote.
#   upload-login.sh <path/to/.credentials.json> <path/to/.claude.json>
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$here/lib.sh"

creds="${1:?usage: upload-login.sh <.credentials.json> <.claude.json>}"
cjson="${2:?usage: upload-login.sh <.credentials.json> <.claude.json>}"
[[ -f "$creds" && -f "$cjson" ]] || { log upload-login "ERROR input file not found"; exit 2; }

check_crypt_access || exit 1

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
# Same minimal key set as backup.sh: never upload machine ids, projects or caches.
jq '{oauthAccount, hasCompletedOnboarding, userID, theme} | with_entries(select(.value != null))' \
  "$cjson" > "$tmp"

rclone copyto "$creds" "$BACKUP_REMOTE/claude/.credentials.json" --quiet
rclone copyto "$tmp" "$BACKUP_REMOTE/claude.json" --quiet
log upload-login "done"
