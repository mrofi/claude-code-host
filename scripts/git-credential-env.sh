#!/usr/bin/env bash
# git credential helper: serves a token from the environment for known git hosts only. The token never
# comes from a file or the command line.
#   github.com                          -> GITHUB_TOKEN_<OWNER> for the repo's owner if set, else GITHUB_TOKEN
#                                          (<OWNER> = the account/org name in upper case, other characters as _;
#                                          e.g. github.com/roketid/x uses GITHUB_TOKEN_ROKETID)
#   dev.azure.com, *.visualstudio.com   -> AZDO_PAT
# Fine-grained GitHub tokens belong to ONE owner, so several accounts/orgs need one token each. git sends the
# repo path only when credential.useHttpPath is on for github.com (the Dockerfile sets it).
set -euo pipefail
[[ "${1:-}" == get ]] || exit 0

host=""; path=""
while IFS='=' read -r k v; do
  [[ -z "$k" ]] && break
  [[ "$k" == host ]] && host="$v"
  [[ "$k" == path ]] && path="$v"
done

token=""
case "$host" in
  github.com)
    user="x-access-token"
    owner="${path%%/*}"
    if [[ -n "$owner" ]]; then
      var="GITHUB_TOKEN_$(printf %s "$owner" | LC_ALL=C tr '[:lower:]' '[:upper:]' | LC_ALL=C tr -c 'A-Z0-9' '_')"
      token="${!var:-}"
    fi
    [[ -n "$token" ]] || token="${GITHUB_TOKEN:-}" ;;
  dev.azure.com|*.visualstudio.com)
    user="azdo"; token="${AZDO_PAT:-}" ;;
  *) exit 0 ;;
esac
[[ -n "$token" ]] || exit 0

echo "username=$user"
echo "password=$token"
