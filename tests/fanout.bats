#!/usr/bin/env bats
# legion-fanout — parallel multi-model fan-out across executors (mock codex on PATH).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  FANOUT="$ROOT/legion-orchestrate/bin/legion-fanout"
  export PATH="$ROOT/legion-router/bin:$ROOT/legion-observability/bin:$BATS_TEST_DIRNAME/mocks/bin:$PATH"     # mock `codex`
  # Pin the REAL delegate: tests/mocks/bin also carries a legion-delegate stub (for
  # legion-claude's fallback tests) that would otherwise shadow the real one here.
  export LEGION_DELEGATE="$ROOT/legion-router/bin/legion-delegate"
  export LEGION_TELEMETRY="$ROOT/legion-observability/bin/legion-trace"
  export LEGION_TELEMETRY_DIR="$BATS_TEST_TMPDIR/spans"
  CODEX_WORKHORSE="$("$ROOT/legion-router/bin/legion-route" --model-ref codex_workhorse)"
  CODEX_REVIEW="$("$ROOT/legion-router/bin/legion-route" --model-ref codex_review)"
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO"
  git -C "$REPO" init -q
  git -C "$REPO" config user.email t@t.c
  git -C "$REPO" config user.name t
  printf 'a\n' > "$REPO/a.ts"
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=t@t.c -c user.name=t commit -qm init
}

@test "fanout: resolves legion-route from PATH before source-tree fallback" {
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  cat > "$bin/legion-route" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"executor":"self","model":"path-stub"}'
SH
  chmod +x "$bin/legion-route"

  printf '%s\n' '{"archetype":"implement-feature","task":"build A"}' > "$BATS_TEST_TMPDIR/path.jsonl"
  PATH="$bin:$PATH" run "$FANOUT" --slices "$BATS_TEST_TMPDIR/path.jsonl" --repo "$REPO"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.inline == 1 and .ok == 0'
}

@test "fanout: missing telemetry command does not block work" {
  local isolated="$BATS_TEST_TMPDIR/isolated/legion-fanout.sh"
  mkdir -p "$(dirname "$isolated")"
  cp "$ROOT/legion-orchestrate/scripts/legion-fanout.sh" "$isolated"
  chmod +x "$isolated"

  printf '%s\n' '{"archetype":"implement-feature","task":"build A"}' > "$BATS_TEST_TMPDIR/no-telemetry.jsonl"
  local clean_path="$ROOT/legion-router/bin:$BATS_TEST_DIRNAME/mocks/bin:$(dirname "$(command -v python3)"):$(dirname "$(command -v jq)"):$(dirname "$(command -v git)"):/usr/bin:/bin:/usr/sbin:/sbin"
  PATH="$clean_path" LEGION_TELEMETRY= \
    run "$isolated" --slices "$BATS_TEST_TMPDIR/no-telemetry.jsonl" --repo "$REPO"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ok == 1 and .failed == 0'
}

@test "fanout: delegates codex slices in parallel + returns self slices inline" {
  printf '%s\n' \
    '{"archetype":"implement-feature","task":"build A"}' \
    '{"archetype":"write-tests","task":"tests for A"}' \
    '{"archetype":"deep-reasoning","task":"decide the design"}' > "$BATS_TEST_TMPDIR/s.jsonl"
  run "$FANOUT" --slices "$BATS_TEST_TMPDIR/s.jsonl" --repo "$REPO" --max-concurrency 2
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.slices == 3 and .ok == 2 and .inline == 1 and .failed == 0'
  echo "$output" | jq -e --arg model "$CODEX_WORKHORSE" '.by_model[$model] == 2'
  echo "$output" | jq -e '[.results[] | select(.status=="inline") | .archetype] == ["deep-reasoning"]'
}

@test "fanout: routes review slices to configured Codex reviewer" {
  printf '%s\n' '{"archetype":"final-review","task":"review the diff"}' > "$BATS_TEST_TMPDIR/r.jsonl"
  run "$FANOUT" --slices "$BATS_TEST_TMPDIR/r.jsonl" --repo "$REPO"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e --arg model "$CODEX_REVIEW" '.by_model[$model] == 1'
}

