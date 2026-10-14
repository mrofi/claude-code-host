#!/usr/bin/env bats

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  export TMUX_TMPDIR="$BATS_TEST_TMPDIR/tmux"
  mkdir -p "$HOME/work" "$TMUX_TMPDIR" "$BATS_TEST_TMPDIR/bin"
  # Stub claude: records its args and stays alive. Stub git: records args, fakes a clone.
  cat > "$BATS_TEST_TMPDIR/bin/claude" <<'STUB'
#!/usr/bin/env bash
echo "$@" > "$PWD/.claude-args"
sleep 300
STUB
  cat > "$BATS_TEST_TMPDIR/bin/git" <<'STUB'
#!/usr/bin/env bash
echo "$@" >> "$GIT_LOG"
if [[ "$1" == clone ]]; then mkdir -p "${@: -1}/.git"; fi
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/"*
  export GIT_LOG="$BATS_TEST_TMPDIR/git.log"
  export PATH="$BATS_TEST_TMPDIR/bin:$BATS_TEST_DIRNAME/../scripts:$PATH"
  unset SESSION_CAP AZDO_PAT GITHUB_TOKEN
}

teardown() { tmux kill-server 2>/dev/null || true; }

AZ="https://dev.azure.com/acme/proj/_git/repo"
GH="https://github.com/acme/repo"

@test "invalid session names are refused" {
  for n in "" "Up" "../x" "-x" "a b" "a;b" "$(printf 'a%.0s' {1..40})"; do
    run spawn-session.sh "$n"
    [ "$status" -ne 0 ]
  done
}

@test "unknown hosts, plain http, ssh or credential-bearing URLs are refused" {
  for u in "https://gitlab.com/a/b" "http://github.com/a/b" "git@github.com:a/b.git" "https://u:pw@github.com/a/b" "http://dev.azure.com/o/p/_git/r" "file:///etc" \
           "git@ssh.dev.azure.com:v3/o/p/r" "https://u:pw@dev.azure.com/o/p/_git/r" \
           "https://dev.azure.com/o/p/_git/r;rm" "--upload-pack=x"; do
    run spawn-session.sh foo --repo "$u"
    [ "$status" -ne 0 ]
    [[ "$output" == *"repo URL"* ]]
  done
}

@test "a github.com repo is accepted and cloned" {
  run spawn-session.sh foo --repo "$GH"
  [ "$status" -eq 0 ]
  grep -q "$GH" "$GIT_LOG"
}

@test "spawn without a repo starts claude with remote control in ~/work/<name>" {
  run spawn-session.sh foo
  [ "$status" -eq 0 ]
  tmux has-session -t foo
  sleep 1
  [ "$(cat "$HOME/work/foo/.claude-args")" = "--dangerously-skip-permissions --remote-control foo" ]
  [ "$(jq -r '.projects["'"$HOME"'/work/foo"].hasTrustDialogAccepted' "$HOME/.claude.json")" = "true" ]
}

@test "a duplicate session name is refused" {
  spawn-session.sh foo
  run spawn-session.sh foo
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]]
}

@test "repo is cloned over https with the requested branch, and the PAT never reaches the command line" {
  export AZDO_PAT="pat-should-not-leak-1234"
  run spawn-session.sh foo --repo "$AZ" --branch dev
  [ "$status" -eq 0 ]
  grep -q "clone" "$GIT_LOG"
  grep -q -- "--branch dev" "$GIT_LOG"
  grep -q "$AZ" "$GIT_LOG"
  run grep -c "pat-should-not-leak-1234" "$GIT_LOG"
  [ "$output" = "0" ]
  [[ "$output" != *"pat-should-not-leak-1234"* ]]
}

@test "the session cap is enforced" {
  export SESSION_CAP=1
  spawn-session.sh one
  run spawn-session.sh two
  [ "$status" -ne 0 ]
  [[ "$output" == *"session cap"* ]]
}

