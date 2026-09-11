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

install_mock_version_registry() {
  export LEGION_EXECUTORS_FILE="$TEST_TMPDIR/executors.toml"
  cp "$REPO_ROOT/legion-router/config/executors.toml" "$LEGION_EXECUTORS_FILE"
  python3 - "$LEGION_EXECUTORS_FILE" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
for executor in ("claude", "cursor", "opencode", "deepseek", "pi", "hermes"):
    start = text.index(f"[executors.{executor}]")
    end = text.find("\n[executors.", start + 1)
    if end < 0:
        end = len(text)
    section = text[start:end].replace(
        "supported_version_patterns = []",
        'supported_version_patterns = ["^[0-9]"]',
        1,
    )
    text = text[:start] + section + text[end:]
path.write_text(text, encoding="utf-8")
PY
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

install_prelaunch_cleanup_failed_python() {
  local shim_dir="$TEST_TMPDIR/prelaunch-cleanup-python" real_python
  real_python="$(command -v python3)"
  mkdir -p "$shim_dir"
  cat > "$shim_dir/python3" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == */legion-process-supervisor.py ]]; then
  status_file="" max_runtime=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --status-file) status_file="$2"; shift 2 ;;
      --max-runtime-seconds) max_runtime="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  jq -cn --argjson runtime "$max_runtime" '
    {schema:"legion.child-execution-lease.v1",status:"cleanup_failed",
     reason:"host containment policy could not be verified",
     max_runtime_seconds:$runtime,child_started:false}
  ' > "$status_file"
  exit 70
fi
exec "$LEGION_TEST_REAL_PYTHON" "$@"
SH
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
  local repo out err pid rc=0 art launch_receipt
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
  if [[ "$adapter" == pi || "$adapter" == hermes ]]; then
    launch_receipt="$art/tmp/provider-launch.json"
    for _ in $(seq 1 200); do
      jq -e '.status == "started"' "$launch_receipt" >/dev/null 2>&1 && break
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.05
    done
    jq -e '.status == "started"' "$launch_receipt" >/dev/null
  fi
  kill -TERM "$pid"
  wait "$pid" || rc=$?
  [ "$rc" -eq 143 ]
  [ "$(find "$art" -name 'attempt-*.json' | wc -l | tr -d ' ')" -eq 1 ]
  [ "$(find "$art" -name 'failure-*.json' | wc -l | tr -d ' ')" -eq 1 ]
  jq -e '.terminal_status == "cancelled" and .failure.class == "cancelled"' \
    "$art/attempt-1.json"
  jq -e '.class == "cancelled" and .retryable == false' "$art/failure-1.json"
  jq -s -e --arg run "$run_id" --arg executor "$adapter" \
    --argjson attempt "$(cat "$art/attempt-1.json")" '
      [.[] | select(.run_id == $run and .executor == $executor
        and .artifacts.provider_attempt == true
        and .artifacts.signal_terminalized == true)] as $spans
      | ($spans | length) == 1
        and $spans[0].tokens == $attempt.usage
        and $spans[0].usage_status == $attempt.usage_status
        and $spans[0].cost_usd == $attempt.cost_usd
        and $spans[0].cost_status == $attempt.cost_status
    ' "$LEGION_TELEMETRY_DIR"/*.jsonl
}

@test "signal receipt honors a child that completed before the trap was dispatched" {
  local art="$TEST_TMPDIR/completed-race" lease="$TEST_TMPDIR/completed-race.lease.json"
  mkdir -p "$art"
  printf '%s\n' \
    '{"schema":"legion.child-execution-lease.v1","status":"completed","reason":"child completed","max_runtime_seconds":30,"child_exit_code":0}' \
    > "$lease"
  run bash -c '
    set -euo pipefail
    source "$1"
    RUN_ID=completed-race
    legion_adapter_arm_signal_receipt "$2" cursor cursor 1 fixture "" "" "" \
      read-only 2026-01-01T00:00:00Z "$(date +%s000)" /dev/null
    legion_adapter_write_signal_receipt 15 127 "$3"
    jq -e '\''
      .terminal_status == "succeeded" and .failure == null
      and .usage_status == "unknown" and .cost_status == "unknown"
    '\'' "$2/attempt-1.json"
  ' _ "$REPO_ROOT/legion-router/scripts/lib/adapter-contract.sh" "$art" "$lease"
  [ "$status" -eq 0 ]
}

