#!/usr/bin/env bash
# Print the browser URL that opens a folder in VS Code (code-server at /code): code-url.sh [path]  (default: cwd).
# Needs CODE_URL, the public base URL of this host (for example https://my-host.example.com), since the container
# cannot know how it is reached from outside.
set -euo pipefail
if [[ -z "${CODE_URL:-}" ]]; then
  echo "code-url.sh: CODE_URL is not set (public base URL of this host), cannot build a link. Tell the owner to set it." >&2
  exit 1
fi
dir="$(realpath -m -- "${1:-$PWD}")"
[[ -d "$dir" ]] || { echo "code-url.sh: not a directory: $dir" >&2; exit 1; }
printf '%s/code/?folder=%s\n' "${CODE_URL%/}" "$(jq -rn --arg d "$dir" '$d | @uri')"
