#!/usr/bin/env bats

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  export PATH="$BATS_TEST_DIRNAME/../scripts:$PATH"
}

@test "creates .claude.json with trust and remoteDialogSeen when absent" {
  run seed-state.sh /home/node/work
  [ "$status" -eq 0 ]
  [ "$(jq -r '.projects["/home/node/work"].hasTrustDialogAccepted' "$HOME/.claude.json")" = "true" ]
  [ "$(jq -r .remoteDialogSeen "$HOME/.claude.json")" = "true" ]
}

@test "keeps existing keys and does not override onboarding" {
  echo '{"userID":"u1","hasCompletedOnboarding":true,"projects":{"/other":{"x":1}}}' > "$HOME/.claude.json"
  run seed-state.sh /home/node/work
  [ "$status" -eq 0 ]
  [ "$(jq -r .userID "$HOME/.claude.json")" = "u1" ]
  [ "$(jq -r '.projects["/other"].x' "$HOME/.claude.json")" = "1" ]
  [ "$(jq -r '.projects["/home/node/work"].hasTrustDialogAccepted' "$HOME/.claude.json")" = "true" ]
}

@test "is idempotent" {
  seed-state.sh /w; first="$(cat "$HOME/.claude.json")"
  seed-state.sh /w
  [ "$(cat "$HOME/.claude.json")" = "$first" ]
}

@test "rejects a missing workdir argument" {
  run seed-state.sh
  [ "$status" -ne 0 ]
}
