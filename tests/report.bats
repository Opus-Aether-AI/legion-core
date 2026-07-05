#!/usr/bin/env bats
# legion-report — telemetry aggregation CLI.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TRACE="$ROOT/legion-observability/bin/legion-trace"
  REPORT="$ROOT/legion-observability/bin/legion-report"
  STATE="$ROOT/legion-observability/bin/legion-state"
  export LEGION_TELEMETRY_DIR="$BATS_TEST_TMPDIR/spans"
}

@test "state: cli prints auto project paths for any repo" {
  unset LEGION_STATE_ROOT LEGION_TELEMETRY_DIR LEGION_REGISTRY_DIR LEGION_REPOS_FILE LEGION_BENCH_DIR LEGION_REPORTS_DIR
  app="$BATS_TEST_TMPDIR/app"; mkdir -p "$app"

  HOME="$BATS_TEST_TMPDIR/home" run "$STATE" --repo "$app" --json

  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.source == "auto" and (.state_root | contains(".legion/projects")) and (.reports_dir | endswith("/reports"))'
}

@test "report: path latest uses auto project reports dir without env setup" {
  unset LEGION_STATE_ROOT LEGION_TELEMETRY_DIR LEGION_REGISTRY_DIR LEGION_REPOS_FILE LEGION_BENCH_DIR LEGION_REPORTS_DIR
  app="$BATS_TEST_TMPDIR/app"; mkdir -p "$app"

  HOME="$BATS_TEST_TMPDIR/home" run bash -c "cd '$app' && '$REPORT' path latest"

  [ "$status" -eq 0 ]
  [[ "$output" == "$BATS_TEST_TMPDIR/home/.legion/projects/"*"/reports/latest.html" ]]
}

@test "report: --trace latest --json accepts roadmap flags" {
  "$TRACE" emit --executor codex --model gpt-5.5 --status ok --cost 0.05 \
    --duration-ms 1200 --tokens '{"input_tokens":10}' >/dev/null

  run "$REPORT" --trace latest --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.by == "executor" and .groups.codex.count == 1 and .total.count == 1'
}

@test "report: --trace latest --html renders demo-friendly observability report" {
  "$TRACE" emit --executor codex --model gpt-5.5 --status ok --cost 0.05 \
    --duration-ms 1200 --tokens '{"input_tokens":10}' >/dev/null

  run "$REPORT" --trace latest --html
  [ "$status" -eq 0 ]
  [[ "$output" == *"<!doctype html>"* ]]
  [[ "$output" == *"Legion Observability Report"* ]]
  [[ "$output" == *"metric-grid"* ]]
  [[ "$output" == *"codex"* ]]
  [[ "$output" == *"100.0%"* ]]
}
