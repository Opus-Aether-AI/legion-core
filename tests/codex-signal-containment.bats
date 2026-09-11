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

install_mock_sandcastle_node() {
  local shim="$TEST_TMPDIR/sandcastle-node" real_node
  real_node="$(command -v node)"
  mkdir -p "$shim"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ "${1:-}" == */sandcastle-run.mjs ]]; then' \
    '  cat >/dev/null' \
    '  [[ -z "${MOCK_SANDCASTLE_PID_FILE:-}" ]] || printf "%s\n" "$$" > "$MOCK_SANDCASTLE_PID_FILE"' \
    '  [[ -z "${MOCK_SANDCASTLE_DELAY:-}" ]] || sleep "$MOCK_SANDCASTLE_DELAY"' \
    '  printf "%s\n" '\''{"status":"ok","sandbox":"docker","branch":"HEAD","diff_path":null,"usage":{"input_tokens":4,"output_tokens":2,"cached_input_tokens":0,"reasoning_output_tokens":0}}'\''' \
    '  exit 0' \
    'fi' \
    'exec "$LEGION_TEST_REAL_NODE" "$@"' > "$shim/node"
  chmod +x "$shim/node"
  export LEGION_TEST_REAL_NODE="$real_node"
  export PATH="$shim:$PATH"
}

install_mock_sandcastle_provider_node() {
  local shim="$TEST_TMPDIR/sandcastle-provider-node" real_node
  real_node="$(command -v node)"
  mkdir -p "$shim"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ "${1:-}" == */sandcastle-run.mjs ]]; then' \
    '  cat >/dev/null' \
    '  codex exec --json -m fixture-model -s workspace-write --skip-git-repo-check - >/dev/null' \
    '  provider_rc=$?' \
    '  [[ "$provider_rc" -eq 0 ]] || exit "$provider_rc"' \
    '  printf "%s\n" '\''{"status":"ok","sandbox":"docker","branch":"HEAD","diff_path":null,"usage":{"input_tokens":4,"output_tokens":2,"cached_input_tokens":0,"reasoning_output_tokens":0}}'\''' \
    '  exit 0' \
    'fi' \
    'exec "$LEGION_TEST_REAL_NODE" "$@"' > "$shim/node"
  chmod +x "$shim/node"
  export LEGION_TEST_REAL_NODE="$real_node"
  export PATH="$shim:$PATH"
}

install_sandcastle_pending_python() {
  local shim="$TEST_TMPDIR/sandcastle-pending-python" real_python
  real_python="$(command -v python3)"
  mkdir -p "$shim"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ "${1:-}" == */sandcastle-provider-bin/provider-launch.py ]]; then' \
    '  marker="$2"; token="$3"' \
    '  if [[ "${MOCK_SANDCASTLE_MARKER_STATE:-pending}" == malformed ]]; then' \
    '    printf "%s\n" "{malformed" > "$marker"' \
    '  else' \
    '    jq -cn --arg token "$token" --arg status "${MOCK_SANDCASTLE_MARKER_STATE:-pending}" '\''{schema:"legion.sandcastle-provider-launch.v1",token:$token,status:$status}'\'' > "$marker"' \
    '  fi' \
    '  : > "$LEGION_TEST_PROVIDER_MARKER_READY"' \
    '  sleep 30' \
    '  exit 143' \
    'fi' \
    'exec "$LEGION_TEST_REAL_PYTHON" "$@"' > "$shim/python3"
  chmod +x "$shim/python3"
  export LEGION_TEST_REAL_PYTHON="$real_python"
  export PATH="$shim:$PATH"
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

