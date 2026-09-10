#!/usr/bin/env bats

load 'helpers/setup'

setup() {
  setup_test_env
  export LEGION_STATE_ROOT="$TEST_TMPDIR/state"
  export LEGION_TELEMETRY_DIR="$TEST_TMPDIR/spans"
  export LEGION_REGISTRY_DIR="$LEGION_STATE_ROOT/registry"
  export DELEGATE="$REPO_ROOT/legion-router/bin/legion-delegate"
  export CODEX_MODEL="$($REPO_ROOT/legion-router/bin/legion-route --model-ref codex_workhorse)"
}

make_repo() {
  local repo="$TEST_TMPDIR/repo-$1"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name test
  printf 'base\n' > "$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -qm init
  printf '%s' "$repo"
}

install_signal_cleanup_failed_python() {
  local shim="$TEST_TMPDIR/python-shim" real_python
  real_python="$(command -v python3)"
  mkdir -p "$shim"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ "${1:-}" == */legion-process-supervisor.py ]]; then' \
    '  status_file=""' \
    '  while [[ $# -gt 0 ]]; do' \
    '    if [[ "$1" == --status-file ]]; then status_file="$2"; break; fi' \
    '    shift' \
    '  done' \
    "  trap 'printf \"%s\\n\" \"{\\\"schema\\\":\\\"legion.child-execution-lease.v1\\\",\\\"status\\\":\\\"cleanup_failed\\\",\\\"reason\\\":\\\"codex signal cleanup failed\\\",\\\"max_runtime_seconds\\\":30}\" > \"\$status_file\"; exit 70' TERM" \
    '  : > "$LEGION_TEST_SUPERVISOR_STARTED"' \
    '  while true; do sleep 1; done' \
    'fi' \
    'exec "$LEGION_TEST_REAL_PYTHON" "$@"' > "$shim/python3"
  chmod +x "$shim/python3"
  export LEGION_TEST_REAL_PYTHON="$real_python"
  export PATH="$shim:$PATH"
}

wait_for_supervisor() {
  local pid="$1"
  for _ in $(seq 1 200); do
    [[ -f "$LEGION_TEST_SUPERVISOR_STARTED" ]] && return 0
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.05
  done
  return 1
}

assert_internal_attempt() {
  local attempt="$1"
  jq -e '.terminal_status == "failed" and .failure.class == "internal"
    and (.failure.message | contains("codex signal cleanup failed"))' "$attempt"
  [ "$(find "$(dirname "$attempt")" -maxdepth 1 -name 'attempt-*.json' \
    ! -name '*.lease.json' | wc -l | tr -d ' ')" -eq 1 ]
  [ "$(find "$(dirname "$attempt")" -maxdepth 1 -name 'failure-*.json' | wc -l | tr -d ' ')" -eq 1 ]
}

@test "native Codex run lets cleanup failure override signal cancellation" {
  local repo pid rc=0 art
  repo="$(make_repo run)"
  install_signal_cleanup_failed_python
  export LEGION_TEST_SUPERVISOR_STARTED="$TEST_TMPDIR/run-started"
  "$DELEGATE" run --executor codex --model "$CODEX_MODEL" --task wait --repo "$repo" \
    --run-id codex-signal-run --keep --quiet >"$TEST_TMPDIR/run.out" 2>"$TEST_TMPDIR/run.err" &
  pid=$!
  wait_for_supervisor "$pid"
  kill -TERM "$pid"
  wait "$pid" || rc=$?
  [ "$rc" -eq 70 ]
  art="$repo/.legion/runs/codex-signal-run"
  assert_internal_attempt "$art/attempt-1.json"
  jq -e '.lifecycle.phase == "containment_failed"' "$LEGION_REGISTRY_DIR/codex-signal-run.json"
  [ -d "$repo/.legion/worktrees/codex-signal-run" ]
}

@test "native Codex review lets cleanup failure override signal cancellation" {
  local repo pid rc=0 art receipt
  repo="$(make_repo review)"
  install_signal_cleanup_failed_python
  export LEGION_TEST_SUPERVISOR_STARTED="$TEST_TMPDIR/review-started"
  "$DELEGATE" review --model "$CODEX_MODEL" --base HEAD --repo "$repo" \
    --max-attempts 1 --quiet >"$TEST_TMPDIR/review.out" 2>"$TEST_TMPDIR/review.err" &
  pid=$!
  wait_for_supervisor "$pid"
  kill -TERM "$pid"
  wait "$pid" || rc=$?
  [ "$rc" -eq 70 ]
  receipt="$(find "$repo/.legion/runs" -name terminal.json -print -quit)"
  art="$(dirname "$receipt")"
  jq -e '.status == "containment_failed" and .codex_exit == 70
    and (.reason | contains("codex signal cleanup failed"))' "$receipt"
  assert_internal_attempt "$art/attempt-1.json"
  [ -d "$(jq -r '.worktree' "$art/status.json")" ]
}

@test "native Codex resume lets cleanup failure override signal cancellation" {
  local repo seed run_id pid rc=0 art
  repo="$(make_repo resume)"
  run "$DELEGATE" run --executor codex --model "$CODEX_MODEL" --task seed --repo "$repo" \
    --keep --quiet
  [ "$status" -eq 0 ]
  seed="$output"
  run_id="$(jq -r .run_id <<<"$seed")"
  art="$repo/.legion/runs/$run_id"
  install_signal_cleanup_failed_python
  export LEGION_TEST_SUPERVISOR_STARTED="$TEST_TMPDIR/resume-started"
  "$DELEGATE" resume --run "$run_id" --task wait --repo "$repo" --quiet \
    >"$TEST_TMPDIR/resume.out" 2>"$TEST_TMPDIR/resume.err" &
  pid=$!
  wait_for_supervisor "$pid"
  kill -TERM "$pid"
  wait "$pid" || rc=$?
  [ "$rc" -eq 70 ]
  assert_internal_attempt "$art/resume-1/attempt-1.json"
  jq -e '.status == "failed" and .result_status == "containment_failed"' "$art/status.json"
  [ -d "$repo/.legion/worktrees/$run_id" ]
}
