#!/usr/bin/env bash
# Boot sequence: restore -> seed state -> health + backup loop -> boot hooks -> tmux server session.
# Stays alive in `wait` so a SIGTERM trap can run a final backup (an `exec`ed PID 1 would ignore it).
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

workdir="$HOME/work"
# PORT: where the health endpoint listens (HTTP 200). Validated here so a typo cannot take the container down.
port="${PORT:-8080}"
if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
  echo "[entrypoint] WARNING invalid PORT '$port' (want 1-65535), using 8080"
  port=8080
fi
export PORT="$port"
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

# Optional VS Code in the browser at /code. Needs the binary (INSTALL_CODE_SERVER=1) and CODE_PASSWORD: it gives a
# shell in this container, so it never starts without a password. It listens on loopback only; health.js proxies
# /code to it (CODE_UPSTREAM). Its settings and extensions live under ~/.claude, so the S3 backup carries them.
code_pid=""
if [[ -n "${CODE_PASSWORD:-}" ]]; then
  code_port="${CODE_PORT:-8081}"
  if ! command -v code-server >/dev/null 2>&1; then
    echo "[entrypoint] WARNING CODE_PASSWORD is set but code-server is not installed (build with INSTALL_CODE_SERVER=1), /code disabled"
  elif ! [[ "$code_port" =~ ^[0-9]+$ ]] || (( code_port < 1 || code_port > 65535 || code_port == port )); then
    echo "[entrypoint] WARNING invalid CODE_PORT '$code_port' (want 1-65535, not PORT), /code disabled"
  else
    export CODE_UPSTREAM="$code_port"   # health.js proxies /code here; code-server itself starts after restore (below)
  fi
fi

# Health first, so a platform that probes a port sees a live service even if restore is slow.
node "$here/health.js" &
health_pid=$!

# Hard cap as a second guard on top of rclone's own timeouts.
timeout 90 "$here/restore.sh" || echo "[entrypoint] restore failed, continuing without restored state"
"$here/lease.sh" take || echo "[entrypoint] could not claim the backup lease (see above), continuing"
"$here/seed-state.sh" "$workdir"
"$here/seed-config.sh" || echo "[entrypoint] seed-config failed (see above), continuing"
# code-server starts only now: restore writes into ~/.claude, where its settings and extensions live.
if [[ -n "${CODE_UPSTREAM:-}" ]]; then
  # code-server lets the PORT env var override --bind-addr, so pin it to its own port.
  PORT="$CODE_UPSTREAM" PASSWORD="$CODE_PASSWORD" code-server --bind-addr "127.0.0.1:$CODE_UPSTREAM" --auth password \
    --user-data-dir "$HOME/.claude/code-server" --disable-telemetry --disable-update-check \
    "$workdir" >"$HOME/.cache/claude-host/code-server.log" 2>&1 &
  code_pid=$!
  echo "[entrypoint] code-server started, served at /code"
fi
# Keep the password out of everything started from here on (sessions run without permission prompts).
unset CODE_PASSWORD
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
  if [[ -n "$code_pid" ]]; then kill "$code_pid" 2>/dev/null || true; fi
  exit 0
}
trap shutdown TERM INT

# `wait` returns when a trapped signal arrives; loop until the health server really exits.
while kill -0 "$health_pid" 2>/dev/null; do
  wait "$health_pid" 2>/dev/null || true
done
