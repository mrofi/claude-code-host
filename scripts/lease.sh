#!/usr/bin/env bash
# Guard against two live instances writing to the same backup prefix (they would overwrite each
# other's login and history). A small lease object lives next to the backup: "<instance id> <epoch>".
#   lease.sh take     boot: claim the prefix (warns if another instance held a fresh lease)
#   lease.sh check    before each backup: refuse if another instance holds a fresh lease, else renew
#   lease.sh release  shutdown: remove the lease if it is still ours
# The newest instance wins. Only active when an instance id exists (the entrypoint creates it).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$here/lib.sh"

# The entrypoint exports INSTANCE_ID and also writes it to a file for callers outside its process tree.
if [[ -z "${INSTANCE_ID:-}" && -r "$HOME/.cache/claude-host/instance-id" ]]; then
  INSTANCE_ID="$(cat "$HOME/.cache/claude-host/instance-id")"
fi
[[ -n "${INSTANCE_ID:-}" ]] || exit 0
ttl="${LEASE_TTL:-900}"
now="$(date +%s)"

read_lease() { rclone cat "$BACKUP_REMOTE/lease" 2>/dev/null | head -c 200 || true; }
# Upload from a real file with copyto, like claude.json: a streamed rcat upload to a crypt remote on
# IDrive e2 fails with "corrupted on transfer: md5 crypted hash differ".
write_lease() {
  local tmp rc=0
  tmp="$(mktemp)"
  printf '%s %s\n' "$INSTANCE_ID" "$now" > "$tmp"
  rclone copyto "$tmp" "$BACKUP_REMOTE/lease" --quiet || rc=$?
  rm -f "$tmp"
  return "$rc"
}
# A lease that cannot be written is a warning, never a reason to skip a backup.
write_lease_or_warn() { write_lease || log lease "WARNING could not write the lease (backup continues)"; }

read -r owner stamp <<<"$(read_lease)" || true
stamp="${stamp:-0}"; [[ "$stamp" =~ ^[0-9]+$ ]] || stamp=0
foreign_fresh=0
if [[ -n "${owner:-}" && "$owner" != "$INSTANCE_ID" ]] && (( now - stamp < ttl )); then foreign_fresh=1; fi

case "${1:-}" in
  take)
    if (( foreign_fresh )); then
      log lease "WARNING another instance ($owner) wrote to this backup $(( (now - stamp) / 60 )) min ago. This instance takes over; the other one will stop backing up. If both are meant to run, give them different S3_PREFIX values."
    fi
    write_lease_or_warn; log lease "claimed backup prefix as $INSTANCE_ID" ;;
  check)
    if (( foreign_fresh )); then
      log lease "ERROR instance $owner owns this backup prefix (seen $(( (now - stamp) / 60 )) min ago); this instance will not back up"
      exit 1
    fi
    write_lease_or_warn ;;
  release)
    if [[ "${owner:-}" == "$INSTANCE_ID" ]]; then rclone deletefile "$BACKUP_REMOTE/lease" --quiet 2>/dev/null || true; fi ;;
  *) echo "usage: lease.sh take|check|release" >&2; exit 2 ;;
esac
