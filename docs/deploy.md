# Deploying

The image is a normal container with one open port (`PORT`, default 8080): the health endpoint, plus VS Code at `/code` if you enabled it (see [configuration](configuration.md#vs-code-in-the-browser); that makes the port sensitive, so put TLS in front of it). Remote Control connects **outbound** to Anthropic, so you do not need to expose anything for claude.ai/code to reach it. The port is only for platforms that insist on probing one.

Build your own image first (see the README: the base has no Claude Code). Below, `my-claude-host` is that image.

## Docker

```
docker run -d --name claude-host --restart unless-stopped \
  -p 8080:8080 \
  -e S3_BUCKET=... -e S3_ENDPOINT=... -e S3_REGION=... -e S3_ACCESS_KEY_ID=... -e S3_SECRET_ACCESS_KEY=... \
  -e CRYPT_PASSWORD=... -e CRYPT_SALT=... \
  my-claude-host
```

Use `--env-file` rather than `-e` for secrets so they stay out of your shell history. Stop it with `docker stop` (not `kill`): `SIGTERM` triggers the final backup. Give it a few seconds: `docker stop -t 30`.

A bind mount or volume on `/home/node` is an alternative to the bucket if the container always runs on the same machine, but then nothing is encrypted and nothing follows the container to another host.

## Docker Compose (example, not covered by the tests)

```yaml
services:
  claude-host:
    image: my-claude-host
    restart: unless-stopped
    stop_grace_period: 30s
    env_file: .env          # S3_*, CRYPT_*, GITHUB_TOKEN ... (never commit this file)
    ports: ["8080:8080"]
```

## Kubernetes and other container platforms

Run it as a single replica (never two on one `S3_PREFIX`), with secrets in the platform's secret store, a `terminationGracePeriodSeconds` of at least 30, and an HTTP probe on `PORT` if the platform wants one. I have not tested these platforms; the same image and variables apply.

## Hugging Face Spaces (tested by the author)

A free CPU Space can run it, with these points:

- Create a **private** Space with the **Docker** SDK. It holds secrets and a live login.
- The Space repo contains a `Dockerfile` (your derived image's Dockerfile, which must start `FROM` a public image or build everything itself) and a `README.md` with this front matter:

  ```
  ---
  title: Claude Code Host
  sdk: docker
  app_port: 8080
  ---
  ```
- Put every credential in the Space's **Secrets** and every non-secret in **Variables**. Adding or changing one restarts the Space.
- A Space restart is a **clean container**: only what is in the bucket comes back (login, history, skills, settings). Clones and files in `~/work` are gone, and sessions are not revived. Free Spaces can also sleep when idle.
- Spaces run containers as uid 1000, which this image already uses.
- Do not pass tokens in the build context or Dockerfile: they would end up in the image layers.

## After the first start

Check the logs for, in order: `starting as uid 1000`, `[lease] claimed backup prefix`, `[restore] done`, `tmux session 'server' started`, `[health] listening`. A `NOT encrypted` warning or `cannot be decrypted` error means the encryption settings are wrong. Then open claude.ai/code: a session named `server` appears.

`[restore] done` only proves files came back, not that the login still works. If Claude Code exits at start with a login error, the message appears in the logs and the container stays up.
