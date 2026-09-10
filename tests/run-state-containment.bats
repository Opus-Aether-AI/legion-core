#!/usr/bin/env bats

@test "run state treats containment_failed as terminal" {
  local root state_lib registry run_id record
  root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  state_lib="$root/legion-observability/scripts/lib/state.sh"
  registry="$BATS_TEST_TMPDIR/registry"
  run_id="containment-terminal"
  record="$registry/$run_id.json"
  mkdir -p "$registry"

  LEGION_REGISTRY_DIR="$registry" bash -c '
    source "$1"
    legion_write_adapter_run_state containment_failed "$2" /repo /run /wt branch model workspace-write HEAD arch
    legion_write_adapter_run_state running "$2" /repo /run /wt branch model workspace-write HEAD arch
  ' _ "$state_lib" "$run_id"

  jq -e '.lifecycle.phase == "containment_failed" and .state_version == 1' "$record"
}
