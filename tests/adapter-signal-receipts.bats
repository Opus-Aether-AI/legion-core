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
  local mode="${1:-immediate}" shim_dir="$TEST_TMPDIR/python-shim" real_python
  real_python="$(command -v python3)"
  mkdir -p "$shim_dir"
  cat > "$shim_dir/python3" <<'SH'
#!/usr/bin/env bash
write_gate() {
  local status="$1" child_pid="${2:-}" temp
  temp="$(mktemp "${launch_gate%/*}/.fixture-launch-gate.XXXXXX")" || exit 70
  if [[ -n "$child_pid" ]]; then
    jq -cn --arg status "$status" --arg token "$launch_token" \
      --argjson pid "$$" --argjson child "$child_pid" \
      '{schema:"legion.child-launch-gate.v1",status:$status,token:$token,supervisor_pid:$pid,child_pid:$child}' > "$temp"
  else
    jq -cn --arg status "$status" --arg token "$launch_token" --argjson pid "$$" \
      '{schema:"legion.child-launch-gate.v1",status:$status,token:$token,supervisor_pid:$pid}' > "$temp"
  fi
  chmod 600 "$temp"
  mv -f "$temp" "$launch_gate"
}

write_provider_started() {
  local wrapper_index=0 receipt="" token_file="" provider="" i
  [[ -n "$descendant_ready" ]] || return 0
  for ((i = 1; i <= $#; i++)); do
    [[ "${!i}" != */provider-launch-wrapper.py ]] || { wrapper_index="$i"; break; }
  done
  [[ "$wrapper_index" -gt 0 ]] || return 70
  i=$((wrapper_index + 1)); receipt="${!i}"
  i=$((wrapper_index + 2)); token_file="${!i}"
  i=$((wrapper_index + 4)); provider="${!i}"
  [[ "$receipt" == "$descendant_ready" && -s "$token_file" && -n "$provider" ]] || return 70
  "$LEGION_TEST_REAL_PYTHON" - "$receipt" "$token_file" "$provider" "$$" <<'PY'
import hashlib, hmac, json, os, pathlib, sys, tempfile
receipt, token_file, executable, provider_pid = sys.argv[1:]
token = pathlib.Path(token_file).read_text(encoding="ascii").strip()
payload = {"schema":"legion.provider-launch.v1", "status":"started",
           "executable_path":executable, "provider_pid":int(provider_pid)}
encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
payload["auth"] = hmac.new(token.encode(), encoded, hashlib.sha256).hexdigest()
fd, temporary = tempfile.mkstemp(prefix=".fixture-provider.", dir=str(pathlib.Path(receipt).parent))
with os.fdopen(fd, "w", encoding="utf-8") as stream:
    json.dump(payload, stream, separators=(",", ":")); stream.write("\n"); stream.flush(); os.fsync(stream.fileno())
os.chmod(temporary, 0o600); os.replace(temporary, receipt)
PY
}

if [[ "${1:-}" == */legion-process-supervisor.py ]]; then
  status_file=""; launch_gate=""; launch_token=""; descendant_ready=""; max_runtime=30
  original=("$@")
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --status-file) status_file="$2"; shift 2 ;;
      --max-runtime-seconds) max_runtime="$2"; shift 2 ;;
      --launch-gate-file) launch_gate="$2"; shift 2 ;;
      --launch-gate-token) launch_token="$2"; shift 2 ;;
      --descendant-signal-ready-file) descendant_ready="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  write_gate ready
  decision=""
  for ((i = 0; i < 500; i++)); do
    decision="$(jq -r --arg token "$launch_token" --argjson pid "$$" \
      'if .schema == "legion.child-launch-gate.v1" and .token == $token and .supervisor_pid == $pid then .status else empty end' \
      "$launch_gate" 2>/dev/null || true)"
    [[ "$decision" != go && "$decision" != cancel ]] || break
    sleep 0.02
  done
  [[ "$decision" == go ]] || exit 70
  write_gate started "$$"
  write_provider_started "${original[@]}" || exit 70
  if [[ "${LEGION_TEST_FIXTURE_CLEANUP_MODE:-immediate}" == signal ]]; then
    trap 'printf "%s\n" "{\"schema\":\"legion.child-execution-lease.v1\",\"status\":\"cleanup_failed\",\"reason\":\"signal drain failed\",\"max_runtime_seconds\":$max_runtime}" > "$status_file"; exit 70' TERM
    : > "$LEGION_TEST_SUPERVISOR_STARTED"
    while true; do sleep 1; done
  fi
  jq -cn --argjson runtime "$max_runtime" \
    '{schema:"legion.child-execution-lease.v1",status:"cleanup_failed",reason:"forced cleanup evidence",max_runtime_seconds:$runtime}' > "$status_file"
  exit 70
