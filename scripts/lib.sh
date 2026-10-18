#!/usr/bin/env bash
# Shared helpers for backup/restore. Source this file; it sets no shell options itself.

log() { echo "[$1] ${*:2}"; }

# Remote: tests override with a local directory; production uses rclone's :s3: backend,
# which reads credentials from RCLONE_S3_* env vars (never from the command line).
if [[ -z "${BACKUP_REMOTE:-}" ]]; then
  if [[ -z "${S3_BUCKET:-}" ]]; then
    # Not an error: a fresh deployment has no bucket yet. Exit the sourcing script cleanly.
    log "${0##*/}" "persistence disabled (S3_BUCKET not set)"
    exit 0
  fi
  BACKUP_REMOTE=":s3:${S3_BUCKET}/${S3_PREFIX:-claude-host}"
fi
# All rclone settings come from env; an empty config file silences the "config not found" notice.
export RCLONE_CONFIG="${RCLONE_CONFIG:-/dev/null}"
# Fail fast: a dead bucket must not stall boot (rclone defaults retry for minutes).
export RCLONE_CONTIMEOUT="${RCLONE_CONTIMEOUT:-10s}"
export RCLONE_TIMEOUT="${RCLONE_TIMEOUT:-30s}"
export RCLONE_RETRIES="${RCLONE_RETRIES:-1}"
export RCLONE_LOW_LEVEL_RETRIES="${RCLONE_LOW_LEVEL_RETRIES:-1}"
export RCLONE_S3_PROVIDER="${S3_PROVIDER:-Other}"
export RCLONE_S3_ENDPOINT="${S3_ENDPOINT:-}"
export RCLONE_S3_REGION="${S3_REGION:-}"
export RCLONE_S3_ACCESS_KEY_ID="${S3_ACCESS_KEY_ID:-}"
export RCLONE_S3_SECRET_ACCESS_KEY="${S3_SECRET_ACCESS_KEY:-}"
export RCLONE_S3_NO_CHECK_BUCKET=true

# Optional client-side encryption (rclone crypt). The password is obscured via stdin so it never
# appears in a process list. CRYPT_SALT is optional but recommended.
RAW_REMOTE="$BACKUP_REMOTE"
if [[ -n "${CRYPT_PASSWORD:-}" ]]; then
  RCLONE_CRYPT_PASSWORD="$(printf %s "$CRYPT_PASSWORD" | rclone obscure -)"
  export RCLONE_CRYPT_PASSWORD
  if [[ -n "${CRYPT_SALT:-}" ]]; then
    RCLONE_CRYPT_PASSWORD2="$(printf %s "$CRYPT_SALT" | rclone obscure -)"
    export RCLONE_CRYPT_PASSWORD2
  fi
  BACKUP_REMOTE=":crypt,remote='${RAW_REMOTE}':"
elif [[ -n "${S3_BUCKET:-}" ]]; then
  # Refuse by default: a half-configured deployment (S3 secrets set, crypt secrets not yet) must never
  # upload credentials in plaintext, nor misread an encrypted bucket as a plain one.
  if [[ "${ALLOW_UNENCRYPTED:-}" != 1 ]]; then
    log "${0##*/}" "ERROR CRYPT_PASSWORD is required when S3_BUCKET is set (set ALLOW_UNENCRYPTED=1 to override)"
    exit 1
  fi
  log "${0##*/}" "WARNING backups are NOT encrypted (ALLOW_UNENCRYPTED=1)"
fi

# Wrong password => the crypt view looks empty while the bucket has data. Treat that as an error,
# otherwise a backup would silently write a second encrypted copy next to the real one.
check_crypt_access() {
  [[ -n "${CRYPT_PASSWORD:-}" ]] || return 0
  local raw crypt
  raw="$(rclone lsf "$RAW_REMOTE" 2>/dev/null || true)"
  crypt="$(rclone lsf "$BACKUP_REMOTE" 2>/dev/null || true)"
  if [[ -n "$raw" && -z "$crypt" ]]; then
    log "${0##*/}" "ERROR bucket has data that cannot be decrypted with CRYPT_PASSWORD/CRYPT_SALT"
    return 1
  fi
}

# Paths excluded from backup: caches and per-machine state that are large or useless elsewhere.
# Anchored with a leading / so only the top level matches: plugins/cache/ holds installed plugin files and must be kept.
# shellcheck disable=SC2034  # used by backup.sh after sourcing
BACKUP_EXCLUDES=(
  --exclude "/cache/**" --exclude "/statsig/**" --exclude "/shell-snapshots/**"
  --exclude "/debug/**" --exclude "/ide/**" --exclude "*.lock"
  --exclude "/code-server/CachedData/**" --exclude "/code-server/logs/**" --exclude "/code-server/Crash Reports/**"
)
