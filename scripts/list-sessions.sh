#!/usr/bin/env bash
# List tmux sessions with their working directories.
set -euo pipefail
tmux list-sessions -F '#{session_name}  #{session_path}  (created #{t:session_created})' 2>/dev/null \
  || echo "no sessions"
