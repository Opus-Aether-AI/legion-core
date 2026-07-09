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
  jq -e '.summary.metrics.cases == 11 and .summary.metrics.required_fail == 0 and .summary.metrics.task_cases == 4' <<<"$output" >/dev/null
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

@test "legion-bench: learning-lift reports before/after percentage" {
  LEGION_BENCH_DIR="$BATS_TEST_TMPDIR/bench" \
  LEGION_TELEMETRY_DIR="$BATS_TEST_TMPDIR/spans" \
    run "$BENCH" learning-lift --repo "$ROOT" --json --strict

  [ "$status" -eq 0 ]
  jq -e '
    .comparison.status == "improved"
    and .baseline.summary.metrics.learning_pass == 1
    and .candidate.summary.metrics.learning_pass == 4
    and .learning_lift.delta_pct_points == 75
    and .learning_lift.relative_lift_reliable == false
  ' <<<"$output" >/dev/null
}

@test "legion-bench: legion-run suite exercises direct plan/validate lifecycle" {
  LEGION_BENCH_DIR="$BATS_TEST_TMPDIR/bench" \
  LEGION_TELEMETRY_DIR="$BATS_TEST_TMPDIR/spans" \
    run "$BENCH" run --suite legion-run --repo "$ROOT" --json --strict

  [ "$status" -eq 0 ]
  jq -e '
    .summary.ok == true
    and .summary.metrics.cases == 1
    and .summary.metrics.required_fail == 0
    and .summary.metrics.task_cases == 1
    and .summary.dimensions.orchestration.required_pass == 1
    and .html_artifacts["task.legion-run-direct-plan-validate"].benchmark_overview
    and .html_artifacts["task.legion-run-direct-plan-validate"].legion_observability
  ' <<<"$output" >/dev/null
}

@test "legion-bench: task cases can preserve HOME for live auth" {
  suite="$BATS_TEST_TMPDIR/preserve-home-suite.json"
  real_home="$BATS_TEST_TMPDIR/real-home"
  mkdir -p "$real_home"
  cat > "$suite" <<JSON
{
  "schema": "legion.bench.suite.v1",
  "suite": "preserve-home",
  "cases": [
    {
      "id": "task.preserve-home",
      "type": "task",
      "preserve_home": true,
      "command": [
        "python3",
        "-c",
        "import json, os; print(json.dumps({'ok': True, 'home': os.environ['HOME']}))"
      ],
      "validators": [
        {
          "type": "stdout_json_field_equals",
          "field": "home",
          "equals": "$real_home"
        }
      ],
      "required": true
    }
  ]
}
JSON

  HOME="$real_home" \
  LEGION_BENCH_DIR="$BATS_TEST_TMPDIR/bench" \
  LEGION_TELEMETRY_DIR="$BATS_TEST_TMPDIR/spans" \
    run "$BENCH" run --suite "$suite" --repo "$ROOT" --json --strict

  [ "$status" -eq 0 ]
  jq -e '
    .summary.ok == true
    and .summary.metrics.required_fail == 0
    and .summary.metrics.task_pass == 1
  ' <<<"$output" >/dev/null
}

@test "legion-bench: stable suite reports repeatable rollup" {
  LEGION_BENCH_DIR="$BATS_TEST_TMPDIR/bench" \
  LEGION_TELEMETRY_DIR="$BATS_TEST_TMPDIR/spans" \
    run "$BENCH" stable --suite stable --repo "$ROOT" --repeat 2 --json --strict

  [ "$status" -eq 0 ]
  jq -e '
    .ok == true
    and .metrics.iterations == 2
    and .metrics.cases_per_iteration == 52
    and .metrics.total_case_runs == 104
    and .metrics.flake_count == 0
    and .dimensions["cli-contract"].pass_rate == 1
    and .dimensions.routing.pass_rate == 1
    and .dimensions.triggering.pass_rate == 1
    and .artifacts.stability_path
  ' <<<"$output" >/dev/null
}

