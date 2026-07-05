#!/usr/bin/env bash
set -euo pipefail

repo="${LEGION_BENCH_REPO:?LEGION_BENCH_REPO required}"
workspace="${LEGION_BENCH_WORKSPACE:?LEGION_BENCH_WORKSPACE required}"
task_file="${LEGION_BENCH_TASK_FILE:?LEGION_BENCH_TASK_FILE required}"

if [[ -n "${LEGION_BENCH_REAL_HOME:-}" ]]; then
  export HOME="$LEGION_BENCH_REAL_HOME"
fi

export PATH="$repo/legion-router/bin:$repo/legion-orchestrate/bin:$repo/legion-observability/bin:$PATH"
export LEGION_STATE_ROOT="${LEGION_STATE_ROOT:-$workspace/.legion-state}"
export LEGION_TELEMETRY_DIR="${LEGION_TELEMETRY_DIR:-$LEGION_STATE_ROOT/spans}"
export LEGION_REGISTRY_DIR="${LEGION_REGISTRY_DIR:-$LEGION_STATE_ROOT/registry}"
export LEGION_REPOS_FILE="${LEGION_REPOS_FILE:-$LEGION_STATE_ROOT/repos.jsonl}"
export LEGION_BENCH_DIR="${LEGION_BENCH_DIR:-$LEGION_STATE_ROOT/bench}"

if [[ ! -d "$workspace/.git" ]]; then
  git -C "$workspace" init -q
  printf '%s\n' "__pycache__/" "*.py[cod]" ".legion-state/" > "$workspace/.gitignore"
  git -C "$workspace" add .
  git -C "$workspace" -c user.email=bench@example.com -c user.name=bench commit -qm init
fi

task="$(cat "$task_file")"
slices="$workspace/legion-slices.jsonl"
jq -cn --arg t "$task" '{archetype:"implement-feature",task:$t}' > "$slices"

legion-doctor --repo "$repo" --strict-demo --json > "$workspace/doctor.json"
legion-route implement-feature --task "$task" > "$workspace/route-implement.json"
legion-route final-review --task "Review FieldOps triage benchmark implementation" > "$workspace/route-review.json"

legion-fanout \
  --slices "$slices" \
  --repo "$workspace" \
  --max-concurrency "${LEGION_BENCH_MAX_CONCURRENCY:-1}" \
  --apply \
  --json > "$workspace/fanout.json"

jq -e '.failed == 0 and .ok >= 1 and .applied >= 1' "$workspace/fanout.json" >/dev/null

legion-delegate review \
  --archetype final-review \
  --repo "$workspace" \
  --base HEAD > "$workspace/review.json"

jq -e 'type == "object"' "$workspace/review.json" >/dev/null

python3 "$workspace/eval_fieldops_triage.py"
legion-report --trace latest --json > "$workspace/legion-report.json"
legion-report --trace latest --html > "$workspace/legion-report.html"
legion-share --window 1d --json > "$workspace/legion-share.json"
legion-self-learn record \
  --logs "$LEGION_STATE_ROOT" \
  --entity "benchmark:fieldops-triage-e2e" \
  --summary "FieldOps triage e2e benchmark completed through fanout, review, eval, observability, and share gates." \
  --severity info \
  --source legion-bench \
  --json > "$workspace/self-learn-record.json"
legion-self-learn hints \
  --logs "$LEGION_STATE_ROOT" \
  --entity "benchmark:fieldops-triage-e2e" \
  --json > "$workspace/self-learn-hints.json"
legion-self-learn run \
  --repo "$repo" \
  --logs "$LEGION_STATE_ROOT" \
  --apply-memory \
  --json > "$workspace/self-learn-run.json"
legion-heal plan --repo "$repo" --json > "$workspace/heal-plan.json"
LEGION_BENCH_DIR="$LEGION_STATE_ROOT/nested-bench" \
LEGION_TELEMETRY_DIR="$LEGION_STATE_ROOT/nested-spans" \
  legion-bench run --suite core --repo "$repo" --json --strict > "$workspace/bench-core.json"

jq -cn \
  --slurpfile doctor "$workspace/doctor.json" \
  --slurpfile route_implement "$workspace/route-implement.json" \
  --slurpfile route_review "$workspace/route-review.json" \
  --slurpfile fanout "$workspace/fanout.json" \
  --slurpfile review "$workspace/review.json" \
  --slurpfile score "$workspace/score.json" \
  --slurpfile report "$workspace/legion-report.json" \
  --slurpfile share "$workspace/legion-share.json" \
  --slurpfile self_learn "$workspace/self-learn-run.json" \
  --slurpfile heal "$workspace/heal-plan.json" \
  --slurpfile bench "$workspace/bench-core.json" \
  '{schema:"legion.bench.fanout-review.v1",doctor:$doctor[0],routes:{implement:$route_implement[0],review:$route_review[0]},fanout:$fanout[0],review:$review[0],score:$score[0],report:$report[0],share:$share[0],self_learn:$self_learn[0],heal:$heal[0],bench_core:$bench[0]}'