fi
exec "$LEGION_TEST_REAL_PYTHON" "$@"
SH
  chmod +x "$shim_dir/python3"
  export LEGION_TEST_REAL_PYTHON="$real_python"
  export LEGION_TEST_FIXTURE_CLEANUP_MODE="$mode"
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

install_malformed_launch_gate_python() {
  local shim_dir="$TEST_TMPDIR/malformed-gate-python" real_python
  real_python="$(command -v python3)"
  mkdir -p "$shim_dir"
  cat > "$shim_dir/python3" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == */legion-process-supervisor.py ]]; then
  gate=""; token=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --launch-gate-file) gate="$2"; shift 2 ;;
      --launch-gate-token) token="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  temp="$(mktemp "${gate%/*}/.malformed-gate-fixture.XXXXXX")" || exit 70
  jq -cn --arg token "$token" --argjson pid "$$" \
    '{schema:"legion.child-launch-gate.v1",status:"ready",token:$token,supervisor_pid:$pid}' > "$temp"
  chmod 600 "$temp"; mv -f "$temp" "$gate"
  for ((i = 0; i < 500; i++)); do
    jq -e --arg token "$token" --argjson pid "$$" \
      '.status == "go" and .token == $token and .supervisor_pid == $pid' "$gate" >/dev/null 2>&1 && break
    sleep 0.02
  done
  printf '%s\n' '{"schema":"legion.child-launch-gate.v1","status":"started","token":"forged"}' > "$gate"
  exit 70
fi
exec "$LEGION_TEST_REAL_PYTHON" "$@"
SH
  chmod +x "$shim_dir/python3"
  export LEGION_TEST_REAL_PYTHON="$real_python"
  export PATH="$shim_dir:$PATH"
}

install_signal_cleanup_failed_python() {
  # Hold after publishing authenticated outer/inner started evidence until the
  # adapter forwards TERM, then publish the post-launch cleanup failure.
  install_cleanup_failed_python signal
}

install_prelaunch_timeout_python() {
  local shim_dir="$TEST_TMPDIR/prelaunch-timeout-python" real_python
  real_python="$(command -v python3)"
  mkdir -p "$shim_dir"
  cat > "$shim_dir/python3" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == */legion-process-supervisor.py && " $* " == *" --launch-gate-file "* ]]; then
  status_file="" launch_gate="" launch_token="" max_runtime=30
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --status-file) status_file="$2"; shift 2 ;;
      --max-runtime-seconds) max_runtime="$2"; shift 2 ;;
      --launch-gate-file) launch_gate="$2"; shift 2 ;;
      --launch-gate-token) launch_token="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  temp="$(mktemp "${launch_gate%/*}/.timeout-ready.XXXXXX")" || exit 70
  jq -cn --arg token "$launch_token" --argjson pid "$$" \
    '{schema:"legion.child-launch-gate.v1",status:"ready",token:$token,supervisor_pid:$pid}' > "$temp"
  chmod 600 "$temp"; mv -f "$temp" "$launch_gate"
  for ((i = 0; i < 500; i++)); do
    jq -e --arg token "$launch_token" --argjson pid "$$" \
      '.status == "go" and .token == $token and .supervisor_pid == $pid' \
      "$launch_gate" >/dev/null 2>&1 && break
    /bin/sleep 0.02
  done
  jq -cn --argjson runtime "$max_runtime" '
    {schema:"legion.child-execution-lease.v1",status:"launch_failed",
     reason:"inherited child lease deadline expired during launch setup",
     max_runtime_seconds:$runtime}' > "$status_file"
  exit 124
fi
exec "$LEGION_TEST_REAL_PYTHON" "$@"
SH
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

