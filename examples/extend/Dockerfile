# Example: your own image on top of the claude-code-host base.
#   docker build -t my-claude-host examples/extend
# Replace the base with the image you pulled or built (see the README).
ARG BASE=ghcr.io/mrofi/claude-code-host:latest
FROM ${BASE}

# The published base image does not include Claude Code: install it here (needs root for a global npm install).
ARG INSTALL_CLAUDE=1
USER root
RUN if [ "$INSTALL_CLAUDE" = "1" ]; then npm install -g @anthropic-ai/claude-code && npm cache clean --force; fi

# Add whatever tools your sessions need. System packages need root.
RUN apt-get update && apt-get install -y --no-install-recommends ripgrep \
 && rm -rf /var/lib/apt/lists/*
USER node

# Boot hooks run before the main session starts; shutdown hooks run before the final backup.
COPY --chown=node:node entrypoint.d/ /home/node/entrypoint.d/
COPY --chown=node:node shutdown.d/   /home/node/shutdown.d/
# Tell the sessions about your tools (appended to ~/work/CLAUDE.md) and add Claude Code settings.
COPY --chown=node:node CLAUDE.d/     /home/node/config/CLAUDE.d/
COPY --chown=node:node settings.d/   /home/node/config/settings.d/
