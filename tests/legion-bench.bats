#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BENCH="$ROOT/legion-observability/bin/legion-bench"
}

@test "legion-bench: core suite writes artifacts and telemetry" {
  LEGION_BENCH_DIR="$BATS_TEST_TMPDIR/bench" \
  LEGION_TELEMETRY_DIR="$BATS_TEST_TMPDIR/spans" \
    run "$BENCH" run --suite core --repo "$ROOT" --json --strict

  [ "$status" -eq 0 ]
  run_path="$(printf '%s' "$output" | jq -r '.run_path')"
  summary_path="$(printf '%s' "$output" | jq -r '.summary_path')"
  span_path="$(printf '%s' "$output" | jq -r '.span_path')"
  [ -f "$run_path" ]
  [ -f "$summary_path" ]
  [ -f "$span_path" ]
  jq -e '.summary.metrics.cases == 7 and .summary.metrics.required_fail == 0' <<<"$output" >/dev/null
  jq -e 'select(.executor == "legion-bench" and .model == "offline")' "$span_path" >/dev/null
  run "$ROOT/legion-observability/bin/legion-trace" validate "$span_path"
  [ "$status" -eq 0 ]
}

@test "legion-bench: compare and gate accept identical runs" {
  LEGION_BENCH_DIR="$BATS_TEST_TMPDIR/bench" \
  LEGION_TELEMETRY_DIR="$BATS_TEST_TMPDIR/spans" \
    run "$BENCH" run --suite core --repo "$ROOT" --json --strict
  [ "$status" -eq 0 ]
  run_path="$(printf '%s' "$output" | jq -r '.run_path')"

  run "$BENCH" compare --baseline "$run_path" --candidate "$run_path" --json
  [ "$status" -eq 0 ]
  jq -e '.status == "neutral"' <<<"$output" >/dev/null

  run "$BENCH" gate --baseline "$run_path" --candidate "$run_path"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pass"* ]]
}

@test "legion-bench: record-failures writes legion-bench outcomes" {
  suite="$BATS_TEST_TMPDIR/fail-suite.json"
  cat > "$suite" <<'JSON'
{
  "schema": "legion.bench.suite.v1",
  "suite": "forced-fail",
  "cases": [
    {
      "id": "eval.forced-fail",
      "type": "eval",
      "scope": "plugin",
      "prompt": "Show per-executor cost and latency from Legion spans.",
      "expect_type": "plugin",
      "expect": "legion-router",
      "expect_not": "legion-observability",
      "required": true
    }
  ]
}
JSON

  LEGION_BENCH_DIR="$BATS_TEST_TMPDIR/bench" \
  LEGION_TELEMETRY_DIR="$BATS_TEST_TMPDIR/spans" \
    run "$BENCH" run --suite "$suite" --repo "$ROOT" --logs "$BATS_TEST_TMPDIR/logs" --record-failures --json

  [ "$status" -eq 0 ]
  jq -e '.summary.ok == false and .recorded_outcomes == 1' <<<"$output" >/dev/null
  outcomes="$BATS_TEST_TMPDIR/logs/self-learn/outcomes.jsonl"
  [ -f "$outcomes" ]
  jq -e 'select(.schema == "legion.outcome.v1" and .source == "legion-bench")' "$outcomes" >/dev/null
}