@test "prelaunch containment evidence remains containment while authenticating no spend" {
  local receipt="$TEST_TMPDIR/prelaunch-containment.json"
  printf '%s\n' \
    '{"schema":"legion.child-execution-lease.v1","status":"cleanup_failed","reason":"host policy cannot be inspected","max_runtime_seconds":30,"child_started":false}' \
    > "$receipt"
  run bash -c '
    set -euo pipefail
    source "$1"
    legion_adapter_supervisor_cleanup_failed "$2"
    legion_adapter_supervisor_cleanup_failed_before_launch "$2"
    legion_adapter_supervisor_launch_failed "$2"
  ' _ "$REPO_ROOT/legion-router/scripts/lib/adapter-contract.sh" "$receipt"
  [ "$status" -eq 0 ]

  jq '.child_started = true' "$receipt" > "$receipt.tmp"
  mv "$receipt.tmp" "$receipt"
  run bash -c '
    source "$1"
    ! legion_adapter_supervisor_cleanup_failed_before_launch "$2"
    ! legion_adapter_supervisor_launch_failed "$2"
  ' _ "$REPO_ROOT/legion-router/scripts/lib/adapter-contract.sh" "$receipt"
  [ "$status" -eq 0 ]
}

@test "every foreground adapter aborts a signal pending at its final launch gate" {
  local bash_env="$TEST_TMPDIR/pending-signal.bash" adapter provider_marker signal expected_rc repo run_id rc art out err lease
  install_mock_version_registry
  cat > "$bash_env" <<'SH'
set -T
trap 'case "$BASH_COMMAND" in abort_pending_signal_launch|abort_pending_claude_signal_launch) kill -"${LEGION_TEST_FINAL_GATE_SIGNAL:-TERM}" "$$";; esac' DEBUG
SH
  for adapter in claude cursor opencode deepseek pi hermes; do
    case "$adapter" in
      claude) provider_marker='claude -p'; signal=TERM; expected_rc=143 ;;
      cursor) provider_marker='agent -p'; signal=INT; expected_rc=130 ;;
      opencode) provider_marker='opencode run'; signal=HUP; expected_rc=129 ;;
      deepseek) provider_marker='dsh --profile'; signal=TERM; expected_rc=143 ;;
      pi) provider_marker='pi -p'; signal=INT; expected_rc=130 ;;
      hermes) provider_marker='hermes --oneshot'; signal=HUP; expected_rc=129 ;;
    esac
    repo="$(make_test_repo "pending-$adapter")"
    run_id="pending-$adapter"
    out="$TEST_TMPDIR/$adapter-pending.out"
    err="$TEST_TMPDIR/$adapter-pending.err"
    rc=0
    local -a extra_args=()
    [[ "$adapter" != claude ]] || extra_args+=(--no-fallback)
    BASH_ENV="$bash_env" LEGION_TEST_FINAL_GATE_SIGNAL="$signal" PI_BIN=pi HERMES_BIN=hermes \
      "$REPO_ROOT/legion-router/bin/legion-$adapter" run --task wait --repo "$repo" \
        --run-id "$run_id" --quiet "${extra_args[@]}" >"$out" 2>"$err" || rc=$?
    [ "$rc" -eq "$expected_rc" ] || { printf 'adapter=%s signal=%s rc=%s out=%s err=%s\n' "$adapter" "$signal" "$rc" "$(cat "$out")" "$(cat "$err")" >&2; return 1; }
    ! grep -Fq "$provider_marker" "$MOCK_CALL_LOG" \
      || { printf 'adapter=%s launched provider\n' "$adapter" >&2; return 1; }
    art="$repo/.legion/runs/$run_id"
    [ "$(find "$art" -maxdepth 1 -name 'attempt-*.json' | wc -l | tr -d ' ')" -eq 0 ]
    [ "$(find "$art" -maxdepth 1 -name 'failure-*.json' | wc -l | tr -d ' ')" -eq 0 ]
    lease="$(find "$art" -maxdepth 1 -name 'lease*.json' -print -quit)"
    [ -n "$lease" ]
    jq -e '
      .schema == "legion.child-execution-lease.v1"
      and .status == "launch_failed"
      and (.reason | contains("final pre-launch gate; no provider launched"))
      and (.max_runtime_seconds | type == "number" and . >= 1 and . == floor)
      and (has("child_exit_code") | not)
      and ((keys_unsorted - ["schema","status","reason","max_runtime_seconds"]) | length == 0)
    ' "$lease" || { printf 'adapter=%s invalid final-gate lease=%s\n' "$adapter" "$(cat "$lease")" >&2; return 1; }
  done
}