@test "prompt review forwards TERM to adapter and preserves its canonical receipts" {
  local repo pid rc=0 provider_pid art attempt lease
  repo="$(make_repo prompt-signal)"
  export MOCK_CURSOR_DELAY=30
  export MOCK_CURSOR_DELAY_PID_FILE="$TEST_TMPDIR/cursor-provider.pid"

  CODEX_BIN=missing-codex-for-review \
    "$DELEGATE" review --base HEAD --repo "$repo" --quiet \
      >"$TEST_TMPDIR/prompt.out" 2>"$TEST_TMPDIR/prompt.err" &
  pid=$!
  for _ in $(seq 1 200); do
    [[ -s "$MOCK_CURSOR_DELAY_PID_FILE" ]] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.05
  done
  [ -s "$MOCK_CURSOR_DELAY_PID_FILE" ]
  provider_pid="$(cat "$MOCK_CURSOR_DELAY_PID_FILE")"
  kill -TERM "$pid"
  wait "$pid" || rc=$?

  [ "$rc" -eq 143 ]
  ! kill -0 "$provider_pid" 2>/dev/null
  art="$(find "$repo/.legion/runs" -mindepth 1 -maxdepth 1 -type d -print -quit)"
  attempt="$(find "$art" -path '*/prompt-review-*/attempt.json' -print -quit)"
  lease="$(find "$art" -path '*/prompt-review-*/lease.json' -print -quit)"
  [ -f "$attempt" ]
  [ -f "$lease" ]
  jq -e '.executor == "cursor" and .provider == "cursor"
    and .terminal_status == "cancelled" and .failure.class == "cancelled"' "$attempt"
  [ "$(find "$art" -path '*/prompt-review-*/attempt.json' | wc -l | tr -d ' ')" -eq 1 ]
  [ "$(find "$art" -path '*/prompt-review-*/failure.json' | wc -l | tr -d ' ')" -eq 1 ]
  jq -e '.schema == "legion.child-execution-lease.v1"' "$lease"
  jq -e '.status == "failed" and .codex_exit == 143 and .executor == "cursor-review"' \
    "$art/terminal.json"
  local signal_span
  signal_span="$(cat "$LEGION_TELEMETRY_DIR"/*.jsonl | jq -c 'select(.executor == "cursor-review")')"
  jq -e --arg model "$(jq -r '.effective_model // .requested_model' "$attempt")" '.model == $model
    and .cost_usd == null and .cost_status == "not_applicable"
    and .tokens == null and .usage_status == "not_applicable"
    and .artifacts.rollup_only == true
    and .artifacts.metering_reconciliation.attempt_count == 1' <<<"$signal_span" || {
      printf 'attempt=%s\npreflight=%s\nlease=%s\nspan=%s\n' \
        "$(cat "$attempt")" "$(cat "$(dirname "$attempt")/preflight.json")" \
        "$(cat "$lease")" "$signal_span"
      false
    }
}

@test "Sandcastle success envelope is a successful tracked attempt" {
  local repo attempt span
  repo="$(make_repo sandcastle-success)"
  install_mock_sandcastle_node

  run "$DELEGATE" run --model "$CODEX_MODEL" --sandbox docker --task work \
    --repo "$repo" --keep --quiet

  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "ok"'
  attempt="$(echo "$output" | jq -r .attempt_receipt)"
  jq -e '.terminal_status == "succeeded" and .failure == null
    and .usage_status == "known"' "$attempt"
  span="$(cat "$LEGION_TELEMETRY_DIR"/*.jsonl | jq -c '
    select(.executor == "codex" and .artifacts.provider_attempt == true)
  ')"
  jq -e --argjson attempt "$(cat "$attempt")" '
    .tokens == $attempt.usage and .usage_status == $attempt.usage_status
    and .cost_usd == $attempt.cost_usd and .cost_status == $attempt.cost_status
  ' <<<"$span"
}

@test "Sandcastle TERM before authenticated provider start emits no paid attempt" {
  local repo pid rc=0 child_pid art
  repo="$(make_repo sandcastle-signal)"
  install_mock_sandcastle_node
  export MOCK_SANDCASTLE_DELAY=30
  export MOCK_SANDCASTLE_PID_FILE="$TEST_TMPDIR/sandcastle.pid"

  "$DELEGATE" run --model "$CODEX_MODEL" --sandbox docker --task wait \
    --repo "$repo" --run-id sandcastle-signal --keep --quiet \
    >"$TEST_TMPDIR/sandcastle.out" 2>"$TEST_TMPDIR/sandcastle.err" &
  pid=$!
  for _ in $(seq 1 200); do
    [[ -s "$MOCK_SANDCASTLE_PID_FILE" ]] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.05
  done
  [ -s "$MOCK_SANDCASTLE_PID_FILE" ]
  child_pid="$(cat "$MOCK_SANDCASTLE_PID_FILE")"
  kill -TERM "$pid"
  wait "$pid" || rc=$?

  [ "$rc" -eq 143 ]
  ! kill -0 "$child_pid" 2>/dev/null
  art="$repo/.legion/runs/sandcastle-signal"
  [ ! -e "$art/sandcastle-provider-launched" ]
  [ "$(find "$art" -maxdepth 1 -name 'attempt-*.json' ! -name '*.lease.json' | wc -l | tr -d ' ')" -eq 0 ]
  [ "$(find "$art" -maxdepth 1 -name 'failure-*.json' | wc -l | tr -d ' ')" -eq 0 ]
  [ "$(cat "$LEGION_TELEMETRY_DIR"/*.jsonl | jq -s '[.[] | select(.artifacts.provider_attempt == true)] | length')" -eq 0 ]
}

