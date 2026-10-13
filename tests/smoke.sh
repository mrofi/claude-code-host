#!/usr/bin/env bash
# shellcheck disable=SC2015  # "check && pass || bad": pass cannot fail, so the pattern is safe here
# Smoke test: boots the real image against a local S3 server (rclone serve s3) with a stub `claude`.
# Covers: boot -> tmux server session, seeded state, SIGTERM final backup, restore on 2nd boot,
# boot with an unreachable bucket, two instances on one prefix, a failing claude, extension hooks and a
# derived image.   Usage: tests/smoke.sh [image]
set -euo pipefail
IMAGE="${1:-claude-host}"
# Local S3 server: rclone's own (`rclone serve s3`). MinIO no longer publishes images.
S3_SERVER_IMAGE="${S3_SERVER_IMAGE:-docker.io/rclone/rclone:latest}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUCKET=smoke
PORT=19000
KEY=smokekey; SECRET=smokesecret123
work="$(mktemp -d)"
fail=0
pass() { echo "ok   - $*"; }
bad()  { echo "FAIL - $*"; fail=1; }
cleanup() { docker rmi -f claude-host-smoke-ext >/dev/null 2>&1 || true; for c in smoke-s3 smoke-a smoke-b smoke-c smoke-d smoke-e; do docker rm -f "$c" >/dev/null 2>&1 || true; done; rm -rf "$work"; }
cleanup_stale() { for c in smoke-s3 smoke-a smoke-b smoke-c smoke-d smoke-e; do docker rm -f "$c" >/dev/null 2>&1 || true; done; }
cleanup_stale
trap cleanup EXIT

cat > "$work/claude" <<'STUB'
#!/usr/bin/env bash
echo "$@" > /tmp/claude-args
echo "Connected stub-session"
sleep infinity
STUB
chmod +x "$work/claude"

s3env=(-e "S3_BUCKET=$BUCKET" -e S3_ENDPOINT="http://127.0.0.1:$PORT" -e "S3_ACCESS_KEY_ID=$KEY" -e "S3_SECRET_ACCESS_KEY=$SECRET" -e S3_PROVIDER=Other -e BACKUP_INTERVAL=3600 -e CRYPT_PASSWORD=smoke-crypt-pw -e CRYPT_SALT=smoke-salt -e SNAPSHOT_DELAY=3)
run_ctr() { # name, extra docker args...
  local name=$1; shift
  docker run -d --name "$name" --network host -v "$work/claude":/home/node/bin/claude:ro "${s3env[@]}" "$@" "$IMAGE" >/dev/null
}

docker run -d --name smoke-s3 --network host "$S3_SERVER_IMAGE" \
  serve s3 /data --addr ":$PORT" --auth-key "$KEY,$SECRET" >/dev/null
for _ in $(seq 30); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 1; done
docker run --rm --network host "${s3env[@]}" --entrypoint rclone "$IMAGE" mkdir ":s3:$BUCKET" --config /dev/null \
  --s3-provider Other --s3-endpoint "http://127.0.0.1:$PORT" --s3-access-key-id $KEY --s3-secret-access-key $SECRET

# --- 1. empty bucket boot
run_ctr smoke-a -e PORT=17861
sleep 6
[[ "$(docker exec smoke-a tmux ls 2>&1)" == server:* ]] && pass "tmux session 'server' exists" || bad "no tmux session 'server'"
args="$(docker exec smoke-a cat /tmp/claude-args 2>/dev/null || true)"
[[ "$args" == remote-control*--spawn\ same-dir*--permission-mode\ bypassPermissions ]] && pass "claude started in server mode: $args" || bad "unexpected claude args: $args"
[[ "$(docker exec smoke-a jq -r '.projects["/home/node/work"].hasTrustDialogAccepted' /home/node/.claude.json)" == true ]] && pass "workspace trust seeded" || bad "trust not seeded"
[[ "$(docker exec smoke-a jq -r .remoteDialogSeen /home/node/.claude.json)" == true ]] && pass "remoteDialogSeen seeded" || bad "remoteDialogSeen not seeded"

[[ "$(docker exec smoke-a jq -r .skipDangerousModePermissionPrompt /home/node/.claude/settings.json)" == true ]] && pass "bypass-prompt skip seeded in settings" || bad "settings not seeded"
docker exec smoke-a grep -q "spawn-session.sh" /home/node/work/CLAUDE.md && pass "CLAUDE.md installed for sessions" || bad "CLAUDE.md missing"
logs_a1="$(docker logs smoke-a 2>&1)"
grep -q '^\[server\] .*Connected stub-session' <<<"$logs_a1" && pass "pane screen is shown in the container logs" || bad "pane output missing from logs: $logs_a1"

