#!/usr/bin/env bash
# git credential helper: serves a token from the environment for known git hosts only. The token never
# comes from a file or the command line.
#   github.com                          -> GITHUB_TOKEN
#   dev.azure.com, *.visualstudio.com   -> AZDO_PAT
set -euo pipefail
[[ "${1:-}" == get ]] || exit 0

host=""
while IFS='=' read -r k v; do
  [[ -z "$k" ]] && break
  [[ "$k" == host ]] && host="$v"
done

case "$host" in
  github.com)                        user="x-access-token"; token="${GITHUB_TOKEN:-}" ;;
  dev.azure.com|*.visualstudio.com)  user="azdo";           token="${AZDO_PAT:-}" ;;
  *) exit 0 ;;
esac
[[ -n "$token" ]] || exit 0

echo "username=$user"
echo "password=$token"
