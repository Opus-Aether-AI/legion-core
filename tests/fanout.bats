#!/usr/bin/env bats
# legion-fanout — parallel multi-model fan-out across executors (mock codex on PATH).

setup() {
  # Fanout's root-span tests must be independent of whichever Legion worker
  # launched Bats. Nested-span tests set their own context explicitly.
  unset LEGION_ACTIVE LEGION_EXECUTOR LEGION_DEPTH LEGION_RUN_ID
  unset LEGION_EXECUTOR_NAME LEGION_CROSS_HARNESS_HANDOFF
  unset LEGION_TRACE_ID LEGION_PARENT_ID
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  FANOUT="$ROOT/legion-orchestrate/bin/legion-fanout"
  export PATH="$ROOT/legion-router/bin:$ROOT/legion-observability/bin:$BATS_TEST_DIRNAME/mocks/bin:$PATH"     # mock `codex`
  # Pin the REAL delegate: tests/mocks/bin also carries a legion-delegate stub (for
  # legion-claude's fallback tests) that would otherwise shadow the real one here.
  export LEGION_DELEGATE="$ROOT/legion-router/bin/legion-delegate"
  export LEGION_TELEMETRY="$ROOT/legion-observability/bin/legion-trace"
  export LEGION_STATE_ROOT="$BATS_TEST_TMPDIR/state"
  export LEGION_TELEMETRY_DIR="$BATS_TEST_TMPDIR/spans"
  export LEGION_REGISTRY_DIR="$LEGION_STATE_ROOT/registry"
  export LEGION_REPOS_FILE="$LEGION_STATE_ROOT/repos.jsonl"
  # Do not inherit whichever harness happens to run Bats. These policy tests
  # model a Claude-primary fanout unless a test overrides it explicitly.
  export LEGION_PRIMARY=claude
  CODEX_WORKHORSE="$("$ROOT/legion-router/bin/legion-route" --model-ref codex_workhorse)"
  CLAUDE_REVIEW="$("$ROOT/legion-router/bin/legion-route" --model-ref claude_default)"
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO"
  git -C "$REPO" init -q
  git -C "$REPO" config user.email t@t.c
  git -C "$REPO" config user.name t
  printf 'a\n' > "$REPO/a.ts"
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=t@t.c -c user.name=t commit -qm init
}