# --- 2. SIGTERM -> final backup, fast exit
docker exec smoke-a sh -c 'mkdir -p ~/.claude/skills/s && echo fake-cred > ~/.claude/.credentials.json && echo sk > ~/.claude/skills/s/SKILL.md'
start=$SECONDS
docker stop -t 15 smoke-a >/dev/null
took=$((SECONDS - start))
(( took < 10 )) && pass "stopped on SIGTERM in ${took}s" || bad "slow stop (${took}s): SIGTERM likely ignored"
logs_a="$(docker logs smoke-a 2>&1)"
grep -q "final backup" <<<"$logs_a" && pass "final backup ran" || bad "final backup did not run"
listing="$(docker run --rm --network host "${s3env[@]}" --entrypoint rclone "$IMAGE" lsf -R ":s3:$BUCKET" --config /dev/null \
  --s3-provider Other --s3-endpoint "http://127.0.0.1:$PORT" --s3-access-key-id $KEY --s3-secret-access-key $SECRET)"
[[ -n "$listing" && "$listing" != *credentials* && "$listing" != *SKILL* ]] && pass "encrypted objects reached the bucket (no plaintext names)" || bad "bucket empty or plaintext names: $listing"

# --- 3. second boot restores
docker rm -f smoke-a >/dev/null
run_ctr smoke-b -e PORT=17862 -e MAX_SESSIONS=5
sleep 6
[[ "$(docker exec smoke-b cat /home/node/.claude/.credentials.json 2>/dev/null)" == fake-cred ]] && pass "credentials restored on 2nd boot" || bad "credentials not restored"
[[ "$(docker exec smoke-b stat -c %a /home/node/.claude/.credentials.json)" == 600 ]] && pass "credentials mode 600" || bad "credentials mode not 600"
[[ "$(docker exec smoke-b cat /home/node/.claude/skills/s/SKILL.md 2>/dev/null)" == sk ]] && pass "skills restored" || bad "skills not restored"
[[ "$(docker exec smoke-b cat /tmp/claude-args)" == *"--capacity 5"* ]] && pass "MAX_SESSIONS=5 sets server capacity" || bad "MAX_SESSIONS did not set capacity"
docker rm -f smoke-b >/dev/null

# --- 4. unreachable bucket still boots
run_ctr smoke-c -e PORT=17863 -e S3_ENDPOINT=http://127.0.0.1:1
sleep 6
[[ "$(docker exec smoke-c tmux ls 2>&1)" == server:* ]] && pass "boots with unreachable bucket" || bad "did not boot without bucket"
logs_c="$(docker logs smoke-c 2>&1)"
grep -q '\[restore\] ERROR' <<<"$logs_c" && pass "restore error logged" || bad "restore error not logged"
grep -q "$SECRET" <<<"$logs_c" && bad "secret leaked into logs" || pass "no secret in logs"
grep -q "smoke-crypt-pw" <<<"$logs_c" && bad "crypt password leaked into logs" || pass "no crypt password in logs"

# --- 6. two live instances on one backup prefix: the newest wins, the older stops writing
run_ctr smoke-a -e PORT=17870
sleep 6
[[ "$(docker exec smoke-a id -u)" == 1000 ]] && pass "runs as uid 1000" || bad "not running as uid 1000"
docker exec smoke-a /home/node/bin/backup.sh >/dev/null 2>&1 && pass "first instance can back up" || bad "first instance cannot back up"
run_ctr smoke-b -e PORT=17871
sleep 6
grep -q 'WARNING another instance' <<<"$(docker logs smoke-b 2>&1)" && pass "second instance warns about the first" || bad "no lease warning on the second instance"
out_a="$(docker exec smoke-a /home/node/bin/backup.sh 2>&1 || true)"
grep -q 'owns this backup prefix' <<<"$out_a" && pass "first instance refuses to back up once displaced" || bad "displaced instance still backs up: $out_a"
docker exec smoke-b /home/node/bin/backup.sh >/dev/null 2>&1 && pass "newest instance can back up" || bad "newest instance cannot back up"
docker rm -f smoke-a smoke-b >/dev/null
# --- 7. claude fails at start (for example expired credentials): the session stays up and the error is in the logs
cat > "$work/claude-fail" <<'STUB'
#!/usr/bin/env bash
echo "Error: OAuth token has expired. Please run /login"
exit 1
STUB
chmod +x "$work/claude-fail"
docker run -d --name smoke-a --network host -v "$work/claude-fail":/home/node/bin/claude:ro "${s3env[@]}" -e PORT=17872 "$IMAGE" >/dev/null
sleep 7
[[ "$(docker exec smoke-a tmux ls 2>&1)" == server:* ]] && pass "tmux session stays up after claude exits" || bad "session vanished after claude failed"
logs_a="$(docker logs smoke-a 2>&1)"
grep -q 'OAuth token has expired' <<<"$logs_a" && pass "claude's error is shown in the logs" || bad "claude's error not in logs"
grep -q 'claude exited with status 1' <<<"$logs_a" && pass "exit status is reported" || bad "exit status not reported"
[[ "$(docker inspect -f '{{.State.Running}}' smoke-a)" == true ]] && pass "container keeps running (health endpoint up)" || bad "container exited"
docker rm -f smoke-a >/dev/null
# --- 8. extension hooks: a failing hook and a slow hook never block boot, later hooks still run
mkdir -p "$work/hooks"
printf '#!/usr/bin/env bash\necho hook-one-fails\nexit 3\n' > "$work/hooks/10-fail.sh"
printf '#!/usr/bin/env bash\nsleep 30\n' > "$work/hooks/20-slow.sh"
printf '#!/usr/bin/env bash\necho ran-after-failures\n' > "$work/hooks/30-ok.sh"
printf 'not executable, must be skipped\n' > "$work/hooks/40-skipped.sh"
chmod +x "$work/hooks/10-fail.sh" "$work/hooks/20-slow.sh" "$work/hooks/30-ok.sh"
run_ctr smoke-a -e PORT=17875 -e HOOK_TIMEOUT=2 -v "$work/hooks":/home/node/entrypoint.d:ro
sleep 9
logs_h="$(docker logs smoke-a 2>&1)"
grep -q 'hook 10-fail.sh failed or timed out (status 3)' <<<"$logs_h" && pass "a failing hook is logged and skipped" || bad "failing hook not reported: $logs_h"
grep -q 'hook 20-slow.sh failed or timed out (status 124)' <<<"$logs_h" && pass "a slow hook is stopped after HOOK_TIMEOUT" || bad "slow hook not stopped"
grep -q 'ran-after-failures' <<<"$logs_h" && pass "later hooks still run" || bad "hook after a failure did not run"
grep -q '40-skipped' <<<"$logs_h" && bad "a non-executable hook was run" || pass "non-executable files are ignored"
[[ "$(docker exec smoke-a tmux ls 2>&1)" == server:* ]] && pass "boot not blocked by hooks" || bad "hooks blocked boot"
docker rm -f smoke-a >/dev/null