@test "legion-bench: corpus reports A/B mode numbers" {
  LEGION_BENCH_DIR="$BATS_TEST_TMPDIR/bench" \
  LEGION_TELEMETRY_DIR="$BATS_TEST_TMPDIR/spans" \
    run "$BENCH" corpus --corpus local-smoke --repo "$ROOT" --json

  [ "$status" -eq 0 ]
  jq -e '
    .summary.corpus == "local-smoke"
    and .summary.modes["control-baseline"].metrics.pass == 1
    and .summary.modes["control-candidate"].metrics.pass == 3
    and .summary.comparisons["control-baseline..control-candidate"].delta_pct_points == 66.667
    and .summary.comparisons["control-baseline..control-candidate"].reliable == false
    and .run_path
    and .cases_path
  ' <<<"$output" >/dev/null
}

@test "legion-bench: heldout corpus dry-run is reliable without model calls" {
  LEGION_BENCH_DIR="$BATS_TEST_TMPDIR/bench" \
  LEGION_TELEMETRY_DIR="$BATS_TEST_TMPDIR/spans" \
    run "$BENCH" corpus --corpus heldout-oss-36 --repo "$ROOT" --dry-run --require-reliable --json

  [ "$status" -eq 0 ]
  jq -e '
    .schema == "legion.bench.corpus-plan.v1"
    and .corpus == "heldout-oss-36"
    and .case_count == 36
    and .total_case_runs == 72
    and .comparisons["scripted-baseline..scripted-oracle"].case_runs == 36
    and .comparisons["scripted-baseline..scripted-oracle"].reliable == true
    and .has_live_modes_selected == false
  ' <<<"$output" >/dev/null
}

@test "legion-bench: heldout corpus control run writes markdown report" {
  report="$BATS_TEST_TMPDIR/heldout-report.md"
  LEGION_BENCH_DIR="$BATS_TEST_TMPDIR/bench" \
  LEGION_TELEMETRY_DIR="$BATS_TEST_TMPDIR/spans" \
    run "$BENCH" corpus --corpus heldout-oss-36 --repo "$ROOT" --json --strict --require-reliable --report-md "$report"

  [ "$status" -eq 0 ]
  [ -f "$report" ]
  jq -e '
    .summary.ok == true
    and .summary.modes["scripted-baseline"].metrics.pass == 0
    and .summary.modes["scripted-oracle"].metrics.pass == 36
    and .summary.comparisons["scripted-baseline..scripted-oracle"].reliable == true
    and .summary.comparisons["scripted-baseline..scripted-oracle"].paired.candidate_only_pass == 36
    and (.summary.failure_clusters | length > 0)
  ' <<<"$output" >/dev/null
  grep -Fq "Legion Corpus Benchmark: heldout-oss-36" "$report"
}

@test "legion-bench: fieldops e2e corpus proves evaluator without live model calls" {
  LEGION_BENCH_DIR="$BATS_TEST_TMPDIR/bench" \
  LEGION_TELEMETRY_DIR="$BATS_TEST_TMPDIR/spans" \
    run "$BENCH" corpus --corpus fieldops-triage-e2e --repo "$ROOT" --json --strict

  [ "$status" -eq 0 ]
  jq -e '
    .summary.ok == true
    and .summary.corpus == "fieldops-triage-e2e"
    and .summary.modes["scripted-baseline"].metrics.pass == 0
    and .summary.modes["scripted-oracle"].metrics.pass == 1
    and .summary.comparisons["scripted-baseline..scripted-oracle"].delta_pct_points == 100
    and .summary.comparisons["scripted-baseline..scripted-oracle"].reliable == false
  ' <<<"$output" >/dev/null
}

@test "legion-bench: fieldops e2e dry-run exposes live fanout-review mode" {
  LEGION_BENCH_DIR="$BATS_TEST_TMPDIR/bench" \
  LEGION_TELEMETRY_DIR="$BATS_TEST_TMPDIR/spans" \
    run "$BENCH" corpus --corpus fieldops-triage-e2e --repo "$ROOT" --mode legion-fanout-review --baseline legion-fanout-review --dry-run --json

  [ "$status" -eq 0 ]
  jq -e '
    .corpus == "fieldops-triage-e2e"
    and .has_live_modes_selected == true
    and .live_modes_selected == ["legion-fanout-review"]
    and .total_case_runs == 1
  ' <<<"$output" >/dev/null
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
