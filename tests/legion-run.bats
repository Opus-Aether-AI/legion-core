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
  run) printf '{"ok":true,"memory":true}\n' ;;
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
  echo "$output" | jq -e '.plugin.name == "fieldops"'
  echo "$output" | jq -e '.pipeline.profile == "legion.full_app.v1"'
  echo "$output" | jq -e '.pipeline.stages == ["doctor","self-learn-hints","plugin-plan","route","fanout-apply","review","validate","evaluate","report","share","self-learn","heal-plan"]'
  echo "$output" | jq -e '.pipeline.required_artifacts | index("legion-report.html") and index("fanout.json") and index("heal-plan.json")'
}

@test "legion-run: fake plugin run writes the required full-app artifacts" {
  install_fake_pipeline_bins
  manifest="$(make_plugin)"

  run "$RUN" --plugin-manifest "$manifest" --repo "$REPO" --task "Build demo" --json
  [ "$status" -eq 0 ]
  run_dir="$(echo "$output" | jq -r '.run_dir')"
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
  echo "$output" | jq -e '.ok == true and .pipeline.profile == "legion.full_app.v1"'
}

@test "legion-run: installed-style plugin directory works through manifest and bin hooks" {
  install_fake_pipeline_bins
  manifest="$(make_installed_style_plugin)"
  plugin_dir="$(dirname "$manifest")"
  export PATH="$plugin_dir/bin:$PATH"

  run "$RUN" --plugin-manifest "$manifest" --repo "$REPO" --task "Add SLA escalation" --json
  [ "$status" -eq 0 ]
  run_dir="$(echo "$output" | jq -r '.run_dir')"
  [ -s "$plugin_dir/SKILL.md" ]
  echo "$output" | jq -e '.plugin.name == "support-app-builder"'
  jq -e '.plugin == "support-app-builder" and .source == "installed-style-plugin"' "$run_dir/plan.json"
  jq -e '.ok == true and .command == "support-validate"' "$run_dir/validation.json"
  jq -e '.score == 1 and .total == 1' "$run_dir/eval.json"
  grep -q "support-validate" "$run_dir/legion-observability.html"
}