@test "fanout: stdin slices work" {
  run bash -c "printf '%s\n' '{\"archetype\":\"cheap-bulk\",\"task\":\"x\"}' | '$FANOUT' --slices - --repo '$REPO'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ok == 1 and .total_cost_usd >= 0'
}

@test "fanout: --task file expands demo slices and --json is accepted" {
  printf 'Build a dispatch board with AI scheduling suggestions.\n' > "$BATS_TEST_TMPDIR/task.md"
  run "$FANOUT" --task "$BATS_TEST_TMPDIR/task.md" --repo "$REPO" --json --max-concurrency 1
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.slices == 3 and .ok == 3 and .failed == 0'
  # Demo expands to two workhorse slices + one review slice; resolve the models
  # from config so this survives default-model swaps.
  echo "$output" | jq -e --arg w "$CODEX_WORKHORSE" --arg r "$CODEX_REVIEW" \
    '[.results[].model] == [$w, $w, $r]'
}

@test "fanout: missing --slices exits 2" {
  run "$FANOUT" --repo "$REPO"
  [ "$status" -eq 2 ]
}

@test "fanout: route failures are returned as structured route-stage errors" {
  local bad_route="$BATS_TEST_TMPDIR/bad-legion-route"
  cat > "$bad_route" <<'SH'
#!/usr/bin/env bash
echo "tomllib unavailable" >&2
exit 2
SH
  chmod +x "$bad_route"

  printf '%s\n' '{"archetype":"implement-feature","task":"build A"}' > "$BATS_TEST_TMPDIR/bad-route.jsonl"
  LEGION_ROUTE="$bad_route" run "$FANOUT" --slices "$BATS_TEST_TMPDIR/bad-route.jsonl" --repo "$REPO"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.failed == 1 and .ok == 0'
  echo "$output" | jq -e '.results[0].status == "error" and .results[0].stage == "route"'
  echo "$output" | jq -e '.results[0].archetype == "implement-feature"'
  echo "$output" | jq -e '.results[0].error | contains("tomllib unavailable")'
}

@test "fanout: all delegate spans + the root span share ONE trace_id (OTel tree)" {
  printf '%s\n' \
    '{"archetype":"implement-feature","task":"build A"}' \
    '{"archetype":"write-tests","task":"tests for A"}' > "$BATS_TEST_TMPDIR/s.jsonl"
  run "$FANOUT" --slices "$BATS_TEST_TMPDIR/s.jsonl" --repo "$REPO"
  [ "$status" -eq 0 ]
  # Exactly one distinct trace_id across every emitted span (2 delegates + 1 root)
  local traces
  traces="$(cat "$LEGION_TELEMETRY_DIR"/*.jsonl | jq -r .trace_id | sort -u | wc -l | tr -d ' ')"
  [ "$traces" = "1" ]
}

@test "fanout: emits a root orchestrator span with no parent; delegates parent to it" {
  printf '%s\n' '{"archetype":"implement-feature","task":"build A"}' > "$BATS_TEST_TMPDIR/s.jsonl"
  run "$FANOUT" --slices "$BATS_TEST_TMPDIR/s.jsonl" --repo "$REPO"
  [ "$status" -eq 0 ]
  # Root span: executor=orchestrator, parent_id null, run_id == the shared trace_id
  run bash -c "cat '$LEGION_TELEMETRY_DIR'/*.jsonl | jq -ec 'select(.executor==\"orchestrator\") | {root:(.parent_id==null), self:(.run_id==.trace_id)}'"
  [ "$output" = '{"root":true,"self":true}' ]
  # The delegate span's parent_id is the root's run_id (= the trace_id)
  run bash -c "cat '$LEGION_TELEMETRY_DIR'/*.jsonl | jq -ec 'select(.executor==\"codex\") | (.parent_id==.trace_id)'"
  [ "$output" = "true" ]
}