@test "version-probe preflight disposition authenticates timeout unavailable and malformed evidence" {
  local receipt="$TEST_TMPDIR/version-probe-preflight.json"
  jq -cn '
    {schema:"legion.preflight.v1",status:"unavailable",identity:null,
     compatibility:{version:{discovered:null,status:"unavailable",
       probe_status:"timed_out",
       probe_reason:"inherited child lease deadline expired during launch setup",
       probe_lease:{schema:"legion.child-execution-lease.v1",status:"launch_failed",
         reason:"inherited child lease deadline expired during launch setup",
         max_runtime_seconds:30}}}}
  ' > "$receipt"
  run bash -c 'source "$1"; legion_adapter_preflight_failure_disposition "$2"' \
    _ "$REPO_ROOT/legion-router/scripts/lib/adapter-contract.sh" "$receipt"
  [ "$status" -eq 0 ]
  [ "$output" = timed_out ]

  jq '
    .compatibility.version.probe_status="launch_failed"
    | .compatibility.version.probe_reason="child launch failed: command not found"
    | .compatibility.version.probe_lease.reason=.compatibility.version.probe_reason
  ' "$receipt" > "$receipt.tmp"; mv "$receipt.tmp" "$receipt"
  run bash -c 'source "$1"; legion_adapter_preflight_failure_disposition "$2"' \
    _ "$REPO_ROOT/legion-router/scripts/lib/adapter-contract.sh" "$receipt"
  [ "$status" -eq 0 ]
  [ "$output" = launch_failed ]

  jq '
    .compatibility.version.probe_reason="executor binary disappeared or changed during version probe"
    | .compatibility.version.probe_lease.reason="child launch failed: command not found: /tmp/provider"
  ' "$receipt" > "$receipt.tmp"; mv "$receipt.tmp" "$receipt"
  run bash -c 'source "$1"; legion_adapter_preflight_failure_disposition "$2"' \
    _ "$REPO_ROOT/legion-router/scripts/lib/adapter-contract.sh" "$receipt"
  [ "$status" -eq 0 ]
  [ "$output" = launch_failed ]

  jq '.compatibility.version.probe_reason="contradictory evidence"' \
    "$receipt" > "$receipt.tmp"; mv "$receipt.tmp" "$receipt"
  run bash -c 'source "$1"; legion_adapter_preflight_failure_disposition "$2"' \
    _ "$REPO_ROOT/legion-router/scripts/lib/adapter-contract.sh" "$receipt"
  [ "$status" -eq 0 ]
  [ "$output" = containment_failed ]

  jq -cn '{schema:"legion.preflight.v1",status:"unavailable",identity:null,compatibility:{}}' \
    > "$receipt"
  run bash -c 'source "$1"; legion_adapter_preflight_failure_disposition "$2"' \
    _ "$REPO_ROOT/legion-router/scripts/lib/adapter-contract.sh" "$receipt"
  [ "$status" -eq 0 ]
  [ "$output" = unavailable ]

  jq '.status="incompatible"' "$receipt" > "$receipt.tmp"; mv "$receipt.tmp" "$receipt"
  run bash -c 'source "$1"; legion_adapter_preflight_failure_disposition "$2"' \
    _ "$REPO_ROOT/legion-router/scripts/lib/adapter-contract.sh" "$receipt"
  [ "$status" -eq 0 ]
  [ "$output" = refused ]
}

