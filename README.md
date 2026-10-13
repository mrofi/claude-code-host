# claude-code-host

A container image that runs [Claude Code](https://claude.com/claude-code) inside tmux with **Remote Control** on, so you can open it from claude.ai/code (browser or phone) and start more sessions from there. Your `~/.claude` (login, history, skills) can be backed up to any S3-compatible bucket with client-side encryption, so a restart brings back your setup.

It is a **base image**: you build your own Dockerfile on top of it and add the tools, config and boot logic your sessions need.

```
        claude.ai/code  ──►  Remote Control  ──►  tmux "server" session ─┬─ session you open in the browser
                                                                          └─ spawn-session.sh <name> --repo ...  (more tmux sessions)
        ~/.claude  ◄── backup every 5 min, restore on boot ──►  S3 bucket (rclone crypt)
```

Single user, one machine. It is not a multi-tenant service.

## Read this first

- **Sessions run with `--dangerously-skip-permissions`.** Nobody approves their commands. Anything the container can reach (tokens in its environment, cloud credentials, networks), a prompt-injected repo or web page could use. Give the container only credentials you are willing to lose, preferably read-only.
- **Claude Code is not open source and this image does not include it.** The published image leaves it out; you install it in your own Dockerfile (below), under [Anthropic's terms](https://www.anthropic.com/legal/commercial-terms). If you build this repo yourself with `INSTALL_CLAUDE=1` (the default), npm downloads it on your machine.
- **Git tokens.** `GITHUB_TOKEN` / `AZDO_PAT` are used by every git command in the container, pushes included, and sessions run without permission prompts. Prefer a read-only fine-grained token; a write token lets a prompt-injected repo or page push to those repos.
- **Remote Control needs a claude.ai login** (a subscription account), not an API key. Whoever holds the login credentials has your account, so treat the bucket and its encryption password accordingly.
- The refresh behavior of a login that was copied from another machine is only lightly tested (see [docs/how-it-works.md](docs/how-it-works.md#login)).

## Quick start

1. Make your own image. The base has no Claude Code, so add it:

   ```dockerfile
   FROM ghcr.io/mrofi/claude-code-host:latest
   USER root
   RUN npm install -g @anthropic-ai/claude-code@2.1.296   # pin the version you tested
   USER node
   ```

   `docker build -t my-claude-host .`

   (Or build this repo directly, which includes Claude Code: `docker build -t my-claude-host .`)

2. Run it. Without a bucket nothing is persisted, but it works:

   ```
   docker run -d --name claude-host -p 8080:8080 my-claude-host
   ```

   The port (health endpoint only) is `PORT`, default 8080: `-e PORT=9000 -p 9000:9000` to change it.

3. Log in once. The container starts, but Claude Code needs your login. Pick one:
   - **Upload an existing login** (Linux): `scripts/upload-login.sh ~/.claude/.credentials.json ~/.claude.json` against your bucket, then start the container. See [docs/how-it-works.md](docs/how-it-works.md#login).
   - On macOS the login lives in the Keychain, not in a file, so log in inside the container instead: `docker exec -it claude-host tmux attach -t server`, then follow the login prompt. (Not tested by me.)

4. Open claude.ai/code. A session named `server` appears. Create sessions from there, or ask a session to run `spawn-session.sh <name> --repo https://github.com/you/repo`.

## Persistence (optional, recommended)

Set these and the container restores `~/.claude` on boot and backs it up every 5 minutes and on `SIGTERM`:

| Variable | Meaning |
|---|---|
| `S3_BUCKET`, `S3_ENDPOINT`, `S3_REGION`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`, `S3_PROVIDER` | Any S3-compatible bucket (AWS, Cloudflare R2, MinIO, IDrive e2, ...). |
| `CRYPT_PASSWORD`, `CRYPT_SALT` | **Required** when `S3_BUCKET` is set. Everything is encrypted client-side (rclone crypt). Keep a copy outside the container: lose them and the backup cannot be read. |
| `S3_PREFIX` | Folder in the bucket (default `claude-host`). Use a different one per container. |

Never run two containers on one prefix: the newest one wins and the older one stops backing up, with a warning in its logs. Details and every other setting: [docs/configuration.md](docs/configuration.md).

## Extend it

Derived images add four kinds of things without editing any base script:

| Add | Where | Effect |
|---|---|---|
| Boot logic | `/home/node/entrypoint.d/*.sh` | Run in name order before the main session starts. A failing or slow hook is logged and skipped. |
| Shutdown logic | `/home/node/shutdown.d/*.sh` | Run on `SIGTERM`, before the final backup. |
| Instructions for the sessions | `/home/node/config/CLAUDE.d/*.md` | Appended to the `CLAUDE.md` the sessions read (tell them about your tools). |
| Claude Code settings | `/home/node/config/settings.d/*.json` | Merged into `~/.claude/settings.json`. |

Plus any packages or tools you install. A complete, tested example is in [`examples/extend`](examples/extend); the guide is [docs/extending.md](docs/extending.md).

## Deploy

It is a normal container: anything that can run one works. See [docs/deploy.md](docs/deploy.md) for Docker, Docker Compose and Hugging Face Spaces (the one I have run it on).

## What is in the image

Node 22 (Debian bookworm), tmux, git, curl, jq, rclone, openssh-client, a non-root `node` user (uid 1000), and the scripts in `scripts/`:

| Script | Purpose |
|---|---|
| `entrypoint.sh` | Boot: restore, seed config, health endpoint, backup loop, hooks, the tmux `server` session. |
| `spawn-session.sh`, `list-sessions.sh`, `kill-session.sh` | More Claude Code sessions in tmux, optionally on a cloned repo (`MAX_SESSIONS` caps them). |
| `backup.sh`, `restore.sh`, `upload-login.sh`, `lease.sh` | Persistence. |
| `git-credential-env.sh` | Serves `GITHUB_TOKEN` / `AZDO_PAT` to git for those hosts only. |

## Develop

```
bats tests/*.bats                               # unit tests (needs bats, rclone, tmux, jq, git, socat)
shellcheck -x -P SCRIPTDIR scripts/*.sh tests/*.sh
docker build --build-arg INSTALL_CLAUDE=0 -t claude-host .
tests/smoke.sh claude-host                      # boots the image against a local S3 server (rclone serve s3) with a stub claude
tests/layer-scan.sh claude-host                 # looks for secrets in every image layer
```

The smoke test uses a local S3 server, which is more forgiving than some real providers. After changing how files are written to the bucket, also try the scripts once against your real bucket with encryption on, in a throwaway `S3_PREFIX`.

## License

MIT, see [LICENSE](LICENSE). Claude Code itself is licensed separately by Anthropic.