@test "fanout: preallocates queued run-state records (adopted by the delegate)" {
  export LEGION_REGISTRY_DIR="$BATS_TEST_TMPDIR/registry"
  printf '%s\n' \
    '{"archetype":"implement-feature","task":"build A"}' \
    '{"archetype":"write-tests","task":"tests for A"}' > "$BATS_TEST_TMPDIR/s.jsonl"
  run "$FANOUT" --slices "$BATS_TEST_TMPDIR/s.jsonl" --repo "$REPO" --max-concurrency 1
  [ "$status" -eq 0 ]
  # Two delegated slices -> two registry records, each adopted by the delegate.
  # state_version >= 3 proves the queued prewrite (sv1) then delegate running(sv2)+terminal(sv3).
  local recs; recs=$(ls "$LEGION_REGISTRY_DIR"/*.json | wc -l | tr -d ' ')
  [ "$recs" = "2" ]
  for f in "$LEGION_REGISTRY_DIR"/*.json; do
    [ "$(jq -r '.state_version >= 3' "$f")" = "true" ]
    [ "$(jq -r '.run_id | endswith("-s0") or endswith("-s1")' "$f")" = "true" ]
  done
}

@test "fanout: self/inline slices do NOT leave a queued record" {
  export LEGION_REGISTRY_DIR="$BATS_TEST_TMPDIR/registry"
  printf '%s\n' '{"archetype":"deep-reasoning","task":"decide design"}' > "$BATS_TEST_TMPDIR/s.jsonl"
  run "$FANOUT" --slices "$BATS_TEST_TMPDIR/s.jsonl" --repo "$REPO"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.inline == 1'
  [ "$(ls "$LEGION_REGISTRY_DIR"/*.json 2>/dev/null | wc -l | tr -d ' ')" = "0" ]
}

@test "fanout: a nested fan-out joins the inherited LEGION_TRACE_ID" {
  printf '%s\n' '{"archetype":"implement-feature","task":"build A"}' > "$BATS_TEST_TMPDIR/s.jsonl"
  LEGION_TRACE_ID="outer-trace" LEGION_PARENT_ID="outer-parent" \
    "$FANOUT" --slices "$BATS_TEST_TMPDIR/s.jsonl" --repo "$REPO" >/dev/null
  # Every span carries the inherited trace; the fan-out root parents to the outer parent
  run bash -c "cat '$LEGION_TELEMETRY_DIR'/*.jsonl | jq -r .trace_id | sort -u"
  [ "$output" = "outer-trace" ]
  run bash -c "cat '$LEGION_TELEMETRY_DIR'/*.jsonl | jq -ec 'select(.executor==\"orchestrator\") | .parent_id'"
  [ "$output" = '"outer-parent"' ]
}

@test "fanout: dependent slices run after prerequisites and see the integration base" {
  local bin="$BATS_TEST_TMPDIR/dag-bin"
  mkdir -p "$bin"
  cat > "$bin/legion-route" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '{"executor":"codex","model":"fake-codex","sandbox":"workspace-write","resolved":true}\n'
SH
  cat > "$bin/legion-delegate" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
repo=""
base="HEAD"
task=""
run_id="fake-run"
while [[ $# -gt 0 ]]; do
  case "$1" in
    run) shift ;;
    --repo) repo="$2"; shift 2 ;;
    --base) base="$2"; shift 2 ;;
    --task) task="$2"; shift 2 ;;
    --run-id) run_id="$2"; shift 2 ;;
    --quiet|--keep) shift ;;
    --archetype|--model|--sandbox|--reasoning-effort|--budget-tokens) shift 2 ;;
    *) shift ;;
  esac
done
art="$repo/.legion/fake-delegate/$run_id"
mkdir -p "$art"
diff="$art/diff.patch"
case "$task" in
  *"create platform contract"*)
    cat > "$diff" <<'PATCH'
diff --git a/platform.txt b/platform.txt
new file mode 100644
index 0000000..e2c6c76
--- /dev/null
+++ b/platform.txt
@@ -0,0 +1 @@
+contract
PATCH
    printf '{"status":"ok","model":"fake-codex","diff_path":%s,"base_ref":%s,"cost_usd":0}\n' \
      "$(jq -Rn --arg p "$diff" '$p')" "$(jq -Rn --arg b "$base" '$b')"
    ;;
  *"use platform contract"*)
    if ! git -C "$repo" cat-file -e "$base:platform.txt" 2>/dev/null; then
      printf '{"status":"failed","model":"fake-codex","error":"missing platform.txt in base","base_ref":%s,"cost_usd":0}\n' \
        "$(jq -Rn --arg b "$base" '$b')"
      exit 1
    fi
    : > "$diff"
    printf '{"status":"ok","model":"fake-codex","diff_path":%s,"base_ref":%s,"cost_usd":0}\n' \
      "$(jq -Rn --arg p "$diff" '$p')" "$(jq -Rn --arg b "$base" '$b')"
    ;;
  *)
    printf '{"status":"failed","model":"fake-codex","error":"unexpected task","cost_usd":0}\n'
    exit 1
    ;;
esac
SH
  chmod +x "$bin"/*

  printf '%s\n' \
    '{"id":"platform-contract","archetype":"implement-feature","task":"create platform contract"}' \
    '{"id":"consumer","depends_on":["platform-contract"],"archetype":"implement-feature","task":"use platform contract"}' \
    > "$BATS_TEST_TMPDIR/dag.jsonl"

  LEGION_ROUTE="$bin/legion-route" LEGION_DELEGATE="$bin/legion-delegate" \
    run "$FANOUT" --slices "$BATS_TEST_TMPDIR/dag.jsonl" --repo "$REPO" --max-concurrency 2 --apply --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ok == 2 and .failed == 0 and .applied == 1'
  echo "$output" | jq -e '[.results[].id] == ["platform-contract","consumer"]'
  echo "$output" | jq -e '.results[1].base_ref != "HEAD"'
  [ "$(cat "$REPO/platform.txt")" = "contract" ]
}

@test "fanout: a failed prerequisite blocks dependents without launching them" {
  local bin="$BATS_TEST_TMPDIR/block-bin"
  mkdir -p "$bin"
  cat > "$bin/legion-route" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '{"executor":"codex","model":"fake-codex","sandbox":"workspace-write","resolved":true}\n'
SH
  cat > "$bin/legion-delegate" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
task=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --task) task="$2"; shift 2 ;;
    *) shift ;;
  esac
done
case "$task" in
  *"break prerequisite"*)
    printf '{"status":"failed","model":"fake-codex","error":"boom","cost_usd":0}\n'
    exit 1
    ;;
  *"must never launch"*)
    printf '{"status":"error","model":"fake-codex","error":"dependent launched","cost_usd":0}\n'
    exit 1
    ;;
  *)
    printf '{"status":"ok","model":"fake-codex","cost_usd":0}\n'
    ;;
esac
SH
  chmod +x "$bin"/*

  printf '%s\n' \
    '{"id":"setup","archetype":"implement-feature","task":"break prerequisite"}' \
    '{"id":"dependent","depends_on":["setup"],"archetype":"implement-feature","task":"must never launch"}' \
    > "$BATS_TEST_TMPDIR/blocked.jsonl"

  LEGION_ROUTE="$bin/legion-route" LEGION_DELEGATE="$bin/legion-delegate" \
    run "$FANOUT" --slices "$BATS_TEST_TMPDIR/blocked.jsonl" --repo "$REPO" --max-concurrency 2 --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ok == 0 and .failed == 2'
  echo "$output" | jq -e '.results[0].id == "setup" and .results[0].status == "failed"'
  echo "$output" | jq -e '.results[1].id == "dependent" and .results[1].status == "blocked"'
  echo "$output" | jq -e '.results[1].blocked_by == ["setup"]'
}
