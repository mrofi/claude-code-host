#!/usr/bin/env bash
# Runs on SIGTERM, before the final backup (limit: SHUTDOWN_HOOK_TIMEOUT seconds, default 10).
echo "bye from the example hook"
