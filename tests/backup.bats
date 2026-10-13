#!/usr/bin/env bats
# Backup/restore tests use a local directory as the rclone remote (BACKUP_REMOTE).

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  export BACKUP_REMOTE="$BATS_TEST_TMPDIR/remote"
  mkdir -p "$HOME" "$BACKUP_REMOTE"
  export PATH="$BATS_TEST_DIRNAME/../scripts:$PATH"
}

@test "restore from an empty remote succeeds and says so" {
  run restore.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to restore"* ]]
}

@test "backup uploads the expected set and skips excluded paths" {
  mkdir -p "$HOME/.claude/skills/x" "$HOME/.claude/cache" "$HOME/.claude/projects/p"
  echo '{"t":1}' > "$HOME/.claude/.credentials.json"
  echo skill > "$HOME/.claude/skills/x/SKILL.md"
  echo junk > "$HOME/.claude/cache/big"
  echo hist > "$HOME/.claude/projects/p/s.jsonl"
  echo '{}' > "$HOME/.claude.json"
  run backup.sh
  [ "$status" -eq 0 ]
  [ -f "$BACKUP_REMOTE/claude/.credentials.json" ]
  [ -f "$BACKUP_REMOTE/claude/skills/x/SKILL.md" ]
  [ -f "$BACKUP_REMOTE/claude/projects/p/s.jsonl" ]
  [ -f "$BACKUP_REMOTE/claude.json" ]
  [ ! -e "$BACKUP_REMOTE/claude/cache/big" ]
}

@test "restore recreates the files and sets credentials to mode 600" {
  mkdir -p "$BACKUP_REMOTE/claude"
  echo '{"t":1}' > "$BACKUP_REMOTE/claude/.credentials.json"
  chmod 644 "$BACKUP_REMOTE/claude/.credentials.json"
  echo '{}' > "$BACKUP_REMOTE/claude.json"
  run restore.sh
  [ "$status" -eq 0 ]
  [ -f "$HOME/.claude/.credentials.json" ]
  [ -f "$HOME/.claude.json" ]
  [ "$(stat -c %a "$HOME/.claude/.credentials.json")" = "600" ]
}

@test "backup then restore round-trips into a fresh home" {
  mkdir -p "$HOME/.claude/skills/y"
  echo secret-ish > "$HOME/.claude/.credentials.json"
  echo s > "$HOME/.claude/skills/y/SKILL.md"
  backup.sh
  export HOME="$BATS_TEST_TMPDIR/home2"; mkdir -p "$HOME"
  run restore.sh
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/.claude/skills/y/SKILL.md")" = "s" ]
}

@test "an unreachable remote fails with a clear message and no secret in output" {
  export BACKUP_REMOTE=":s3:nonexistent-bucket/p"
  export S3_ENDPOINT="http://127.0.0.1:1"
  export S3_ACCESS_KEY_ID="AKIA-TEST-KEY" S3_SECRET_ACCESS_KEY="s3cr3t-value"
  run restore.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"[restore] ERROR"* ]]
  [[ "$output" != *"s3cr3t-value"* ]]
}

@test "two concurrent backups do not overlap" {
  mkdir -p "$HOME/.claude"; echo a > "$HOME/.claude/f"
  export BACKUP_LOCK="$BATS_TEST_TMPDIR/lock"
  exec 9>"$BACKUP_LOCK"; flock 9
  run backup.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"already running"* ]]
}

@test "backup uploads only the minimal .claude.json keys, never machine ids" {
  mkdir -p "$HOME/.claude"
  cat > "$HOME/.claude.json" <<'JSON'
{"oauthAccount":{"emailAddress":"a@b.c"},"hasCompletedOnboarding":true,"userID":"u1","theme":"dark",
 "machineID":"m-1","remoteControlMachineId":"rc-1","projects":{"/x":{}},"cachedGrowthBookFeatures":{"a":1}}
JSON
  run backup.sh
  [ "$status" -eq 0 ]
  run jq -r 'keys | join(",")' "$BACKUP_REMOTE/claude.json"
  [ "$output" = "hasCompletedOnboarding,oauthAccount,theme,userID" ]
}

@test "restore merges the minimal keys over an existing .claude.json" {
  mkdir -p "$BACKUP_REMOTE/claude"
  echo '{"oauthAccount":{"emailAddress":"a@b.c"},"userID":"u1"}' > "$BACKUP_REMOTE/claude.json"
  echo '{"machineID":"local-m","userID":"old"}' > "$HOME/.claude.json"
  run restore.sh
  [ "$status" -eq 0 ]
  [ "$(jq -r .machineID "$HOME/.claude.json")" = "local-m" ]
  [ "$(jq -r .userID "$HOME/.claude.json")" = "u1" ]
  [ "$(jq -r .oauthAccount.emailAddress "$HOME/.claude.json")" = "a@b.c" ]
}

@test "restore and backup say persistence is disabled when no bucket is configured" {
  unset BACKUP_REMOTE S3_BUCKET
  run restore.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"persistence disabled"* ]]
  run backup.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"persistence disabled"* ]]
}

