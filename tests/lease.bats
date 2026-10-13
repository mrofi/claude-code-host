#!/usr/bin/env bats
# Two instances on one backup prefix: the newest wins, the older one stops writing.

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  export BACKUP_REMOTE="$BATS_TEST_TMPDIR/remote"
  mkdir -p "$HOME/.claude" "$BACKUP_REMOTE"
  echo '{"t":1}' > "$HOME/.claude/.credentials.json"
  export PATH="$BATS_TEST_DIRNAME/../scripts:$PATH"
}

as() { INSTANCE_ID="$1" "${@:2}"; }

@test "without INSTANCE_ID the lease is not used (manual runs, other tests)" {
  run lease.sh take
  [ "$status" -eq 0 ]
  [ ! -e "$BACKUP_REMOTE/lease" ]
}

@test "a fresh boot claims the prefix and its backups are allowed" {
  run as A lease.sh take
  [ "$status" -eq 0 ]
  [[ "$(cat "$BACKUP_REMOTE/lease")" == "A "* ]]
  run as A backup.sh
  [ "$status" -eq 0 ]
  [ -f "$BACKUP_REMOTE/claude/.credentials.json" ]
}

@test "a second instance takes over with a warning, and the first one stops backing up" {
  as A lease.sh take
  run as B lease.sh take
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING another instance (A)"* ]]
  [[ "$output" == *"S3_PREFIX"* ]]
  run as A backup.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"owns this backup prefix"* ]]
  [ ! -e "$BACKUP_REMOTE/claude/.credentials.json" ]
  run as B backup.sh
  [ "$status" -eq 0 ]
  [ -f "$BACKUP_REMOTE/claude/.credentials.json" ]
}

@test "a stale lease (crashed instance) is taken over without a warning" {
  printf 'A %s\n' $(( $(date +%s) - 4000 )) > "$BACKUP_REMOTE/lease"
  run as B lease.sh take
  [ "$status" -eq 0 ]
  [[ "$output" != *"WARNING"* ]]
  run as B backup.sh
  [ "$status" -eq 0 ]
}

@test "release removes only our own lease" {
  as A lease.sh take
  as B lease.sh release
  [ -e "$BACKUP_REMOTE/lease" ]
  as A lease.sh release
  [ ! -e "$BACKUP_REMOTE/lease" ]
}

@test "a lease alone does not make restore think there is a backup" {
  as A lease.sh take
  run restore.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to restore"* ]]
}

@test "a garbled lease does not block backups" {
  echo 'garbage' > "$BACKUP_REMOTE/lease"
  run as B backup.sh
  [ "$status" -eq 0 ]
}

@test "the instance id file makes a hand-run backup obey the lease" {
  mkdir -p "$HOME/.cache/claude-host"
  printf A > "$HOME/.cache/claude-host/instance-id"
  as B lease.sh take
  run backup.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"owns this backup prefix"* ]]
}

@test "a lease that cannot be written does not stop the backup" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  real="$(command -v rclone)"
  cat > "$BATS_TEST_TMPDIR/bin/rclone" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == copyto && "\$3" == */lease ]]; then echo "corrupted on transfer: md5 crypted hash differ" >&2; exit 1; fi
exec "$real" "\$@"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/rclone"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  run as A backup.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING could not write the lease"* ]]
  [ -f "$BACKUP_REMOTE/claude/.credentials.json" ]
}

@test "the lease is uploaded with copyto, never a streamed rcat" {
  run grep -q 'rclone rcat' "$BATS_TEST_DIRNAME/../scripts/lease.sh"
  [ "$status" -ne 0 ]
}