@test "launch gate signal after pending snapshot atomically cancels before go publication" {
  local gate="$TEST_TMPDIR/race-gate.json" lease="$TEST_TMPDIR/race-lease.json"
  local launched="$TEST_TMPDIR/provider-launched" token="race-token" supervisor rc=0
  (
    local status
    while true; do
      status="$(jq -r '.status // empty' "$gate" 2>/dev/null || true)"
      case "$status" in
        cancel)
          jq -cn '{schema:"legion.child-execution-lease.v1",status:"launch_failed",
            reason:"provider launch cancelled by signal 15 at supervisor gate; no provider launched",
            max_runtime_seconds:30}' > "$lease"
          exit 143
          ;;
        go)
          : > "$launched"
          exit 70
          ;;
      esac
      /bin/sleep 0.01
    done
  ) &
  supervisor=$!
  jq -cn --arg token "$token" --argjson pid "$supervisor" '
    {schema:"legion.child-launch-gate.v1",status:"ready",token:$token,supervisor_pid:$pid}
  ' > "$gate"

  run env CONTRACT="$REPO_ROOT/legion-router/scripts/lib/adapter-contract.sh" \
    GATE="$gate" LEASE="$lease" TOKEN="$token" SUPERVISOR="$supervisor" \
    bash -c '
      set -euo pipefail
      set -T
      source "$CONTRACT"
      LEGION_ADAPTER_LAUNCH_GATE_PATH="$GATE"
      LEGION_ADAPTER_LAUNCH_GATE_TOKEN="$TOKEN"
      PENDING=""
      trap '\''
        if [[ "${LEGION_TEST_RACE_FIRED:-0}" == 0
              && "$BASH_COMMAND" == "LEGION_ADAPTER_LAUNCH_GATE_SIGNAL_SEALED=1" \
              && "${LEGION_ADAPTER_LAUNCH_GATE_SIGNAL_FD_OPEN:-0}" == 1 \
              && "${decision:-}" == go \
              && " ${FUNCNAME[*]:-} " == *" legion_adapter_complete_supervisor_launch_gate "* ]]; then
          LEGION_TEST_RACE_FIRED=1
          trap - DEBUG
          legion_adapter_record_launch_signal PENDING 15
        fi
      '\'' DEBUG
      legion_adapter_complete_supervisor_launch_gate "$SUPERVISOR" "$LEASE" PENDING
      [[ "$LEGION_TEST_RACE_FIRED" == 1 ]]
      [[ "$PENDING" == 15 ]]
      [[ "$LEGION_ADAPTER_LAUNCH_GATE_OUTCOME" == launch_failed ]]
      [[ "$LEGION_ADAPTER_LAUNCH_GATE_SIGNAL_ACTIVE" == 0 ]]
      [[ -z "$LEGION_ADAPTER_LAUNCH_GATE_SIGNAL_DECISION_TEMP" ]]
    '
  rc=$status
  kill "$supervisor" 2>/dev/null || true
  wait "$supervisor" 2>/dev/null || true
  [ "$rc" -eq 0 ] || { printf 'child rc=%s output=%s gate=%s lease=%s\n' \
    "$rc" "$output" "$(cat "$gate" 2>/dev/null)" "$(cat "$lease" 2>/dev/null)" >&2; return 1; }
  [ ! -e "$launched" ]
  jq -e '
    .schema == "legion.child-launch-gate.v1" and .status == "cancel"
    and .signal == 15
    and ((keys_unsorted - ["schema","status","token","supervisor_pid","signal"]) | length == 0)
  ' "$gate"
  jq -e '.status == "launch_failed" and (has("child_exit_code") | not)' "$lease"
}

@test "launch gate rejects an extra-key ready receipt at final revalidation" {
  local gate="$TEST_TMPDIR/extra-ready.json" lease="$TEST_TMPDIR/extra-ready-lease.json"
  local shim_dir="$TEST_TMPDIR/extra-ready-jq" token="extra-ready-token" supervisor
  mkdir -p "$shim_dir"
  /bin/sleep 30 & supervisor=$!
  jq -cn --arg token "$token" --argjson pid "$supervisor" '
    {schema:"legion.child-launch-gate.v1",status:"ready",token:$token,supervisor_pid:$pid}
  ' > "$gate"
  cat > "$shim_dir/jq" <<'SH'
#!/usr/bin/env bash
"$LEGION_TEST_REAL_JQ" "$@"
rc=$?
if [[ "$rc" -eq 0 && " $* " == *'status == "ready"'* \
      && "${LEGION_TEST_READY_MUTATED:-0}" == 0 ]]; then
  export LEGION_TEST_READY_MUTATED=1
  path="${!#}"
  "$LEGION_TEST_REAL_JQ" '.extra=true' "$path" > "$path.tmp"
  chmod 600 "$path.tmp"
  mv -f "$path.tmp" "$path"
fi
exit "$rc"
SH
  chmod +x "$shim_dir/jq"
  run env PATH="$shim_dir:$PATH" LEGION_TEST_REAL_JQ="$(command -v jq)" \
    CONTRACT="$REPO_ROOT/legion-router/scripts/lib/adapter-contract.sh" \
    GATE="$gate" LEASE="$lease" TOKEN="$token" SUPERVISOR="$supervisor" \
    bash -c '
      set -euo pipefail
      source "$CONTRACT"
      LEGION_ADAPTER_LAUNCH_GATE_PATH="$GATE"
      LEGION_ADAPTER_LAUNCH_GATE_TOKEN="$TOKEN"
      PENDING=""
      legion_adapter_complete_supervisor_launch_gate "$SUPERVISOR" "$LEASE" PENDING
      [[ "$LEGION_ADAPTER_LAUNCH_GATE_OUTCOME" == containment_failed ]]
      [[ "$LEGION_ADAPTER_LAUNCH_GATE_SIGNAL_ACTIVE" == 0 ]]
      [[ -z "$LEGION_ADAPTER_LAUNCH_GATE_SIGNAL_DECISION_TEMP" ]]
    '
  kill "$supervisor" 2>/dev/null || true
  wait "$supervisor" 2>/dev/null || true
  [ "$status" -eq 0 ]
  jq -e '.status == "ready" and .extra == true' "$gate"
}

