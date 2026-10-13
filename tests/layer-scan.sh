#!/usr/bin/env bash
# Scan every layer of the image (including files deleted by later layers) for secrets.
#   tests/layer-scan.sh [image]
# Optional: LITERALS_FROM="file1 file2" also searches for the exact VALUES found in those KEY=VALUE or JSON
# files (for example ~/e2.env and a service-account key). Values are never printed, only which file matched.
# shellcheck disable=SC2015  # "check && pass || bad": pass cannot fail, so the pattern is safe here
set -euo pipefail
IMAGE="${1:-claude-host}"
mkdir -p "${SCAN_TMP:-$HOME/.cache}"
work="$(mktemp -d -p "${SCAN_TMP:-$HOME/.cache}" layer-scan.XXXXXX)"
trap 'rm -rf "$work"' EXIT
fail=0

mkdir "$work/fs"
# Stream the image: each layer is piped through tar, keeping only the places where application or user
# data can end up (system packages are not ours to judge). Nothing large is ever written to disk.
cat > "$work/extract-layer.sh" <<EXTRACT
#!/bin/sh
n=\$(( \$(find "$work/fs" -mindepth 1 -maxdepth 1 | wc -l) + 1 ))
mkdir -p "$work/fs/\$n"
tar -x -C "$work/fs/\$n" --wildcards 'home/*' 'root/*' 'tmp/*' 'etc/*' 'opt/*' 'srv/*' 'var/tmp/*' 2>/dev/null
exit 0
EXTRACT
chmod +x "$work/extract-layer.sh"
docker save "$IMAGE" | tar -x --to-command="$work/extract-layer.sh" --wildcards '*.tar' 'blobs/*/*' >/dev/null 2>&1 || true
n="$(find "$work/fs" -mindepth 1 -maxdepth 1 | wc -l)"
(( n > 0 )) || { echo "FAIL - could not read any layer of $IMAGE"; exit 1; }
echo "scanned $n layer archives"

patterns=(
  '-----BEGIN [A-Z ]*PRIVATE KEY-----'
  'eyJ[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{10,}\.'
  'sk-ant-[A-Za-z0-9_-]{10,}'
  'hf_[A-Za-z0-9]{30,}'
  'AKIA[0-9A-Z]{16}'
  '"private_key"'
  'accessToken'
  'refreshToken'
)
for p in "${patterns[@]}"; do
  if grep -rIlE -- "$p" "$work/fs" >/dev/null 2>&1; then
    echo "FAIL - pattern '$p' found in: $(grep -rIlE -- "$p" "$work/fs" | sed "s|$work/fs/||" | head -5 | tr '\n' ' ')"
    fail=1
  fi
done
(( fail == 0 )) && echo "ok   - no secret patterns in image layers"

# Image metadata: ENV, ARG and commands must carry no secrets either.
meta="$(docker history --no-trunc --format '{{.CreatedBy}}' "$IMAGE"; docker inspect --format '{{json .Config.Env}}' "$IMAGE")"
for p in "${patterns[@]}"; do
  if grep -qE -- "$p" <<<"$meta"; then echo "FAIL - pattern '$p' found in image history/env"; fail=1; fi
done
(( fail == 0 )) && echo "ok   - no secret patterns in image history or env"

# Exact values of real secrets (optional, supplied by the caller).
for f in ${LITERALS_FROM:-}; do
  [[ -r "$f" ]] || { echo "skip - cannot read $f"; continue; }
  hits=0; checked=0
  if jq -e . "$f" >/dev/null 2>&1; then
    # Only the secret fields of a service-account key: its URLs and project id are public and also ship
    # inside the Google SDK. For the PEM key, search its first body line.
    values="$(jq -r '[.private_key_id, .client_id, (.private_key // "" | split("\n")[1])] | .[] | select(. != null)' "$f")"
  else
    values="$(sed -n 's/^[A-Za-z_][A-Za-z0-9_]*=//p' "$f" | sed -e 's/^"//' -e 's/"$//')"
  fi
  while IFS= read -r v; do
    # Skip short or non-secret-looking values (bucket names, regions, booleans).
    (( ${#v} >= 12 )) || continue
    checked=$((checked + 1))
    if grep -rIlF -- "$v" "$work/fs" >/dev/null 2>&1 || grep -qF -- "$v" <<<"$meta"; then hits=$((hits + 1)); fi
  done <<<"$values"
  if (( hits > 0 )); then echo "FAIL - $hits real secret value(s) from $(basename "$f") are inside the image"; fail=1
  else echo "ok   - none of $checked secret values from $(basename "$f") are inside the image"; fi
done
(( fail == 0 )) && echo "LAYER SCAN PASSED" || { echo "LAYER SCAN FAILED"; exit 1; }
