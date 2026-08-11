#!/usr/bin/env bats
# Pi reads the shared catalog directly. Hermes setup manages one symlink into
# the native skills directory that Hermes actually scans.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SETUP_SH="$ROOT/legion-setup/scripts/legion-setup.sh"
  INSTALL_SH="$ROOT/scripts/install.sh"
  export HOME="$BATS_TEST_TMPDIR/home"
  export AGENTS_HOME="$BATS_TEST_TMPDIR/agents"
  export HERMES_HOME="$HOME/.hermes"
  export PATH="$ROOT/legion-setup/bin:$ROOT/legion-router/bin:$BATS_TEST_DIRNAME/mocks/bin:$PATH"
  for kind in pi hermes; do
    mkdir -p "$AGENTS_HOME/skills/legion-$kind-mode"
    printf -- '---\nname: legion-%s-mode\ndescription: d\n---\nbody\n' "$kind" \
      > "$AGENTS_HOME/skills/legion-$kind-mode/SKILL.md"
  done
  mkdir -p "$HERMES_HOME/skills"
  ln -s "$AGENTS_HOME/skills/legion-hermes-mode" "$HERMES_HOME/skills/legion-hermes-mode"
}

@test "legion-setup pi verify confirms the shared Pi skill and symmetric runtime" {
  run "$SETUP_SH" pi verify
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok legion-pi-mode discoverable"* ]]
  [[ "$output" == *"ok filesystem write sandbox available"* ]]
  [[ "$output" == *"ok pi registered as a coding executor"* ]]
}

@test "legion-setup hermes verify confirms the shared Hermes skill and symmetric runtime" {
  run "$SETUP_SH" hermes verify
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok legion-hermes-mode discoverable"* ]]
  [[ "$output" == *"ok filesystem write sandbox available"* ]]
  [[ "$output" == *"ok hermes registered as a coding executor"* ]]
}

@test "Pi and Hermes setup all is idempotent and leaves the shared catalog untouched" {
  local before after
  rm "$HERMES_HOME/skills/legion-hermes-mode"
  before="$(find "$AGENTS_HOME" -type f -print | sort | xargs shasum)"
  run "$SETUP_SH" pi
  [ "$status" -eq 0 ]
  run "$SETUP_SH" hermes
  [ "$status" -eq 0 ]
  run "$SETUP_SH" hermes
  [ "$status" -eq 0 ]
  after="$(find "$AGENTS_HOME" -type f -print | sort | xargs shasum)"
  [ "$before" = "$after" ]
  [ "$(readlink "$HERMES_HOME/skills/legion-hermes-mode")" = "$AGENTS_HOME/skills/legion-hermes-mode" ]
}

@test "Pi setup verify fails closed when its discoverable mode skill is absent" {
  rm -rf "$AGENTS_HOME/skills/legion-pi-mode"
  run "$SETUP_SH" pi verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing legion-pi-mode"* ]]
}

@test "Hermes verify fails closed when only the shared skill exists" {
  rm "$HERMES_HOME/skills/legion-hermes-mode"
  run "$SETUP_SH" hermes verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing legion-hermes-mode in $HERMES_HOME/skills"* ]]
}

@test "Hermes verify rejects a different skill symlink even when it has SKILL.md" {
  local other="$BATS_TEST_TMPDIR/operator-hermes-mode"
  rm "$HERMES_HOME/skills/legion-hermes-mode"
  mkdir -p "$other"
  printf 'operator-owned\n' > "$other/SKILL.md"
  ln -s "$other" "$HERMES_HOME/skills/legion-hermes-mode"

  run "$SETUP_SH" hermes verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing legion-hermes-mode in $HERMES_HOME/skills"* ]]
}

@test "Hermes setup preserves a non-Legion native skill" {
  rm "$HERMES_HOME/skills/legion-hermes-mode"
  mkdir -p "$HERMES_HOME/skills/legion-hermes-mode"
  printf 'operator-owned\n' > "$HERMES_HOME/skills/legion-hermes-mode/SKILL.md"

  run "$SETUP_SH" hermes
  [ "$status" -ne 0 ]
  [ "$(cat "$HERMES_HOME/skills/legion-hermes-mode/SKILL.md")" = "operator-owned" ]
}

@test "installer exposes Pi and Hermes primary-mode skills through the shared catalog" {
  export AGENTS_HOME="$BATS_TEST_TMPDIR/catalog-agents"
  mkdir -p "$AGENTS_HOME/sources"
  ln -s "$ROOT" "$AGENTS_HOME/sources/legion-core"

  run bash "$INSTALL_SH" --refresh-symlinks --no-claude --no-codex-skills --no-cursor --no-cron
  [ "$status" -eq 0 ]
  [ "$(readlink "$AGENTS_HOME/skills/legion-pi-mode")" = "$AGENTS_HOME/sources/legion-core/legion-pi-mode" ]
  [ "$(readlink "$AGENTS_HOME/skills/legion-hermes-mode")" = "$AGENTS_HOME/sources/legion-core/legion-hermes-mode" ]
}