@test "Sandcastle TERM after authenticated provider start emits one paid attempt" {
  local repo pid rc=0 provider_pid art marker
  repo="$(make_repo sandcastle-provider-signal)"
  install_mock_sandcastle_provider_node
  export MOCK_CODEX_DELAY=30
  export MOCK_CODEX_DELAY_PID_FILE="$TEST_TMPDIR/sandcastle-provider.pid"

  "$DELEGATE" run --model "$CODEX_MODEL" --sandbox docker --task wait \
    --repo "$repo" --run-id sandcastle-provider-signal --keep --quiet \
    >"$TEST_TMPDIR/sandcastle-provider.out" 2>"$TEST_TMPDIR/sandcastle-provider.err" &
  pid=$!
  marker="$repo/.legion/runs/sandcastle-provider-signal/sandcastle-provider-launched"
  for _ in $(seq 1 200); do
    jq -e '.schema == "legion.sandcastle-provider-launch.v1" and .status == "started"' \
      "$marker" >/dev/null 2>&1 && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.05
  done
  jq -e '.schema == "legion.sandcastle-provider-launch.v1" and .status == "started"
    and (.token | type == "string" and length == 48) and .provider_pid > 0' "$marker"
  provider_pid="$(cat "$MOCK_CODEX_DELAY_PID_FILE")"
  kill -TERM "$pid"
  wait "$pid" || rc=$?

  [ "$rc" -eq 143 ]
  ! kill -0 "$provider_pid" 2>/dev/null
  art="$repo/.legion/runs/sandcastle-provider-signal"
  jq -e '.executor == "codex" and .terminal_status == "cancelled"' "$art/attempt-1.json"
  [ "$(find "$art" -maxdepth 1 -name 'attempt-*.json' ! -name '*.lease.json' | wc -l | tr -d ' ')" -eq 1 ]
  [ "$(cat "$LEGION_TELEMETRY_DIR"/*.jsonl | jq -s '[.[] | select(.artifacts.provider_attempt == true)] | length')" -eq 1 ]
}

@test "Sandcastle authenticated not-started marker remains no-launch on TERM" {
  local repo pid rc=0 art
  repo="$(make_repo sandcastle-not-started-signal)"
  install_mock_sandcastle_provider_node
  install_sandcastle_pending_python
  export MOCK_SANDCASTLE_MARKER_STATE=not-started
  export LEGION_TEST_PROVIDER_MARKER_READY="$TEST_TMPDIR/not-started-ready"

  "$DELEGATE" run --model "$CODEX_MODEL" --sandbox docker --task wait \
    --repo "$repo" --run-id sandcastle-not-started-signal --keep --quiet \
    >"$TEST_TMPDIR/not-started.out" 2>"$TEST_TMPDIR/not-started.err" &
  pid=$!
  for _ in $(seq 1 200); do
    [[ -e "$LEGION_TEST_PROVIDER_MARKER_READY" ]] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.05
  done
  [ -e "$LEGION_TEST_PROVIDER_MARKER_READY" ]
  kill -TERM "$pid"
  wait "$pid" || rc=$?

  [ "$rc" -eq 143 ]
  art="$repo/.legion/runs/sandcastle-not-started-signal"
  jq -e '.schema == "legion.sandcastle-provider-launch.v1" and .status == "not-started"' \
    "$art/sandcastle-provider-launched"
  [ "$(find "$art" -maxdepth 1 -name 'attempt-*.json' ! -name '*.lease.json' | wc -l | tr -d ' ')" -eq 0 ]
  [ "$(cat "$LEGION_TELEMETRY_DIR"/*.jsonl | jq -s '[.[] | select(.artifacts.provider_attempt == true)] | length')" -eq 0 ]
}

@test "Sandcastle unresolved or malformed launch evidence fails containment closed" {
  local state repo pid rc art
  install_mock_sandcastle_provider_node
  install_sandcastle_pending_python
  for state in pending malformed; do
    repo="$(make_repo "sandcastle-$state-signal")"
    export MOCK_SANDCASTLE_MARKER_STATE="$state"
    export LEGION_TEST_PROVIDER_MARKER_READY="$TEST_TMPDIR/$state-ready"
    "$DELEGATE" run --model "$CODEX_MODEL" --sandbox docker --task wait \
      --repo "$repo" --run-id "sandcastle-$state-signal" --keep --quiet \
      >"$TEST_TMPDIR/$state.out" 2>"$TEST_TMPDIR/$state.err" &
    pid=$!
    for _ in $(seq 1 200); do
      [[ -e "$LEGION_TEST_PROVIDER_MARKER_READY" ]] && break
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.05
    done
    [ -e "$LEGION_TEST_PROVIDER_MARKER_READY" ]
    kill -TERM "$pid"
    rc=0
    wait "$pid" || rc=$?

    [ "$rc" -eq 70 ]
    art="$repo/.legion/runs/sandcastle-$state-signal"
    [ "$(find "$art" -maxdepth 1 -name 'attempt-*.json' ! -name '*.lease.json' | wc -l | tr -d ' ')" -eq 0 ]
    [ "$(cat "$LEGION_TELEMETRY_DIR"/*.jsonl | jq -s '[.[] | select(.artifacts.provider_attempt == true)] | length')" -eq 0 ]
    jq -e '.lifecycle.phase == "containment_failed"' \
      "$LEGION_REGISTRY_DIR/sandcastle-$state-signal.json"
    [ -d "$repo/.legion/worktrees/sandcastle-$state-signal" ]
  done
}