@test "every foreground adapter retains containment when final-gate evidence collides" {
  local bash_env="$TEST_TMPDIR/pending-signal-collision.bash" adapter provider_marker repo run_id rc art out err worktree
  install_mock_version_registry
  cat > "$bash_env" <<'SH'
set -T
trap 'case "$BASH_COMMAND" in abort_pending_signal_launch|abort_pending_claude_signal_launch)
  if [[ "${LEGION_TEST_FINAL_GATE_INJECTED:-0}" == 0 ]]; then
    LEGION_TEST_FINAL_GATE_INJECTED=1
    : > "$SIGNAL_LEASE_STATUS"
    kill -TERM "$$"
  fi
;; esac' DEBUG
SH
  for adapter in claude cursor opencode deepseek pi hermes; do
    case "$adapter" in
      claude) provider_marker='claude -p' ;;
      cursor) provider_marker='agent -p' ;;
      opencode) provider_marker='opencode run' ;;
      deepseek) provider_marker='dsh --profile' ;;
      pi) provider_marker='pi -p' ;;
      hermes) provider_marker='hermes --oneshot' ;;
    esac
    repo="$(make_test_repo "pending-collision-$adapter")"
    run_id="pending-collision-$adapter"
    out="$TEST_TMPDIR/$adapter-pending-collision.out"
    err="$TEST_TMPDIR/$adapter-pending-collision.err"
    rc=0
    local -a extra_args=()
    [[ "$adapter" != claude ]] || extra_args+=(--no-fallback)
    BASH_ENV="$bash_env" PI_BIN=pi HERMES_BIN=hermes \
      "$REPO_ROOT/legion-router/bin/legion-$adapter" run --task wait --repo "$repo" \
        --run-id "$run_id" --quiet "${extra_args[@]}" >"$out" 2>"$err" || rc=$?
    [ "$rc" -eq 70 ] || { printf 'adapter=%s rc=%s out=%s err=%s\n' "$adapter" "$rc" "$(cat "$out")" "$(cat "$err")" >&2; return 1; }
    ! grep -Fq "$provider_marker" "$MOCK_CALL_LOG"
    art="$repo/.legion/runs/$run_id"
    [ "$(find "$art" -maxdepth 1 -name 'attempt-*.json' | wc -l | tr -d ' ')" -eq 0 ]
    [ "$(find "$art" -maxdepth 1 -name 'failure-*.json' | wc -l | tr -d ' ')" -eq 0 ]
    jq -e '.lifecycle.phase == "containment_failed"' "$LEGION_REGISTRY_DIR/$run_id.json"
    worktree="$(jq -r '.worktree_dir' "$LEGION_REGISTRY_DIR/$run_id.json")"
    [ -d "$worktree" ]
  done
}

