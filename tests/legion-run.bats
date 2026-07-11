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
  implement-feature) printf '{"executor":"codex","model":"gpt-5.5","sandbox":"workspace-write","resolved":true}\n' ;;
  write-tests) printf '{"executor":"codex","model":"gpt-5.5","sandbox":"workspace-write","resolved":true}\n' ;;
  refactor-module) printf '{"executor":"codex","model":"gpt-5.5","sandbox":"workspace-write","resolved":true}\n' ;;
  final-review) printf '{"executor":"codex","model":"gpt-5.5","sandbox":"read-only","resolved":true}\n' ;;
  *) exit 2 ;;
esac
SH
  cat > "$BATS_TEST_TMPDIR/bin/legion-fanout" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '{"ok":1,"slices":1,"failed":0,"applied":1,"results":[]}\n'
SH
  cat > "$BATS_TEST_TMPDIR/bin/legion-delegate" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '{"status":"ok","model":"gpt-5.5","verdict":"ok"}\n'
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
  echo "$json" | jq -e '.pipeline.stages == ["doctor","self-learn-hints","plan","route","fanout-apply","review","validate","evaluate","report","share","self-learn","heal-plan"]'
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

  run "$RUN" --plugin-manifest "$manifest" --repo "$REPO" --task "Build FieldOps AI Dispatch" --json
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
  jq -e '.outcomes[] | select(.source == "legion-run:fanout-apply" and .target_type == "command" and .target_name == "legion-fanout" and (.summary | contains("1 failed")))' "$run_dir/learning-feedback.json"
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
  jq -e '.outcomes[] | select(.source == "validation-feedback" and .target_type == "skill" and .target_name == "legion-run" and (.summary | contains("idempotency")))' "$run_dir/learning-feedback.json"
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
{"status":"ok","model":"gpt-5.5","verdict":{"verdict":"request_changes","summary":"Review found a blocking cold-chain SLA regression.","findings":[{"severity":"high","title":"Include all cold-chain assets in outage escalation"}]}}
JSON
SH
  chmod +x "$BATS_TEST_TMPDIR/bin"/heavy-* "$BATS_TEST_TMPDIR/bin/legion-delegate"

  run "$RUN" \
    --repo "$REPO" \
    --task "Add billing export with tests and review" \
    --name billing-export \
    --plan-command heavy-plan \
    --validate-command heavy-validate \
    --evaluate-command heavy-eval \
    --json
  [ "$status" -eq 1 ]
  json="$(printf '%s' "$output" | json_from_output)"
  run_dir="$(echo "$json" | jq -r '.run_dir')"
  echo "$json" | jq -e '.ok == false and .failed_stage == "review"'
  jq -e '.verdict.verdict == "request_changes"' "$run_dir/review.json"
  jq -e '.outcomes[] | select(.source == "legion-run:review" and .target_type == "command" and .target_name == "legion-delegate" and (.summary | contains("request_changes")))' "$run_dir/learning-feedback.json"
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