@test "with CRYPT_PASSWORD the remote holds no plaintext names or contents" {
  export CRYPT_PASSWORD="correct horse battery staple"
  mkdir -p "$HOME/.claude/skills/x"
  echo 'TOP-SECRET-TOKEN' > "$HOME/.claude/.credentials.json"
  echo skill > "$HOME/.claude/skills/x/SKILL.md"
  run backup.sh
  [ "$status" -eq 0 ]
  [ -d "$BACKUP_REMOTE" ]
  run find "$BACKUP_REMOTE" -type f
  [[ "$output" != *"credentials"* ]]
  [[ "$output" != *"SKILL"* ]]
  run grep -r "TOP-SECRET-TOKEN" "$BACKUP_REMOTE"
  [ "$status" -ne 0 ]
}

@test "encrypted backup then restore round-trips" {
  export CRYPT_PASSWORD="pw-one" CRYPT_SALT="salt-one"
  echo '{"userID":"u1"}' > "$HOME/.claude.json"; mkdir -p "$HOME/.claude"
  echo 'cred' > "$HOME/.claude/.credentials.json"
  backup.sh
  export HOME="$BATS_TEST_TMPDIR/home2"; mkdir -p "$HOME"
  run restore.sh
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/.claude/.credentials.json")" = "cred" ]
}

@test "wrong CRYPT_PASSWORD is an error, not an empty bucket" {
  export CRYPT_PASSWORD="right"
  mkdir -p "$HOME/.claude"; echo c > "$HOME/.claude/.credentials.json"
  backup.sh
  export CRYPT_PASSWORD="wrong"
  run restore.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot be decrypted"* ]]
  run backup.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot be decrypted"* ]]
}

@test "the encryption password never appears in output" {
  export CRYPT_PASSWORD="hunter2-very-secret"
  mkdir -p "$HOME/.claude"; echo c > "$HOME/.claude/f"
  run backup.sh
  [[ "$output" != *"hunter2-very-secret"* ]]
}

@test "a configured bucket without CRYPT_PASSWORD is refused, never uploaded unencrypted" {
  unset BACKUP_REMOTE CRYPT_PASSWORD ALLOW_UNENCRYPTED
  export S3_BUCKET=b S3_ENDPOINT="http://127.0.0.1:1" S3_ACCESS_KEY_ID=k S3_SECRET_ACCESS_KEY=s
  mkdir -p "$HOME/.claude"; echo c > "$HOME/.claude/.credentials.json"
  run backup.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"CRYPT_PASSWORD is required"* ]]
  run restore.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"CRYPT_PASSWORD is required"* ]]
}

@test "ALLOW_UNENCRYPTED=1 permits an unencrypted bucket with a warning" {
  unset BACKUP_REMOTE CRYPT_PASSWORD
  export ALLOW_UNENCRYPTED=1 S3_BUCKET=b S3_ENDPOINT="http://127.0.0.1:1" S3_ACCESS_KEY_ID=k S3_SECRET_ACCESS_KEY=s
  run restore.sh
  [[ "$output" == *"NOT encrypted"* ]]
  [[ "$output" != *"CRYPT_PASSWORD is required"* ]]
}

@test "upload-login copies only the login files and never deletes other remote data" {
  export CRYPT_PASSWORD="pw" CRYPT_SALT="salt"
  # existing remote data (e.g. history) written by a normal backup
  mkdir -p "$HOME/.claude/skills/keep"; echo k > "$HOME/.claude/skills/keep/SKILL.md"
  backup.sh
  # login files from "another machine", including fields that must not be uploaded
  src="$BATS_TEST_TMPDIR/src"; mkdir -p "$src"
  echo '{"claudeAiOauth":{"accessToken":"x"}}' > "$src/.credentials.json"
  echo '{"oauthAccount":{"emailAddress":"a@b.c"},"userID":"u","machineID":"m","projects":{"/x":{}}}' > "$src/claude.json"
  run upload-login.sh "$src/.credentials.json" "$src/claude.json"
  [ "$status" -eq 0 ]
  export HOME="$BATS_TEST_TMPDIR/home3"; mkdir -p "$HOME"
  run restore.sh
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/.claude/skills/keep/SKILL.md")" = "k" ]
  [ "$(jq -r .claudeAiOauth.accessToken "$HOME/.claude/.credentials.json")" = "x" ]
  [ "$(jq -r .oauthAccount.emailAddress "$HOME/.claude.json")" = "a@b.c" ]
  [ "$(jq -r '.machineID // "none"' "$HOME/.claude.json")" = "none" ]
}

@test "user skills and installed plugin files are backed up, only top-level caches are skipped" {
  mkdir -p "$HOME/.claude/skills/mine" "$HOME/.claude/plugins/cache/p/skills/x" "$HOME/.claude/cache"
  echo s > "$HOME/.claude/skills/mine/SKILL.md"
  echo p > "$HOME/.claude/plugins/cache/p/skills/x/SKILL.md"
  echo junk > "$HOME/.claude/cache/big"
  run backup.sh
  [ "$status" -eq 0 ]
  [ -f "$BACKUP_REMOTE/claude/skills/mine/SKILL.md" ]
  [ -f "$BACKUP_REMOTE/claude/plugins/cache/p/skills/x/SKILL.md" ]
  [ ! -e "$BACKUP_REMOTE/claude/cache/big" ]
}
