# How it works

## Boot

`entrypoint.sh`, in order:

1. Starts a tiny HTTP health endpoint (so a platform sees a live service even while restore runs).
2. Restores `~/.claude` from the bucket (hard limit 90 s; an unreachable bucket is logged and boot continues).
3. Claims the backup prefix (`lease.sh`), seeds `~/.claude.json` and `~/work/CLAUDE.md`, merges settings.
4. Starts the backup loop (only if `S3_BUCKET` is set and encryption is configured).
5. Runs your boot hooks (`entrypoint.d`).
6. Starts a tmux session named `server` running `claude remote-control --spawn same-dir --capacity N --permission-mode bypassPermissions` in `~/work`. That is the process claude.ai/code connects to.
7. Prints snapshots of the pane to the logs (at +20 s and +120 s), because many hosts give you no shell. Then it waits; on `SIGTERM` it runs shutdown hooks, a final backup and stops cleanly.

`MAIN_MODE=interactive` starts one `claude --dangerously-skip-permissions --remote-control main` instead of the server.

## Sessions

- **From claude.ai/code:** the `server` process accepts new sessions up to `MAX_SESSIONS`, each in `~/work`.
- **From a session:** `spawn-session.sh <name> --repo <url>` clones into `~/work/<name>` and starts `claude --dangerously-skip-permissions --remote-control <name>` in its own tmux session, which appears in claude.ai/code under that name. `list-sessions.sh` and `kill-session.sh` manage them. The `server` and `main` sessions cannot be killed this way.
- Names are lowercase `a-z0-9-`, up to 31 characters. URLs must be https on github.com or Azure DevOps, without credentials.

Why tmux: Claude Code needs a real terminal, and tmux keeps it alive and lets you `docker exec -it <ctr> tmux attach -t <name>` to look.

## What a headless start needs

Learned by testing Claude Code 2.1.296; newer versions may differ.

- A login: `~/.claude/.credentials.json` (mode 600) plus a minimal `~/.claude.json`.
- The workspace marked trusted (`projects["<dir>"].hasTrustDialogAccepted`), or Claude Code refuses to start.
- `remoteDialogSeen: true`, or it waits on an `Enable Remote Control? (y/n)` prompt.
- `skipDangerousModePermissionPrompt: true` in settings, or the skip-permissions confirmation waits for a keypress.
- A TTY (tmux provides it).

`seed-state.sh` and `seed-config.sh` set these on every boot.

## Persistence

Backed up (to `<prefix>/claude/`): `~/.claude` except `cache`, `statsig`, `shell-snapshots`, `debug`, `ide` (top level only: `plugins/cache` is kept) and `*.lock`. That includes history, skills, agents, commands, plugins and settings. Also a **minimal** `~/.claude.json` with only `oauthAccount`, `hasCompletedOnboarding`, `userID` and `theme`. The machine ids and per-project entries are never copied, so a restored container looks like a new machine on the same account.

Not backed up: `~/work` (clone and push), anything outside `~/.claude`, and your platform's secrets.

When: every `BACKUP_INTERVAL` (300 s) and on `SIGTERM`. A hard kill loses up to one interval. `backup.sh` forces one now.

Encryption: rclone crypt (file contents and names). The bucket sees only random-looking names. A wrong password is reported as an error (`cannot be decrypted`), never as an empty bucket, and a half-configured container (bucket but no password) refuses to touch the bucket.

### Two containers on one prefix

`lease.sh` keeps a small lease file next to the backup. The newest container to boot takes it (with a warning if the previous owner was recent). The older one then refuses to back up (`owns this backup prefix`), so it cannot overwrite the newer state. A crashed container's lease expires after `LEASE_TTL`. If you want two containers, give each its own `S3_PREFIX`.

## Login

Remote Control needs a claude.ai login. Two ways to get one into the container:

1. **Upload an existing login** from a machine where you are logged in with `claude`: run `scripts/upload-login.sh ~/.claude/.credentials.json ~/.claude.json` with the `S3_*` and `CRYPT_*` variables set. It uploads only those two files (the second reduced to the minimal keys) and never deletes anything in the bucket. This works where Claude Code keeps the login in `~/.claude/.credentials.json` (Linux). On macOS it is in the Keychain, so use option 2.
2. **Log in inside the container:** attach to the `server` tmux session and follow the prompts. The login is then included in the next backup. (Not tested by the author.)

Tested: a login restored this way started and connected on a Team subscription account, and new sessions could be created from claude.ai/code.

Not tested, so be aware: what happens when the access token is refreshed inside the container. If the refresh token rotates, the copy on your own machine may stop working and ask you to log in again. If that happens, give the container its own login (option 2) instead of sharing one.

## Failure behavior

| Situation | Result |
|---|---|
| Bucket unreachable at boot | Logged (`[restore] ERROR`); boot continues without restored state; sessions work. |
| Wrong `CRYPT_PASSWORD` | Restore and backup refuse with `cannot be decrypted`; nothing is overwritten. |
| `S3_BUCKET` set, no `CRYPT_PASSWORD` | Persistence disabled with an error; nothing uploaded. |
| `claude` missing or exits at start | The container and the tmux pane stay up; the error and exit status are in the logs. |
| A boot hook fails or hangs | Logged and skipped after `HOOK_TIMEOUT`; the main session still starts. |
| Two containers, one prefix | The older stops backing up, with an error. |

## Security notes

- Sessions run without permission prompts. Limit what the container can reach; prefer read-only tokens.
- Secrets live in the container's environment and are visible to every session. `CLAUDE.md` tells sessions not to print them, but that is an instruction, not a control.
- Do not put credentials in the image: `tests/layer-scan.sh` checks every layer, including deleted files, for secret patterns, and can search for the exact values of your real secrets.
- The bucket holds your Claude login (encrypted). Use a bucket key limited to that bucket, and keep `CRYPT_PASSWORD` and `CRYPT_SALT` in a password manager.
- The container runs as uid 1000, not root.
