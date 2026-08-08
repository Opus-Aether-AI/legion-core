#!/usr/bin/env bats
# legion-run — enforced domain-plugin pipeline runner.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  RUN="$ROOT/legion-orchestrate/bin/legion-run"
  export PATH="$BATS_TEST_TMPDIR/bin:$ROOT/legion-orchestrate/bin:$ROOT/legion-router/bin:$ROOT/legion-observability/bin:$BATS_TEST_DIRNAME/mocks/bin:$PATH"
  export LEGION_STATE_ROOT="$BATS_TEST_TMPDIR/state"
  export LEGION_TELEMETRY_DIR="$LEGION_STATE_ROOT/spans"
  export LEGION_REGISTRY_DIR="$LEGION_STATE_ROOT/registry"
  export LEGION_REPOS_FILE="$LEGION_STATE_ROOT/repos.jsonl"
  export LEGION_BENCH_DIR="$LEGION_STATE_ROOT/bench"
  export LEGION_REPORTS_DIR="$LEGION_STATE_ROOT/reports"
  # Pin both learning stores. A Legion-managed parent environment exports these,
  # and a test that resets only LEGION_STATE_ROOT would otherwise read and write
  # the operator's real hints through the inherited path.
  export LEGION_PROJECT_LEARNING_DIR="$LEGION_STATE_ROOT/learning"
  export LEGION_GLOBAL_LEARNING_DIR="$LEGION_STATE_ROOT/global-learning"

  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO"
  git -C "$REPO" init -q
  git -C "$REPO" config user.email t@t.c
  git -C "$REPO" config user.name t
  printf 'demo\n' > "$REPO/README.md"
  git -C "$REPO" add -A
  git -C "$REPO" commit -qm init
}

make_plugin() {
  local dir="$BATS_TEST_TMPDIR/plugin"
  mkdir -p "$dir"
  cat > "$dir/legion-plugin.toml" <<'TOML'
[plugin]
name = "fieldops"
kind = "domain-plugin"

[pipeline]
profile = "legion.full_app.v1"
entrypoint = "legion-run"

[commands]
plan = "fieldops-plan"
validate = "fieldops-validate"
evaluate = "fieldops-eval"
TOML
  printf '%s\n' "$dir/legion-plugin.toml"
}

json_from_output() {
  python3 -c '
import json
import re
import sys

text = sys.stdin.read()
decoder = json.JSONDecoder()
for match in re.finditer(r"{", text):
    try:
        obj, _ = decoder.raw_decode(text[match.start():])
    except json.JSONDecodeError:
        continue
    if isinstance(obj, dict) and (
        obj.get("schema") == "legion.run.contract.v1" or "run_dir" in obj
    ):
        print(json.dumps(obj, indent=2, sort_keys=True))
        raise SystemExit(0)
raise SystemExit("no Legion JSON object in output")
'
}

