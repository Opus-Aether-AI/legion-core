#!/usr/bin/env bats
# legion-setup — install/update dispatcher. Tests the safe (non-network) dispatch paths.

setup() {
  SETUP="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/legion-setup/bin/legion-setup"
  export AGENTS_HOME="$BATS_TEST_TMPDIR/agents"   # clean home -> "not installed"
}

@test "setup: status reports not-installed on a clean home" {
  run "$SETUP" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"not installed"* ]]
}

@test "setup: unknown arg exits 2" {
  run "$SETUP" --bogus
  [ "$status" -eq 2 ]
}

@test "setup: --help prints usage" {
  run "$SETUP" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"install"* ]]
}