@test "launch gate does not block on a decision arbiter that exits before opening" {
  local gate="$TEST_TMPDIR/arbiter-exit-gate.json" lease="$TEST_TMPDIR/arbiter-exit-lease.json"
  local token="arbiter-exit-token" supervisor start elapsed
  /bin/sleep 30 & supervisor=$!
  jq -cn --arg token "$token" --argjson pid "$supervisor" '
    {schema:"legion.child-launch-gate.v1",status:"ready",token:$token,supervisor_pid:$pid}
  ' > "$gate"
  start="$(date +%s)"
  run env CONTRACT="$REPO_ROOT/legion-router/scripts/lib/adapter-contract.sh" \
    GATE="$gate" LEASE="$lease" TOKEN="$token" SUPERVISOR="$supervisor" \
    bash -c '
      set -euo pipefail
      source "$CONTRACT"
      legion_adapter_launch_gate_decision_arbiter() { return 70; }
      LEGION_ADAPTER_LAUNCH_GATE_PATH="$GATE"
      LEGION_ADAPTER_LAUNCH_GATE_TOKEN="$TOKEN"
      PENDING=""
      legion_adapter_complete_supervisor_launch_gate "$SUPERVISOR" "$LEASE" PENDING
      [[ "$LEGION_ADAPTER_LAUNCH_GATE_OUTCOME" == containment_failed ]]
    '
  elapsed=$(( $(date +%s) - start ))
  kill "$supervisor" 2>/dev/null || true
  wait "$supervisor" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [ "$elapsed" -lt 5 ]
  jq -e '.status == "ready"' "$gate"
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

@test "every foreground adapter preserves a prelaunch supervisor deadline as timed_out" {
  local adapter repo run_id result_file err_file rc art lease provider_marker
  install_mock_version_registry
  install_prelaunch_timeout_python
  for adapter in claude cursor opencode deepseek pi hermes; do
    case "$adapter" in
      claude) provider_marker='claude -p' ;;
      cursor) provider_marker='agent -p' ;;
      opencode) provider_marker='opencode run' ;;
      deepseek) provider_marker='dsh --profile' ;;
      pi) provider_marker='pi -p' ;;
      hermes) provider_marker='hermes --oneshot' ;;
    esac
    repo="$(make_test_repo "prelaunch-timeout-$adapter")"
    run_id="prelaunch-timeout-$adapter"
    result_file="$TEST_TMPDIR/$adapter-prelaunch-timeout.out"
    err_file="$TEST_TMPDIR/$adapter-prelaunch-timeout.err"
    rc=0
    local -a extra_args=()
    [[ "$adapter" != claude ]] || extra_args+=(--no-fallback)
    PI_BIN=pi HERMES_BIN=hermes \
      "$REPO_ROOT/legion-router/bin/legion-$adapter" run --task wait --repo "$repo" \
        --run-id "$run_id" --quiet "${extra_args[@]}" > "$result_file" 2>"$err_file" || rc=$?
    [ "$rc" -ne 0 ]
    jq -e '
      .status == "timed_out"
      and .attempt_receipt == null and .failure_receipt == null
      and .usage == null and .usage_status == "not_applicable"
      and .cost_usd == null and .cost_status == "not_applicable"
      and (.reason | contains("deadline expired"))
    ' "$result_file" || {
      printf 'adapter=%s rc=%s output=%s err=%s\n' \
        "$adapter" "$rc" "$(cat "$result_file")" "$(cat "$err_file")" >&2
      return 1
    }
    lease="$(jq -r '.lease_receipt // empty' "$result_file")"
    [ -n "$lease" ]
    jq -e '.status == "launch_failed" and (has("child_exit_code") | not)' "$lease"
    art="$repo/.legion/runs/$run_id"
    [ "$(find "$art" -maxdepth 1 -name 'attempt-*.json' | wc -l | tr -d ' ')" -eq 0 ]
    [ "$(find "$art" -maxdepth 1 -name 'failure-*.json' | wc -l | tr -d ' ')" -eq 0 ]
    ! grep -Fq "$provider_marker" "$MOCK_CALL_LOG"
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