make_installed_style_plugin() {
  local dir="$BATS_TEST_TMPDIR/support-app-builder"
  mkdir -p "$dir/bin"
  cat > "$dir/SKILL.md" <<'MD'
---
name: support-app-builder
description: Use when building or changing a customer-support SaaS app.
---

Run legion-run with this plugin manifest for support-app feature work.
MD
  cat > "$dir/legion-plugin.toml" <<'TOML'
[plugin]
name = "support-app-builder"
kind = "domain-plugin"

[pipeline]
profile = "legion.full_app.v1"
entrypoint = "legion-run"

[commands]
plan = "support-plan"
validate = "support-validate"
evaluate = "support-eval"
TOML
  cat > "$dir/bin/support-plan" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat > "$LEGION_RUN_PLAN_FILE" <<JSON
{"schema":"legion.plugin.plan.v1","plugin":"$LEGION_PLUGIN_NAME","task":"$LEGION_TASK","source":"installed-style-plugin"}
JSON
cat > "$LEGION_RUN_SLICES_FILE" <<JSONL
{"archetype":"implement-feature","task":"Build the support workflow for: $LEGION_TASK"}
JSONL
SH
  cat > "$dir/bin/support-validate" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '{"ok":true,"command":"support-validate","gates":["unit","build"]}\n'
SH
  cat > "$dir/bin/support-eval" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '{"ok":true,"score":1,"total":1,"checks":["support workflow implemented"]}\n'
SH
  chmod +x "$dir/bin"/*
  printf '%s\n' "$dir/legion-plugin.toml"
}

install_fake_pipeline_bins() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/fieldops-plan" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat > "$LEGION_RUN_PLAN_FILE" <<JSON
{"schema":"legion.plugin.plan.v1","plugin":"$LEGION_PLUGIN_NAME","task":"$LEGION_TASK"}
JSON
cat > "$LEGION_RUN_SLICES_FILE" <<'JSONL'
{"archetype":"implement-feature","task":"Build the fieldops slice."}
JSONL
SH
  cat > "$BATS_TEST_TMPDIR/bin/fieldops-validate" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '{"ok":true,"command":"fieldops-validate"}\n'
SH
  cat > "$BATS_TEST_TMPDIR/bin/fieldops-eval" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '{"ok":true,"score":1,"total":1}\n'
SH
  cat > "$BATS_TEST_TMPDIR/bin/legion-route" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  implement-feature) printf '{"executor":"codex","model":"test-model-beta","sandbox":"workspace-write","resolved":true}\n' ;;
  write-tests) printf '{"executor":"codex","model":"test-model-beta","sandbox":"workspace-write","resolved":true}\n' ;;
  refactor-module) printf '{"executor":"codex","model":"test-model-beta","sandbox":"workspace-write","resolved":true}\n' ;;
  final-review) printf '{"executor":"codex","model":"test-model-beta","sandbox":"read-only","resolved":true}\n' ;;
  *) exit 2 ;;
esac
SH
  cat > "$BATS_TEST_TMPDIR/bin/legion-fanout" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
ledger="$LEGION_RUN_DIR/fanout-task-ledger.json"
printf '{"schema":"legion.task-ledger.v1","status":"completed","tasks":[]}\n' > "$ledger"
jq -cn --arg ledger "$ledger" \
  '{ok:1,slices:1,failed:0,applied:1,results:[],task_ledger_path:$ledger}'
SH
  cat > "$BATS_TEST_TMPDIR/bin/legion-delegate" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '{"status":"ok","model":"test-model-beta","verdict":{"verdict":"approve","summary":"independent review passed","findings":[]}}\n'
SH
  cat > "$BATS_TEST_TMPDIR/bin/legion-claude" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" > "$LEGION_RUN_DIR/claude-review.args"
printf '{"status":"ok","model":"test-model-claude","result":"{\\"verdict\\":\\"approve\\",\\"summary\\":\\"independent review passed\\",\\"findings\\":[]}"}\n'
SH
  cat > "$BATS_TEST_TMPDIR/bin/legion-doctor" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '{"ok":true,"fail":0,"warn":0}\n'
SH
  cat > "$BATS_TEST_TMPDIR/bin/legion-report" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '{"ok":true,"html":"legion-observability.html"}\n'
SH
  cat > "$BATS_TEST_TMPDIR/bin/legion-share" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '{"status":"met","codex_runs":1,"failed_runs":0}\n'
SH
  cat > "$BATS_TEST_TMPDIR/bin/legion-self-learn" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  hints) printf '{"schema":"legion.self-learning.hints.v1","entities":{}}\n' ;;
  record) printf '{"ok":true,"recorded":true}\n' ;;
  run)
    memory_dir="${LEGION_STATE_ROOT:-$PWD/.legion}/self-learn"
    mkdir -p "$memory_dir"
    cat > "$memory_dir/harness-memory.json" <<'JSON'
{"schema":"legion.self-learning.memory.v1","entities":{"test:applied":{"hints":["fake memory applied"]}},"processed_outcome_ids":[]}
JSON
    printf '{"ok":true,"memory":true,"applied_memory":true,"memory_path":"%s"}\n' "$memory_dir/harness-memory.json"
    ;;
  *) printf '{"ok":true}\n' ;;
esac
SH
  cat > "$BATS_TEST_TMPDIR/bin/legion-heal" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '{"ok":true,"findings":0,"fixable":0}\n'
SH
  chmod +x "$BATS_TEST_TMPDIR/bin"/*
}

# This is deliberately a command-boundary fake, not an implementation stub.  The
# runner must compile a safe, typed context document for each lifecycle
# boundary and make the exact immutable path/revision available downstream.
install_learning_context_boundary_fake() {
  cat > "$BATS_TEST_TMPDIR/bin/legion-self-learn" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

case "$1" in
  compile-context)
    mkdir -p "$LEGION_RUN_DIR/boundary-inputs"
    args=("$@")
    entity=""
    stage=""
    for ((index = 0; index < ${#args[@]}; index++)); do
      case "${args[$index]}" in
        --entity) entity="${args[$((index + 1))]}" ;;
        --stage) stage="${args[$((index + 1))]}" ;;
      esac
    done
    jq -cn '$ARGS.positional' --args -- "$@" > "$LEGION_RUN_DIR/boundary-inputs/compile-context.${stage}.args.json"
    if [[ "$stage" == "plan" ]]; then
      cp "$LEGION_RUN_DIR/boundary-inputs/compile-context.${stage}.args.json" \
        "$LEGION_RUN_DIR/boundary-inputs/compile-context.args.json"
    fi
    if [[ "${LEARNING_CONTEXT_FAIL_STAGE:-}" == "$stage" ]]; then
      printf '%s\n' "simulated $stage learning-context compiler failure" >&2
      exit 7
    fi
    case "${LEARNING_CONTEXT_CASE:-no-hints}" in
      compiler-failure)
        printf '%s\n' 'simulated learning-context compiler failure' >&2
        exit 7
        ;;
      compiler-timeout)
        sleep 5
        ;;
    esac
    case "${LEARNING_CONTEXT_CASE:-no-hints}" in
      advisory)
        cat <<JSON
{"schema":"legion.learning-context.v1","repository_identity":"$LEGION_REPOSITORY_IDENTITY","entity":"$entity","stage":"$stage","limits":{"max_hints":20,"max_tokens":1200},"usage":{"schema":"legion.learning-usage.v1","hint_count":1,"token_count":40},"selected_hints":[{"id":"advisory-coverage","scope":"global","guidance":"Advisory: cover the public API boundary.","selection_reason":"global","token_count":40}],"excluded_hints":[]}
JSON
        ;;
      required)
        cat <<JSON
{"schema":"legion.learning-context.v1","repository_identity":"$LEGION_REPOSITORY_IDENTITY","entity":"$entity","stage":"$stage","limits":{"max_hints":20,"max_tokens":1200},"usage":{"schema":"legion.learning-usage.v1","hint_count":1,"token_count":52},"selected_hints":[{"id":"required-contract","scope":"exact","guidance":"Required: preserve the billing idempotency contract.","selection_reason":"exact","token_count":52}],"excluded_hints":[]}
JSON
        ;;
      retired)
        cat <<JSON
{"schema":"legion.learning-context.v1","repository_identity":"$LEGION_REPOSITORY_IDENTITY","entity":"$entity","stage":"$stage","limits":{"max_hints":20,"max_tokens":1200},"usage":{"schema":"legion.learning-usage.v1","hint_count":0,"token_count":0},"selected_hints":[],"excluded_hints":[{"id":"retired-danger","exclusion_reason":"retired"}]}
JSON
        ;;
      prompt-budget)
        cat <<JSON
{"schema":"legion.learning-context.v1","repository_identity":"$LEGION_REPOSITORY_IDENTITY","entity":"$entity","stage":"$stage","limits":{"max_hints":2,"max_tokens":130},"usage":{"schema":"legion.learning-usage.v1","hint_count":2,"token_count":118},"selected_hints":[{"id":"a-first","scope":"global","guidance":"alpha alpha alpha alpha alpha alpha alpha alpha alpha alpha","selection_reason":"global","token_count":59},{"id":"b-second","scope":"global","guidance":"bravo bravo bravo bravo bravo bravo bravo bravo bravo bravo","selection_reason":"global","token_count":59}],"excluded_hints":[{"id":"m-middle","exclusion_reason":"token_limit"},{"id":"z-last","exclusion_reason":"hint_limit"}]}
JSON
        ;;
      stage-scoped)
        case "$stage" in
          plan) hint_id="plan-only"; guidance="Plan boundary guidance."; tokens=23 ;;
          fanout) hint_id="fanout-only"; guidance="Fanout boundary guidance."; tokens=25 ;;
          validate) hint_id="validate-only"; guidance="Validate boundary guidance."; tokens=27 ;;
          review) hint_id="review-only"; guidance="Review boundary guidance."; tokens=25 ;;
        esac
        jq -cn \
          --arg repository_identity "$LEGION_REPOSITORY_IDENTITY" \
          --arg entity "$entity" --arg stage "$stage" --arg id "$hint_id" \
          --arg guidance "$guidance" --argjson tokens "$tokens" \
          '{schema:"legion.learning-context.v1",repository_identity:$repository_identity,entity:$entity,stage:$stage,limits:{max_hints:20,max_tokens:1200},usage:{schema:"legion.learning-usage.v1",hint_count:1,token_count:$tokens},selected_hints:[{id:$id,scope:"exact",guidance:$guidance,selection_reason:"exact",token_count:$tokens}],excluded_hints:[]}'
        ;;
      forged-budget)
        guidance="$(printf 'x%.0s' {1..20000})"
        jq -cn \
          --arg repository_identity "$LEGION_REPOSITORY_IDENTITY" \
          --arg entity "$entity" --arg stage "$stage" --arg guidance "$guidance" \
          '{schema:"legion.learning-context.v1",repository_identity:$repository_identity,entity:$entity,stage:$stage,limits:{max_hints:1000000,max_tokens:1000000},usage:{schema:"legion.learning-usage.v1",hint_count:1,token_count:0},selected_hints:[{id:"forged",scope:"global",guidance:$guidance,selection_reason:"global",token_count:0}],excluded_hints:[]}'
        ;;
      unavailable)
        printf '{"ok":true}\n'
        ;;
      wrong-boundary)
        cat <<JSON
{"schema":"legion.learning-context.v1","repository_identity":"$LEGION_REPOSITORY_IDENTITY","entity":"heavy-task:wrong","stage":"$stage","limits":{"max_hints":20,"max_tokens":1200},"usage":{"schema":"legion.learning-usage.v1","hint_count":0,"token_count":0},"selected_hints":[],"excluded_hints":[]}
JSON
        ;;
      *)
        cat <<JSON
{"schema":"legion.learning-context.v1","repository_identity":"$LEGION_REPOSITORY_IDENTITY","entity":"$entity","stage":"$stage","limits":{"max_hints":20,"max_tokens":1200},"usage":{"schema":"legion.learning-usage.v1","hint_count":0,"token_count":0},"selected_hints":[],"excluded_hints":[]}
JSON
        ;;
    esac
    ;;
  hints) printf '{"schema":"legion.self-learning.hints.v1","entities":{}}\n' ;;
  record) printf '{"ok":true,"recorded":true}\n' ;;
  run) printf '{"ok":true,"applied_memory":true}\n' ;;
  *) printf '{"ok":true}\n' ;;
esac
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/legion-self-learn"
}

install_learning_boundary_consumers() {
  cat > "$BATS_TEST_TMPDIR/bin/fieldops-plan" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$LEGION_RUN_DIR/boundary-inputs"
jq -cn --arg path "${LEGION_LEARNING_CONTEXT_PATH-unset}" --arg revision "${LEGION_LEARNING_CONTEXT_REVISION-unset}" \
  --slurpfile context "$LEGION_LEARNING_CONTEXT_PATH" \
  '{path:$path,revision:$revision,stage:$context[0].stage,hint_ids:[$context[0].selected_hints[].id]}' \
  > "$LEGION_RUN_DIR/boundary-inputs/plan.json"
jq -cn --arg task "$LEGION_TASK" \
  --arg boundary "$LEGION_LEARNING_CONTEXT_BOUNDARY" \
  --arg revision "$LEGION_LEARNING_CONTEXT_REVISION" \
  '{schema:"legion.plugin.plan.v1",task:$task,learning_context_ack:{boundary:$boundary,revision:$revision}}' \
  > "$LEGION_RUN_PLAN_FILE"
printf '%s\n' '{"id":"one","archetype":"implement-feature","task":"Implement the first delegated slice."}' '{"id":"two","archetype":"write-tests","task":"Implement the second delegated slice."}' > "$LEGION_RUN_SLICES_FILE"
SH
  cat > "$BATS_TEST_TMPDIR/bin/fieldops-validate" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$LEGION_RUN_DIR/boundary-inputs"
jq -cn --arg path "${LEGION_LEARNING_CONTEXT_PATH-unset}" --arg revision "${LEGION_LEARNING_CONTEXT_REVISION-unset}" \
  --slurpfile context "$LEGION_LEARNING_CONTEXT_PATH" \
  '{path:$path,revision:$revision,stage:$context[0].stage,hint_ids:[$context[0].selected_hints[].id]}' \
  > "$LEGION_RUN_DIR/boundary-inputs/validate.json"
jq -cn --arg boundary "$LEGION_LEARNING_CONTEXT_BOUNDARY" \
  --arg revision "$LEGION_LEARNING_CONTEXT_REVISION" \
  '{ok:true,command:"fieldops-validate",learning_context_ack:{boundary:$boundary,revision:$revision}}'
SH
  cat > "$BATS_TEST_TMPDIR/bin/legion-fanout" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$LEGION_RUN_DIR/boundary-inputs"
slices=""
while [[ $# -gt 0 ]]; do
  case "$1" in --slices) slices="$2"; shift 2 ;; *) shift ;; esac
done
cp "$slices" "$LEGION_RUN_DIR/boundary-inputs/delegated-slices.jsonl"
ledger="$LEGION_RUN_DIR/fanout-task-ledger.json"
printf '{"schema":"legion.task-ledger.v1","status":"completed","tasks":[]}\n' > "$ledger"
jq -cn --arg ledger "$ledger" '{ok:1,slices:2,failed:0,applied:2,results:[],task_ledger_path:$ledger}'
SH
  cat > "$BATS_TEST_TMPDIR/bin/legion-route" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  final-review) printf '{"executor":"claude","model":"test-model-claude","reasoning_effort":"high","resolved":true}\n' ;;
  *) printf '{"executor":"codex","model":"test-model-beta","sandbox":"workspace-write","resolved":true}\n' ;;
esac
SH
  cat > "$BATS_TEST_TMPDIR/bin/legion-claude" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" > "$LEGION_RUN_DIR/boundary-inputs/final-review.args"
printf '{"status":"ok","model":"test-model-claude","result":"{\\"verdict\\":\\"approve\\",\\"summary\\":\\"approved\\",\\"findings\\":[]}"}\n'
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/fieldops-plan" "$BATS_TEST_TMPDIR/bin/fieldops-validate" \
    "$BATS_TEST_TMPDIR/bin/legion-fanout" "$BATS_TEST_TMPDIR/bin/legion-route" "$BATS_TEST_TMPDIR/bin/legion-claude"
}

run_learning_context_lifecycle() {
  manifest="$(make_plugin)"
  run "$RUN" --plugin-manifest "$manifest" --repo "$REPO" --task "Exercise learning context" --name learning-contract --json "$@"
  json="$(printf '%s' "$output" | json_from_output)"
  run_dir="$(echo "$json" | jq -r '.run_dir')"
}

assert_learning_context_artifacts() {
  [ -s "$run_dir/learning-context.json" ]
  [ -s "$run_dir/learning-usage.json" ]
  jq -e '.schema == "legion.learning-context.v1"' "$run_dir/learning-context.json"
  jq -e '.schema == "legion.learning-usage.v1"' "$run_dir/learning-usage.json"
}

@test "legion-run: no-hint lifecycle still emits typed context and usage before planning" {
  install_fake_pipeline_bins
  install_learning_context_boundary_fake
  install_learning_boundary_consumers
  export LEARNING_CONTEXT_CASE=no-hints

  run_learning_context_lifecycle
  [ "$status" -eq 0 ]
  assert_learning_context_artifacts
  jq -e '.selected_hints == [] and .excluded_hints == []' "$run_dir/learning-context.json"
  jq -e '.hint_count == 0 and .token_count == 0' "$run_dir/learning-usage.json"
  repo_real="$(cd "$REPO" && pwd -P)"
  jq -e --arg repo "$repo_real" '
    . == ["compile-context", "--repo", $repo, "--entity", "heavy-task:learning-contract", "--stage", "plan", "--json"]
  ' \
    "$run_dir/boundary-inputs/compile-context.args.json"
  jq -e --arg path "$run_dir/learning-context.json" \
    '.path == $path and (.revision | length > 0)' "$run_dir/boundary-inputs/plan.json"
  jq -e '
    (.learning_contexts | keys) == ["fanout", "plan", "review", "validate"] and
    (.receipts | map(.context_boundary) | unique) == ["fanout", "plan", "review", "validate"]
  ' "$run_dir/learning-receipts.json"
}

@test "legion-run: advisory trusted guidance reaches planning, every delegated slice, validation, and final review" {
  install_fake_pipeline_bins
  install_learning_context_boundary_fake
  install_learning_boundary_consumers
  export LEARNING_CONTEXT_CASE=advisory

  run_learning_context_lifecycle
  [ "$status" -eq 0 ]
  assert_learning_context_artifacts
  jq -e '.selected_hints | map(.id) == ["advisory-coverage"]' "$run_dir/learning-context.json"
  jq -e --arg path "$run_dir/learning-context.json" \
    '.learning_context.path == $path and (.learning_context.revision | length > 0) and (.learning_context.dispositions[] | select(.id == "advisory-coverage" and .disposition == "advisory"))' "$run_dir/plan.json"
  jq -e -s 'length == 2 and all(.[]; .task | contains("Advisory: cover the public API boundary."))' \
    "$run_dir/boundary-inputs/delegated-slices.jsonl"
  jq -e --arg path "$run_dir/learning-contexts/validate.json" \
    '.path == $path and .stage == "validate" and (.revision | length > 0)' "$run_dir/boundary-inputs/validate.json"
  grep -Fq 'Advisory: cover the public API boundary.' "$run_dir/boundary-inputs/final-review.args"
}

@test "legion-run: stage-scoped hints are compiled and delivered only at their matching boundary" {
  install_fake_pipeline_bins
  install_learning_context_boundary_fake
  install_learning_boundary_consumers
  export LEARNING_CONTEXT_CASE=stage-scoped

  run_learning_context_lifecycle --learning-context-mode required

  [ "$status" -eq 0 ]
  jq -e '.stage == "plan" and .hint_ids == ["plan-only"]' \
    "$run_dir/boundary-inputs/plan.json"
  jq -e -s '
    length == 2 and
    all(.[]; (.task | contains("Fanout boundary guidance."))) and
    all(.[]; (.task | contains("Plan boundary guidance.") or contains("Validate boundary guidance.") or contains("Review boundary guidance.")) | not)
  ' "$run_dir/boundary-inputs/delegated-slices.jsonl"
  jq -e '.stage == "validate" and .hint_ids == ["validate-only"]' \
    "$run_dir/boundary-inputs/validate.json"
  grep -Fq 'Review boundary guidance.' "$run_dir/boundary-inputs/final-review.args"
  ! grep -Fq 'Plan boundary guidance.' "$run_dir/boundary-inputs/final-review.args"
  ! grep -Fq 'Fanout boundary guidance.' "$run_dir/boundary-inputs/final-review.args"
  ! grep -Fq 'Validate boundary guidance.' "$run_dir/boundary-inputs/final-review.args"
  for stage in plan fanout validate review; do
    jq -e --arg stage "$stage" '
      index("--stage") as $index | .[$index + 1] == $stage
    ' "$run_dir/boundary-inputs/compile-context.${stage}.args.json"
  done
}

@test "legion-run: required trusted guidance has a required disposition at every delegated boundary" {
  install_fake_pipeline_bins
  install_learning_context_boundary_fake
  install_learning_boundary_consumers
  export LEARNING_CONTEXT_CASE=required

  run_learning_context_lifecycle --learning-context-mode required
  [ "$status" -eq 0 ]
  assert_learning_context_artifacts
  jq -e --arg path "$run_dir/learning-context.json" \
    '.learning_context.path == $path and (.learning_context.dispositions[] | select(.id == "required-contract" and .disposition == "required"))' "$run_dir/plan.json"
  jq -e -s 'all(.[]; .task | contains("Required: preserve the billing idempotency contract."))' \
    "$run_dir/boundary-inputs/delegated-slices.jsonl"
  grep -Fq 'Required: preserve the billing idempotency contract.' "$run_dir/boundary-inputs/final-review.args"
}

@test "legion-run: required mode rejects planner or validator without boundary revision acknowledgement" {
  install_fake_pipeline_bins
  install_learning_context_boundary_fake
  install_learning_boundary_consumers
  export LEARNING_CONTEXT_CASE=required
  cat > "$BATS_TEST_TMPDIR/bin/fieldops-plan" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '{"schema":"legion.plugin.plan.v1","task":"unacknowledged"}\n' > "$LEGION_RUN_PLAN_FILE"
printf '%s\n' '{"id":"one","archetype":"implement-feature","task":"slice"}' > "$LEGION_RUN_SLICES_FILE"
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/fieldops-plan"

  run_learning_context_lifecycle --learning-context-mode required

  [ "$status" -eq 1 ]
  echo "$json" | jq -e '.failed_stage == "plan" and (.error | contains("not acknowledged by planner"))'

  install_learning_boundary_consumers
  cat > "$BATS_TEST_TMPDIR/bin/fieldops-validate" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '{"ok":true,"command":"fieldops-validate"}\n'
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/fieldops-validate"

  run_learning_context_lifecycle --learning-context-mode required

  [ "$status" -eq 1 ]
  echo "$json" | jq -e '.failed_stage == "validate" and (.error | contains("not acknowledged by validator"))'
}

@test "legion-run: Codex final review receives selected guidance as bounded task input" {
  install_fake_pipeline_bins
  install_learning_context_boundary_fake
  install_learning_boundary_consumers
  cat > "$BATS_TEST_TMPDIR/bin/legion-route" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  final-review) printf '{"executor":"codex","model":"test-model-beta","reasoning_effort":"xhigh","resolved":true}\n' ;;
  *) printf '{"executor":"codex","model":"test-model-beta","sandbox":"workspace-write","resolved":true}\n' ;;
esac
SH
  cat > "$BATS_TEST_TMPDIR/bin/legion-delegate" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" > "$LEGION_RUN_DIR/boundary-inputs/codex-final-review.args"
printf '{"status":"ok","model":"test-model-beta","verdict":{"verdict":"approve","summary":"approved","findings":[]}}\n'
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/legion-route" "$BATS_TEST_TMPDIR/bin/legion-delegate"
  export LEARNING_CONTEXT_CASE=advisory

  run_learning_context_lifecycle

  [ "$status" -eq 0 ]
  grep -Fq -- '--task Review the immutable repository diff' \
    "$run_dir/boundary-inputs/codex-final-review.args"
  grep -Fq 'Advisory: cover the public API boundary.' \
    "$run_dir/boundary-inputs/codex-final-review.args"
}

@test "legion-run: retired hints are recorded as excluded and never reach planner, slices, validator, or reviewer" {
  install_fake_pipeline_bins
  install_learning_context_boundary_fake
  install_learning_boundary_consumers
  export LEARNING_CONTEXT_CASE=retired

  run_learning_context_lifecycle
  [ "$status" -eq 0 ]
  assert_learning_context_artifacts
  jq -e '.selected_hints == [] and (.excluded_hints[] | select(.id == "retired-danger" and .exclusion_reason == "retired"))' "$run_dir/learning-context.json"
  jq -e '.learning_context.dispositions[] | select(.id == "retired-danger" and .disposition == "retired")' "$run_dir/plan.json"
  ! grep -R -F 'retired-danger' "$run_dir/boundary-inputs"
}

@test "legion-run: prompt-budgeted context keeps selected guidance and exposes exclusions in plan dispositions" {
  install_fake_pipeline_bins
  install_learning_context_boundary_fake
  install_learning_boundary_consumers
  export LEARNING_CONTEXT_CASE=prompt-budget

  run_learning_context_lifecycle
  [ "$status" -eq 0 ]
  assert_learning_context_artifacts
  jq -e '.hint_count == 2 and .token_count == 118' "$run_dir/learning-usage.json"
  jq -e '.selected_hints | map(.id) == ["a-first", "b-second"]' "$run_dir/learning-context.json"
  jq -e '.learning_context.dispositions[] | select(.id == "m-middle" and .disposition == "token_limit")' "$run_dir/plan.json"
  jq -e '.learning_context.dispositions[] | select(.id == "z-last" and .disposition == "hint_limit")' "$run_dir/plan.json"
  grep -Fq 'alpha alpha alpha' "$run_dir/boundary-inputs/final-review.args"
  ! grep -R -F 'm-middle' "$run_dir/boundary-inputs"
  ! grep -R -F 'z-last' "$run_dir/boundary-inputs"
}

@test "legion-run: rejects forged compiler budgets and token accounting before planning" {
  install_fake_pipeline_bins
  install_learning_context_boundary_fake
  install_learning_boundary_consumers
  export LEARNING_CONTEXT_CASE=forged-budget

  run_learning_context_lifecycle

  [ "$status" -eq 1 ]
  echo "$json" | jq -e '.ok == false and .failed_stage == "learning-context"'
  jq -e '.error | contains("absolute caps")' \
    "$run_dir/learning-context-receipt.json"
  [ ! -e "$run_dir/boundary-inputs/plan.json" ]
}

@test "legion-run: unavailable compiler is explicit in advisory mode and fatal in required mode" {
  install_fake_pipeline_bins
  install_learning_context_boundary_fake
  install_learning_boundary_consumers
  export LEARNING_CONTEXT_CASE=unavailable

  run_learning_context_lifecycle
  [ "$status" -eq 0 ]
  jq -e '.status == "unavailable"' "$run_dir/learning-context-receipt.json"

  manifest="$(make_plugin)"
  run "$RUN" --plugin-manifest "$manifest" --repo "$REPO" \
    --task "Exercise required learning context" --name learning-contract \
    --learning-context-mode required --json
  [ "$status" -eq 1 ]
  required_json="$(printf '%s' "$output" | json_from_output)"
  required_run_dir="$(echo "$required_json" | jq -r '.run_dir')"
  echo "$required_json" | jq -e '.failed_stage == "learning-context"'
  jq -e '.status == "unavailable"' "$required_run_dir/learning-context-receipt.json"
}

@test "legion-run: reauthenticates a context after delivery and stops on replacement" {
  install_fake_pipeline_bins
  install_learning_context_boundary_fake
  install_learning_boundary_consumers
  cat > "$BATS_TEST_TMPDIR/bin/fieldops-plan" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
replacement="${LEGION_LEARNING_CONTEXT_PATH}.replacement"
printf '{"schema":"replaced"}\n' > "$replacement"
mv "$replacement" "$LEGION_LEARNING_CONTEXT_PATH"
printf '{"schema":"legion.plugin.plan.v1","task":"%s"}\n' "$LEGION_TASK" > "$LEGION_RUN_PLAN_FILE"
printf '%s\n' '{"id":"one","archetype":"implement-feature","task":"slice"}' > "$LEGION_RUN_SLICES_FILE"
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/fieldops-plan"
  export LEARNING_CONTEXT_CASE=advisory

  run_learning_context_lifecycle

  [ "$status" -eq 1 ]
  echo "$json" | jq -e '.failed_stage == "plan" and (.error | contains("learning context integrity failure"))'
  [ ! -e "$run_dir/boundary-inputs/compile-context.fanout.args.json" ]
}

@test "legion-run: compiler failure still writes empty typed artifacts and records the learning-context failure" {
  install_fake_pipeline_bins
  install_learning_context_boundary_fake
  install_learning_boundary_consumers
  export LEARNING_CONTEXT_CASE=compiler-failure

  run_learning_context_lifecycle
  [ "$status" -eq 1 ]
  assert_learning_context_artifacts
  echo "$json" | jq -e '.ok == false and .failed_stage == "learning-context"'
  jq -e '.hint_count == 0 and .token_count == 0' "$run_dir/learning-usage.json"
  jq -e '.stages[] | select(.stage == "learning-context" and .status == "failed")' "$run_dir/stage-status.json"
}

@test "legion-run: fanout context failure is attributed to plan before delegation starts" {
  install_fake_pipeline_bins
  install_learning_context_boundary_fake
  install_learning_boundary_consumers
  export LEARNING_CONTEXT_CASE=no-hints
  export LEARNING_CONTEXT_FAIL_STAGE=fanout

  run_learning_context_lifecycle

  [ "$status" -eq 1 ]
  echo "$json" | jq -e '.failed_stage == "plan"'
  jq -e '.status == "failed" and (.exit_code | type == "number" and . > 0)' \
    "$run_dir/learning-contexts/fanout-receipt.json"
  [ ! -e "$run_dir/boundary-inputs/delegated-slices.jsonl" ]
}

@test "legion-run: rejects a compiled context for a different boundary" {
  install_fake_pipeline_bins
  install_learning_context_boundary_fake
  install_learning_boundary_consumers
  export LEARNING_CONTEXT_CASE=wrong-boundary

  run_learning_context_lifecycle

  [ "$status" -eq 1 ]
  echo "$json" | jq -e '.ok == false and .failed_stage == "learning-context"'
  jq -e '.error | contains("compiled entity does not match")' \
    "$run_dir/learning-context-receipt.json"
}

@test "legion-run: context compiler timeout leaves typed artifacts and a timed-out learning-context receipt" {
  install_fake_pipeline_bins
  install_learning_context_boundary_fake
  install_learning_boundary_consumers
  export LEARNING_CONTEXT_CASE=compiler-timeout

  manifest="$(make_plugin)"
  run "$RUN" --plugin-manifest "$manifest" --repo "$REPO" --task "Exercise learning context" --name learning-contract --stage-timeout-seconds 1 --json
  [ "$status" -eq 124 ]
  json="$(printf '%s' "$output" | json_from_output)"
  run_dir="$(echo "$json" | jq -r '.run_dir')"
  assert_learning_context_artifacts
  echo "$json" | jq -e '.ok == false and .failed_stage == "learning-context"'
  jq -e '.stages[] | select(.stage == "learning-context" and .status == "failed" and .terminal_status == "timed_out")' "$run_dir/stage-status.json"
}

# Every other learning-context test shadows legion-self-learn with a stub that
# prints curated fixture text, so the compiler, the runner's validation of what
# it returns, and the seam that splices guidance into a prompt are all asserted
# against a fake.  A regression anywhere on the real path -- a hint that no
# longer loads, a document the runner now rejects, guidance that reaches a
# receipt but not the prompt -- stays invisible to them.  This test writes a
# real hints file, runs the real compiler, and asserts on the delivered prompt
# text rather than on any receipt or descriptor.
@test "legion-run: real compiled guidance from a project hints file reaches the planner prompt and every delegated slice" {
  install_fake_pipeline_bins
  install_learning_boundary_consumers
  # install_fake_pipeline_bins stubs legion-self-learn; drop the stub so PATH
  # resolves the real command from legion-observability/bin.
  rm -f "$BATS_TEST_TMPDIR/bin/legion-self-learn"
  # The real compiler reads the project store and the global store. Pin the
  # global one at an empty directory so a developer's own promoted laws cannot
  # add guidance this test would then attribute to the fixture.
  export LEGION_GLOBAL_LEARNING_DIR="$BATS_TEST_TMPDIR/global-learning"
  mkdir -p "$LEGION_GLOBAL_LEARNING_DIR" "$LEGION_STATE_ROOT/learning"
  guidance="Reconcile the persisted ledger before reporting success."
  cat > "$LEGION_STATE_ROOT/learning/hints.json" <<'JSON'
{
  "schema": "legion.learning-hints.v1",
  "hints": [
    {
      "schema": "legion.learning-hint.v1",
      "id": "promoted-ledger-law",
      "scope": "global",
      "status": "active",
      "trusted": true,
      "guidance": "Reconcile the persisted ledger before reporting success.",
      "evidence_ids": ["ev-promoted-ledger-law"]
    },
    {
      "schema": "legion.learning-hint.v1",
      "id": "retired-ledger-law",
      "scope": "global",
      "status": "retired",
      "trusted": true,
      "guidance": "Never deliver this retired ledger guidance.",
      "evidence_ids": ["ev-retired-ledger-law"]
    }
  ]
}
JSON

  run_learning_context_lifecycle

  [ "$status" -eq 0 ]
  assert_learning_context_artifacts
  # The compiled document must come from the fixture hints, not from an empty
  # or defaulted context that would make every assertion below vacuous.
  jq -e --arg guidance "$guidance" '
    (.selected_hints | map(.id)) == ["promoted-ledger-law"] and
    .selected_hints[0].guidance == $guidance and
    .usage.hint_count == 1
  ' "$run_dir/learning-context.json"

  # The delivered prompt is the invariant: the planner's task contract and each
  # delegated slice must carry the marker and the real guidance text.
  jq -e --arg guidance "$guidance" '
    (.task | contains("Trusted learning guidance (bounded):")) and
    (.task | contains($guidance))
  ' "$run_dir/plan.json"
  jq -e -s --arg guidance "$guidance" '
    length == 2 and
    all(.[]; .task | contains("Trusted learning guidance (bounded):")) and
    all(.[]; .task | contains($guidance))
  ' "$run_dir/slices.jsonl"
  # slices.jsonl is the runner's copy; assert on what legion-fanout was handed.
  jq -e -s --arg guidance "$guidance" \
    'length == 2 and all(.[]; .task | contains($guidance))' \
    "$run_dir/boundary-inputs/delegated-slices.jsonl"
  grep -Fq 'Trusted learning guidance (bounded):' "$run_dir/boundary-inputs/final-review.args"
  grep -Fq "$guidance" "$run_dir/boundary-inputs/final-review.args"
  ! grep -R -F 'retired ledger guidance' "$run_dir/boundary-inputs"
}

@test "legion-run: rejects a domain plugin that does not require legion-run" {
  manifest="$(make_plugin)"
  perl -0pi -e 's/entrypoint = "legion-run"/entrypoint = "custom-runner"/' "$manifest"

  run "$RUN" --plugin-manifest "$manifest" --repo "$REPO" --task "Build demo" --dry-run --json
  [ "$status" -eq 2 ]
  [[ "$output" == *"domain plugin must run through legion-run"* ]]
}

@test "legion-run: dry-run exposes the enforced full-app pipeline contract" {
  manifest="$(make_plugin)"

  run "$RUN" --plugin-manifest "$manifest" --repo "$REPO" --task "Build demo" --dry-run --json
  [ "$status" -eq 0 ]
  json="$(printf '%s' "$output" | json_from_output)"
  echo "$json" | jq -e '.plugin.name == "fieldops"'
  echo "$json" | jq -e '.pipeline.profile == "legion.full_app.v1"'
  echo "$json" | jq -e '.pipeline.stages == ["doctor","self-learn-hints","plan","route","fanout-apply","validate","review","evaluate","report","share","self-learn","heal-plan"]'
  echo "$json" | jq -e '.pipeline.required_artifacts | index("legion-report.html") and index("fanout.json") and index("heal-plan.json") and index("artifact-manifest.json")'
}

@test "legion-run: fake plugin run writes the required full-app artifacts" {
  install_fake_pipeline_bins
  manifest="$(make_plugin)"

  run "$RUN" --plugin-manifest "$manifest" --repo "$REPO" --task "Build demo" --json
  [ "$status" -eq 0 ]
  json="$(printf '%s' "$output" | json_from_output)"
  run_dir="$(echo "$json" | jq -r '.run_dir')"
  [ -d "$run_dir" ]
  for artifact in \
    doctor.json self-learn-hints.json plan.json slices.jsonl routes.json \
    fanout.json review.json validation.json eval.json legion-report.json \
    legion-report.html legion-observability.html share.json self-learn.json heal-plan.json
  do
    [ -s "$run_dir/$artifact" ] || {
      echo "missing artifact: $artifact in $run_dir" >&2
      return 1
    }
  done
  grep -q "Full Pipeline Outputs" "$run_dir/legion-observability.html"
  grep -q "fieldops-validate" "$run_dir/legion-observability.html"
  grep -q "codex_runs" "$run_dir/legion-observability.html"
  echo "$json" | jq -e '.ok == true and .pipeline.profile == "legion.full_app.v1"'
}

@test "legion-run: concurrent runs report only their own exact trace" {
  install_fake_pipeline_bins
  export REPORT_BARRIER="$BATS_TEST_TMPDIR/report-barrier"
  cat > "$BATS_TEST_TMPDIR/bin/legion-report" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
trace=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --trace) trace="$2"; shift 2 ;;
    --json) shift ;;
    *) shift ;;
  esac
done
mkdir -p "$REPORT_BARRIER"
printf '%s\n' "$LEGION_RUN_ID" > "$REPORT_BARRIER/$LEGION_RUN_ID"
python3 - "$REPORT_BARRIER" <<'PY'
import sys
import time
from pathlib import Path

barrier = Path(sys.argv[1])
deadline = time.monotonic() + 5
while len(list(barrier.iterdir())) < 2:
    if time.monotonic() >= deadline:
        raise SystemExit("timed out waiting for concurrent report stage")
    time.sleep(0.01)
PY
latest="$(find "$REPORT_BARRIER" -type f -maxdepth 1 -exec basename {} \; | sort | tail -n 1)"
resolved="$trace"
[[ "$trace" != "latest" ]] || resolved="$latest"
jq -cn \
  --arg requested "$trace" \
  --arg resolved "$resolved" \
  --arg env_trace "${LEGION_TRACE_ID-unset}" \
  '{trace:{requested:$requested,resolved:$resolved},env_trace:$env_trace}'
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/legion-report"
  manifest="$(make_plugin)"

  "$RUN" --plugin-manifest "$manifest" --repo "$REPO" --task "Build alpha" --json \
    > "$BATS_TEST_TMPDIR/alpha.out" 2>&1 &
  alpha_pid=$!
  "$RUN" --plugin-manifest "$manifest" --repo "$REPO" --task "Build beta" --json \
    > "$BATS_TEST_TMPDIR/beta.out" 2>&1 &
  beta_pid=$!
  wait "$alpha_pid"
  alpha_status=$?
  wait "$beta_pid"
  beta_status=$?

  [ "$alpha_status" -eq 0 ]
  [ "$beta_status" -eq 0 ]
  alpha_json="$(json_from_output < "$BATS_TEST_TMPDIR/alpha.out")"
  beta_json="$(json_from_output < "$BATS_TEST_TMPDIR/beta.out")"
  alpha_run_id="$(jq -r .run_id <<<"$alpha_json")"
  beta_run_id="$(jq -r .run_id <<<"$beta_json")"
  alpha_run_dir="$(jq -r .run_dir <<<"$alpha_json")"
  beta_run_dir="$(jq -r .run_dir <<<"$beta_json")"

  [ "$alpha_run_id" != "$beta_run_id" ]
  [ "$alpha_run_dir" != "$beta_run_dir" ]
  jq -e --arg run "$alpha_run_id" \
    '.env_trace == $run and .trace.requested == $run and .trace.resolved == $run' \
    "$alpha_run_dir/legion-report.json"
  jq -e --arg run "$beta_run_id" \
    '.env_trace == $run and .trace.requested == $run and .trace.resolved == $run' \
    "$beta_run_dir/legion-report.json"
}

@test "legion-run: generates default TDD slices when plugin plan emits only a brief" {
  install_fake_pipeline_bins
  cat > "$BATS_TEST_TMPDIR/bin/fieldops-plan" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat > "$LEGION_RUN_PLAN_FILE" <<JSON
{
  "schema": "legion.plugin.plan.v1",
  "plugin": "$LEGION_PLUGIN_NAME",
  "mode": "legion-generate-slices",
  "task": "$LEGION_TASK",
  "planning_instruction": "Read PLAN.md and build this app TDD style. Start with failing tests, implement only enough to pass, then refactor after green.",
  "context_files": ["PLAN.md"],
  "required_skills": ["ai-architect", "software-architect", "javascript-testing-patterns", "e2e-testing-patterns"],
  "quality_gates": ["lint", "typecheck", "test", "build", "playwright"],
  "eval_goal": "Freezer-down request is triaged, scheduled, validated, replied to, and exported."
}
JSON
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/fieldops-plan"
  manifest="$(make_plugin)"

  run "$RUN" --plugin-manifest "$manifest" --repo "$REPO" --task "Build FieldOps AI Dispatch" --allow-generated-slices --json
  [ "$status" -eq 0 ]
  json="$(printf '%s' "$output" | json_from_output)"
  run_dir="$(echo "$json" | jq -r '.run_dir')"
  [ -s "$run_dir/slices.jsonl" ]
  jq -e '.mode == "legion-generate-slices"' "$run_dir/plan.json"
  jq -e 'select(.phase == "red" and .archetype == "write-tests")' "$run_dir/slices.jsonl" >/dev/null
  jq -e 'select(.phase == "green" and .archetype == "implement-feature")' "$run_dir/slices.jsonl" >/dev/null
  jq -e 'select(.phase == "refactor" and .archetype == "refactor-module")' "$run_dir/slices.jsonl" >/dev/null
  grep -q "generated_by" "$run_dir/slices.jsonl"
}

@test "legion-run: requires an explicit slice contract unless compatibility is requested" {
  install_fake_pipeline_bins
  cat > "$BATS_TEST_TMPDIR/bin/fieldops-plan" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '{"schema":"legion.plugin.plan.v1","plugin":"%s","task":"%s"}\n' "$LEGION_PLUGIN_NAME" "$LEGION_TASK" > "$LEGION_RUN_PLAN_FILE"
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/fieldops-plan"
  manifest="$(make_plugin)"

  run "$RUN" --plugin-manifest "$manifest" --repo "$REPO" --task "Build FieldOps AI Dispatch" --json
  [ "$status" -eq 2 ]
  json="$(printf '%s' "$output" | json_from_output)"
  run_dir="$(echo "$json" | jq -r '.run_dir')"
  echo "$json" | jq -e '.ok == false and .failed_stage == "plan"'
  jq -e '.stages[] | select(.stage == "plan" and .status == "failed")' "$run_dir/stage-status.json"
  jq -e '(.message | contains("explicit slices"))' "$run_dir/failure.json"
}

@test "legion-run: timeout creates a terminal stage receipt and cleans the child group" {
  install_fake_pipeline_bins
  cat > "$BATS_TEST_TMPDIR/bin/legion-fanout" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
sleep 5
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/legion-fanout"
  manifest="$(make_plugin)"

  run "$RUN" --plugin-manifest "$manifest" --repo "$REPO" --task "Build demo" --stage-timeout-seconds 1 --json
  [ "$status" -eq 124 ]
  json="$(printf '%s' "$output" | json_from_output)"
  run_dir="$(echo "$json" | jq -r '.run_dir')"
  echo "$json" | jq -e '.ok == false and .failed_stage == "fanout-apply"'
  jq -e '.status == "timed_out" and .exit_code == 124 and .timeout_seconds == 1' "$run_dir/fanout.json"
  jq -e '.stages[] | select(.stage == "fanout-apply" and .status == "failed" and .terminal_status == "timed_out")' "$run_dir/stage-status.json"
  jq -e '.stages[] | select(.stage == "review" and .status == "skipped" and .terminal_status == "not_run")' "$run_dir/stage-status.json"
}

@test "legion-run: dispatches final review through the resolved Claude route" {
  install_fake_pipeline_bins
  cat > "$BATS_TEST_TMPDIR/bin/legion-route" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  final-review) printf '{"executor":"claude","model":"test-model-claude","reasoning_effort":"high","resolved":true}\n' ;;
  *) printf '{"executor":"codex","model":"test-model-beta","sandbox":"workspace-write","resolved":true}\n' ;;
esac
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/legion-route"
  manifest="$(make_plugin)"

  run "$RUN" --plugin-manifest "$manifest" --repo "$REPO" --task "Build demo" --json
  [ "$status" -eq 0 ]
  json="$(printf '%s' "$output" | json_from_output)"
  run_dir="$(echo "$json" | jq -r '.run_dir')"
  jq -e '.model == "test-model-claude" and (.result | contains("approve"))' "$run_dir/review.json"
  grep -Fq -- "--sandbox read-only" "$run_dir/claude-review.args"
}

@test "legion-run: fails closed when Claude omits the terminal review verdict" {
  install_fake_pipeline_bins
  cat > "$BATS_TEST_TMPDIR/bin/legion-route" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  final-review) printf '{"executor":"claude","model":"test-model-claude","reasoning_effort":"high","resolved":true}\n' ;;
  *) printf '{"executor":"codex","model":"test-model-beta","sandbox":"workspace-write","resolved":true}\n' ;;
esac
SH
  cat > "$BATS_TEST_TMPDIR/bin/legion-claude" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '{"status":"ok","model":"test-model-claude","result":"Review incomplete due to timeout."}\n'
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/legion-route" "$BATS_TEST_TMPDIR/bin/legion-claude"
  manifest="$(make_plugin)"

  run "$RUN" --plugin-manifest "$manifest" --repo "$REPO" --task "Build demo" --json

  [ "$status" -eq 1 ]
  json="$(printf '%s' "$output" | json_from_output)"
  run_dir="$(echo "$json" | jq -r '.run_dir')"
  echo "$json" | jq -e '.ok == false and .failed_stage == "review"'
  jq -e '(.message | contains("invalid terminal verdict"))' "$run_dir/failure.json"
}

@test "legion-run: validation is role-clean and review uses an immutable snapshot" {
  install_fake_pipeline_bins
  cat > "$BATS_TEST_TMPDIR/bin/legion-fanout" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
repo=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf 'generated\n' > "$repo/generated.txt"
ledger="$LEGION_RUN_DIR/fanout-task-ledger.json"
printf '{"schema":"legion.task-ledger.v1","status":"completed","tasks":[]}\n' > "$ledger"
jq -cn --arg ledger "$ledger" \
  '{ok:1,slices:1,failed:0,applied:1,results:[],task_ledger_path:$ledger}'
SH
  cat > "$BATS_TEST_TMPDIR/bin/fieldops-validate" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
jq -cn \
  --arg active "${LEGION_ACTIVE-unset}" \
  --arg executor "${LEGION_EXECUTOR-unset}" \
  --arg depth "${LEGION_DEPTH-unset}" \
  --arg trace "${LEGION_TRACE_ID-unset}" \
  --arg parent "${LEGION_PARENT_ID-unset}" \
  --arg validation "${LEGION_VALIDATION-unset}" \
  '{ok:true,active:$active,executor:$executor,depth:$depth,
    trace:$trace,parent:$parent,validation:$validation}'
SH
  cat > "$BATS_TEST_TMPDIR/bin/legion-delegate" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" > "$LEGION_RUN_DIR/review-args.txt"
printf '{"status":"ok","model":"test-model-beta","verdict":{"verdict":"approve","summary":"immutable snapshot reviewed","findings":[]}}\n'
SH
  cat > "$BATS_TEST_TMPDIR/bin/legion-report" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" > "$LEGION_RUN_DIR/report-args.txt"
jq -cn --arg trace "${LEGION_TRACE_ID-unset}" '{ok:true,env_trace:$trace}'
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/legion-fanout" \
    "$BATS_TEST_TMPDIR/bin/fieldops-validate" \
    "$BATS_TEST_TMPDIR/bin/legion-delegate" \
    "$BATS_TEST_TMPDIR/bin/legion-report"
  manifest="$(make_plugin)"

  LEGION_ACTIVE=1 LEGION_EXECUTOR=1 LEGION_DEPTH=3 \
  LEGION_TRACE_ID=outer-trace LEGION_PARENT_ID=outer-parent \
    run "$RUN" --plugin-manifest "$manifest" --repo "$REPO" --task "Build demo" --json
  [ "$status" -eq 0 ]
  json="$(printf '%s' "$output" | json_from_output)"
  run_dir="$(echo "$json" | jq -r '.run_dir')"
  jq -e '
    .active == "unset"
    and .executor == "unset"
    and .depth == "unset"
    and .trace == "outer-trace"
    and .parent == "outer-parent"
    and .validation == "1"
  ' "$run_dir/validation.json"
  base_sha="$(jq -r .base_sha "$run_dir/review-input.json")"
  head_sha="$(jq -r .head_sha "$run_dir/review-input.json")"
  [ "${#base_sha}" -eq 40 ]
  [ "${#head_sha}" -eq 40 ]
  [ "$base_sha" != "$head_sha" ]
  git -C "$REPO" cat-file -e "$head_sha:generated.txt"
  grep -Fq -- "--base $base_sha --head $head_sha" "$run_dir/review-args.txt"
  grep -Fq -- "--trace outer-trace --json" "$run_dir/report-args.txt"
  jq -e '.env_trace == "outer-trace"' "$run_dir/legion-report.json"
}

@test "legion-run: a successful fanout must return its task ledger" {
  install_fake_pipeline_bins
  cat > "$BATS_TEST_TMPDIR/bin/legion-fanout" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '{"ok":1,"slices":1,"failed":0,"applied":1,"results":[]}\n'
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/legion-fanout"
  manifest="$(make_plugin)"

  run "$RUN" --plugin-manifest "$manifest" --repo "$REPO" --task "Build demo" --json

  [ "$status" -eq 1 ]
  json="$(printf '%s' "$output" | json_from_output)"
  run_dir="$(echo "$json" | jq -r '.run_dir')"
  echo "$json" | jq -e '.failed_stage == "fanout-apply"'
  jq -e '.status == "unavailable"' "$run_dir/task-ledger.json"
}

@test "legion-run: immutable review snapshot excludes ignored runtime state" {
  install_fake_pipeline_bins
  cat > "$BATS_TEST_TMPDIR/bin/legion-fanout" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'generated\n' > generated.txt
ledger="$LEGION_RUN_DIR/fanout-task-ledger.json"
printf '{"schema":"legion.task-ledger.v1","status":"completed","tasks":[]}\n' > "$ledger"
jq -cn --arg ledger "$ledger" \
  '{ok:1,slices:1,failed:0,applied:1,results:[],task_ledger_path:$ledger}'
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/legion-fanout"
  mkdir -p "$REPO/.legion"
  printf '*\n' > "$REPO/.legion/.gitignore"
  printf 'local runtime secret\n' > "$REPO/.legion/runtime.json"
  manifest="$(make_plugin)"

  run "$RUN" --plugin-manifest "$manifest" --repo "$REPO" --task "Build demo" --json

  [ "$status" -eq 0 ]
  json="$(printf '%s' "$output" | json_from_output)"
  run_dir="$(echo "$json" | jq -r '.run_dir')"
  head_sha="$(jq -r .head_sha "$run_dir/review-input.json")"
  git -C "$REPO" cat-file -e "$head_sha:generated.txt"
  run git -C "$REPO" cat-file -e "$head_sha:.legion/.gitignore"
  [ "$status" -ne 0 ]
  run git -C "$REPO" cat-file -e "$head_sha:.legion/runtime.json"
  [ "$status" -ne 0 ]
}

@test "legion-run: refuses a dirty source before reviewer snapshotting" {
  install_fake_pipeline_bins
  printf 'local secret material\n' > "$REPO/private-local.txt"
  manifest="$(make_plugin)"

  run "$RUN" --plugin-manifest "$manifest" --repo "$REPO" --task "Build demo" --json

  [ "$status" -eq 2 ]
  [[ "$output" == *"requires a clean source worktree"* ]]
}

@test "legion-run: dispatches a configured Cursor final reviewer through its adapter" {
  install_fake_pipeline_bins
  cat > "$BATS_TEST_TMPDIR/bin/legion-route" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  final-review) printf '{"executor":"cursor","model":"test-cursor","reasoning_effort":"high","resolved":true}\n' ;;
  *) printf '{"executor":"codex","model":"test-model-beta","sandbox":"workspace-write","resolved":true}\n' ;;
esac
SH
  cat > "$BATS_TEST_TMPDIR/bin/legion-delegate" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" > "$LEGION_RUN_DIR/review-args.txt"
printf '{"status":"ok","model":"test-cursor","result":"{\\"verdict\\":\\"approve\\",\\"summary\\":\\"adapter review passed\\",\\"findings\\":[]}"}\n'
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/legion-route" "$BATS_TEST_TMPDIR/bin/legion-delegate"
  manifest="$(make_plugin)"

  run "$RUN" --plugin-manifest "$manifest" --repo "$REPO" --task "Build demo" --json

  [ "$status" -eq 0 ]
  json="$(printf '%s' "$output" | json_from_output)"
  run_dir="$(echo "$json" | jq -r '.run_dir')"
  grep -Fq -- "run --executor cursor --model test-cursor --sandbox read-only" \
    "$run_dir/review-args.txt"
}

@test "legion-run: snapshot failures are attributed to the review stage" {
  install_fake_pipeline_bins
  printf 'generated.txt filter=reject-review\n' > "$REPO/.gitattributes"
  git -C "$REPO" add .gitattributes
  git -C "$REPO" commit -qm "configure review filter"
  git -C "$REPO" config filter.reject-review.clean false
  git -C "$REPO" config filter.reject-review.required true
  cat > "$BATS_TEST_TMPDIR/bin/legion-fanout" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
repo=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf 'generated\n' > "$repo/generated.txt"
ledger="$LEGION_RUN_DIR/fanout-task-ledger.json"
printf '{"schema":"legion.task-ledger.v1","status":"completed","tasks":[]}\n' > "$ledger"
jq -cn --arg ledger "$ledger" \
  '{ok:1,slices:1,failed:0,applied:1,results:[],task_ledger_path:$ledger}'
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/legion-fanout"
  manifest="$(make_plugin)"

  run "$RUN" --plugin-manifest "$manifest" --repo "$REPO" --task "Build demo" --json

  [ "$status" -eq 1 ]
  json="$(printf '%s' "$output" | json_from_output)"
  echo "$json" | jq -e '.failed_stage == "review"'
}

@test "legion-run: installed-style plugin directory works through manifest and bin hooks" {
  install_fake_pipeline_bins
  manifest="$(make_installed_style_plugin)"
  plugin_dir="$(dirname "$manifest")"
  export PATH="$plugin_dir/bin:$PATH"

  run "$RUN" --plugin-manifest "$manifest" --repo "$REPO" --task "Add SLA escalation" --json
  [ "$status" -eq 0 ]
  json="$(printf '%s' "$output" | json_from_output)"
  run_dir="$(echo "$json" | jq -r '.run_dir')"
  [ -s "$plugin_dir/SKILL.md" ]
  echo "$json" | jq -e '.plugin.name == "support-app-builder"'
  jq -e '.plugin == "support-app-builder" and .source == "installed-style-plugin"' "$run_dir/plan.json"
  jq -e '.ok == true and .command == "support-validate"' "$run_dir/validation.json"
  jq -e '.score == 1 and .total == 1' "$run_dir/eval.json"
  grep -q "support-validate" "$run_dir/legion-observability.html"
}

@test "legion-run: direct heavy-task mode runs the full lifecycle without a plugin manifest" {
  install_fake_pipeline_bins
  cat > "$BATS_TEST_TMPDIR/bin/heavy-plan" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat > "$LEGION_RUN_PLAN_FILE" <<JSON
{
  "schema": "legion.heavy-task.plan.v1",
  "mode": "legion-generate-slices",
  "task": "$LEGION_TASK",
  "planning_instruction": "Build this as a TDD feature: failing tests first, implementation second, refactor after green.",
  "required_skills": ["software-architect", "ai-architect"],
  "quality_gates": ["unit", "build"],
  "eval_goal": "The heavy task is complete and verified."
}
JSON
SH
  cat > "$BATS_TEST_TMPDIR/bin/heavy-validate" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '{"ok":true,"command":"heavy-validate","gates":["unit","build"]}\n'
SH
  cat > "$BATS_TEST_TMPDIR/bin/heavy-eval" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '{"ok":true,"score":3,"total":3,"rubric":"heavy-task"}\n'
SH
  chmod +x "$BATS_TEST_TMPDIR/bin"/heavy-*

  run "$RUN" \
    --repo "$REPO" \
    --task "Add billing export with tests and review" \
    --name billing-export \
    --allow-generated-slices \
    --plan-command heavy-plan \
    --validate-command heavy-validate \
    --evaluate-command heavy-eval \
    --json
  [ "$status" -eq 0 ]
  json="$(printf '%s' "$output" | json_from_output)"
  run_dir="$(echo "$json" | jq -r '.run_dir')"
  echo "$json" | jq -e '.ok == true and .runner.mode == "direct"'
  echo "$json" | jq -e '.pipeline.profile == "legion.heavy_task.v1"'
  [ -s "$run_dir/artifact-manifest.json" ]
  jq -e '.profile == "legion.heavy_task.v1"' "$run_dir/plan.json"
  jq -e 'select(.profile == "legion.heavy_task.v1" and .phase == "red")' "$run_dir/slices.jsonl" >/dev/null
  jq -e '.command == "heavy-validate" and .ok == true' "$run_dir/validation.json"
  jq -e '.rubric == "heavy-task" and .score == 3' "$run_dir/eval.json"
  grep -q "Legion Heavy Task Pipeline" "$run_dir/legion-observability.html"
  grep -q "artifact-manifest.json" "$run_dir/legion-observability.html"
}

@test "legion-run: direct plan-file is resolved relative to the target repo" {
  install_fake_pipeline_bins
  printf 'Use repo-local PLAN.md to build this TDD style.\n' > "$REPO/PLAN.md"
  git -C "$REPO" add PLAN.md
  git -C "$REPO" commit -qm "add plan"
  cat > "$BATS_TEST_TMPDIR/bin/heavy-validate" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '{"ok":true,"command":"heavy-validate"}\n'
SH
  cat > "$BATS_TEST_TMPDIR/bin/heavy-eval" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '{"ok":true,"score":1,"total":1}\n'
SH
  chmod +x "$BATS_TEST_TMPDIR/bin"/heavy-*

  run "$RUN" \
    --repo "$REPO" \
    --task "Use the repo plan" \
    --name repo-plan \
    --allow-generated-slices \
    --plan-file ./PLAN.md \
    --validate-command heavy-validate \
    --evaluate-command heavy-eval \
    --json
  [ "$status" -eq 0 ]
  json="$(printf '%s' "$output" | json_from_output)"
  run_dir="$(echo "$json" | jq -r '.run_dir')"
  expected_plan="$(cd "$REPO" && pwd -P)/PLAN.md"
  jq -e --arg p "$expected_plan" '.plan_source == $p and (.planning_instruction | contains("repo-local PLAN.md"))' "$run_dir/plan.json"
  jq -e 'select(.generated_by == "legion-run.default-tdd-planner")' "$run_dir/slices.jsonl" >/dev/null
}

@test "legion-run: direct mode accepts multiple repo-relative plan files" {
  install_fake_pipeline_bins
  printf 'Product plan: build invitations TDD style.\n' > "$REPO/PLAN.md"
  printf 'Architecture notes: reuse existing auth boundaries.\n' > "$REPO/ARCH.md"
  git -C "$REPO" add PLAN.md ARCH.md
  git -C "$REPO" commit -qm "add plans"
  cat > "$BATS_TEST_TMPDIR/bin/heavy-validate" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '{"ok":true,"command":"heavy-validate"}\n'
SH
  cat > "$BATS_TEST_TMPDIR/bin/heavy-eval" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '{"ok":true,"score":1,"total":1}\n'
SH
  chmod +x "$BATS_TEST_TMPDIR/bin"/heavy-*

  run "$RUN" \
    --repo "$REPO" \
    --task "Use several repo plans" \
    --name multi-plan \
    --allow-generated-slices \
    --plan-file ./PLAN.md \
    --plan-file ./ARCH.md \
    --validate-command heavy-validate \
    --evaluate-command heavy-eval \
    --json
  [ "$status" -eq 0 ]
  json="$(printf '%s' "$output" | json_from_output)"
  run_dir="$(echo "$json" | jq -r '.run_dir')"
  expected_plan="$(cd "$REPO" && pwd -P)/PLAN.md"
  expected_arch="$(cd "$REPO" && pwd -P)/ARCH.md"
  jq -e --arg p "$expected_plan" --arg a "$expected_arch" \
    '.plan_sources == [$p, $a] and (.planning_instruction | contains("Product plan")) and (.planning_instruction | contains("Architecture notes"))' \
    "$run_dir/plan.json"
  jq -e --arg p "$expected_plan" --arg a "$expected_arch" \
    'select((.task | contains($p)) and (.task | contains($a)))' "$run_dir/slices.jsonl" >/dev/null
}

@test "legion-run: failed fanout still emits partial report, learning, heal plan, and manifest" {
  install_fake_pipeline_bins
  cat > "$BATS_TEST_TMPDIR/bin/heavy-plan" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat > "$LEGION_RUN_PLAN_FILE" <<JSON
{"schema":"legion.heavy-task.plan.v1","mode":"legion-generate-slices","task":"$LEGION_TASK"}
JSON
SH
  cat > "$BATS_TEST_TMPDIR/bin/heavy-validate" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '{"ok":true,"command":"heavy-validate"}\n'
SH
  cat > "$BATS_TEST_TMPDIR/bin/heavy-eval" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '{"ok":true,"score":1,"total":1}\n'
SH
  cat > "$BATS_TEST_TMPDIR/bin/legion-fanout" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '{"ok":0,"failed":1,"results":[{"status":"failed","id":"green-core-implementation","error":"simulated fanout failure"}]}\n'
exit 1
SH
  chmod +x "$BATS_TEST_TMPDIR/bin"/heavy-* "$BATS_TEST_TMPDIR/bin/legion-fanout"

  run "$RUN" \
    --repo "$REPO" \
    --task "Add billing export with tests and review" \
    --name billing-export \
    --allow-generated-slices \
    --plan-command heavy-plan \
    --validate-command heavy-validate \
    --evaluate-command heavy-eval \
    --json
  [ "$status" -eq 1 ]
  json="$(printf '%s' "$output" | json_from_output)"
  run_dir="$(echo "$json" | jq -r '.run_dir')"
  echo "$json" | jq -e '.ok == false and .failed_stage == "fanout-apply"'
  for artifact in failure.json stage-status.json partial-summary.json artifact-manifest.json legion-report.html legion-observability.html self-learn.json heal-plan.json
  do
    [ -s "$run_dir/$artifact" ] || {
      echo "missing failure artifact: $artifact in $run_dir" >&2
      return 1
    }
  done
  jq -e '.failed_stage == "fanout-apply" and (.message | contains("fanout.json"))' "$run_dir/failure.json"
  jq -e '.stages[] | select(.stage == "fanout-apply" and .status == "failed")' "$run_dir/stage-status.json"
  jq -e '.stages[] | select(.stage == "review" and .status == "skipped")' "$run_dir/stage-status.json"
  jq -e '.artifacts[] | select(.path == "fanout.json" and .exists == true)' "$run_dir/artifact-manifest.json"
  jq -e '(.record.ok == true or .record.recorded == true) and .run.applied_memory == true' "$run_dir/self-learn.json"
  [ -s "$run_dir/self-learn-run.json" ]
  jq -e '.stages[] | select(.stage == "self-learn" and .status == "passed")' "$run_dir/stage-status.json"
  grep -q "FAILED" "$run_dir/legion-observability.html"
  grep -q "simulated fanout failure" "$run_dir/legion-observability.html"
}

@test "legion-run: doctor failure records entity-scoped learning and applies memory" {
  install_fake_pipeline_bins
  cat > "$BATS_TEST_TMPDIR/bin/legion-doctor" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat <<'JSON'
[{"check":"skill-frontmatter","severity":"fail","entity":"skill:caveman","message":"SKILL.md block-scalar description blanks line-based readers."}]
JSON
exit 1
SH
  cat > "$BATS_TEST_TMPDIR/bin/heavy-plan" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat > "$LEGION_RUN_PLAN_FILE" <<JSON
{"schema":"legion.heavy-task.plan.v1","mode":"legion-generate-slices","task":"$LEGION_TASK"}
JSON
SH
  cat > "$BATS_TEST_TMPDIR/bin/heavy-validate" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '{"ok":true,"command":"heavy-validate"}\n'
SH
  cat > "$BATS_TEST_TMPDIR/bin/heavy-eval" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '{"ok":true,"score":1,"total":1}\n'
SH
  chmod +x "$BATS_TEST_TMPDIR/bin"/heavy-* "$BATS_TEST_TMPDIR/bin/legion-doctor"

  run "$RUN" \
    --repo "$REPO" \
    --task "Add billing export with tests and review" \
    --name billing-export \
    --allow-generated-slices \
    --plan-command heavy-plan \
    --validate-command heavy-validate \
    --evaluate-command heavy-eval \
    --json
  [ "$status" -eq 1 ]
  json="$(printf '%s' "$output" | json_from_output)"
  run_dir="$(echo "$json" | jq -r '.run_dir')"
  echo "$json" | jq -e '.ok == false and .failed_stage == "doctor"'
  jq -e '.recorded >= 1' "$run_dir/learning-feedback.json"
  jq -e '.outcomes[] | select(.source == "legion-run:doctor" and .target_type == "skill" and .target_name == "caveman" and (.summary | contains("block-scalar description")))' "$run_dir/learning-feedback.json"
  jq -e '.run.applied_memory == true' "$run_dir/self-learn.json"
  [ -s "$run_dir/self-learn-run.json" ]
  jq -e '.stages[] | select(.stage == "self-learn" and .status == "passed")' "$run_dir/stage-status.json"
}

@test "legion-run: fanout semantic failure fails the stage and records learning even with exit zero" {
  install_fake_pipeline_bins
  cat > "$BATS_TEST_TMPDIR/bin/heavy-plan" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat > "$LEGION_RUN_PLAN_FILE" <<JSON
{"schema":"legion.heavy-task.plan.v1","mode":"legion-generate-slices","task":"$LEGION_TASK"}
JSON
SH
  cat > "$BATS_TEST_TMPDIR/bin/heavy-validate" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '{"ok":true,"command":"heavy-validate"}\n'
SH
  cat > "$BATS_TEST_TMPDIR/bin/heavy-eval" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '{"ok":true,"score":1,"total":1}\n'
SH
  cat > "$BATS_TEST_TMPDIR/bin/legion-fanout" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat <<'JSON'
{"ok":1,"slices":3,"failed":1,"applied":2,"apply_conflicts":0,"results":[{"status":"failed","id":"red-demo-flow-tests","error":"Playwright seed data setup never ran"}]}
JSON
SH
  chmod +x "$BATS_TEST_TMPDIR/bin"/heavy-* "$BATS_TEST_TMPDIR/bin/legion-fanout"

  run "$RUN" \
    --repo "$REPO" \
    --task "Add billing export with tests and review" \
    --name billing-export \
    --allow-generated-slices \
    --plan-command heavy-plan \
    --validate-command heavy-validate \
    --evaluate-command heavy-eval \
    --json
  [ "$status" -eq 1 ]
  json="$(printf '%s' "$output" | json_from_output)"
  run_dir="$(echo "$json" | jq -r '.run_dir')"
  echo "$json" | jq -e '.ok == false and .failed_stage == "fanout-apply"'
  jq -e '.failed == 1 and .exit_code == 0' "$run_dir/fanout.json"
  jq -e '.failed_stage == "fanout-apply" and (.message | contains("semantic failure"))' "$run_dir/failure.json"
  jq -e '.outcomes[] | select(.source == "legion-run:fanout-apply" and .target_type == "heavy-task" and .target_name == "billing-export" and (.summary | contains("1 failed")))' "$run_dir/learning-feedback.json"
  jq -e '.run.applied_memory == true' "$run_dir/self-learn.json"
}

@test "legion-run: validation failure records validator feedback before learning finalization" {
  install_fake_pipeline_bins
  cat > "$BATS_TEST_TMPDIR/bin/heavy-plan" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat > "$LEGION_RUN_PLAN_FILE" <<JSON
{"schema":"legion.heavy-task.plan.v1","mode":"legion-generate-slices","task":"$LEGION_TASK"}
JSON
SH
  cat > "$BATS_TEST_TMPDIR/bin/heavy-validate" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat <<'JSON'
{"ok":false,"learning_feedback":[{"id":"missing-contract-test","source":"validation-feedback","target_type":"skill","target_name":"legion-run","severity":"high","summary":"Validation discovered that generated slices can pass without a contract test for billing export idempotency.","evidence":{"gate":"integration","missing":"idempotency contract"}}]}
JSON
exit 1
SH
  cat > "$BATS_TEST_TMPDIR/bin/heavy-eval" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '{"ok":true,"score":1,"total":1}\n'
SH
  chmod +x "$BATS_TEST_TMPDIR/bin"/heavy-*

  run "$RUN" \
    --repo "$REPO" \
    --task "Add billing export with tests and review" \
    --name billing-export \
    --allow-generated-slices \
    --plan-command heavy-plan \
    --validate-command heavy-validate \
    --evaluate-command heavy-eval \
    --json
  [ "$status" -eq 1 ]
  json="$(printf '%s' "$output" | json_from_output)"
  run_dir="$(echo "$json" | jq -r '.run_dir')"
  echo "$json" | jq -e '.ok == false and .failed_stage == "validate"'
  jq -e '.ok == false and .exit_code == 1' "$run_dir/validation.json"
  jq -e '.recorded >= 1' "$run_dir/learning-feedback.json"
  jq -e '.outcomes[] | select(.source == "legion-run:validate" and .target_type == "heavy-task" and .target_name == "billing-export" and (.summary | contains("idempotency")))' "$run_dir/learning-feedback.json"
  jq -e '.run.applied_memory == true' "$run_dir/self-learn.json"
  [ -s "$run_dir/self-learn-run.json" ]
}

@test "legion-run: review findings fail the gate and record learning" {
  install_fake_pipeline_bins
  cat > "$BATS_TEST_TMPDIR/bin/heavy-plan" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat > "$LEGION_RUN_PLAN_FILE" <<JSON
{"schema":"legion.heavy-task.plan.v1","mode":"legion-generate-slices","task":"$LEGION_TASK"}
JSON
SH
  cat > "$BATS_TEST_TMPDIR/bin/heavy-validate" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '{"ok":true,"command":"heavy-validate"}\n'
SH
  cat > "$BATS_TEST_TMPDIR/bin/heavy-eval" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '{"ok":true,"score":1,"total":1}\n'
SH
  cat > "$BATS_TEST_TMPDIR/bin/legion-delegate" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat <<'JSON'
{"status":"ok","model":"test-model-beta","verdict":{"verdict":"request_changes","summary":"Review found a blocking cold-chain SLA regression.","findings":[{"severity":"high","title":"Include all cold-chain assets in outage escalation"}]}}
JSON
SH
  chmod +x "$BATS_TEST_TMPDIR/bin"/heavy-* "$BATS_TEST_TMPDIR/bin/legion-delegate"

  run "$RUN" \
    --repo "$REPO" \
    --task "Add billing export with tests and review" \
    --name billing-export \
    --allow-generated-slices \
    --plan-command heavy-plan \
    --validate-command heavy-validate \
    --evaluate-command heavy-eval \
    --json
  [ "$status" -eq 1 ]
  json="$(printf '%s' "$output" | json_from_output)"
  run_dir="$(echo "$json" | jq -r '.run_dir')"
  echo "$json" | jq -e '.ok == false and .failed_stage == "review"'
  jq -e '.verdict.verdict == "request_changes"' "$run_dir/review.json"
  jq -e '.outcomes[] | select(.source == "legion-run:review" and .target_type == "heavy-task" and .target_name == "billing-export" and (.summary | contains("request_changes")))' "$run_dir/learning-feedback.json"
  jq -e '.run.applied_memory == true' "$run_dir/self-learn.json"
  jq -e '.stages[] | select(.stage == "review" and .status == "failed")' "$run_dir/stage-status.json"
  jq -e '.stages[] | select(.stage == "self-learn" and .status == "passed")' "$run_dir/stage-status.json"
  [ -s "$run_dir/heal-plan.json" ]
}

@test "legion-run: self-learning command failure is visible and still leaves a heal plan" {
  install_fake_pipeline_bins
  cat > "$BATS_TEST_TMPDIR/bin/heavy-plan" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat > "$LEGION_RUN_PLAN_FILE" <<JSON
{"schema":"legion.heavy-task.plan.v1","mode":"legion-generate-slices","task":"$LEGION_TASK"}
JSON
SH
  cat > "$BATS_TEST_TMPDIR/bin/heavy-validate" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '{"ok":true,"command":"heavy-validate"}\n'
SH
  cat > "$BATS_TEST_TMPDIR/bin/heavy-eval" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '{"ok":true,"score":1,"total":1}\n'
SH
  cat > "$BATS_TEST_TMPDIR/bin/legion-self-learn" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  hints) printf '{"schema":"legion.self-learning.hints.v1","entities":{}}\n' ;;
  record) printf '{"ok":true,"recorded":true}\n' ;;
  run) printf '{"ok":false,"error":"memory write denied"}\n'; exit 1 ;;
  *) printf '{"ok":true}\n' ;;
esac
SH
  chmod +x "$BATS_TEST_TMPDIR/bin"/heavy-* "$BATS_TEST_TMPDIR/bin/legion-self-learn"

  run "$RUN" \
    --repo "$REPO" \
    --task "Add billing export with tests and review" \
    --name billing-export \
    --allow-generated-slices \
    --plan-command heavy-plan \
    --validate-command heavy-validate \
    --evaluate-command heavy-eval \
    --json
  [ "$status" -eq 1 ]
  json="$(printf '%s' "$output" | json_from_output)"
  run_dir="$(echo "$json" | jq -r '.run_dir')"
  echo "$json" | jq -e '.ok == false and .failed_stage == "self-learn"'
  jq -e '.run.exit_code == 1 and (.run.error | contains("memory write denied"))' "$run_dir/self-learn.json"
  jq -e '.stages[] | select(.stage == "self-learn" and .status == "failed")' "$run_dir/stage-status.json"
  jq -e '.stages[] | select(.stage == "heal-plan" and .status == "passed")' "$run_dir/stage-status.json"
  [ -s "$run_dir/learning-feedback.json" ]
  [ -s "$run_dir/heal-plan.json" ]
  grep -q "self-learning command failed" "$run_dir/legion-observability.html"
}