@test "kill-session removes a session and refuses the server session" {
  spawn-session.sh foo
  run kill-session.sh foo
  [ "$status" -eq 0 ]
  run tmux has-session -t foo
  [ "$status" -ne 0 ]
  tmux new-session -d -s server "sleep 300"
  run kill-session.sh server
  [ "$status" -ne 0 ]
  tmux has-session -t server
}

@test "list-sessions shows spawned sessions" {
  spawn-session.sh foo
  run list-sessions.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"foo"* ]]
}

@test "credential helper answers per host, only from the matching environment variable" {
  export AZDO_PAT="az-tok" GITHUB_TOKEN="gh-tok"
  run bash -c 'printf "protocol=https\nhost=dev.azure.com\n\n" | git-credential-env.sh get'
  [[ "$output" == *"password=az-tok"* ]]
  [[ "$output" != *"gh-tok"* ]]
  run bash -c 'printf "protocol=https\nhost=org.visualstudio.com\n\n" | git-credential-env.sh get'
  [[ "$output" == *"password=az-tok"* ]]
  run bash -c 'printf "protocol=https\nhost=github.com\n\n" | git-credential-env.sh get'
  [[ "$output" == *"password=gh-tok"* ]]
  [[ "$output" != *"az-tok"* ]]
  run bash -c 'printf "protocol=https\nhost=gitlab.com\n\n" | git-credential-env.sh get'
  [ -z "$output" ]
  unset AZDO_PAT GITHUB_TOKEN
  run bash -c 'printf "protocol=https\nhost=dev.azure.com\n\n" | git-credential-env.sh get'
  [ -z "$output" ]
  run bash -c 'printf "protocol=https\nhost=github.com\n\n" | git-credential-env.sh get'
  [ -z "$output" ]
}

@test "MAX_SESSIONS sets the spawn cap, and SESSION_CAP overrides it" {
  export MAX_SESSIONS=1
  spawn-session.sh one
  run spawn-session.sh two
  [ "$status" -ne 0 ]
  [[ "$output" == *"session cap reached (1"* ]]
  export SESSION_CAP=2
  run spawn-session.sh two
  [ "$status" -eq 0 ]
}

@test "an invalid MAX_SESSIONS is rejected with a clear message" {
  for v in abc 0 -1 1.5 "" " "; do
    export MAX_SESSIONS="$v"
    run spawn-session.sh foo
    if [ -n "${v// /}" ]; then
      [ "$status" -ne 0 ]
      [[ "$output" == *"MAX_SESSIONS"* ]]
    fi
  done
}

@test "github.com: GITHUB_TOKEN_<OWNER> is chosen by the repo owner (case-insensitive, - becomes _), else GITHUB_TOKEN" {
  export GITHUB_TOKEN=default-tok GITHUB_TOKEN_ROKETID=roketid-tok GITHUB_TOKEN_LIVECMS=livecms-tok GITHUB_TOKEN_MY_ORG=myorg-tok
  ask() { printf 'protocol=https\nhost=github.com\npath=%s\n\n' "$1" | git-credential-env.sh get; }
  run ask roketid/proxy.git;  [[ "$output" == *password=roketid-tok* ]]
  run ask LiveCMS/site;       [[ "$output" == *password=livecms-tok* ]]
  run ask my-org/x;           [[ "$output" == *password=myorg-tok* ]]
  run ask mrofi/repo;         [[ "$output" == *password=default-tok* ]]
  run ask "";                 [[ "$output" == *password=default-tok* ]]
  unset GITHUB_TOKEN
  run ask mrofi/repo;         [ -z "$output" ]
  run ask roketid/proxy.git;  [[ "$output" == *password=roketid-tok* ]]
}

@test "an owner name cannot be used to read another variable" {
  export GITHUB_TOKEN=default-tok SECRET_THING=leak
  run bash -c 'printf "host=github.com\npath=%s\n\n" "x\$(echo pwn)/y" | git-credential-env.sh get'
  [[ "$output" == *password=default-tok* ]]
  [[ "$output" != *leak* ]]
}