@test "every foreground adapter preserves prelaunch containment without provider accounting" {
  local adapter repo run_id result_file provider_marker err_file rc
  install_mock_version_registry
  install_prelaunch_cleanup_failed_python
  for adapter in claude cursor opencode deepseek pi hermes; do
    case "$adapter" in
      claude) provider_marker='claude -p' ;;
      cursor) provider_marker='agent -p' ;;
      opencode) provider_marker='opencode run' ;;
      deepseek) provider_marker='dsh --profile' ;;
      pi) provider_marker='pi -p' ;;
      hermes) provider_marker='hermes --oneshot' ;;
    esac
    repo="$(make_test_repo "prelaunch-containment-$adapter")"
    run_id="prelaunch-containment-$adapter"
    result_file="$TEST_TMPDIR/$adapter-prelaunch-containment.out"
    err_file="$TEST_TMPDIR/$adapter-prelaunch-containment.err"
    rc=0
    local -a extra_args=()
    [[ "$adapter" != claude ]] || extra_args+=(--no-fallback)
    PI_BIN=pi HERMES_BIN=hermes \
      "$REPO_ROOT/legion-router/bin/legion-$adapter" run --task wait --repo "$repo" \
        --run-id "$run_id" --quiet "${extra_args[@]}" > "$result_file" 2>"$err_file" || rc=$?
    jq -e '
      .status == "containment_failed"
      and .attempt_receipt == null and .failure_receipt == null
      and ((.result // .reason) | contains("containment policy could not be verified"))
    ' "$result_file" || { printf 'adapter=%s rc=%s output=%s err=%s\n' "$adapter" "$rc" "$(cat "$result_file")" "$(cat "$err_file")" >&2; return 1; }
    jq -e '.status == "cleanup_failed" and .child_started == false' \
      "$(jq -r '.lease_receipt' "$result_file")"
    ! grep -Fq "$provider_marker" "$MOCK_CALL_LOG"
  done
}

@test "normal and delayed-signal publication share one durable provider-span claim" {
  local art="$TEST_TMPDIR/shared-span-claim" spans="$TEST_TMPDIR/shared-span-claim-spans"
  mkdir -p "$art" "$spans"
  run bash -c '
    set -euo pipefail
    source "$1"
    RUN_ID=shared-span-claim
    LEGION_TELEMETRY_DIR="$3"
    legion_adapter_arm_signal_receipt "$2" cursor cursor 1 fixture "" "" "" \
      read-only 2026-01-01T00:00:00Z "$(date +%s000)" /dev/null
    legion_adapter_write_attempt "$2" cursor cursor 1 fixture "" "" "" read-only \
      succeeded 2026-01-01T00:00:00Z 2026-01-01T00:00:01Z 1000 \
      "{}" unknown "" 0 unknown "" "" false true "" ""
    emit_span() {
      jq -cn --arg attempt "$LEGION_ADAPTER_ATTEMPT_PATH" \
        '\''{schema:"legion.span.v1",artifacts:{provider_attempt:true,attempt_receipt:$attempt}}'\'' \
        >> "$LEGION_TELEMETRY_DIR/spans.jsonl"
    }
    legion_adapter_emit_normal_provider_span "$LEGION_ADAPTER_ATTEMPT_PATH"
    legion_adapter_write_signal_receipt 15 127 ""
    legion_adapter_emit_signal_span delayed "" || true
    [[ -d "$LEGION_ADAPTER_ATTEMPT_PATH.provider-span-emitted" ]]
    [[ "$(wc -l < "$LEGION_TELEMETRY_DIR/spans.jsonl" | tr -d " ")" == 1 ]]
  ' _ "$REPO_ROOT/legion-router/scripts/lib/adapter-contract.sh" "$art" "$spans"
  [ "$status" -eq 0 ]
}

@test "failed normal provider-span publication releases claim and can be retried" {
  local art="$TEST_TMPDIR/retry-span-claim" spans="$TEST_TMPDIR/retry-span-claim-spans"
  mkdir -p "$art" "$spans"
  run bash -c '
    set -euo pipefail
    source "$1"
    RUN_ID=retry-span-claim
    LEGION_TELEMETRY_DIR="$3"
    legion_adapter_write_attempt "$2" cursor cursor 1 fixture "" "" "" read-only \
      succeeded 2026-01-01T00:00:00Z 2026-01-01T00:00:01Z 1000 \
      "{}" unknown "" 0 unknown "" "" false true "" ""
    emit_span() { return 0; }
    if legion_adapter_emit_normal_provider_span "$LEGION_ADAPTER_ATTEMPT_PATH"; then
      exit 10
    fi
    [[ -d "$LEGION_ADAPTER_ATTEMPT_PATH.provider-span-emitted" ]]
    [[ ! -f "$LEGION_ADAPTER_ATTEMPT_PATH.provider-span-emitted/owner.json" ]]
    emit_span() {
      jq -cn --arg attempt "$LEGION_ADAPTER_ATTEMPT_PATH" \
        '\''{schema:"legion.span.v1",artifacts:{provider_attempt:true,attempt_receipt:$attempt}}'\'' \
        >> "$LEGION_TELEMETRY_DIR/spans.jsonl"
    }
    legion_adapter_emit_normal_provider_span "$LEGION_ADAPTER_ATTEMPT_PATH"
    [[ -d "$LEGION_ADAPTER_ATTEMPT_PATH.provider-span-emitted" ]]
    [[ "$(wc -l < "$LEGION_TELEMETRY_DIR/spans.jsonl" | tr -d " ")" == 1 ]]
  ' _ "$REPO_ROOT/legion-router/scripts/lib/adapter-contract.sh" "$art" "$spans"
  [ "$status" -eq 0 ]
}

@test "rollup-only span cannot satisfy provider-span durability" {
  local spans="$TEST_TMPDIR/rollup-is-not-provider"
  mkdir -p "$spans"
  run bash -c '
    set -euo pipefail
    source "$1"
    LEGION_TELEMETRY_DIR="$2"
    jq -cn --arg attempt "$3" \
      '\''{schema:"legion.span.v1",artifacts:{rollup_only:true,attempt_receipt:$attempt}}'\'' \
      > "$LEGION_TELEMETRY_DIR/spans.jsonl"
    ! legion_adapter_provider_span_is_durable "$3"
  ' _ "$REPO_ROOT/legion-router/scripts/lib/adapter-contract.sh" "$spans" \
    "$TEST_TMPDIR/attempt-1.json"
  [ "$status" -eq 0 ]
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
  local repo output_json attempt span
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
  span="$(cat "$LEGION_TELEMETRY_DIR"/*.jsonl | jq -c 'select(.executor == "hermes")')"
  jq -e --argjson attempt "$(cat "$attempt")" '
    .tokens == $attempt.usage and .usage_status == $attempt.usage_status
    and .cost_usd == $attempt.cost_usd and .cost_status == $attempt.cost_status
  ' <<<"$span"
}

@test "Pi span preserves its canonical attempt metering exactly" {
  local repo output_json attempt span
  repo="$(make_test_repo pi-provenance)"
  run env PI_BIN=pi "$REPO_ROOT/legion-router/bin/legion-pi" run \
    --model openai/fixture-model --task edit --repo "$repo" --quiet
  [ "$status" -eq 0 ]
  output_json="$output"
  attempt="$(jq -r '.attempt_receipt' <<<"$output_json")"
  span="$(cat "$LEGION_TELEMETRY_DIR"/*.jsonl | jq -c 'select(.executor == "pi")')"
  jq -e --argjson attempt "$(cat "$attempt")" '
    .tokens == $attempt.usage and .usage_status == $attempt.usage_status
    and .cost_usd == $attempt.cost_usd and .cost_status == $attempt.cost_status
  ' <<<"$span"
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

@test "prompt review propagates adapter containment failure and retains evidence" {
  local repo result_file worktree lease
  repo="$(make_test_repo prompt-review-containment)"
  result_file="$TEST_TMPDIR/prompt-review-containment.out"
  install_cleanup_failed_python

  CODEX_BIN=missing-codex-for-review \
    "$REPO_ROOT/legion-router/bin/legion-delegate" review --base HEAD \
      --repo "$repo" --quiet >"$result_file" 2>/dev/null || true

  jq -e '.status == "containment_failed" and (.reason | contains("forced cleanup evidence"))' \
    "$result_file"
  worktree="$(jq -r '.worktree' "$result_file")"
  [ -d "$worktree" ]
  lease="$(jq -r '.lease_receipt' "$result_file")"
  [ -f "$lease" ]
  jq -e '.status == "cleanup_failed"' "$lease"
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
    if [[ "$adapter" == pi || "$adapter" == hermes ]]; then
      # Their authenticated inner launch boundary proves this fixture never
      # reached a provider, even though outer descendant cleanup failed.
      [ "$(find "$art" -maxdepth 1 -name 'attempt-*.json' | wc -l | tr -d ' ')" -eq 0 ]
      [ "$(find "$art" -maxdepth 1 -name 'failure-*.json' | wc -l | tr -d ' ')" -eq 0 ]
    else
      jq -e '.terminal_status == "failed" and .failure.class == "internal"
        and (.failure.message | contains("worktree retained"))' "$art/attempt-1.json"
      [ "$(find "$art" -maxdepth 1 -name 'attempt-*.json' | wc -l | tr -d ' ')" -eq 1 ]
      [ "$(find "$art" -maxdepth 1 -name 'failure-*.json' | wc -l | tr -d ' ')" -eq 1 ]
    fi
    jq -e '.lifecycle.phase == "containment_failed"' "$LEGION_REGISTRY_DIR/$run_id.json"
    [ -d "$repo/.legion/worktrees/$run_id" ]
  done
}
