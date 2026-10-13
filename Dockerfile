# Claude Code host: tmux sessions reachable through Remote Control, with optional S3 persistence.
# Build args:
#   INSTALL_CLAUDE=1  install Claude Code from npm (default, for building it yourself).
#                     The published base image is built with INSTALL_CLAUDE=0; derived images add it.
#   CLAUDE_CODE_VERSION  version to install when INSTALL_CLAUDE=1.
FROM node:22-bookworm-slim

ARG INSTALL_CLAUDE=1
ARG CLAUDE_CODE_VERSION=latest

LABEL org.opencontainers.image.title="claude-code-host" \
      org.opencontainers.image.description="Base image for a Claude Code host: tmux, Remote Control, S3-backed ~/.claude" \
      org.opencontainers.image.source="https://github.com/mrofi/claude-code-host"

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      tmux git curl ca-certificates openssh-client jq rclone procps \
 && rm -rf /var/lib/apt/lists/* \
 && if [ "$INSTALL_CLAUDE" = "1" ]; then \
      npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" && npm cache clean --force; \
    fi

# git asks this helper for credentials for every command (clone, pull, push), not only for spawn-session.sh. It answers
# only for github.com (GITHUB_TOKEN) and Azure DevOps (AZDO_PAT), only when that variable is set, and says nothing
# otherwise. GIT_TERMINAL_PROMPT=0 makes a missing token fail fast instead of waiting for a password nobody can type.
RUN git config --system credential.helper /home/node/bin/git-credential-env.sh
ENV GIT_TERMINAL_PROMPT=0

# node:22 ships a non-root `node` user with uid 1000. Claude Code refuses --dangerously-skip-permissions as
# root, and many hosts require a non-root uid, so everything runs as `node`.
USER node
ENV HOME=/home/node \
    PATH=/home/node/bin:$PATH
WORKDIR /home/node

COPY --chown=node:node scripts/ /home/node/bin/
COPY --chown=node:node config/ /home/node/config/
# Extension points for derived images (see docs/extending.md).
RUN chmod +x /home/node/bin/*.sh 2>/dev/null || true \
 && mkdir -p /home/node/entrypoint.d /home/node/shutdown.d /home/node/config/CLAUDE.d /home/node/config/settings.d

EXPOSE 8080
CMD ["/home/node/bin/entrypoint.sh"]
