#!/usr/bin/env bash
# Start a new Claude Code session (tmux + Remote Control), optionally on a cloned repo.
#   spawn-session.sh <name> [--repo <https github.com or Azure DevOps url>] [--branch <branch>]
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "spawn-session: $*" >&2; exit "${2:-1}"; }

name="${1:-}"; shift || true
[[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || die "invalid session name (lowercase letters, digits, '-', max 31 chars)" 2

repo=""; branch=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)   repo="${2:-}"; shift 2 ;;
    --branch) branch="${2:-}"; shift 2 ;;
    *) die "unknown argument: $1" 2 ;;
  esac
done

if [[ -n "$repo" ]]; then
  # https only, known git hosts only, optional bare username (no password), no shell metacharacters.
  re='^https://([A-Za-z0-9._-]+@)?(github\.com|dev\.azure\.com|[A-Za-z0-9-]+\.visualstudio\.com)/[A-Za-z0-9._~%/-]+$'
  [[ "$repo" =~ $re ]] || die "repo URL must be an https github.com or Azure DevOps URL without credentials" 2
fi
[[ -z "$branch" || "$branch" =~ ^[A-Za-z0-9._/-]+$ ]] || die "invalid branch name" 2
[[ "$branch" != -* ]] || die "invalid branch name" 2

if tmux has-session -t "$name" 2>/dev/null; then
  die "session '$name' already exists"
fi

cap="${SESSION_CAP:-${MAX_SESSIONS:-3}}"
[[ "$cap" =~ ^[1-9][0-9]*$ ]] || die "MAX_SESSIONS/SESSION_CAP must be a positive integer (got '$cap')" 2
running="$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -vcE '^(server|main)$' || true)"
(( running < cap )) || die "session cap reached ($cap spawned sessions); kill one first"

dir="$HOME/work/$name"
if [[ -n "$repo" ]]; then
  [[ ! -e "$dir" ]] || die "directory $dir already exists"
  # Credential helper is injected through env, so the token is never written to .git/config.
  export GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper
  export GIT_CONFIG_VALUE_0="$here/git-credential-env.sh"
  args=(clone)
  [[ -n "$branch" ]] && args+=(--branch "$branch")
  git "${args[@]}" -- "$repo" "$dir" >&2 || die "git clone failed"
else
  mkdir -p "$dir"
fi

"$here/seed-state.sh" "$dir"
tmux new-session -d -s "$name" -c "$dir" -x 200 -y 50 \
  "claude --dangerously-skip-permissions --remote-control $name; echo \"[$name] claude exited with status \$?\"; sleep infinity"
echo "started session '$name' in $dir (open claude.ai/code to use it)"
