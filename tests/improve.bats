#!/usr/bin/env bats

# Public CLI compatibility boundaries for the separate review-only engine.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  IMPROVE="$ROOT/legion-observability/bin/legion-improve"
  HEAL="$ROOT/legion-observability/scripts/legion-heal.sh"
  LEARN="$ROOT/legion-observability/bin/legion-self-learn"
}

@test "legion-improve publishes modes and the durable state-machine contract" {
  [ -x "$IMPROVE" ]
  run bash "$IMPROVE" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"off"* ]]
  [[ "$output" == *"dry-run"* ]]
  [[ "$output" == *"draft"* ]]
  [[ "$output" == *"eligible"* ]]
  [[ "$output" == *"draft_created"* ]]
}

@test "legion-heal remains scoped to doctor findings" {
  run bash "$HEAL" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"doctor"* ]]
  [[ "$output" == *"legion-heal run"* ]]
  [[ "$output" == *"findings only"* ]]

  run bash "$HEAL" run --proposal proposal.json
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown arg"* ]]
}

@test "legacy apply-source is compatibility dry-run and cannot bypass legion-improve" {
  run "$LEARN" run --apply-source --json
  [ "$status" -ne 0 ]
  [[ "$output" == *"legion-improve"* ]]
  [[ "$output" == *"dry-run"* ]]
}
