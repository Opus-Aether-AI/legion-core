#!/usr/bin/env bats
# legion-setup — install/update dispatcher. Tests the safe (non-network) dispatch paths.

setup() {
  # Legion's machine-wide state (executor health, day spend, model lists) must
  # come from the test, never from the developer's ~/.legion.
  export LEGION_HOME="$BATS_TEST_TMPDIR/legion-home/.legion"
  unset LEGION_HEALTH_FILE LEGION_RUN_BUDGET_USD LEGION_DAY_BUDGET_USD
  unset LEGION_REVIEW_FIX_MAX_ROUNDS LEGION_MODELS_CACHE_DIR LEGION_HEALTH
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
