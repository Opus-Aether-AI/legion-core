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
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name test
  printf 'base\n' > "$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -qm init
  printf '%s' "$repo"
}

install_launch_failed_python() {
  local shim_dir="$TEST_TMPDIR/launch-failed-python" real_python
  real_python="$(command -v python3)"
  mkdir -p "$shim_dir"
  cat > "$shim_dir/python3" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == */legion-process-supervisor.py ]]; then
  status_file=""
  max_runtime=""
  for ((i=1; i <= $#; i++)); do
    if [[ "${!i}" == --status-file ]]; then
      j=$((i + 1)); status_file="${!j}"
    elif [[ "${!i}" == --max-runtime-seconds ]]; then
      j=$((i + 1)); max_runtime="${!j}"
    fi
  done
  jq -cn --arg reason 'child launch failed: command not found: admitted-provider' \
    --argjson runtime "$max_runtime" \
    '{schema:"legion.child-execution-lease.v1",status:"launch_failed",
      reason:$reason,max_runtime_seconds:$runtime}' > "$status_file"
  exit 127
fi
exec "$LEGION_TEST_REAL_PYTHON" "$@"
SH
  chmod +x "$shim_dir/python3"
  export LEGION_TEST_REAL_PYTHON="$real_python"
  export PATH="$shim_dir:$PATH"
}

@test "authenticated launch failure suppresses signal-path provider accounting" {
  local art="$TEST_TMPDIR/signal-art" lease="$TEST_TMPDIR/signal-lease.json"
  mkdir -p "$art"
  printf '%s\n' \
    '{"schema":"legion.child-execution-lease.v1","status":"launch_failed","reason":"child launch failed","max_runtime_seconds":30}' \
    > "$lease"

  run bash -c '
    set -euo pipefail
    source "$1"
    RUN_ID=launch-failed-signal
    legion_adapter_arm_signal_receipt "$2" cursor cursor 1 fixture "" "" "" \
      read-only 2026-01-01T00:00:00Z "$(date +%s000)" /dev/null
    legion_adapter_write_signal_receipt 15 127 "$3"
    [[ "$LEGION_ADAPTER_SIGNAL_TERMINALIZED" == 0 ]]
    ! compgen -G "$2/attempt-*.json" >/dev/null
    ! compgen -G "$2/failure-*.json" >/dev/null
  ' _ "$REPO_ROOT/legion-router/scripts/lib/adapter-contract.sh" "$art" "$lease"

  [ "$status" -eq 0 ]
}

@test "contradictory launch-failure lookalike cannot suppress signal accounting" {
  local art="$TEST_TMPDIR/malformed-art" lease="$TEST_TMPDIR/malformed-lease.json"
  mkdir -p "$art"
  printf '%s\n' \
    '{"schema":"legion.child-execution-lease.v1","status":"launch_failed","reason":"forged no-launch claim","max_runtime_seconds":30,"child_exit_code":0}' \
    > "$lease"

  run bash -c '
    set -euo pipefail
    source "$1"
    RUN_ID=malformed-launch-failed-signal
    legion_adapter_arm_signal_receipt "$2" cursor cursor 1 fixture "" "" "" \
      read-only 2026-01-01T00:00:00Z "$(date +%s000)" /dev/null
    legion_adapter_write_signal_receipt 15 127 "$3"
    [[ "$LEGION_ADAPTER_SIGNAL_TERMINALIZED" == 1 ]]
    jq -e '\''
      .terminal_status == "cancelled"
      and (.failure.message | contains("sidecar was invalid"))
    '\'' "$2/attempt-1.json"
  ' _ "$REPO_ROOT/legion-router/scripts/lib/adapter-contract.sh" "$art" "$lease"

  [ "$status" -eq 0 ]
}

@test "every allowed direct adapter preserves no-launch evidence without provider accounting" {
  local adapter repo run_id result_file art lease rc
  install_launch_failed_python

  for adapter in cursor opencode deepseek pi hermes; do
    repo="$(make_test_repo "$adapter")"
    run_id="launch-failed-$adapter"
    result_file="$TEST_TMPDIR/$adapter-result.json"
    rc=0
    PI_BIN=pi HERMES_BIN=hermes \
      "$REPO_ROOT/legion-router/bin/legion-$adapter" run --task inspect \
        --repo "$repo" --run-id "$run_id" --quiet > "$result_file" 2>/dev/null || rc=$?

    [ "$rc" -ne 0 ]
    jq -e --arg executor "$adapter" '
      .status == "failed" and .executor == $executor
      and .attempt_receipt == null and .failure_receipt == null
      and .usage == null and .cost_usd == null
      and (.reason | contains("child launch failed"))
      and (.lease_receipt | type == "string" and length > 0)
    ' "$result_file" || {
      printf 'adapter=%s rc=%s output=%s\n' "$adapter" "$rc" "$(cat "$result_file")" >&2
      return 1
    }
    lease="$(jq -r '.lease_receipt' "$result_file")"
    jq -e '
      .schema == "legion.child-execution-lease.v1"
      and .status == "launch_failed"
      and (has("child_exit_code") | not)
    ' "$lease"
    art="$repo/.legion/runs/$run_id"
    [ "$(find "$art" -maxdepth 1 -name 'attempt-*.json' | wc -l | tr -d ' ')" -eq 0 ]
    [ "$(find "$art" -maxdepth 1 -name 'failure-*.json' | wc -l | tr -d ' ')" -eq 0 ]
  done

  run grep -Eq '^(agent -p|opencode run|dsh --profile|pi -p|hermes --oneshot)' "$MOCK_CALL_LOG"
  [ "$status" -ne 0 ]
  if compgen -G "$LEGION_TELEMETRY_DIR/*.jsonl" >/dev/null; then
    run jq -s -e '[.[] | select(.artifacts.provider_attempt == true)] | length > 0' \
      "$LEGION_TELEMETRY_DIR"/*.jsonl
    [ "$status" -ne 0 ]
  fi
}
