#!/usr/bin/env bats

load 'helpers/setup'

setup() {
  setup_test_env
  export LEGION_STATE_ROOT="$TEST_TMPDIR/state"
  export LEGION_TELEMETRY_DIR="$TEST_TMPDIR/spans"
  export LEGION_REGISTRY_DIR="$LEGION_STATE_ROOT/registry"
}

make_test_repo() {
  local repo="$TEST_TMPDIR/repo-$1"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@t.c
  git -C "$repo" config user.name t
  printf 'base\n' > "$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -qm init
  printf '%s' "$repo"
}

install_cleanup_failed_python() {
  local shim_dir="$TEST_TMPDIR/python-shim" real_python
  real_python="$(command -v python3)"
  mkdir -p "$shim_dir"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ "${1:-}" == */legion-process-supervisor.py ]]; then' \
    '  status_file=""' \
    '  while [[ $# -gt 0 ]]; do' \
    '    if [[ "$1" == --status-file ]]; then status_file="$2"; break; fi' \
    '    shift' \
    '  done' \
    '  printf '\''%s\n'\'' '\''{"schema":"legion.child-execution-lease.v1","status":"cleanup_failed","reason":"forced cleanup evidence","max_runtime_seconds":30}'\'' > "$status_file"' \
    '  exit 70' \
    'fi' \
    'exec "$LEGION_TEST_REAL_PYTHON" "$@"' > "$shim_dir/python3"
  chmod +x "$shim_dir/python3"
  export LEGION_TEST_REAL_PYTHON="$real_python"
  export PATH="$shim_dir:$PATH"
}

install_signal_cleanup_failed_python() {
  local shim_dir="$TEST_TMPDIR/signal-python-shim" real_python
  real_python="$(command -v python3)"
  mkdir -p "$shim_dir"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ "${1:-}" == */legion-process-supervisor.py ]]; then' \
    '  status_file=""' \
    '  while [[ $# -gt 0 ]]; do' \
    '    if [[ "$1" == --status-file ]]; then status_file="$2"; break; fi' \
    '    shift' \
    '  done' \
    "  trap 'printf \"%s\\n\" \"{\\\"schema\\\":\\\"legion.child-execution-lease.v1\\\",\\\"status\\\":\\\"cleanup_failed\\\",\\\"reason\\\":\\\"signal drain failed\\\",\\\"max_runtime_seconds\\\":30}\" > \"\$status_file\"; exit 70' TERM" \
    '  : > "$LEGION_TEST_SUPERVISOR_STARTED"' \
    '  while true; do sleep 1; done' \
    'fi' \
    'exec "$LEGION_TEST_REAL_PYTHON" "$@"' > "$shim_dir/python3"
  chmod +x "$shim_dir/python3"
  export LEGION_TEST_REAL_PYTHON="$real_python"
  export PATH="$shim_dir:$PATH"
}

assert_signal_receipt() {
  local adapter="$1" marker="$2" delay_name="$3" run_id="signal-$adapter"
  local repo out err pid rc=0 art
  repo="$(make_test_repo "$adapter")"
  out="$TEST_TMPDIR/$adapter.out"
  err="$TEST_TMPDIR/$adapter.err"
  art="$repo/.legion/runs/$run_id"

  env "$delay_name=30" PI_BIN=pi HERMES_BIN=hermes \
    "$REPO_ROOT/legion-router/bin/legion-$adapter" run --task wait --repo "$repo" \
      --run-id "$run_id" --keep --quiet >"$out" 2>"$err" &
  pid=$!
  for _ in $(seq 1 200); do
    grep -q "$marker" "$MOCK_CALL_LOG" 2>/dev/null && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.05
  done
  grep -q "$marker" "$MOCK_CALL_LOG"
  kill -TERM "$pid"
  wait "$pid" || rc=$?
  [ "$rc" -eq 143 ]
  [ "$(find "$art" -name 'attempt-*.json' | wc -l | tr -d ' ')" -eq 1 ]
  [ "$(find "$art" -name 'failure-*.json' | wc -l | tr -d ' ')" -eq 1 ]
  jq -e '.terminal_status == "cancelled" and .failure.class == "cancelled"' \
    "$art/attempt-1.json"
  jq -e '.class == "cancelled" and .retryable == false' "$art/failure-1.json"
}

@test "Claude writes one terminal attempt when signalled after launch" {
  assert_signal_receipt claude 'claude -p' MOCK_CLAUDE_DELAY
}

@test "Cursor writes one terminal attempt when signalled after launch" {
  assert_signal_receipt cursor 'agent -p' MOCK_CURSOR_DELAY
}

@test "OpenCode writes one terminal attempt when signalled after launch" {
  MOCK_OPENCODE_ERROR_EVENT=1 assert_signal_receipt opencode 'opencode run' MOCK_OPENCODE_ERROR_DELAY
}

@test "DeepSeek writes one terminal attempt when signalled after launch" {
  assert_signal_receipt deepseek 'dsh --profile' MOCK_DSH_DELAY
}

@test "Pi writes one terminal attempt when signalled after launch" {
  assert_signal_receipt pi 'pi -p' MOCK_PI_DELAY
}

@test "Hermes writes one terminal attempt when signalled after launch" {
  assert_signal_receipt hermes 'hermes --oneshot' MOCK_HERMES_DELAY
}

@test "Hermes attempt receipt preserves estimated-cost provenance" {
  local repo output_json attempt
  repo="$(make_test_repo hermes-provenance)"
  run env HERMES_BIN=hermes "$REPO_ROOT/legion-router/bin/legion-hermes" run \
    --model openai/fixture-hermes --task edit --repo "$repo" --quiet
  [ "$status" -eq 0 ]
  output_json="$output"
  attempt="$(jq -r '.attempt_receipt' <<<"$output_json")"
  jq -e '
    .cost_usd == 0.002 and .cost_status == "known"
    and .cost_source == "hermes-usage-file:estimated:official_docs_snapshot"
  ' "$attempt"
}

@test "cleanup-failed sidecars retain their distinct supervisor reason" {
  local receipt="$TEST_TMPDIR/cleanup.json"
  printf '%s\n' '{"schema":"legion.child-execution-lease.v1","status":"cleanup_failed","reason":"descendant cleanup was incomplete","max_runtime_seconds":30}' > "$receipt"
  run bash -c 'source "$1"; legion_adapter_supervisor_cleanup_failed "$2"; legion_adapter_supervisor_reason "$2"' \
    _ "$REPO_ROOT/legion-router/scripts/lib/adapter-contract.sh" "$receipt"
  [ "$status" -eq 0 ]
  [ "$output" = "descendant cleanup was incomplete" ]
}

@test "every direct adapter retains cleanup-failed evidence and worktree" {
  local adapter repo run_id result_file attempt worktree
  install_cleanup_failed_python
  for adapter in claude cursor opencode deepseek pi hermes; do
    repo="$(make_test_repo "cleanup-$adapter")"
    run_id="cleanup-$adapter"
    result_file="$TEST_TMPDIR/$adapter-cleanup.out"
    local -a extra_args=()
    [[ "$adapter" != claude ]] || extra_args+=(--no-fallback)
    PI_BIN=pi HERMES_BIN=hermes \
      "$REPO_ROOT/legion-router/bin/legion-$adapter" run --task wait --repo "$repo" \
        --run-id "$run_id" --quiet "${extra_args[@]}" > "$result_file" 2>/dev/null || true
    jq -e '.status == "containment_failed" and ((.result // .reason) | contains("forced cleanup evidence"))' \
      "$result_file" || { printf 'adapter=%s output=%s\n' "$adapter" "$(cat "$result_file")" >&2; return 1; }
    attempt="$(jq -r '.attempt_receipt' "$result_file")"
    jq -e '.terminal_status == "failed" and .failure.class == "internal"' "$attempt"
    worktree="$(jq -r '.worktree' "$result_file")"
    [ -d "$worktree" ]
    jq -e '.status == "cleanup_failed"' "$(jq -r '.lease_receipt' "$result_file")"
  done
}

@test "every native adapter lets signal cleanup failure override cancellation" {
  local adapter repo run_id result_file pid rc art lease
  install_signal_cleanup_failed_python
  for adapter in claude cursor opencode deepseek pi hermes; do
    repo="$(make_test_repo "signal-cleanup-$adapter")"
    run_id="signal-cleanup-$adapter"
    result_file="$TEST_TMPDIR/$adapter-signal-cleanup.out"
    export LEGION_TEST_SUPERVISOR_STARTED="$TEST_TMPDIR/$adapter-supervisor-started"
    local -a extra_args=()
    [[ "$adapter" != claude ]] || extra_args+=(--no-fallback)
    PI_BIN=pi HERMES_BIN=hermes \
      "$REPO_ROOT/legion-router/bin/legion-$adapter" run --task wait --repo "$repo" \
        --run-id "$run_id" --quiet "${extra_args[@]}" > "$result_file" 2>/dev/null &
    pid=$!
    for _ in $(seq 1 200); do
      [[ -f "$LEGION_TEST_SUPERVISOR_STARTED" ]] && break
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.05
    done
    [ -f "$LEGION_TEST_SUPERVISOR_STARTED" ]
    kill -TERM "$pid"
    rc=0; wait "$pid" || rc=$?
    [ "$rc" -eq 70 ]
    art="$repo/.legion/runs/$run_id"
    lease="$(find "$art" -maxdepth 1 -name 'lease*.json' -print -quit)"
    [ -n "$lease" ]
    jq -e '.status == "cleanup_failed" and (.reason | contains("signal drain failed"))' "$lease"
    jq -e '.terminal_status == "failed" and .failure.class == "internal"
      and (.failure.message | contains("worktree retained"))' "$art/attempt-1.json"
    [ "$(find "$art" -maxdepth 1 -name 'attempt-*.json' | wc -l | tr -d ' ')" -eq 1 ]
    [ "$(find "$art" -maxdepth 1 -name 'failure-*.json' | wc -l | tr -d ' ')" -eq 1 ]
    jq -e '.lifecycle.phase == "containment_failed"' "$LEGION_REGISTRY_DIR/$run_id.json"
    [ -d "$repo/.legion/worktrees/$run_id" ]
  done
}
