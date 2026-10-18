#!/usr/bin/env bats
# code-url.sh: the /code link for a folder, from CODE_URL.

setup() { export PATH="$BATS_TEST_DIRNAME/../scripts:$PATH"; }

@test "builds the link for a path, URL-encoded, ignoring a trailing slash on CODE_URL" {
  mkdir -p "$BATS_TEST_TMPDIR/my repo"
  CODE_URL=https://h.example.com/ run code-url.sh "$BATS_TEST_TMPDIR/my repo"
  [ "$status" -eq 0 ]
  [ "$output" = "https://h.example.com/code/?folder=$(jq -rn --arg d "$BATS_TEST_TMPDIR/my repo" '$d|@uri')" ]
}

@test "defaults to the current directory" {
  cd "$BATS_TEST_TMPDIR"
  CODE_URL=https://h.example.com run code-url.sh
  [[ "$output" == "https://h.example.com/code/?folder="*"$(basename "$BATS_TEST_TMPDIR")" ]]
}

@test "fails with a clear message without CODE_URL, or for a missing directory" {
  unset CODE_URL
  run code-url.sh
  [ "$status" -ne 0 ]; [[ "$output" == *CODE_URL* ]]
  CODE_URL=x run code-url.sh /nope/nope
  [ "$status" -ne 0 ]; [[ "$output" == *"not a directory"* ]]
}
