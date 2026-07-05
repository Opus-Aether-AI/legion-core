#!/usr/bin/env bats
# legion-report — telemetry aggregation CLI.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TRACE="$ROOT/legion-observability/bin/legion-trace"
  REPORT="$ROOT/legion-observability/bin/legion-report"
  export LEGION_TELEMETRY_DIR="$BATS_TEST_TMPDIR/spans"
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