file_mode() {
  local path="$1"
  if stat -f '%Lp' "$path" >/dev/null 2>&1; then
    stat -f '%Lp' "$path"
  else
    stat -c '%a' "$path"
  fi
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

@test "fanout: top-level same-family slices still launch scoped subagents" {
  export LEGION_PRIMARY=codex
  export MOCK_CALL_LOG="$BATS_TEST_TMPDIR/calls.log"
  printf '%s\n' '{"archetype":"implement-feature","task":"build A"}' > "$BATS_TEST_TMPDIR/caller.jsonl"

  run "$FANOUT" --slices "$BATS_TEST_TMPDIR/caller.jsonl" --repo "$REPO"

  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ok == 1 and .inline == 0 and .failed == 0'
  grep -qF "codex exec" "$MOCK_CALL_LOG"
}

@test "fanout: delegated executor context returns nested routes inline" {
  export LEGION_PRIMARY=codex
  export LEGION_ACTIVE=1
  export LEGION_EXECUTOR=1
  export LEGION_DEPTH=1
  export MOCK_CALL_LOG="$BATS_TEST_TMPDIR/nested-calls.log"
  printf '%s\n' '{"archetype":"implement-feature","task":"build directly"}' > "$BATS_TEST_TMPDIR/nested.jsonl"

  run "$FANOUT" --slices "$BATS_TEST_TMPDIR/nested.jsonl" --repo "$REPO"

  [ "$status" -eq 0 ]
  echo "$output" | jq -e '
    .inline == 1 and .failed == 0
    and .results[0].route_reason == "delegated-context-route"
  '
  [ ! -s "$MOCK_CALL_LOG" ]
}

@test "fanout: routes final review slices to the configured Fable reviewer" {
  # A Codex-primary run may delegate its independent review to Claude/Fable.
  export LEGION_PRIMARY=codex
  printf '%s\n' '{"archetype":"final-review","task":"review the diff"}' > "$BATS_TEST_TMPDIR/r.jsonl"
  run "$FANOUT" --slices "$BATS_TEST_TMPDIR/r.jsonl" --repo "$REPO"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e --arg model "$CLAUDE_REVIEW" '.by_model[$model] == 1'
}

@test "fanout: stdin slices work" {
  run bash -c "printf '%s\n' '{\"archetype\":\"cheap-bulk\",\"task\":\"x\"}' | '$FANOUT' --slices - --repo '$REPO'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ok == 1 and .total_cost_usd >= 0'
}

@test "fanout: --task file expands demo slices and --json is accepted" {
  # Use a third harness so this expansion test exercises all three delegated
  # slices rather than caller-aware inline handling.
  export LEGION_PRIMARY=opencode
  printf 'Build a dispatch board with AI scheduling suggestions.\n' > "$BATS_TEST_TMPDIR/task.md"
  run "$FANOUT" --task "$BATS_TEST_TMPDIR/task.md" --repo "$REPO" --json --max-concurrency 1
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.slices == 3 and .ok == 3 and .failed == 0'
  # Demo expands to two workhorse slices + an independent Fable review slice; resolve the models
  # from config so this survives default-model swaps.
  echo "$output" | jq -e --arg w "$CODEX_WORKHORSE" --arg r "$CLAUDE_REVIEW" \
    '[.results[].model] == [$w, $w, $r]'
}

@test "fanout: missing --slices exits 2" {
  run "$FANOUT" --repo "$REPO"
  [ "$status" -eq 2 ]
}

@test "fanout: invalid DAG does not leave preallocated runs queued" {
  printf '%s\n' \
    '{"id":"a","depends_on":["b"],"archetype":"implement-feature","task":"build A"}' \
    '{"id":"b","depends_on":["a"],"archetype":"write-tests","task":"test A"}' \
    > "$BATS_TEST_TMPDIR/invalid-dag.jsonl"

  run "$FANOUT" --slices "$BATS_TEST_TMPDIR/invalid-dag.jsonl" --repo "$REPO"

  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "error" and .stage == "dag"'
  [ "$(find "$LEGION_REGISTRY_DIR" -maxdepth 1 -name '*.json' -type f 2>/dev/null | wc -l | tr -d ' ')" = "0" ]
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
  [ "$(file_mode "$LEGION_REGISTRY_DIR")" = "700" ]
  for f in "$LEGION_REGISTRY_DIR"/*.json; do
    [ "$(jq -r '.state_version >= 3' "$f")" = "true" ]
    [ "$(jq -r '.run_id | endswith("-s0") or endswith("-s1")' "$f")" = "true" ]
    [ "$(file_mode "$f")" = "600" ]
  done
  local ledger; ledger="$(echo "$output" | jq -r .task_ledger_path)"
  jq -e '
    .schema == "legion.task-ledger.v1"
    and .status == "completed"
    and (.source_base_sha | length == 40)
    and (.tasks | length == 2)
    and all(.tasks[];
      .state == "completed"
      and .result_status == "ok"
      and (.queued_at | length > 0)
      and (.started_at | length > 0)
      and (.completed_at | length > 0)
    )
  ' "$ledger"
}

@test "adapter state updates serialize versions and never regress terminal state" {
  local state_lib="$ROOT/legion-observability/scripts/lib/state.sh"
  local registry="$BATS_TEST_TMPDIR/concurrent-registry"
  local run_id="concurrent-adapter-state"
  mkdir -p "$registry"
  jq -cn --arg run "$run_id" '
    {schema:"legion.run-state.v1",run_id:$run,state_version:1,
     lifecycle:{phase:"queued",started_at:"",updated_at:"2026-07-31T10:25:17Z"}}
  ' > "$registry/$run_id.json"

  local i
  for ((i = 0; i < 12; i++)); do
    LEGION_REGISTRY_DIR="$registry" LEGION_TRACE_ID="trace" \
      bash -c 'source "$1"; legion_write_adapter_run_state running "$2" /repo /run /wt branch model workspace-write HEAD arch' \
        _ "$state_lib" "$run_id" &
  done
  wait

  jq -e '.state_version == 13 and .lifecycle.phase == "running"' \
    "$registry/$run_id.json"
  LEGION_REGISTRY_DIR="$registry" LEGION_TRACE_ID="trace" \
    bash -c 'source "$1"; legion_write_adapter_run_state ok "$2" /repo /run /wt branch model workspace-write HEAD arch' \
      _ "$state_lib" "$run_id"
  LEGION_REGISTRY_DIR="$registry" LEGION_TRACE_ID="trace" \
    bash -c 'source "$1"; legion_write_adapter_run_state running "$2" /repo /run /wt branch model workspace-write HEAD arch' \
      _ "$state_lib" "$run_id"
  LEGION_REGISTRY_DIR="$registry" LEGION_TRACE_ID="trace" \
    bash -c 'source "$1"; legion_write_adapter_run_state failed "$2" /repo /run /wt branch model workspace-write HEAD arch' \
      _ "$state_lib" "$run_id"
  jq -e '.state_version == 14 and .lifecycle.phase == "ok"' \
    "$registry/$run_id.json"
}

@test "state lock keeps 40 contending Bash writers mutually exclusive" {
  local state_lib="$ROOT/legion-observability/scripts/lib/state.sh"
  local round root record completed guard overlap i

  for ((round = 0; round < 5; round++)); do
    root="$BATS_TEST_TMPDIR/lock-stress-$round"
    record="$root/state.json"
    completed="$root/completed"
    guard="$root/critical-section"
    overlap="$root/overlap"
    mkdir -p "$root"
    : > "$record"
    mkdir "$record.lock"
    printf '99999999\n' > "$record.lock/pid"

    for ((i = 0; i < 40; i++)); do
      bash -c '
        source "$1"
        lock="$(legion_acquire_run_state_lock "$2")" || exit 3
        if ! mkdir "$3" 2>/dev/null; then
          : > "$4"
        fi
        sleep 0.02
        rmdir "$3" 2>/dev/null || true
        printf "%s\n" "$5" >> "$6"
        legion_release_run_state_lock "$lock"
      ' _ "$state_lib" "$record" "$guard" "$overlap" "$i" "$completed" &
    done
    wait

    [ ! -e "$overlap" ]
    [ "$(wc -l < "$completed" | tr -d ' ')" = "40" ]
  done
}

@test "state lock recovery cannot delete a replacement owner generation" {
  local state_lib="$ROOT/legion-observability/scripts/lib/state.sh"
  local root="$BATS_TEST_TMPDIR/lock-recovery-race"
  local record="$root/state.json"
  local guard="$root/critical-section"
  local overlap="$root/overlap"
  local recovery_ready="$root/recovery-ready"
  local allow_dead="$root/allow-dead"
  local quarantined="$root/quarantined"
  local allow_cleanup="$root/allow-cleanup"
  local recovery_done="$root/recovery-done"
  local new_entered="$root/new-entered"
  local release_new="$root/release-new"
  local reclaimer_entered="$root/reclaimer-entered"
  local release_reclaimer="$root/release-reclaimer"
  local expected_owner=424242 reclaimer_pid new_pid held new_owner i
  mkdir -p "$root"
  : > "$record"
  mkdir "$record.lock"
  printf '%s\n' "$expected_owner" > "$record.lock/pid"

  EXPECT_OWNER="$expected_owner" LOCK_PATH="$record.lock" \
    RECOVERY_READY="$recovery_ready" ALLOW_DEAD="$allow_dead" \
    QUARANTINED="$quarantined" ALLOW_CLEANUP="$allow_cleanup" \
    RECOVERY_DONE="$recovery_done" RECLAIMER_ENTERED="$reclaimer_entered" \
    RELEASE_RECLAIMER="$release_reclaimer" \
    bash -c '
      kill() {
        if [[ "${1:-}" == "-0" && "${2:-}" == "$EXPECT_OWNER" ]]; then
          [[ -d "$LOCK_PATH/.claim" && ! -L "$LOCK_PATH/.claim" ]] || return 0
          : > "$RECOVERY_READY"
          while [[ ! -e "$ALLOW_DEAD" ]]; do sleep 0.005; done
          return 1
        fi
        builtin kill "$@"
      }
      mv() {
        command mv "$@" || return
        if [[ "${1:-}" == "$LOCK_PATH" ]]; then
          : > "$QUARANTINED"
          while [[ ! -e "$ALLOW_CLEANUP" ]]; do sleep 0.005; done
        fi
      }
      source "$1"
      legion_recover_dead_run_state_lock "$2.lock"
      : > "$RECOVERY_DONE"
      lock="$(legion_acquire_run_state_lock "$2")" || exit 3
      if ! mkdir "$3" 2>/dev/null; then : > "$4"; fi
      : > "$RECLAIMER_ENTERED"
      while [[ ! -e "$RELEASE_RECLAIMER" ]]; do sleep 0.005; done
      rmdir "$3" 2>/dev/null || true
      legion_release_run_state_lock "$lock"
    ' _ "$state_lib" "$record" "$guard" "$overlap" &
  reclaimer_pid=$!

  for ((i = 0; i < 1000; i++)); do
    [[ -e "$recovery_ready" ]] && break
    sleep 0.005
  done
  [ -e "$recovery_ready" ]
  [ -d "$record.lock/.claim" ]
  [ "$(cat "$record.lock/pid")" = "$expected_owner" ]
  : > "$allow_dead"

  for ((i = 0; i < 1000; i++)); do
    [[ -e "$quarantined" ]] && break
    sleep 0.005
  done
  [ -e "$quarantined" ]
  [ ! -e "$record.lock" ]
  held="$(find "$root" -maxdepth 2 -path '*/.legion-lock-reap.*/held' -type d -print -quit)"
  [ -n "$held" ]
  [ -d "$held/.claim" ]
  [ "$(cat "$held/pid")" = "$expected_owner" ]

  NEW_ENTERED="$new_entered" RELEASE_NEW="$release_new" \
    bash -c '
      source "$1"
      lock="$(legion_acquire_run_state_lock "$2")" || exit 3
      if ! mkdir "$3" 2>/dev/null; then : > "$4"; fi
      : > "$NEW_ENTERED"
      while [[ ! -e "$RELEASE_NEW" ]]; do sleep 0.005; done
      rmdir "$3" 2>/dev/null || true
      legion_release_run_state_lock "$lock"
    ' _ "$state_lib" "$record" "$guard" "$overlap" &
  new_pid=$!

  for ((i = 0; i < 200; i++)); do
    [[ -e "$new_entered" ]] && break
    sleep 0.005
  done
  [ -e "$new_entered" ]
  [ -d "$record.lock" ]
  [ -f "$record.lock/pid" ]
  new_owner="$(cat "$record.lock/pid")"
  [ "$new_owner" = "$new_pid" ]
  : > "$allow_cleanup"

  for ((i = 0; i < 1000; i++)); do
    [[ -e "$recovery_done" ]] && break
    sleep 0.005
  done
  [ -e "$recovery_done" ]
  [ ! -e "$held" ]
  [ -d "$record.lock" ]
  [ "$(cat "$record.lock/pid")" = "$new_owner" ]
  for ((i = 0; i < 100; i++)); do
    [[ -e "$reclaimer_entered" || -e "$overlap" ]] && break
    sleep 0.005
  done
  [ ! -e "$reclaimer_entered" ]
  [ ! -e "$overlap" ]

  : > "$release_new"
  wait "$new_pid"
  for ((i = 0; i < 1000; i++)); do
    [[ -e "$reclaimer_entered" ]] && break
    sleep 0.005
  done
  [ -e "$reclaimer_entered" ]
  : > "$release_reclaimer"
  wait "$reclaimer_pid"

  [ ! -e "$overlap" ]
  [ -z "$(find "$root" -maxdepth 1 -name '.legion-lock-reap.*' -print -quit)" ]
}

@test "state lock recovery fails closed on incomplete and symlinked locks" {
  local state_lib="$ROOT/legion-observability/scripts/lib/state.sh"
  local root="$BATS_TEST_TMPDIR/lock-fail-closed"
  local empty="$root/empty.json.lock"
  local invalid="$root/invalid.json.lock"
  local linked="$root/linked.json.lock"
  local claim_linked="$root/claim-linked.json.lock"
  local target="$root/target"
  mkdir -p "$empty" "$invalid" "$claim_linked" "$target"
  printf 'not-a-pid\n' > "$invalid/pid"
  printf '99999999\n' > "$claim_linked/pid"
  ln -s "$target" "$linked"
  ln -s "$target" "$claim_linked/.claim"
  source "$state_lib"

  legion_recover_dead_run_state_lock "$empty"
  legion_recover_dead_run_state_lock "$invalid"
  legion_recover_dead_run_state_lock "$claim_linked"
  if legion_acquire_run_state_lock "${linked%.lock}"; then
    false
  fi

  [ -d "$empty" ]
  [ ! -e "$empty/pid" ]
  [ "$(cat "$invalid/pid")" = "not-a-pid" ]
  [ -L "$linked" ]
  [ -L "$claim_linked/.claim" ]
  [ "$(cat "$claim_linked/pid")" = "99999999" ]
  [ -z "$(find "$root" -maxdepth 1 -name '.legion-lock-reap.*' -print -quit)" ]
}

@test "state lock contender retries a transient non-regular PID generation" {
  local state_lib="$ROOT/legion-observability/scripts/lib/state.sh"
  local root="$BATS_TEST_TMPDIR/lock-pid-turnover"
  local record="$root/state.json"
  local acquired="$root/acquired"
  local retrying="$root/retrying"
  local contender i
  mkdir -p "$record.lock"
  : > "$record"
  mkdir "$record.lock/pid"

  RETRYING="$retrying" bash -c '
    sleep() {
      [[ -e "$RETRYING" ]] || : > "$RETRYING"
      command sleep "$@"
    }
    source "$1"
    lock="$(legion_acquire_run_state_lock "$2")" || exit 3
    : > "$3"
    legion_release_run_state_lock "$lock"
  ' _ "$state_lib" "$record" "$acquired" &
  contender=$!

  # A malformed generation is never read. Once it disappears, the waiting
  # contender must remain eligible to acquire the next cooperative generation.
  for ((i = 0; i < 200; i++)); do
    [[ -e "$retrying" ]] && break
    sleep 0.005
  done
  if [[ ! -e "$retrying" ]]; then
    rmdir "$record.lock/pid"
    rmdir "$record.lock"
    wait "$contender" 2>/dev/null || true
    false
  fi
  rmdir "$record.lock/pid"
  rmdir "$record.lock"
  wait "$contender"

  [ -e "$acquired" ]
  [ ! -e "$record.lock" ]
}

@test "state lock acquisition enforces a wall-clock deadline" {
  local state_lib="$ROOT/legion-observability/scripts/lib/state.sh"
  local root="$BATS_TEST_TMPDIR/lock-deadline"
  local record="$root/state.json"
  local retries="$root/retries"
  mkdir -p "$record.lock"
  : > "$record"
  : > "$retries"
  printf '%s\n' "$$" > "$record.lock/pid"

  RETRIES="$retries" bash -c '
    sleep() {
      printf x >> "$RETRIES"
      SECONDS=$((SECONDS + 31))
    }
    source "$1"
    if legion_acquire_run_state_lock "$2"; then
      exit 4
    fi
  ' _ "$state_lib" "$record"

  [ "$(wc -c < "$retries" | tr -d ' ')" = "1" ]
  [ -d "$record.lock" ]
  [ "$(cat "$record.lock/pid")" = "$$" ]
}

@test "state lock PID metadata rejects symlinks and FIFOs without blocking" {
  local state_lib="$ROOT/legion-observability/scripts/lib/state.sh"
  local root="$BATS_TEST_TMPDIR/lock-pid-types"
  local recover_link="$root/recover-link.json.lock"
  local release_link="$root/release-link.json.lock"
  local recover_fifo="$root/recover-fifo.json.lock"
  local release_fifo="$root/release-fifo.json.lock"
  local dead_target="$root/dead-pid"
  local self_target="$root/self-pid"
  local operation lock done pid i blocked=0
  mkdir -p "$recover_link" "$release_link" "$recover_fifo" "$release_fifo"
  printf '99999999\n' > "$dead_target"
  printf '%s\n' "$$" > "$self_target"
  ln -s "$dead_target" "$recover_link/pid"
  ln -s "$self_target" "$release_link/pid"
  mkfifo "$recover_fifo/pid" "$release_fifo/pid"
  source "$state_lib"

  legion_recover_dead_run_state_lock "$recover_link"
  legion_release_run_state_lock "$release_link"

  for operation in legion_recover_dead_run_state_lock legion_release_run_state_lock; do
    if [[ "$operation" == "legion_recover_dead_run_state_lock" ]]; then
      lock="$recover_fifo"
    else
      lock="$release_fifo"
    fi
    done="$root/$operation.done"
    bash -c 'source "$1"; "$2" "$3"; : > "$4"' \
      _ "$state_lib" "$operation" "$lock" "$done" &
    pid=$!
    for ((i = 0; i < 200; i++)); do
      [[ -e "$done" ]] && break
      sleep 0.005
    done
    if [[ ! -e "$done" ]]; then
      blocked=1
      # Unblock a regressed reader so the failing test cannot leak a child cat.
      printf 'not-a-pid\n' > "$lock/pid"
    fi
    wait "$pid" 2>/dev/null || true
  done

  [ "$blocked" -eq 0 ]
  [ -d "$recover_link" ]
  [ -L "$recover_link/pid" ]
  [ -d "$release_link" ]
  [ -L "$release_link/pid" ]
  [ -d "$recover_fifo" ]
  [ -p "$recover_fifo/pid" ]
  [ -d "$release_fifo" ]
  [ -p "$release_fifo/pid" ]
}

@test "adapter state temp creation does not follow a predictable symlink" {
  local state_lib="$ROOT/legion-observability/scripts/lib/state.sh"
  local registry="$BATS_TEST_TMPDIR/symlink-registry"
  local victim="$BATS_TEST_TMPDIR/victim.json"
  local record="$registry/symlink-state.json"
  mkdir -p "$registry"
  printf 'do-not-overwrite\n' > "$victim"

  jq -cn \
    '{schema:"legion.run-state.v1",run_id:"symlink-state",state_version:1,
      lifecycle:{phase:"queued",started_at:"",updated_at:"old"}}' > "$record"
  ln -s "$victim" "$record.tmp.$$"
  export LEGION_REGISTRY_DIR="$registry" LEGION_TRACE_ID="trace"
  source "$state_lib"
  legion_write_adapter_run_state ok symlink-state \
    /repo /run /wt branch model workspace-write HEAD arch

  [ "$(cat "$victim")" = "do-not-overwrite" ]
  [ ! -L "$record" ]
  jq -e '.state_version == 2 and .lifecycle.phase == "ok"' \
    "$record"
}

