#!/usr/bin/env bats

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  export CONFIG_DIR="$BATS_TEST_DIRNAME/../config"
  export PATH="$BATS_TEST_DIRNAME/../scripts:$PATH"
}

@test "installs CLAUDE.md into ~/work and the bypass-prompt skip into settings" {
  run seed-config.sh
  [ "$status" -eq 0 ]
  [ -s "$HOME/work/CLAUDE.md" ]
  grep -q "spawn-session.sh" "$HOME/work/CLAUDE.md"
  [ "$(jq -r .skipDangerousModePermissionPrompt "$HOME/.claude/settings.json")" = "true" ]
}

@test "CLAUDE.md is always refreshed from the image" {
  mkdir -p "$HOME/work"; echo stale > "$HOME/work/CLAUDE.md"
  seed-config.sh
  [[ "$(cat "$HOME/work/CLAUDE.md")" != "stale" ]]
}

@test "existing settings are kept, only the required key is forced on" {
  mkdir -p "$HOME/.claude"
  echo '{"theme":"dark","skipDangerousModePermissionPrompt":false,"env":{"A":"1"}}' > "$HOME/.claude/settings.json"
  run seed-config.sh
  [ "$status" -eq 0 ]
  [ "$(jq -r .theme "$HOME/.claude/settings.json")" = "dark" ]
  [ "$(jq -r .env.A "$HOME/.claude/settings.json")" = "1" ]
  [ "$(jq -r .skipDangerousModePermissionPrompt "$HOME/.claude/settings.json")" = "true" ]
}

@test "a corrupt settings.json is not silently destroyed" {
  mkdir -p "$HOME/.claude"
  echo 'not json {' > "$HOME/.claude/settings.json"
  run seed-config.sh
  [ "$status" -ne 0 ]
  [ "$(cat "$HOME/.claude/settings.json")" = "not json {" ]
  [[ "$output" == *"settings.json"* ]]
}

@test "CLAUDE.md never contains a secret-looking value and names every helper script" {
  for s in spawn-session.sh kill-session.sh list-sessions.sh backup.sh; do
    grep -q "$s" "$CONFIG_DIR/CLAUDE.md"
    [ -x "$BATS_TEST_DIRNAME/../scripts/$s" ]
  done
  run grep -E "hf_[A-Za-z0-9]{10,}|AKIA|password=" "$CONFIG_DIR/CLAUDE.md"
  [ "$status" -ne 0 ]
}

@test "fragments from derived images extend CLAUDE.md and settings, in name order" {
  cfg="$BATS_TEST_TMPDIR/cfg"
  cp -r "$CONFIG_DIR" "$cfg"
  mkdir -p "$cfg/CLAUDE.d" "$cfg/settings.d"
  echo "## Tool B" > "$cfg/CLAUDE.d/20-b.md"
  echo "## Tool A" > "$cfg/CLAUDE.d/10-a.md"
  echo '{"env":{"X":"1"},"theme":"light"}' > "$cfg/settings.d/10.json"
  echo '{"theme":"dark"}' > "$cfg/settings.d/20.json"
  CONFIG_DIR="$cfg" run seed-config.sh
  [ "$status" -eq 0 ]
  grep -q "spawn-session.sh" "$HOME/work/CLAUDE.md"
  [ "$(grep -n 'Tool A' "$HOME/work/CLAUDE.md" | cut -d: -f1)" -lt "$(grep -n 'Tool B' "$HOME/work/CLAUDE.md" | cut -d: -f1)" ]
  [ "$(jq -r .env.X "$HOME/.claude/settings.json")" = "1" ]
  [ "$(jq -r .theme "$HOME/.claude/settings.json")" = "dark" ]
  [ "$(jq -r .skipDangerousModePermissionPrompt "$HOME/.claude/settings.json")" = "true" ]
}

@test "an invalid settings fragment fails loudly and leaves settings.json untouched" {
  cfg="$BATS_TEST_TMPDIR/cfg"
  cp -r "$CONFIG_DIR" "$cfg"; mkdir -p "$cfg/settings.d"
  echo 'nope {' > "$cfg/settings.d/10.json"
  mkdir -p "$HOME/.claude"; echo '{"theme":"x"}' > "$HOME/.claude/settings.json"
  CONFIG_DIR="$cfg" run seed-config.sh
  [ "$status" -ne 0 ]
  [ "$(cat "$HOME/.claude/settings.json")" = '{"theme":"x"}' ]
}
