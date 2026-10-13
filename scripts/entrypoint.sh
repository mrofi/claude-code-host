#!/usr/bin/env bash
# Boot sequence: restore -> seed state -> health + backup loop -> boot hooks -> tmux server session.
# Stays alive in `wait` so a SIGTERM trap can run a final backup (an `exec`ed PID 1 would ignore it).
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

workdir="$HOME/work"
mode="${MAIN_MODE:-server}"
# One knob for both limits: server-mode capacity and the spawn-session cap (see spawn-session.sh).
capacity="${CAPACITY:-${MAX_SESSIONS:-3}}"
if ! [[ "$capacity" =~ ^[1-9][0-9]*$ ]]; then
  echo "[entrypoint] WARNING invalid MAX_SESSIONS/CAPACITY '$capacity', using 3"
  capacity=3
fi
mkdir -p "$workdir"

# Identifies this boot to lease.sh (two live instances on one backup prefix would overwrite each other).
# Kept in a file as well, so a backup run by hand (docker exec, a session) obeys the same lease.
INSTANCE_ID="$(hostname)-$$-$(date +%s)"
export INSTANCE_ID
mkdir -p "$HOME/.cache/claude-host" && printf %s "$INSTANCE_ID" > "$HOME/.cache/claude-host/instance-id"

echo "[entrypoint] starting as uid $(id -u), MAIN_MODE=$mode"

# Health first, so a platform that probes a port sees a live service even if restore is slow.
node "$here/health.js" &
health_pid=$!

# Hard cap as a second guard on top of rclone's own timeouts.
timeout 90 "$here/restore.sh" || echo "[entrypoint] restore failed, continuing without restored state"
"$here/lease.sh" take || echo "[entrypoint] could not claim the backup lease (see above), continuing"
"$here/seed-state.sh" "$workdir"
"$here/seed-config.sh" || echo "[entrypoint] seed-config failed (see above), continuing"
if [[ -n "${S3_BUCKET:-}" && -z "${CRYPT_PASSWORD:-}" && "${ALLOW_UNENCRYPTED:-}" != 1 ]]; then
  echo "[entrypoint] ERROR S3_BUCKET is set but CRYPT_PASSWORD is not: persistence disabled, no backup loop"
  sync_pid=""
elif [[ -n "${BACKUP_REMOTE:-}${S3_BUCKET:-}" ]]; then
  "$here/sync-loop.sh" &
  sync_pid=$!
else
  echo "[entrypoint] S3_BUCKET not set: persistence disabled, no backup loop"
  sync_pid=""
fi

# Extension point for derived images: run every executable *.sh in $ENTRYPOINT_D (sorted) before the main
# session starts. A hook that fails or runs too long is logged and skipped, so it can never block the
# main session. A hook that starts something long-lived must background it. See docs/extending.md.
run_hooks() { # dir, timeout seconds
  local dir=$1 limit=$2 f rc
  [[ -d "$dir" ]] || return 0
  for f in "$dir"/*.sh; do
    [[ -f "$f" && -x "$f" ]] || continue
    echo "[entrypoint] hook $(basename "$f")"
    timeout "$limit" "$f"; rc=$?
    (( rc == 0 )) || echo "[entrypoint] hook $(basename "$f") failed or timed out (status $rc), continuing"
  done
}
run_hooks "${ENTRYPOINT_D:-$HOME/entrypoint.d}" "${HOOK_TIMEOUT:-60}"

if ! command -v claude >/dev/null 2>&1; then
  echo "[entrypoint] ERROR the 'claude' command is not installed in this image. The published base image does not include Claude Code; add it in your own Dockerfile (see README, 'Install Claude Code'). The container stays up so you can see this message."
fi

case "$mode" in
  server)
    cmd="claude remote-control --name server --spawn same-dir --capacity $capacity --permission-mode bypassPermissions"
    session=server ;;
  interactive)
    cmd="claude --dangerously-skip-permissions --remote-control main"
    session=main ;;
  *) echo "[entrypoint] ERROR unknown MAIN_MODE=$mode"; exit 2 ;;
esac
# The trailing sleep keeps the pane (and its output) around if claude exits.
tmux new-session -d -s "$session" -c "$workdir" -x 200 -y 50 \
  "$cmd; echo \"[$session] claude exited with status \$?\"; sleep infinity"
echo "[entrypoint] tmux session '$session' started"

# Many hosts give no shell, so surface the pane's screen in the logs (is Remote Control connected, or
# did claude print an error?). Snapshots only, not a stream, to keep logs small and readable.
snapshot_pane() {
  tmux capture-pane -p -t "$session" 2>/dev/null | sed -e 's/[[:space:]]*$//' -e '/^$/d' \
    | sed "s/^/[$session] /"
}
(
  sleep "${SNAPSHOT_DELAY:-20}"; snapshot_pane
  sleep 100; snapshot_pane
) &

shutdown() {
  echo "[entrypoint] SIGTERM received, final backup"
  if [[ -n "$sync_pid" ]]; then kill "$sync_pid" 2>/dev/null || true; fi
  # Shutdown hooks run first so anything they write into ~/.claude is part of the final backup.
  run_hooks "${SHUTDOWN_D:-$HOME/shutdown.d}" "${SHUTDOWN_HOOK_TIMEOUT:-10}"
  "$here/backup.sh" || echo "[entrypoint] final backup failed"
  "$here/lease.sh" release || true
  tmux kill-server 2>/dev/null || true
  kill "$health_pid" 2>/dev/null || true
  exit 0
}
trap shutdown TERM INT

# `wait` returns when a trapped signal arrives; loop until the health server really exits.
while kill -0 "$health_pid" 2>/dev/null; do
  wait "$health_pid" 2>/dev/null || true
done
