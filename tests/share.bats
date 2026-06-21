#!/usr/bin/env bats
# legion-share — codex work-share measurement + next-executor controller.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TRACE="$ROOT/legion-observability/bin/legion-trace"
  SHARE="$ROOT/legion-observability/bin/legion-share"
  export LEGION_TELEMETRY_DIR="$BATS_TEST_TMPDIR/spans"
}

@test "share: empty history recommends codex (start delegating)" {
  run "$SHARE" next
  [ "$status" -eq 0 ]
  [ "$output" = "codex" ]
}

@test "share: under target recommends codex" {
  "$TRACE" emit --executor codex --model gpt-5.4 --status ok >/dev/null
  "$TRACE" emit --executor opus  --model opus    --status ok >/dev/null
  "$TRACE" emit --executor opus  --model opus    --status ok >/dev/null
  run "$SHARE"
  echo "$output" | jq -e '.total_runs==3 and .codex_runs==1 and .status=="under" and .target==0.5'
  run "$SHARE" next
  [ "$output" = "codex" ]
}

@test "share: at/over target recommends opus" {
  "$TRACE" emit --executor codex       --model gpt-5.4 --status ok >/dev/null
  "$TRACE" emit --executor codex-review --model gpt-5.5 --status ok >/dev/null
  "$TRACE" emit --executor opus         --model opus    --status ok >/dev/null
  run "$SHARE"
  echo "$output" | jq -e '.codex_share_runs >= 0.5 and .status=="met"'
  run "$SHARE" next
  [ "$output" = "opus" ]
}

@test "share: all-codex with no logged Opus work reports no_opus_baseline (not a false 'met')" {
  "$TRACE" emit --executor codex        --model gpt-5.4 --status ok >/dev/null
  "$TRACE" emit --executor codex-review --model gpt-5.5 --status ok >/dev/null
  run "$SHARE"
  # warning goes to stderr (merged by bats run); strip it, parse the JSON
  echo "$output" | grep -v '^legion-share:' | jq -e '.status == "no_opus_baseline" and .opus_runs == 0'
}

@test "share: failed runs do not count toward the share" {
  "$TRACE" emit --executor codex --model gpt-5.4 --status failed >/dev/null
  "$TRACE" emit --executor opus  --model opus    --status ok     >/dev/null
  run "$SHARE"
  echo "$output" | jq -e '.failed_runs == 1 and .codex_runs == 0 and .total_runs == 1'
}

@test "share: --target override changes the verdict" {
  "$TRACE" emit --executor codex --model gpt-5.4 --status ok >/dev/null
  "$TRACE" emit --executor opus  --model opus    --status ok >/dev/null
  # 50% codex; with target 0.8 it's under -> codex
  run "$SHARE" next --target 0.8
  [ "$output" = "codex" ]
}