@test "every foreground adapter cancels through the supervisor handshake after background fork" {
  local bash_env="$TEST_TMPDIR/post-fork-signal.bash" adapter provider_marker signal expected_rc repo run_id rc art out err lease
  install_mock_version_registry
  cat > "$bash_env" <<'SH'
set -T
trap 'case "$BASH_COMMAND" in legion_adapter_complete_supervisor_launch_gate*)
  if [[ "${LEGION_TEST_POST_FORK_SIGNALLED:-0}" == 0 ]]; then
    LEGION_TEST_POST_FORK_SIGNALLED=1
    kill -"${LEGION_TEST_POST_FORK_SIGNAL:-TERM}" "$$"
  fi
;; esac' DEBUG
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
    repo="$(make_test_repo "post-fork-$adapter")"
    run_id="post-fork-$adapter"
    out="$TEST_TMPDIR/$adapter-post-fork.out"
    err="$TEST_TMPDIR/$adapter-post-fork.err"
    rc=0
    local -a extra_args=()
    [[ "$adapter" != claude ]] || extra_args+=(--no-fallback)
    BASH_ENV="$bash_env" LEGION_TEST_POST_FORK_SIGNAL="$signal" PI_BIN=pi HERMES_BIN=hermes \
      "$REPO_ROOT/legion-router/bin/legion-$adapter" run --task wait --repo "$repo" \
        --run-id "$run_id" --quiet "${extra_args[@]}" >"$out" 2>"$err" || rc=$?
    [ "$rc" -eq "$expected_rc" ] || { printf 'adapter=%s signal=%s rc=%s out=%s err=%s\n' "$adapter" "$signal" "$rc" "$(cat "$out")" "$(cat "$err")" >&2; return 1; }
    ! grep -Fq "$provider_marker" "$MOCK_CALL_LOG"
    art="$repo/.legion/runs/$run_id"
    [ "$(find "$art" -maxdepth 1 -name 'attempt-*.json' | wc -l | tr -d ' ')" -eq 0 ]
    [ "$(find "$art" -maxdepth 1 -name 'failure-*.json' | wc -l | tr -d ' ')" -eq 0 ]
    lease="$(find "$art" -maxdepth 1 -name 'lease*.json' -print -quit)"
    jq -e '
      .schema == "legion.child-execution-lease.v1" and .status == "launch_failed"
      and (.reason | contains("final pre-launch gate"))
      and (has("child_exit_code") | not)
    ' "$lease"
  done
}

