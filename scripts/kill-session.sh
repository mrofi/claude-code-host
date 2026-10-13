#!/usr/bin/env bash
# Stop a spawned session. The main session cannot be killed from here.
set -euo pipefail
name="${1:-}"
[[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || { echo "kill-session: invalid name" >&2; exit 2; }
[[ "$name" != server && "$name" != main ]] || { echo "kill-session: refusing to kill the main session" >&2; exit 2; }
tmux has-session -t "$name" 2>/dev/null || { echo "kill-session: no such session '$name'" >&2; exit 1; }
tmux kill-session -t "$name"
echo "killed session '$name' (its directory ~/work/$name is kept)"
