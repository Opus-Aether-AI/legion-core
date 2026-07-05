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

@test "fanout: missing --slices exits 2" {
  run "$FANOUT" --repo "$REPO"
  [ "$status" -eq 2 ]
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
