#!/usr/bin/env bash
# Periodic backup. Exits cleanly on SIGTERM so the entrypoint can run a final backup.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
interval="${BACKUP_INTERVAL:-300}"

trap 'exit 0' TERM INT
while true; do
  sleep "$interval" &
  wait $!
  "$here/backup.sh" || echo "[sync-loop] backup failed, will retry in ${interval}s"
done
