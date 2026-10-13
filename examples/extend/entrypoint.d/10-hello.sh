#!/usr/bin/env bash
# Runs at every boot, after ~/.claude has been restored. Anything long-lived must be started in the
# background (cmd &). A non-zero exit is logged and ignored; a hook is stopped after HOOK_TIMEOUT seconds.
echo "hello from the example hook (GREETING=${GREETING:-unset})"
touch "$HOME/.example-hook-ran"
