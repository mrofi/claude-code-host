# Configuration

Everything is an environment variable. Unset optional ones are skipped quietly. Treat anything holding a credential as a secret in your platform (not a plain variable).

## Persistence (S3-compatible bucket)

| Name | Secret | Default | Meaning |
|---|---|---|---|
| `S3_BUCKET` | | none | Setting it turns persistence on. |
| `S3_ENDPOINT` | | none | The provider's endpoint URL. |
| `S3_REGION` | | none | Region name. |
| `S3_PROVIDER` | | `Other` | rclone provider name (`AWS`, `Cloudflare`, `Minio`, `Other`, ...). |
| `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY` | yes | none | Credentials for the bucket. Use a key limited to this bucket. |
| `S3_PREFIX` | | `claude-host` | Folder inside the bucket. One per container. |
| `CRYPT_PASSWORD`, `CRYPT_SALT` | yes | none | Client-side encryption (rclone crypt). `CRYPT_PASSWORD` is required when `S3_BUCKET` is set: without it the scripts refuse to back up or restore rather than upload in plaintext. The salt is optional but recommended. Keep both outside the container. |
| `ALLOW_UNENCRYPTED` | | unset | `1` allows a bucket without encryption. Not recommended: it holds your Claude login. |
| `BACKUP_INTERVAL` | | `300` | Seconds between backups. A backup also runs on `SIGTERM`. |
| `LEASE_TTL` | | `900` | Seconds after which another instance's lease counts as stale. Keep it above `BACKUP_INTERVAL`. |
| `RCLONE_CONTIMEOUT`, `RCLONE_TIMEOUT`, `RCLONE_RETRIES`, `RCLONE_LOW_LEVEL_RETRIES` | | `10s`, `30s`, `1`, `1` | How long an unreachable bucket may delay boot. Rarely changed. |

## Sessions

| Name | Default | Meaning |
|---|---|---|
| `MAX_SESSIONS` | `3` | Concurrent sessions. Sets both the server capacity (sessions created from claude.ai/code) and the cap for `spawn-session.sh`. Must be a positive integer. |
| `CAPACITY` | `MAX_SESSIONS` | Override for the server capacity only. |
| `SESSION_CAP` | `MAX_SESSIONS` | Override for the `spawn-session.sh` cap only. |
| `MAIN_MODE` | `server` | `interactive` runs a single `claude --remote-control main` instead of the multi-session server. |
| `GITHUB_TOKEN` (secret) | none | Default token for github.com, used by every git command in the container (clone, pull, push). Use a read-only fine-grained token unless sessions must push. |
| `GITHUB_TOKEN_<OWNER>` (secret) | none | Token for repos of one account or org, chosen by the repo owner and tried before `GITHUB_TOKEN`. `<OWNER>` is the name in upper case with other characters as `_`: `GITHUB_TOKEN_ROKETID` for `github.com/roketid/...`, `GITHUB_TOKEN_MY_ORG` for `my-org`. |
| `AZDO_PAT` (secret) | none | Same for Azure DevOps (`dev.azure.com`, `*.visualstudio.com`). Code: Read is enough. |

Git is configured system-wide with a credential helper (`git-credential-env.sh`), so **every** git command in the container (clone, pull, push), including those the sessions run themselves, uses the token for those hosts. The token is never put in a URL, `.git/config` or a process argument. With a read-only token, pushes are refused by the host. With a write token, the sessions (which run without permission prompts) can push to the repos it covers: use a fine-grained token limited to the repos you need, with an expiry. Without a token, git fails fast instead of prompting.

**Several accounts or orgs.** A fine-grained GitHub token belongs to exactly one owner, so create one token per owner (each limited to the repos you need) and set one secret each, for example `GITHUB_TOKEN_MROFI`, `GITHUB_TOKEN_ROKETID` and `GITHUB_TOKEN_LIVECMS`. Git sends the repo's owner to the helper, which uses that owner's token. A repo whose owner has no `GITHUB_TOKEN_<OWNER>` falls back to `GITHUB_TOKEN`, so that token is also sent to other owners' repos on github.com (it simply fails there if it has no access). Leave `GITHUB_TOKEN` unset if you want only the per-owner tokens to apply.

## Runtime

| Name | Default | Meaning |
|---|---|---|
| `PORT` | `8080` | Port of the health endpoint (HTTP 200 `ok`). Platforms that probe a port, such as Hugging Face Spaces, need it to match. An invalid value (not a number from 1 to 65535) logs a warning and uses 8080. With plain Docker, publish the same port: `-e PORT=9000 -p 9000:9000`. |
| `ENTRYPOINT_D` | `~/entrypoint.d` | Directory of boot hooks. |
| `SHUTDOWN_D` | `~/shutdown.d` | Directory of shutdown hooks. |
| `HOOK_TIMEOUT` | `60` | Seconds a boot hook may run. |
| `SHUTDOWN_HOOK_TIMEOUT` | `10` | Seconds a shutdown hook may run. Platforms give a short grace period on `SIGTERM`, and the final backup runs after the hooks. |
| `SNAPSHOT_DELAY` | `20` | Seconds before the first snapshot of the `server` pane appears in the logs. |
| `CLAUDE_D`, `SETTINGS_D`, `CONFIG_DIR` | under `~/config` | Where `CLAUDE.d`, `settings.d` and the base config are read from. |
