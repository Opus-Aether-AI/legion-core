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
  [ -s "$output" ]
  grep -q "Legion Observability Report" "$output"
}

@test "report: --trace latest --json accepts roadmap flags" {
  "$TRACE" emit --executor codex --model test-model-beta --status ok --cost 0.05 \
    --duration-ms 1200 --tokens '{"input_tokens":10}' >/dev/null

  run "$REPORT" --trace latest --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.by == "executor" and .groups.codex.count == 1 and .total.count == 1'
}

@test "report: --trace filters JSON aggregation to one trace tree" {
  "$TRACE" emit --trace-id trace-a --run-id trace-a-root \
    --executor orchestrator --model legion-fanout --status ok --cost 0 \
    --duration-ms 20 --tokens '{}' >/dev/null
  "$TRACE" emit --trace-id trace-a --run-id trace-a-codex --parent-id trace-a-root \
    --executor codex --model test-model-beta --status ok --cost 0.05 \
    --duration-ms 1200 --tokens '{"input_tokens":10}' >/dev/null
  "$TRACE" emit --trace-id trace-b --run-id trace-b-codex \
    --executor codex --model test-model-beta --status failed --cost 0.99 \
    --duration-ms 3000 --tokens '{"input_tokens":99}' >/dev/null

  run "$REPORT" --trace trace-a --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.trace.requested == "trace-a" and .trace.resolved == "trace-a"'
  echo "$output" | jq -e '.total.count == 2 and .total.ok == 2'
  echo "$output" | jq -e '.groups.codex.count == 1 and .groups.orchestrator.count == 1'
  echo "$output" | jq -e '.groups.codex.cost_usd == 0.05'
}

@test "report: --trace latest resolves newest trace instead of mixing old spans" {
  "$TRACE" emit --trace-id old-trace --run-id old-run \
    --executor codex --model test-model-beta --status ok --cost 0.01 \
    --duration-ms 100 --tokens '{"input_tokens":1}' >/dev/null
  "$TRACE" emit --trace-id latest-trace --run-id latest-run \
    --executor codex --model test-model-beta --status failed --cost 0.02 \
    --duration-ms 200 --tokens '{"input_tokens":2}' >/dev/null

  run "$REPORT" --trace latest --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.trace.requested == "latest" and .trace.resolved == "latest-trace"'
  echo "$output" | jq -e '.total.count == 1 and .total.ok == 0'
  echo "$output" | jq -e '.groups.codex.count == 1 and .groups.codex.cost_usd == 0.02'
}

@test "report: --trace latest --html renders demo-friendly observability report" {
  "$TRACE" emit --executor codex --model test-model-beta --status ok --cost 0.05 \
    --duration-ms 1200 --tokens '{"input_tokens":10}' >/dev/null

  run "$REPORT" --trace latest --html
  [ "$status" -eq 0 ]
  [[ "$output" == *"<!doctype html>"* ]]
  [[ "$output" == *"Legion Observability Report"* ]]
  [[ "$output" == *"metric-grid"* ]]
  [[ "$output" == *"codex"* ]]
  [[ "$output" == *"100.0%"* ]]
}