@test "every foreground adapter preserves typed prelaunch and malformed-gate containment" {
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

  # A forged post-ready gate is neither authenticated launch evidence nor a
  # no-launch attestation. It must return a terminal containment envelope,
  # retain the worktree, and preserve usage/cost as unknown without inventing
  # an attempt.
  export PATH="${PATH#*:}"
  install_malformed_launch_gate_python
  for adapter in claude cursor opencode deepseek pi hermes; do
    case "$adapter" in
      claude) provider_marker='claude -p' ;;
      cursor) provider_marker='agent -p' ;;
      opencode) provider_marker='opencode run' ;;
      deepseek) provider_marker='dsh --profile' ;;
      pi) provider_marker='pi -p' ;;
      hermes) provider_marker='hermes --oneshot' ;;
    esac
    repo="$(make_test_repo "malformed-gate-$adapter")"
    run_id="malformed-gate-$adapter"
    result_file="$TEST_TMPDIR/$adapter-malformed-gate.out"
    err_file="$TEST_TMPDIR/$adapter-malformed-gate.err"
    rc=0
    local -a gate_args=()
    [[ "$adapter" != claude ]] || gate_args+=(--no-fallback)
    PI_BIN=pi HERMES_BIN=hermes \
      "$REPO_ROOT/legion-router/bin/legion-$adapter" run --task wait --repo "$repo" \
        --run-id "$run_id" --quiet "${gate_args[@]}" >"$result_file" 2>"$err_file" || rc=$?
    [ "$rc" -eq 70 ] || { printf 'adapter=%s rc=%s output=%s err=%s\n' "$adapter" "$rc" "$(cat "$result_file")" "$(cat "$err_file")" >&2; return 1; }
    jq -e '
      .status == "containment_failed" and .attempt_receipt == null and .failure_receipt == null
      and .usage == null and .usage_status == "unknown"
      and .cost_usd == null and .cost_status == "unknown"
      and (.reason | contains("launch-gate authentication or handshake failed"))
      and (.lease_receipt | type == "string")
    ' "$result_file"
    jq -e '.schema == "legion.child-execution-lease.v1" and .status == "cleanup_failed"' \
      "$(jq -r .lease_receipt "$result_file")"
    ! grep -Fq "$provider_marker" "$MOCK_CALL_LOG"
    [ "$(find "$repo/.legion/runs/$run_id" -maxdepth 1 -name 'attempt-*.json' | wc -l | tr -d ' ')" -eq 0 ]
    jq -e '.lifecycle.phase == "containment_failed"' "$LEGION_REGISTRY_DIR/$run_id.json"
    [ -d "$(jq -r .worktree_dir "$LEGION_REGISTRY_DIR/$run_id.json")" ]
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
        '\''{schema:"legion.span.v1",ts:"2026-01-01T00:00:01Z",run_id:"shared-span-claim",
          executor:"cursor",model:"fixture",status:"ok",duration_ms:1000,
          cost_usd:null,cost_status:"unknown",tokens:null,usage_status:"unknown",
          artifacts:{provider_attempt:true,attempt_receipt:$attempt}}'\'' \
        >> "$LEGION_TELEMETRY_DIR/$LEGION_ADAPTER_SPAN_DATE.jsonl"
    }
    legion_adapter_emit_normal_provider_span "$LEGION_ADAPTER_ATTEMPT_PATH"
    legion_adapter_write_signal_receipt 15 127 ""
    legion_adapter_emit_signal_span delayed "" || true
    [[ -d "$LEGION_ADAPTER_ATTEMPT_PATH.provider-span-emitted" ]]
    [[ "$(wc -l < "$LEGION_TELEMETRY_DIR/$(date -u +%F).jsonl" | tr -d " ")" == 1 ]]
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
        '\''{schema:"legion.span.v1",ts:"2026-01-01T00:00:01Z",run_id:"retry-span-claim",
          executor:"cursor",model:"fixture",status:"ok",duration_ms:1000,
          cost_usd:null,cost_status:"unknown",tokens:null,usage_status:"unknown",
          artifacts:{provider_attempt:true,attempt_receipt:$attempt}}'\'' \
        >> "$LEGION_TELEMETRY_DIR/$LEGION_ADAPTER_SPAN_DATE.jsonl"
    }
    legion_adapter_emit_normal_provider_span "$LEGION_ADAPTER_ATTEMPT_PATH"
    [[ -d "$LEGION_ADAPTER_ATTEMPT_PATH.provider-span-emitted" ]]
    [[ "$(wc -l < "$LEGION_TELEMETRY_DIR/$(date -u +%F).jsonl" | tr -d " ")" == 1 ]]
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
    jq -e '.terminal_status == "failed" and .failure.class == "internal"
      and (.failure.message | contains("worktree retained"))' "$art/attempt-1.json"
    [ "$(find "$art" -maxdepth 1 -name 'attempt-*.json' | wc -l | tr -d ' ')" -eq 1 ]
    [ "$(find "$art" -maxdepth 1 -name 'failure-*.json' | wc -l | tr -d ' ')" -eq 1 ]
    jq -e '.lifecycle.phase == "containment_failed"' "$LEGION_REGISTRY_DIR/$run_id.json"
    [ -d "$repo/.legion/worktrees/$run_id" ]
  done
}