# --- 9. a derived image (examples/extend) adds tools, a hook, a shutdown hook, CLAUDE.md and settings
if docker build -q --build-arg "BASE=$IMAGE" --build-arg INSTALL_CLAUDE=0 -t claude-host-smoke-ext "$root/examples/extend" >/dev/null; then
  pass "examples/extend builds on the base image"
  docker run -d --name smoke-e --network host -v "$work/claude":/home/node/bin/claude:ro -e PORT=17873 -e GREETING=hi claude-host-smoke-ext >/dev/null
  sleep 6
  logs_e="$(docker logs smoke-e 2>&1)"
  grep -q 'hello from the example hook (GREETING=hi)' <<<"$logs_e" && pass "the derived image's boot hook ran" || bad "example hook did not run: $logs_e"
  docker exec smoke-e test -f /home/node/.example-hook-ran && pass "the hook ran as the node user in its HOME" || bad "hook side effect missing"
  docker exec smoke-e rg --version >/dev/null && pass "a tool added by the derived image is available" || bad "added tool missing"
  docker exec smoke-e grep -q 'ripgrep' /home/node/work/CLAUDE.md && pass "the derived CLAUDE.md fragment reached the sessions" || bad "CLAUDE.d fragment missing"
  docker exec smoke-e grep -q 'spawn-session.sh' /home/node/work/CLAUDE.md && pass "the base CLAUDE.md is still there" || bad "base CLAUDE.md lost"
  [[ "$(docker exec smoke-e jq -r .env.EXAMPLE_IMAGE /home/node/.claude/settings.json)" == 1 ]] && pass "the derived settings fragment was merged" || bad "settings.d not merged"
  [[ "$(docker exec smoke-e jq -r .skipDangerousModePermissionPrompt /home/node/.claude/settings.json)" == true ]] && pass "required settings survive the merge" || bad "required setting lost"
  docker stop -t 15 smoke-e >/dev/null
  grep -q 'bye from the example hook' <<<"$(docker logs smoke-e 2>&1)" && pass "the shutdown hook ran on SIGTERM" || bad "shutdown hook did not run"
  docker rm -f smoke-e >/dev/null
else
  bad "examples/extend does not build"
fi

# --- 10. default health port is 8080, and a missing claude is explained (only checkable when the image has none)
docker run -d --name smoke-a -p 18080:8080 "$IMAGE" >/dev/null
sleep 5
[[ "$(curl -s --max-time 5 http://127.0.0.1:18080/)" == ok ]] && pass "health endpoint answers on the default port 8080" || bad "no health answer on 8080"
if docker run --rm --entrypoint sh "$IMAGE" -c 'command -v claude' >/dev/null 2>&1; then
  echo "skip - this image includes claude, so the missing-claude message cannot be checked"
else
  grep -q "'claude' command is not installed" <<<"$(docker logs smoke-a 2>&1)" && pass "a missing claude is explained in the logs" || bad "missing claude not explained"
  [[ "$(docker inspect -f '{{.State.Running}}' smoke-a)" == true ]] && pass "the container stays up without claude" || bad "container exited without claude"
fi
docker rm -f smoke-a >/dev/null
(( fail == 0 )) && echo "SMOKE PASSED" || { echo "SMOKE FAILED"; exit 1; }