@test "fanout: self/inline slices do NOT leave a queued record" {
  export LEGION_REGISTRY_DIR="$BATS_TEST_TMPDIR/registry"
  printf '%s\n' '{"archetype":"deep-reasoning","task":"decide design"}' > "$BATS_TEST_TMPDIR/s.jsonl"
  run "$FANOUT" --slices "$BATS_TEST_TMPDIR/s.jsonl" --repo "$REPO"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.inline == 1'
  [ "$(ls "$LEGION_REGISTRY_DIR"/*.json 2>/dev/null | wc -l | tr -d ' ')" = "0" ]
}

@test "fanout: interruption kills descendant process groups and cleans slices before terminalizing its ledger" {
  local bin="$BATS_TEST_TMPDIR/interrupt-bin"
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
run_id=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --run-id) run_id="$2"; shift 2 ;;
    *) shift ;;
  esac
done

worktree="$repo/.legion/worktrees/$run_id"
branch="legion/delegate-$run_id"
git -C "$repo" worktree add -q -b "$branch" "$worktree" HEAD
record="$LEGION_REGISTRY_DIR/$run_id.json"
jq --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
  .state_version = ((.state_version // 0) + 1)
  | .lifecycle.phase = "running"
  | .lifecycle.updated_at = $now
' "$record" > "$record.tmp.$$"
mv -f "$record.tmp.$$" "$record"
printf 'delegate %s\n' "$$" >> "$INTERRUPT_PIDS"

python3 - "$INTERRUPT_PIDS" "$INTERRUPT_WORKER_READY" "$INTERRUPT_LATE_READY" <<'PY' &
import os
import signal
import subprocess
import sys
import time

pids_path, ready_path, late_path = sys.argv[1:4]
os.setsid()
spawned = False

def append(kind, pid):
    with open(pids_path, "a", encoding="utf-8") as handle:
        handle.write(f"{kind} {pid}\n")
        handle.flush()

def spawn_late_child(_signum, _frame):
    global spawned
    if spawned:
        return
    spawned = True
    child = subprocess.Popen([
        sys.executable,
        "-c",
        (
            "import signal,time;"
            "signal.signal(signal.SIGTERM, signal.SIG_IGN);"
            "signal.signal(signal.SIGINT, signal.SIG_IGN);"
            "signal.signal(signal.SIGHUP, signal.SIG_IGN);"
            "time.sleep(60)"
        ),
    ])
    append("late", child.pid)
    with open(late_path, "w", encoding="utf-8") as handle:
        handle.write(str(child.pid))

signal.signal(signal.SIGTERM, spawn_late_child)
signal.signal(signal.SIGINT, spawn_late_child)
signal.signal(signal.SIGHUP, spawn_late_child)
append("leader", os.getpid())
with open(ready_path, "w", encoding="utf-8") as handle:
    handle.write(str(os.getpid()))
while True:
    time.sleep(1)
PY

while [[ ! -s "$INTERRUPT_WORKER_READY" ]]; do sleep 0.01; done
printf 'ready\n' > "$INTERRUPT_READY"
while :; do sleep 1; done
SH
  chmod +x "$bin"/*
  printf '%s\n' \
    '{"id":"slow","archetype":"implement-feature","task":"slow slice"}' \
    '{"id":"dependent","depends_on":["slow"],"archetype":"write-tests","task":"wait for slow"}' \
    > "$BATS_TEST_TMPDIR/interrupt.jsonl"
  local stdout="$BATS_TEST_TMPDIR/interrupt.out"
  export INTERRUPT_PIDS="$BATS_TEST_TMPDIR/interrupt.pids"
  export INTERRUPT_READY="$BATS_TEST_TMPDIR/interrupt.ready"
  export INTERRUPT_WORKER_READY="$BATS_TEST_TMPDIR/interrupt-worker.ready"
  export INTERRUPT_LATE_READY="$BATS_TEST_TMPDIR/interrupt-late.ready"
  export LEGION_REGISTRY_DIR="$BATS_TEST_TMPDIR/interrupt-registry"

  LEGION_ROUTE="$bin/legion-route" LEGION_DELEGATE="$bin/legion-delegate" \
    "$FANOUT" --slices "$BATS_TEST_TMPDIR/interrupt.jsonl" --repo "$REPO" \
    --keep > "$stdout" 2>&1 &
  local fanout_pid=$!
  local ledger=""
  for _ in {1..100}; do
    ledger="$(find "$REPO/.legion/fanout" -name task-ledger.json -print -quit 2>/dev/null || true)"
    [[ -n "$ledger" && -s "$INTERRUPT_READY" ]] && break
    sleep 0.02
  done
  [ -n "$ledger" ]
  [ -s "$INTERRUPT_READY" ]
  local slice_run_id
  slice_run_id="$(jq -r '.tasks[0].run_id' "$ledger")"
  local integration_branch
  integration_branch="legion/fanout-$(jq -r '.fanout_run_id' "$ledger")"
  [ -d "$REPO/.legion/worktrees/$slice_run_id" ]
  [ -d "$(dirname "$ledger")/integration" ]

  kill -TERM "$fanout_pid"
  for _ in {1..100}; do
    [[ -s "$INTERRUPT_LATE_READY" ]] && break
    sleep 0.02
  done
  local ledger_status_during_cleanup
  ledger_status_during_cleanup="$(jq -r '.status' "$ledger")"
  local fanout_rc=0
  wait "$fanout_pid" || fanout_rc=$?

  local process_leaked=0 pid
  while read -r _kind pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    if kill -0 "$pid" 2>/dev/null; then
      process_leaked=1
    fi
  done < "$INTERRUPT_PIDS"
  local slice_worktree_leaked=0 slice_branch_leaked=0
  local integration_worktree_leaked=0 integration_branch_leaked=0
  [ ! -d "$REPO/.legion/worktrees/$slice_run_id" ] || slice_worktree_leaked=1
  [ -z "$(git -C "$REPO" branch --list "legion/delegate-$slice_run_id")" ] || slice_branch_leaked=1
  [ ! -d "$(dirname "$ledger")/integration" ] || integration_worktree_leaked=1
  [ -z "$(git -C "$REPO" branch --list "$integration_branch")" ] || integration_branch_leaked=1

  # A failing implementation must not leak the fixture after this assertion
  # snapshot; remove anything it left behind before checking the expectations.
  while read -r _kind pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] && kill -KILL "$pid" 2>/dev/null || true
  done < "$INTERRUPT_PIDS"
  git -C "$REPO" worktree remove --force "$REPO/.legion/worktrees/$slice_run_id" >/dev/null 2>&1 || true
  git -C "$REPO" worktree remove --force "$(dirname "$ledger")/integration" >/dev/null 2>&1 || true
  git -C "$REPO" worktree prune >/dev/null 2>&1 || true
  git -C "$REPO" branch -D "legion/delegate-$slice_run_id" "$integration_branch" >/dev/null 2>&1 || true

  [ "$fanout_rc" -eq 143 ]
  [ -s "$INTERRUPT_LATE_READY" ]
  [ "$ledger_status_during_cleanup" = "running" ]
  [ "$process_leaked" -eq 0 ]
  [ "$slice_worktree_leaked" -eq 0 ]
  [ "$slice_branch_leaked" -eq 0 ]
  [ "$integration_worktree_leaked" -eq 0 ]
  [ "$integration_branch_leaked" -eq 0 ]
  jq -e '
    .status == "failed"
    and .tasks[0].state == "failed"
    and .tasks[0].result_status == "missing_terminal_result"
    and .tasks[1].state == "failed"
    and (.completed_at | length > 0)
  ' "$ledger"
  jq -s -e '
    length == 2
    and all(.[];
      .schema == "legion.run-state.v1"
      and .lifecycle.phase == "failed"
      and (.lifecycle.updated_at | length > 0)
    )
    and ([.[].state_version] | sort) == [2, 3]
  ' "$LEGION_REGISTRY_DIR"/*.json
  for f in "$LEGION_REGISTRY_DIR"/*.json; do
    [ "$(file_mode "$f")" = "600" ]
  done
  [ -z "$(find "$LEGION_REGISTRY_DIR" -name '*.tmp.*' -print -quit)" ]
}

@test "fanout: normal --keep still retains slice worktrees for inspection" {
  printf '%s\n' '{"archetype":"implement-feature","task":"build A"}' > "$BATS_TEST_TMPDIR/keep.jsonl"

  run "$FANOUT" --slices "$BATS_TEST_TMPDIR/keep.jsonl" --repo "$REPO" --keep

  [ "$status" -eq 0 ]
  local run_id
  run_id="$(echo "$output" | jq -r '.results[0].run_id')"
  [ -n "$run_id" ]
  [ -d "$REPO/.legion/worktrees/$run_id" ]
  [ -n "$(git -C "$REPO" branch --list "legion/delegate-$run_id")" ]

  "$LEGION_DELEGATE" cleanup --run "$run_id" --repo "$REPO" --quiet
}

@test "fanout: slice cleanup prunes the global worktree registry only once" {
  local bin="$BATS_TEST_TMPDIR/git-log-bin"
  local real_git
  real_git="$(command -v git)"
  mkdir -p "$bin"
  cat > "$bin/git" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'git %s\n' "$*" >> "$FANOUT_GIT_CALL_LOG"
exec "$FANOUT_REAL_GIT" "$@"
SH
  chmod +x "$bin/git"
  export FANOUT_REAL_GIT="$real_git"
  export FANOUT_GIT_CALL_LOG="$BATS_TEST_TMPDIR/git-calls.log"
  printf '%s\n' \
    '{"archetype":"implement-feature","task":"build A"}' \
    '{"archetype":"write-tests","task":"test A"}' \
    '{"archetype":"cheap-bulk","task":"document A"}' \
    > "$BATS_TEST_TMPDIR/prune-once.jsonl"

  PATH="$bin:$PATH" run "$FANOUT" \
    --slices "$BATS_TEST_TMPDIR/prune-once.jsonl" --repo "$REPO"

  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ok == 3 and .failed == 0'
  [ "$(grep -cE '^git -C .+ worktree prune$' "$FANOUT_GIT_CALL_LOG")" -eq 1 ]
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
  ledger="$(echo "$output" | jq -r .task_ledger_path)"
  jq -e '
    all(.tasks[]; (.base_ref | length) == 40)
    and (.tasks[0].apply_status == "applied")
    and (.tasks[1].apply_status == "no_changes")
  ' "$ledger"
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
