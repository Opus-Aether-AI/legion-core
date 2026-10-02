#!/usr/bin/env bash
# Shared diff-contract runner for the Pi and Hermes coding CLIs.  The provider
# processes never receive the caller's repository: each run gets a disposable
# worktree and returns only an artifact-backed patch.
set -euo pipefail

_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$_self_dir/lib/model-config.sh"
# shellcheck disable=SC1091
source "$_self_dir/lib/executor-context.sh"
# shellcheck disable=SC1091
# shellcheck source=lib/run-id.sh
source "$_self_dir/lib/run-id.sh"
# shellcheck disable=SC1091
source "$_self_dir/lib/task-scan.sh"
# shellcheck disable=SC1091
# shellcheck source=lib/adapter-contract.sh
source "$_self_dir/lib/adapter-contract.sh"
_state_lib="$_self_dir/../../legion-observability/scripts/lib/state.sh"
# shellcheck disable=SC1090
[[ -f "$_state_lib" ]] && source "$_state_lib"

ADAPTER_KIND="${LEGION_ADAPTER_KIND:?LEGION_ADAPTER_KIND must be pi or hermes}"
case "$ADAPTER_KIND" in pi|hermes) ;; *) printf 'invalid Legion adapter kind\n' >&2; exit 2 ;; esac
ADAPTER="legion-$ADAPTER_KIND"
PROVIDER_BIN="${PI_BIN:-pi}"
[[ "$ADAPTER_KIND" == hermes ]] && PROVIDER_BIN="${HERMES_BIN:-hermes}"
RUN_ID="" CHILD_PID="" CHILD_WAIT_RC=0 KEEP=0 WT="" WT_RECORD="" BRANCH="" REPO="" ART=""
SIGNAL_CHILD_PID=""
SIGNAL_LAUNCH_PENDING=""
WT_CREATED=0 BRANCH_CREATED=0
BROKER_PID="" BROKER_SOCKET_DIR="" BROKER_SOCKET="" BROKER_TOKEN="" BROKER_ROOT="" BROKER_RC=0
CONTROL_EMPTY_DIR="" SANITIZED_PROVIDER_PATH=""
SUPERVISOR_DENY_CANARY="" SUPERVISOR_ALLOW_CANARY=""
TARGET_SUPERVISOR_DENY_CANARY="" TARGET_SUPERVISOR_ALLOW_CANARY=""
WT_GIT_FILE_ID="" BASE_SHA="" SAFE_GIT_DIR="" COMMON_GIT_OBJECTS=""
PROVIDER_OUT="" PROVIDER_ERR="" PROVIDER_USAGE=""
PROVIDER_OUT_ID="" PROVIDER_ERR_ID="" PROVIDER_USAGE_ID=""
PROVIDER_LAUNCH_WRAPPER="" PROVIDER_LAUNCH_WRAPPER_ID="" PROVIDER_LAUNCH_TOKEN_FILE=""
PROVIDER_EXEC_GATE="" PROVIDER_EXEC_GATE_ID=""
PROVIDER_LAUNCH_RECEIPT="" PROVIDER_LAUNCH_TOKEN=""
FS_SANDBOX_BIN="" FS_SANDBOX_KIND=""
MAX_RUNTIME_SECONDS=""
CHILD_LEASE_DEADLINE_NS=""
PRIVATE_RUNTIME_DIR="" PI_PRIVATE_AGENT_DIR="" HERMES_PRIVATE_HOME=""
FS_SANDBOX_COMMAND=()
DELEGATE_BLOCK_PATHS=()

establish_child_lease_deadline() {
  local inherited="${LEGION_CHILD_LEASE_DEADLINE_NS:-}"
  [[ -z "$inherited" || "$inherited" =~ ^[1-9][0-9]*$ ]] \
    || die 'invalid inherited child lease deadline'
  CHILD_LEASE_DEADLINE_NS="$(python3 - "$MAX_RUNTIME_SECONDS" "$inherited" <<'PY'
import sys
import time

deadline = time.monotonic_ns() + int(sys.argv[1]) * 1_000_000_000
if sys.argv[2]:
    deadline = min(deadline, int(sys.argv[2]))
print(deadline)
PY
)" || die 'unable to establish child execution deadline'
  export LEGION_CHILD_LEASE_DEADLINE_NS="$CHILD_LEASE_DEADLINE_NS"
}

remaining_child_lease_seconds() {
  python3 - "$CHILD_LEASE_DEADLINE_NS" <<'PY'
import sys
import time

remaining = int(sys.argv[1]) - time.monotonic_ns()
print(max(0, (remaining + 999_999_999) // 1_000_000_000))
PY
}

die() { printf '%s: %s\n' "$ADAPTER" "$*" >&2; exit 2; }
note() { [[ "${QUIET:-0}" == 1 ]] || printf '%s\n' "$*" >&2; }
_run_id() { legion_new_run_id; }

with_git_worktree_lock() {
  local repo="$1"
  shift
  if declare -F legion_with_git_worktree_lock >/dev/null 2>&1; then
    legion_with_git_worktree_lock "$repo" "$@"
  else
    return 1
  fi
}

remove_owned_worktree_unlocked() {
  git -C "$REPO" worktree remove --force "$WT" || return 1
  [[ "$BRANCH_CREATED" != 1 || -z "$BRANCH" ]] || git -C "$REPO" branch -D "$BRANCH" || return 1
  git -C "$REPO" worktree prune
}

cleanup_worktree() {
  stop_handoff_broker
  if [[ -n "$BROKER_SOCKET_DIR" ]]; then
    rm -rf "$BROKER_SOCKET_DIR"
    BROKER_SOCKET_DIR=""
  fi
  if [[ -n "$PRIVATE_RUNTIME_DIR" ]]; then
    rm -rf "$PRIVATE_RUNTIME_DIR"
    PRIVATE_RUNTIME_DIR=""
  fi
  [[ "$KEEP" == 1 || "$WT_CREATED" != 1 || -z "$WT" || -z "$REPO" ]] && return 0
  if with_git_worktree_lock "$REPO" remove_owned_worktree_unlocked >/dev/null 2>&1; then
    WT_CREATED=0 BRANCH_CREATED=0
  else
    note "warning: could not acquire the shared Git worktree lock for cleanup; retained $WT"
  fi
}
stop_child() {
  [[ -n "$CHILD_PID" ]] || return 0
  kill -TERM "$CHILD_PID" 2>/dev/null || true
  local i=0
  while kill -0 "$CHILD_PID" 2>/dev/null && (( i < 140 )); do sleep 0.05; i=$((i + 1)); done
  kill -KILL "$CHILD_PID" 2>/dev/null || true
  CHILD_WAIT_RC=0
  wait "$CHILD_PID" 2>/dev/null || CHILD_WAIT_RC=$?
  CHILD_PID=""
}
stop_handoff_broker() {
  [[ -n "$BROKER_PID" ]] || return 0
  kill -TERM "$BROKER_PID" 2>/dev/null || true
  local i=0
  while kill -0 "$BROKER_PID" 2>/dev/null && (( i < 200 )); do sleep 0.05; i=$((i + 1)); done
  kill -KILL "$BROKER_PID" 2>/dev/null || true
  set +e
  wait "$BROKER_PID" 2>/dev/null
  BROKER_RC=$?
  set -e
  BROKER_PID=""
}
on_signal() {
  local signum="$1" containment_reason="" supervised_pid="${SIGNAL_CHILD_PID:-unknown}"
  local launch_evidence='' launch_status=""
  trap - INT TERM HUP
  stop_child
  stop_handoff_broker
  [[ -z "$PROVIDER_LAUNCH_TOKEN_FILE" ]] || rm -f "$PROVIDER_LAUNCH_TOKEN_FILE"
  if legion_adapter_supervisor_cleanup_failed "${ART:-}/lease.json" \
      || { [[ -f "${ART:-}/lease.json" ]] && jq -e \
        '.schema == "legion.child-execution-lease.v1" and .status == "containment_failed"' \
        "${ART:-}/lease.json" >/dev/null 2>&1; }; then
    containment_reason="$(legion_adapter_supervisor_reason "$ART/lease.json") (evidence: $ART/lease.json; supervisor pid: $supervised_pid; worktree retained: $WT_RECORD)"
  elif [[ "$CHILD_WAIT_RC" -eq 70 ]]; then
    containment_reason="child supervisor exited 70 without a valid cleanup sidecar (evidence expected: $ART/lease.json; worktree retained: $WT_RECORD)"
  elif [[ "$BROKER_RC" -eq 70 ]]; then
    containment_reason="handoff broker reported incomplete descendant cleanup (evidence: $ART/broker.err; worktree retained: $WT_RECORD)"
  fi
  if [[ "${LEGION_ADAPTER_SIGNAL_ARMED:-0}" == 1 ]]; then
    launch_evidence="$(provider_launch_status)"
    launch_status="$(jq -r '.status // "malformed"' <<<"$launch_evidence" 2>/dev/null \
      || printf malformed)"
    case "$launch_status" in
      launch_failed)
        # The authenticated inner wrapper proves that the admitted provider
        # never existed, so a late signal must not manufacture an attempt.
        legion_adapter_disarm_signal_receipt
        ;;
      started)
        legion_adapter_write_signal_receipt "$signum" "$CHILD_WAIT_RC" "${ART:-}/lease.json"
        ;;
      pending|absent)
        # The outer supervisor may have launched only the trusted wrapper. A
        # paid provider attempt is not established until that wrapper durably
        # authenticates the child PID. Missing or unresolved evidence is also
        # not a no-spend assertion: retain it as a containment failure.
        legion_adapter_disarm_signal_receipt
        KEEP=1
        if [[ -z "$containment_reason" ]]; then
          containment_reason="provider launch evidence remained $launch_status after signal cleanup (evidence: $PROVIDER_LAUNCH_RECEIPT; supervisor: $ART/lease.json; supervisor pid: $supervised_pid; worktree retained: $WT_RECORD)"
        else
          containment_reason="$containment_reason; provider launch evidence: $launch_status at $PROVIDER_LAUNCH_RECEIPT"
        fi
        ;;
      malformed)
        # Invalid or replayed evidence cannot prove no spend. Preserve the
        # conservative provider attempt while failing containment closed.
        legion_adapter_write_signal_receipt "$signum" "$CHILD_WAIT_RC" "${ART:-}/lease.json"
        KEEP=1
        if [[ -z "$containment_reason" ]]; then
          containment_reason="provider launch evidence was malformed after signal cleanup (evidence: $PROVIDER_LAUNCH_RECEIPT; supervisor: $ART/lease.json; supervisor pid: $supervised_pid; worktree retained: $WT_RECORD)"
        else
          containment_reason="$containment_reason; malformed provider launch evidence: $PROVIDER_LAUNCH_RECEIPT"
        fi
        ;;
    esac
  fi
  if [[ -n "$containment_reason" ]]; then
    KEEP=1
    legion_adapter_fail_recorded_attempt "$ART" "$ADAPTER_KIND" 1 internal 70 "$containment_reason" || true
    [[ -z "$RUN_ID" || -z "$ART" ]] || write_state containment_failed
    legion_adapter_emit_signal_span "${task:-}" "${ART:-}/lease.json" || true
    exit 70
  fi
  if ! legion_adapter_emit_signal_span "${task:-}" "${ART:-}/lease.json"; then
    KEEP=1
    containment_reason="provider attempt receipt is durable but its signal-path span publication is uncertain (evidence: $ART/attempt-$LEGION_ADAPTER_SIGNAL_ORDINAL.json; worktree retained: $WT_RECORD)"
    legion_adapter_fail_recorded_attempt "$ART" "$ADAPTER_KIND" \
      "$LEGION_ADAPTER_SIGNAL_ORDINAL" internal 70 "$containment_reason" || true
    [[ -z "$RUN_ID" || -z "$ART" ]] || write_state containment_failed
    exit 70
  fi
  [[ -z "$RUN_ID" || -z "$ART" ]] || write_state failed
  exit $((128+signum))
}
begin_signal_launch() {
  SIGNAL_LAUNCH_PENDING=""
  trap 'legion_adapter_record_launch_signal SIGNAL_LAUNCH_PENDING 2' INT
  trap 'legion_adapter_record_launch_signal SIGNAL_LAUNCH_PENDING 15' TERM
  trap 'legion_adapter_record_launch_signal SIGNAL_LAUNCH_PENDING 1' HUP
}
abort_pending_signal_launch() {
  local pending="$SIGNAL_LAUNCH_PENDING"
  [[ -n "$pending" ]] || return 0
  if ! legion_adapter_write_final_gate_no_launch "$SIGNAL_LEASE_STATUS" \
      "$MAX_RUNTIME_SECONDS" "$pending"; then
    trap - INT TERM HUP
    KEEP=1
    note "provider launch cancelled before Popen, but no-launch evidence could not be persisted; retaining containment"
    [[ -z "${RUN_ID:-}" || -z "${ART:-}" ]] || write_state containment_failed
    [[ -z "${PRESET_RUN_ID:-}" ]] || legion_disarm_adopted_run_guard
    exit 70
  fi
  finish_signal_launch
}
finish_signal_launch() {
  local pending="$SIGNAL_LAUNCH_PENDING"
  SIGNAL_LAUNCH_PENDING=""
  trap 'on_signal 2' INT; trap 'on_signal 15' TERM; trap 'on_signal 1' HUP
  [[ -z "$pending" ]] || on_signal "$pending"
}
trap 'declare -F legion_terminalize_adopted_run_on_exit >/dev/null 2>&1 && legion_terminalize_adopted_run_on_exit; cleanup_worktree' EXIT
trap 'on_signal 2' INT
trap 'on_signal 15' TERM
trap 'on_signal 1' HUP

resolve_state() {
  if declare -F legion_resolve_state >/dev/null 2>&1; then legion_resolve_state "$1"; else
    export LEGION_STATE_ROOT="${LEGION_STATE_ROOT:-$HOME/.legion/projects/default}"
    export LEGION_TELEMETRY_DIR="${LEGION_TELEMETRY_DIR:-$LEGION_STATE_ROOT/spans}"
  fi
}
write_state() {
  local phase="$1"
  [[ -n "${PRESET_RUN_ID:-}" ]] || return 0
  legion_write_adapter_run_state "$phase" "$RUN_ID" "$REPO" "$ART" "$WT_RECORD" "$BRANCH" "$MODEL" "$SANDBOX" "$BASE" "$ARCHETYPE" "${THINKING:-}"
}

write_pre_provider_no_launch_lease() {
  local reason="$1" lease="$ART/lease.json" temp=""
  temp="$(mktemp "$ART/.lease.json.tmp.XXXXXX")" || return 1
  jq -cn --arg reason "$reason" --argjson runtime "$MAX_RUNTIME_SECONDS" '
    {schema:"legion.child-execution-lease.v1",status:"launch_failed",
     reason:$reason,max_runtime_seconds:$runtime}
  ' > "$temp" || { rm -f "$temp"; return 1; }
  chmod 600 "$temp" || { rm -f "$temp"; return 1; }
  if ! legion_adapter_durable_exclusive_link "$temp" "$lease"; then
    rm -f "$temp"
    return 1
  fi
}

terminalize_pre_provider_timeout() {
  local timeout_reason="$1" terminal_status=timed_out terminal_reason="$1"
  local report="$WT_RECORD" diff="$ART/diff.patch" last="$ART/last-message.txt"

  # A timeout before the provider exists is a timed-out adapter run, but its
  # lease evidence must use the strict launch_failed shape understood by every
  # adapter. It deliberately has no child_exit_code or provider attempt.
  if ! write_pre_provider_no_launch_lease "$timeout_reason"; then
    terminal_status=containment_failed
    terminal_reason="unable to persist authenticated no-launch lease evidence; worktree retained: $WT_RECORD"
    KEEP=1
  else
    stop_handoff_broker
    if [[ "$BROKER_RC" -eq 70 ]]; then
      terminal_status=containment_failed
      terminal_reason="handoff broker reported incomplete descendant cleanup (evidence: $ART/broker.err; worktree retained: $WT_RECORD)"
      KEEP=1
    else
      # Lease expiry overrides --keep, matching a post-launch timed_out run.
      KEEP=0
      cleanup_worktree
      if [[ "$WT_CREATED" == 1 ]]; then
        terminal_status=containment_failed
        terminal_reason="unable to remove the expired child worktree; worktree retained: $WT_RECORD"
        KEEP=1
      else
        report='(removed; child execution lease expired before provider launch)'
      fi
    fi
  fi

  : > "$diff"
  printf '%s\n' "$terminal_reason" > "$last"
  write_state "$terminal_status"
  [[ -z "$PRESET_RUN_ID" ]] || legion_disarm_adopted_run_guard
  jq -cn --arg run "$RUN_ID" --arg status "$terminal_status" \
    --arg executor "$ADAPTER_KIND" --arg model "$MODEL" --arg result "$terminal_reason" \
    --arg worktree "$report" --arg diff "$diff" --arg last "$last" \
    --arg preflight "$LEGION_ADAPTER_PREFLIGHT_PATH" --arg lease "$ART/lease.json" '
    {run_id:$run,status:$status,executor:$executor,model:$model,result:$result,
     worktree:$worktree,diff_path:$diff,last_message_path:$last,
     usage:null,tokens:null,usage_status:"not_applicable",
     cost_usd:null,cost_status:"not_applicable",provider_exit:null,
     preflight_receipt:$preflight,attempt_receipt:null,failure_receipt:null,
     lease_receipt:$lease,provider_launch_receipt:null,reason:$result}
  '
  [[ "$terminal_status" != containment_failed ]] || exit 70
  exit 1
}

terminalize_pre_provider_launch_failure() {
  local launch_reason="$1" terminal_status=failed terminal_reason="$1"
  local report='(not created; provider disappeared before launch)' diff="$ART/diff.patch"
  local last="$ART/last-message.txt"

  if ! write_pre_provider_no_launch_lease "$launch_reason"; then
    terminal_status=containment_failed
    terminal_reason="unable to persist authenticated no-launch lease evidence; worktree retained: $WT_RECORD"
    report="$WT_RECORD"
    KEEP=1
  fi
  : > "$diff"
  printf '%s\n' "$terminal_reason" > "$last"
  write_state "$terminal_status"
  [[ -z "$PRESET_RUN_ID" ]] || legion_disarm_adopted_run_guard
  jq -cn --arg run "$RUN_ID" --arg status "$terminal_status" \
    --arg executor "$ADAPTER_KIND" --arg model "$MODEL" --arg result "$terminal_reason" \
    --arg worktree "$report" --arg diff "$diff" --arg last "$last" \
    --arg preflight "$LEGION_ADAPTER_PREFLIGHT_PATH" --arg lease "$ART/lease.json" '
    {run_id:$run,status:$status,executor:$executor,model:$model,result:$result,
     worktree:$worktree,diff_path:$diff,last_message_path:$last,
     usage:null,tokens:null,usage_status:"not_applicable",
     cost_usd:null,cost_status:"not_applicable",provider_exit:null,
     preflight_receipt:$preflight,attempt_receipt:null,failure_receipt:null,
     lease_receipt:$lease,provider_launch_receipt:null,reason:$result}
  '
  [[ "$terminal_status" != containment_failed ]] || exit 70
  exit 1
}
emit_span() {
  local status="$1" duration="$2" cost="$3" usage="$4" task="$5" artifacts="$6"
  local usage_status="${7:-known}" cost_status="${8:-known}"
  local trace_bin="$_self_dir/../../legion-observability/bin/legion-trace"
  if [[ ! -x "$trace_bin" ]]; then
    note "warning: canonical legion-trace emitter is unavailable; span was not emitted"
    return 0
  fi
  if ! (cd "$REPO" && "$trace_bin" emit \
      --executor "$ADAPTER_KIND" --model "${SPAN_PROVIDER_MODEL:-$MODEL}" --status "$status" \
      --run-id "$RUN_ID" --trace-id "${LEGION_TRACE_ID:-$RUN_ID}" \
      --parent-id "${LEGION_PARENT_ID:-}" --archetype "$ARCHETYPE" \
      --duration-ms "$duration" --cost "$cost" --cost-status "$cost_status" --task "$task" \
      --tokens "$usage" --usage-status "$usage_status" --artifacts "$artifacts") \
      > /dev/null 2>>"$ART/telemetry.err"; then
    note "warning: canonical Legion span emission failed; inspect $ART/telemetry.err"
  fi
}

pi_usage() {
  local file="$1"
  [[ -s "$file" ]] || { printf '{}'; return 0; }
  python3 "$_self_dir/lib/provider-usage.py" pi "$file"
}
pi_cost() {
  local file="$1"
  [[ -s "$file" ]] || { printf 0; return 0; }
  jq -s -r '
    ([.[] | select(.type == "message_end" and .message.role == "assistant") | .message.usage.cost.total]
      + [.[] | select(.type == "compaction_end" and .aborted == false and .result.usage != null) | .result.usage.cost.total])
    | add // 0' \
    "$file" 2>/dev/null || printf 0
}
pi_cost_known() {
  local file="$1"
  [[ -s "$file" ]] || return 1
  jq -s -e '
    def valid_cost:
      type == "number"
      and (isnan | not)
      and (isinfinite | not)
      and . >= 0;
    ([.[] | select(.type == "message_end" and .message.role == "assistant") | .message.usage.cost.total]
      + [.[] | select(.type == "compaction_end" and .aborted == false and .result.usage != null) | .result.usage.cost.total]) as $costs
    | ($costs | length) > 0 and all($costs[]; valid_cost)
  ' "$file" >/dev/null 2>&1
}
pi_result() {
  local file="$1"
  jq -s -r '
    ([.[] | select(.type == "agent_end")] | last) as $end
    | if $end == null then empty else
        ([$end.messages[]? | select(.role == "assistant")] | last) as $m
        | ($m.content // "") | if type=="string" then . else [ .[]? | select(.type=="text") | .text ] | join("") end
      end' "$file" 2>/dev/null || true
}
pi_terminal_ok() {
  jq -s -e '
    def nn: type == "number" and . >= 0;
    def nni: nn and floor == .;
    def valid_usage:
      type == "object"
      and (.input | nni)
      and (.output | nni)
      and (.cacheRead | nni)
      and (.cacheWrite | nni)
      and ((.reasoning == null) or (.reasoning | nni))
      and ((.reasoning // 0) <= .output)
      and (.totalTokens | nni)
      and (.cost | type == "object")
      and (.cost.input | nn)
      and (.cost.output | nn)
      and (.cost.cacheRead | nn)
      and (.cost.cacheWrite | nn)
      and (.cost.total | nn);
    ([.[] | select(.type == "agent_end")] | last) as $end
    | [$end.messages[]? | select(.role == "assistant")] as $messages
    | ($messages | last) as $final
    | [.[] | select(.type == "message_end" and .message.role == "assistant") | .message] as $calls
    | [.[] | select(.type == "compaction_end" and .aborted == false and .result.usage != null) | .result.usage] as $compactions
    | all(.[]; type == "object")
      and (all(.[]; .type? != "error"))
      and ($end | type == "object")
      and ($end.willRetry == false)
      and ($messages | length > 0)
      and ($calls | length > 0)
      and all($calls[];
        (.provider | type == "string" and length > 0)
        and (.model | type == "string" and length > 0)
        and (.stopReason | IN("stop", "length", "toolUse", "error", "aborted"))
        and (.usage | valid_usage))
      and all($compactions[]; valid_usage)
      and ($final.stopReason == "stop" or $final.stopReason == "length")
  ' "$1" >/dev/null 2>&1 || return 1
  python3 "$_self_dir/lib/provider-usage.py" pi-total "$1"
}
pi_actual_model() {
  jq -s -r '
    ([.[] | select(.type == "agent_end")] | last) as $end
    | ([$end.messages[]? | select(.role == "assistant")] | last) as $message
    | ($message.provider // "") as $provider
    | (if (($message.responseModel // "") | length) > 0 then $message.responseModel else ($message.model // "") end) as $model
    | if $model == "" then empty
      elif $provider == "" or ($model | startswith($provider + "/")) then $model
      else $provider + "/" + $model end' "$1" 2>/dev/null || true
}
hermes_usage() {
  local file="$1"
  [[ -s "$file" ]] || { printf '{}'; return 0; }
  python3 "$_self_dir/lib/provider-usage.py" hermes "$file"
}
hermes_cost() {
  local file="$1"
  [[ -s "$file" ]] || { printf 0; return 0; }
  jq -r '.estimated_cost_usd' "$file" 2>/dev/null || printf 0
}

# The span schema requires cost_usd to be a non-null number, so a missing or
# malformed cost necessarily becomes 0 -- which is indistinguishable from
# genuinely free execution. Hermes already reports cost_status and cost_source
# (the terminal validator above checks both), so carry them alongside the number
# and let a reader tell "free" from "we do not know".
hermes_cost_provenance() {
  local file="$1"
  if [[ ! -s "$file" ]]; then
    printf '{"cost_status":"unknown","cost_source":"none"}'
    return 0
  fi
  jq -c '{cost_status: (.cost_status // "unknown"),
          cost_source: (.cost_source // "none")}' "$file" 2>/dev/null \
    || printf '{"cost_status":"unknown","cost_source":"none"}'
}
hermes_result() {
  cat "$1"
}
hermes_terminal_ok() {
  local out_file="$1" usage_file="$2"
  grep -q '[^[:space:]]' "$out_file" || return 1
  jq -e '
    def nn: type == "number" and . >= 0;
    def nni: nn and floor == .;
    type == "object"
    and .completed == true
    and .failed == false
    and (.input_tokens | nni)
    and (.output_tokens | nni)
    and (.cache_read_tokens | nni)
    and (.cache_write_tokens | nni)
    and (.reasoning_tokens | nni)
    and .reasoning_tokens <= .output_tokens
    and (.total_tokens | nni)
    and (.api_calls | nni and . > 0)
    and (.estimated_cost_usd | nn)
    and (.cost_status | IN("actual", "estimated", "included", "unknown"))
    and (.cost_source | IN("provider_cost_api", "provider_generation_api", "provider_models_api", "official_docs_snapshot", "user_override", "custom_contract", "none"))
    and (.model | type == "string" and length > 0)
    and (.provider | type == "string" and length > 0)
    and (.session_id | type == "string" and length > 0)
    and ((.service_tier == null) or (.service_tier | type == "string"))
    and (has("failure") | not)
  ' "$usage_file" >/dev/null 2>&1 || return 1
  python3 "$_self_dir/lib/provider-usage.py" hermes-total "$usage_file"
}
hermes_actual_model() { jq -r '.model // empty' "$1" 2>/dev/null || true; }
provider_ready() {
  local env_prefix resolved
  env_prefix="$(printf '%s' "$ADAPTER_KIND" | tr '[:lower:]' '[:upper:]')"
  resolved="$(command -v "$PROVIDER_BIN" 2>/dev/null || true)"
  [[ -n "$resolved" ]] || return 127
  PROVIDER_BIN="$resolved"
  [[ "$MODEL" != "$ADAPTER_KIND-default" ]] || die "no concrete model configured: set ${env_prefix}_MODEL or update ${ADAPTER_KIND}_default in models.toml."
}

prepare_delegate_boundary() {
  local candidate resolved dir path_tail=""
  DELEGATE_BLOCK_PATHS=()
  while IFS= read -r candidate; do
    [[ -n "$candidate" && "$candidate" != "$ART/broker-bin/legion-delegate" ]] || continue
    DELEGATE_BLOCK_PATHS+=("$candidate")
    resolved="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$candidate" 2>/dev/null || true)"
    [[ -z "$resolved" || "$resolved" == "$candidate" ]] || DELEGATE_BLOCK_PATHS+=("$resolved")
  done < <(
    type -a -p legion-delegate 2>/dev/null || true
    printf '%s\n' "$_self_dir/../bin/legion-delegate" "$WT/legion-router/bin/legion-delegate" "$WT/legion-router/scripts/delegate.sh"
  )

  IFS=: read -r -a path_entries <<<"$PATH"
  for dir in "${path_entries[@]}"; do
    [[ -n "$dir" ]] || dir=.
    [[ ! -e "$dir/legion-delegate" ]] || continue
    path_tail="${path_tail:+$path_tail:}$dir"
  done
  SANITIZED_PROVIDER_PATH="$ART/broker-bin${path_tail:+:$path_tail}"
}
valid_thinking() { case "$1" in off|minimal|low|medium|high|xhigh|max) return 0;; *) return 1;; esac; }

resolve_fs_sandbox() {
  local requested="${LEGION_FS_SANDBOX_BIN:-}" candidate=""
  if [[ -n "$requested" ]]; then
    if [[ "$requested" == */* ]]; then
      [[ -x "$requested" ]] || die "filesystem sandbox is unavailable or not executable: $requested"
      candidate="$requested"
    else
      candidate="$(command -v "$requested" 2>/dev/null || true)"
      [[ -n "$candidate" ]] || die "filesystem sandbox is unavailable: $requested"
    fi
  elif command -v sandbox-exec >/dev/null 2>&1; then
    candidate="$(command -v sandbox-exec)"
  elif command -v bwrap >/dev/null 2>&1; then
    candidate="$(command -v bwrap)"
  elif command -v bubblewrap >/dev/null 2>&1; then
    candidate="$(command -v bubblewrap)"
  else
    die "no filesystem write sandbox is available (macOS: sandbox-exec; Linux: install bubblewrap/bwrap)"
  fi
  FS_SANDBOX_BIN="$candidate"
  case "$(basename "$candidate")" in
    sandbox-exec) FS_SANDBOX_KIND="sandbox-exec" ;;
    bwrap|bubblewrap) FS_SANDBOX_KIND=bwrap ;;
    *) die "unsupported filesystem sandbox executable: $candidate" ;;
  esac
}

scheme_escape() {
  [[ "$1" != *$'\n'* && "$1" != *$'\r'* ]] || die 'filesystem sandbox path contains a newline'
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

build_fs_sandbox_command() {
  FS_SANDBOX_COMMAND=()
  if [[ "$FS_SANDBOX_KIND" == sandbox-exec ]]; then
    local profile="$ART/filesystem.sb" escaped_wt escaped_tmp escaped_cache escaped_private escaped_out escaped_err escaped_usage escaped_broker escaped_supervisor_deny blocked escaped_blocked
    escaped_wt="$(scheme_escape "$WT")"
    escaped_tmp="$(scheme_escape "$ART/tmp")"
    escaped_cache="$(scheme_escape "$ART/cache")"
    escaped_private="$(scheme_escape "$PRIVATE_RUNTIME_DIR")"
    escaped_out="$(scheme_escape "$PROVIDER_OUT")"
    escaped_err="$(scheme_escape "$PROVIDER_ERR")"
    escaped_usage="$(scheme_escape "$PROVIDER_USAGE")"
    escaped_broker="$(scheme_escape "$BROKER_SOCKET")"
    escaped_supervisor_deny="$(scheme_escape "$SUPERVISOR_DENY_CANARY")"
    printf '%s\n' \
      '(version 1)' \
      '(allow default)' \
      '(deny file-write*)' \
      '(deny signal)' \
      '(deny process-info*)' \
      "(deny file-read* (literal \"$escaped_supervisor_deny\"))" \
      '(deny network-outbound (remote unix-socket))' \
      '(allow network-outbound (remote unix-socket (path-literal "/private/var/run/mDNSResponder")))' \
      "(allow network-outbound (remote unix-socket (path-literal \"$escaped_broker\")))" \
      "(allow file-write* (literal \"/dev/null\") (literal \"/dev/tty\") (subpath \"$escaped_wt\") (subpath \"$escaped_tmp\") (subpath \"$escaped_cache\") (subpath \"$escaped_private\") (literal \"$escaped_out\") (literal \"$escaped_err\") (literal \"$escaped_usage\"))" \
      > "$profile"
    for blocked in "${DELEGATE_BLOCK_PATHS[@]}"; do
      [[ "$blocked" != "$ART/broker-bin/legion-delegate" ]] || continue
      escaped_blocked="$(scheme_escape "$blocked")"
      printf '(deny process-exec (literal "%s"))\n' "$escaped_blocked" >> "$profile"
      # An absolute script can otherwise bypass process-exec by being handed to
      # an interpreter. Hide installed copies outside the generated worktree;
      # worktree files remain readable so a Legion source task can edit them.
      if [[ "$blocked" != "$WT"/* ]]; then
        printf '(deny file-read* (literal "%s"))\n' "$escaped_blocked" >> "$profile"
      fi
    done
    FS_SANDBOX_COMMAND=("$FS_SANDBOX_BIN" -f "$profile")
  else
    FS_SANDBOX_COMMAND=("$FS_SANDBOX_BIN" --die-with-parent --new-session --unshare-pid \
      --ro-bind / / --bind "$WT" "$WT" \
      --bind "$ART/tmp" "$ART/tmp" --bind "$ART/cache" "$ART/cache" \
      --bind "$PRIVATE_RUNTIME_DIR" "$PRIVATE_RUNTIME_DIR" \
      --bind "$PROVIDER_OUT" "$PROVIDER_OUT" --bind "$PROVIDER_ERR" "$PROVIDER_ERR" \
      --bind "$PROVIDER_USAGE" "$PROVIDER_USAGE")
    FS_SANDBOX_COMMAND+=(--tmpfs /run)
    local control_dir
    for control_dir in \
      /var/run "$HOME/.docker/run" "$HOME/.docker/desktop" "$HOME/.local/share/containers" \
      "$HOME/.colima" "$HOME/.orbstack" "$HOME/Library/Containers/com.docker.docker" \
      "$HOME/Library/Group Containers/group.com.docker"; do
      [[ -d "$control_dir" && ! -L "$control_dir" ]] || continue
      FS_SANDBOX_COMMAND+=(--ro-bind "$CONTROL_EMPTY_DIR" "$control_dir")
    done
    local blocked
    for blocked in "${DELEGATE_BLOCK_PATHS[@]}"; do
      [[ -e "$blocked" && "$blocked" != "$ART/broker-bin/legion-delegate" ]] || continue
      FS_SANDBOX_COMMAND+=(--ro-bind "$ART/broker-bin/legion-delegate" "$blocked")
    done
    FS_SANDBOX_COMMAND+=(--proc /proc --chdir "$WT" --)
  fi
}

file_identity() {
  if stat -f '%d:%i' "$1" >/dev/null 2>&1; then stat -f '%d:%i' "$1"; else stat -c '%d:%i' "$1"; fi
}

verify_provider_file() {
  local file="$1" expected="$2"
  [[ -f "$file" && ! -L "$file" && "$(file_identity "$file" 2>/dev/null || true)" == "$expected" ]]
}

provider_launch_status() {
  [[ -n "$PROVIDER_LAUNCH_RECEIPT" && -n "$PROVIDER_LAUNCH_TOKEN" ]] || {
    printf '{"status":"absent","reason":null}'
    return 0
  }
  if [[ ! -e "$PROVIDER_LAUNCH_RECEIPT" && ! -L "$PROVIDER_LAUNCH_RECEIPT" ]]; then
    printf '{"status":"absent","reason":null}'
    return 0
  fi
  [[ -f "$PROVIDER_LAUNCH_RECEIPT" && ! -L "$PROVIDER_LAUNCH_RECEIPT" ]] || {
    printf '{"status":"malformed","reason":null}'
    return 0
  }
  python3 - "$PROVIDER_LAUNCH_RECEIPT" "$PROVIDER_LAUNCH_TOKEN" "$PROVIDER_BIN" <<'PY' \
    2>/dev/null || printf '{"status":"malformed","reason":null}'
import hashlib
import hmac
import json
import os
import stat
import sys

path, token, executable = sys.argv[1:]
flags = os.O_RDONLY
if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW
if hasattr(os, "O_NONBLOCK"):
    flags |= os.O_NONBLOCK
descriptor = os.open(path, flags)
try:
    opened = os.fstat(descriptor)
    if not stat.S_ISREG(opened.st_mode) or opened.st_nlink != 1 or opened.st_size > 4096:
        raise SystemExit(1)
    path_stat = os.stat(path, follow_symlinks=False)
    if (path_stat.st_dev, path_stat.st_ino) != (opened.st_dev, opened.st_ino):
        raise SystemExit(1)
    # Read one byte beyond the contract maximum so concurrent growth cannot be
    # mistaken for an accepted prefix. This is the only provider-controlled
    # read in the parent-side launch classifier.
    chunks = []
    total = 0
    while total <= 4096:
        chunk = os.read(descriptor, min(4096, 4097 - total))
        if not chunk:
            break
        chunks.append(chunk)
        total += len(chunk)
    raw = b"".join(chunks)
    closed = os.fstat(descriptor)
    path_stat = os.stat(path, follow_symlinks=False)
    if (
        len(raw) > 4096
        or not stat.S_ISREG(closed.st_mode)
        or closed.st_nlink != 1
        or closed.st_size > 4096
        or (closed.st_dev, closed.st_ino) != (opened.st_dev, opened.st_ino)
        or (path_stat.st_dev, path_stat.st_ino) != (opened.st_dev, opened.st_ino)
        or closed.st_mtime_ns != opened.st_mtime_ns
        or closed.st_ctime_ns != opened.st_ctime_ns
    ):
        raise SystemExit(1)
finally:
    os.close(descriptor)
value = json.loads(raw)
if not isinstance(value, dict):
    raise SystemExit(1)
status = value.get("status")
expected_keys = {
    "pending": {"auth", "executable_path", "schema", "status"},
    "started": {"auth", "executable_path", "provider_pid", "schema", "status"},
    "launch_failed": {"auth", "errno", "executable_path", "reason", "schema", "status"},
}.get(status)
if expected_keys is None or set(value) != expected_keys:
    raise SystemExit(1)
if value.get("schema") != "legion.provider-launch.v1" or value.get("executable_path") != executable:
    raise SystemExit(1)
if status == "started" and (type(value.get("provider_pid")) is not int or value["provider_pid"] < 1):
    raise SystemExit(1)
if status == "launch_failed" and (
    not isinstance(value.get("reason"), str) or not value["reason"]
    or type(value.get("errno")) is not int or value["errno"] < 1
):
    raise SystemExit(1)
auth = value.pop("auth")
if not isinstance(auth, str) or len(auth) != 64:
    raise SystemExit(1)
encoded = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
expected = hmac.new(token.encode(), encoded, hashlib.sha256).hexdigest()
if not hmac.compare_digest(auth, expected):
    raise SystemExit(1)
print(
    json.dumps(
        {
            "status": status,
            "reason": value.get("reason") if status == "launch_failed" else None,
            "errno": value.get("errno") if status == "launch_failed" else None,
        },
        separators=(",", ":"),
    ),
    end="",
)
PY
}

provider_launch_reason() {
  jq -r '.reason // "provider launch failed before process creation"' \
    <<<"$1" 2>/dev/null \
    || printf 'provider launch failed before process creation'
}

prepare_provider_files() {
  PROVIDER_OUT="$ART/$ADAPTER_KIND.out.jsonl"
  PROVIDER_ERR="$ART/$ADAPTER_KIND.err"
  PROVIDER_USAGE="$ART/$ADAPTER_KIND.usage.json"
  PROVIDER_LAUNCH_WRAPPER="$ART/provider-launch-wrapper.py"
  PROVIDER_EXEC_GATE="$ART/child-exec-gate.py"
  PROVIDER_LAUNCH_RECEIPT="$ART/tmp/provider-launch.json"
  PROVIDER_LAUNCH_TOKEN_FILE="$ART/tmp/provider-launch.token"
  rm -f "$PROVIDER_LAUNCH_RECEIPT" "$PROVIDER_LAUNCH_TOKEN_FILE"
  : > "$PROVIDER_OUT"
  : > "$PROVIDER_ERR"
  : > "$PROVIDER_USAGE"
  : > "$ART/telemetry.err"
  cp "$_self_dir/lib/child-exec-gate.py" "$PROVIDER_EXEC_GATE"
  chmod 500 "$PROVIDER_EXEC_GATE"
  cat > "$PROVIDER_LAUNCH_WRAPPER" <<'PY'
#!/usr/bin/env python3
"""Supervise the admitted provider and attest its exact launch boundary."""

import hashlib
import hmac
import errno
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import tempfile
import time


def write_receipt(receipt: Path, payload: dict, token: str) -> None:
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    payload = {**payload, "auth": hmac.new(token.encode(), encoded, hashlib.sha256).hexdigest()}
    descriptor, temporary = tempfile.mkstemp(
        prefix=f".{receipt.name}.", suffix=".tmp", dir=receipt.parent
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as destination:
            json.dump(payload, destination, separators=(",", ":"))
            destination.write("\n")
            destination.flush()
            os.fsync(destination.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, receipt)
        directory = os.open(receipt.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def main() -> int:
    receipt = Path(sys.argv[1])
    token_path = Path(sys.argv[2])
    exec_gate = Path(sys.argv[3])
    command = sys.argv[5:]
    if token_path.is_symlink() or not token_path.is_file():
        return 126
    token = token_path.read_text(encoding="ascii").strip()
    token_path.unlink()
    if not token or not command:
        return 126
    base = {
        "schema": "legion.provider-launch.v1",
        "executable_path": command[0],
    }
    inherited_deadline = os.environ.get("LEGION_CHILD_LEASE_DEADLINE_NS", "")
    try:
        deadline_ns = int(inherited_deadline) if inherited_deadline else None
        if deadline_ns is not None and deadline_ns <= 0:
            raise ValueError("nonpositive inherited deadline")
    except ValueError:
        write_receipt(receipt, {**base, "status": "launch_failed",
                                "reason": "invalid inherited child lease deadline",
                                "errno": errno.EINVAL}, token)
        return 126
    child = None
    started_durable = False
    pending_signal = None
    authorization_fd = -1

    def forward(signum: int, _frame: object) -> None:
        nonlocal pending_signal, authorization_fd
        if child is not None and started_durable:
            try:
                child.send_signal(signum)
            except ProcessLookupError:
                pass
        else:
            pending_signal = signum
            if authorization_fd >= 0:
                try:
                    os.close(authorization_fd)
                except OSError:
                    pass
                authorization_fd = -1

    # Install handlers before publishing pending. A signal before Popen then
    # becomes authenticated no-launch; a signal during Popen is remembered and
    # forwarded only after the durable started receipt exists.
    for caught in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(caught, forward)
    write_receipt(receipt, {**base, "status": "pending"}, token)
    launch_signals = {signal.SIGINT, signal.SIGTERM, signal.SIGHUP}
    gate_read = error_read = error_write = -1
    previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, launch_signals)
    try:
        if pending_signal is not None:
            reason = "provider launch cancelled before process creation"
            write_receipt(receipt, {
                **base,
                "status": "launch_failed",
                "reason": reason,
                "errno": errno.ECANCELED,
            }, token)
            return 128 + pending_signal
        pending_launch_signals = signal.sigpending() & launch_signals
        if pending_launch_signals:
            signum = min(pending_launch_signals)
            reason = "provider launch cancelled before process creation"
            write_receipt(receipt, {
                **base,
                "status": "launch_failed",
                "reason": reason,
                "errno": errno.ECANCELED,
            }, token)
            return 128 + signum
        try:
            gate_read, authorization_fd = os.pipe()
            error_read, error_write = os.pipe()
            child = subprocess.Popen(
                [sys.executable, str(exec_gate), str(gate_read), str(error_write), *command],
                env=os.environ,
                pass_fds=(gate_read, error_write),
                # Keep the parent's launch decision atomic without leaking its
                # temporary blocked-signal mask into the provider after exec.
                preexec_fn=lambda: signal.pthread_sigmask(
                    signal.SIG_SETMASK, previous_mask
                ),
            )
        except OSError as error:
            reason = f"provider launch failed before process creation: {error}"
            write_receipt(receipt, {
                **base,
                "status": "launch_failed",
                "reason": reason,
                "errno": error.errno or 1,
            }, token)
            print(f"legion provider launcher: {reason}", file=sys.stderr)
            return 127 if error.errno == 2 else 126
        finally:
            for descriptor in (gate_read, error_write):
                if descriptor >= 0:
                    os.close(descriptor)
            if child is None:
                for descriptor in (authorization_fd, error_read):
                    if descriptor >= 0:
                        os.close(descriptor)
                authorization_fd = -1
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
    if deadline_ns is not None and time.monotonic_ns() >= deadline_ns:
        if authorization_fd >= 0:
            os.close(authorization_fd)
            authorization_fd = -1
        os.close(error_read)
        child.wait(timeout=2)
        write_receipt(receipt, {**base, "status": "launch_failed",
                                "reason": "inherited child lease deadline expired before provider authorization",
                                "errno": errno.ETIMEDOUT}, token)
        return 124
    if pending_signal is not None or authorization_fd < 0:
        if authorization_fd >= 0:
            os.close(authorization_fd)
            authorization_fd = -1
        os.close(error_read)
        child.wait(timeout=2)
        if pending_signal is None:
            raise RuntimeError("provider authorization gate closed without a signal")
        reason = "provider launch cancelled before process creation"
        write_receipt(receipt, {**base, "status": "launch_failed",
                                "reason": reason, "errno": errno.ECANCELED}, token)
        return 128 + pending_signal
    try:
        os.write(authorization_fd, b"G")
    except OSError:
        os.close(error_read)
        child.wait(timeout=2)
        if pending_signal is None:
            raise RuntimeError("provider authorization gate failed without a signal")
        reason = "provider launch cancelled before process creation"
        write_receipt(receipt, {**base, "status": "launch_failed",
                                "reason": reason, "errno": errno.ECANCELED}, token)
        return 128 + pending_signal
    finally:
        if authorization_fd >= 0:
            os.close(authorization_fd)
            authorization_fd = -1
    try:
        if not select.select([error_read], [], [], 2)[0]:
            raise RuntimeError("provider exec gate did not confirm launch")
        launch_error = os.read(error_read, 4097)
    finally:
        os.close(error_read)
    if launch_error:
        detail = json.loads(launch_error)
        reason = f"provider launch failed before process creation: {detail['reason']}"
        write_receipt(receipt, {**base, "status": "launch_failed",
                                "reason": reason, "errno": detail["errno"]}, token)
        return 127 if detail["errno"] == errno.ENOENT else 126
    write_receipt(receipt, {**base, "status": "started", "provider_pid": child.pid}, token)
    started_durable = True
    if pending_signal is not None:
        signum = pending_signal
        pending_signal = None
        try:
            child.send_signal(signum)
        except ProcessLookupError:
            pass
    return child.wait()


if __name__ == "__main__":
    raise SystemExit(main())
PY
  chmod 500 "$PROVIDER_LAUNCH_WRAPPER"
  PROVIDER_OUT_ID="$(file_identity "$PROVIDER_OUT")"
  PROVIDER_ERR_ID="$(file_identity "$PROVIDER_ERR")"
  PROVIDER_USAGE_ID="$(file_identity "$PROVIDER_USAGE")"
  PROVIDER_LAUNCH_WRAPPER_ID="$(file_identity "$PROVIDER_LAUNCH_WRAPPER")"
  PROVIDER_EXEC_GATE_ID="$(file_identity "$PROVIDER_EXEC_GATE")"
}

copy_private_runtime_file() {
  local source="$1" destination="$2" size=""
  [[ -f "$source" && ! -L "$source" ]] || return 0
  if stat -f '%z' "$source" >/dev/null 2>&1; then size="$(stat -f '%z' "$source")"; else size="$(stat -c '%s' "$source")"; fi
  [[ "$size" =~ ^[0-9]+$ && "$size" -le 16777216 ]] || return 0
  mkdir -p "${destination%/*}"
  cp "$source" "$destination"
  chmod 600 "$destination"
}

prepare_private_provider_runtime() {
  local source name
  PRIVATE_RUNTIME_DIR="$(mktemp -d "${TMPDIR:-/tmp}/legion-provider-runtime.XXXXXX")" \
    || die 'unable to allocate private provider runtime'
  chmod 700 "$PRIVATE_RUNTIME_DIR"
  if [[ "$ADAPTER_KIND" == pi ]]; then
    PI_PRIVATE_AGENT_DIR="$PRIVATE_RUNTIME_DIR/pi-agent"
    mkdir -p "$PI_PRIVATE_AGENT_DIR"
    source="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
    for name in auth.json settings.json models.json keybindings.json; do
      copy_private_runtime_file "$source/$name" "$PI_PRIVATE_AGENT_DIR/$name"
    done
  else
    HERMES_PRIVATE_HOME="$PRIVATE_RUNTIME_DIR/hermes"
    mkdir -p "$HERMES_PRIVATE_HOME"
    source="${HERMES_HOME:-$HOME/.hermes}"
    for name in .env auth.json; do
      copy_private_runtime_file "$source/$name" "$HERMES_PRIVATE_HOME/$name"
    done
  fi
}

safe_git() {
  env GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    GIT_OBJECT_DIRECTORY="$SAFE_GIT_DIR/objects" GIT_ALTERNATE_OBJECT_DIRECTORIES="$COMMON_GIT_OBJECTS" \
    GIT_INDEX_FILE="$SAFE_GIT_DIR/index" \
    git --git-dir="$SAFE_GIT_DIR" --work-tree="$WT" "$@"
}

copy_safe_git_setting() {
  local key="$1" pattern="$2" value=""
  value="$(git -C "$REPO" config --get "$key" 2>/dev/null || true)"
  [[ -n "$value" ]] || return 0
  [[ "$value" =~ $pattern ]] || die "unsupported trusted Git setting $key=$value"
  git config --file "$SAFE_GIT_DIR/config" "$key" "$value"
}

trusted_attributes_have_filters() {
  safe_git ls-files --cached --others --exclude-standard -z \
    | safe_git check-attr --stdin -z filter \
    | python3 -c 'import sys
parts = sys.stdin.buffer.read().split(b"\0")
if parts and parts[-1] == b"": parts.pop()
if len(parts) % 3: raise SystemExit(2)
raise SystemExit(any(parts[i + 2] not in (b"unspecified", b"unset") for i in range(0, len(parts), 3)))'
}

reject_unrepresented_attribute_sources() {
  local common_git_dir="$1" worktree_git_dir attributes_file
  worktree_git_dir="$(git -C "$WT" rev-parse --absolute-git-dir 2>/dev/null)" \
    || die 'unable to resolve worktree Git directory for attributes'
  attributes_file="$(git -C "$WT" config --path --get core.attributesFile 2>/dev/null || true)"
  [[ -z "$attributes_file" ]] \
    || die 'Git core.attributesFile is unsupported by isolated diff capture; refusing to change repository semantics'
  for attributes_file in "$worktree_git_dir/info/attributes" "$common_git_dir/info/attributes"; do
    [[ ! -L "$attributes_file" ]] \
      || die 'symlinked Git info/attributes is unsupported by isolated diff capture'
    [[ ! -s "$attributes_file" ]] \
      || die 'Git info/attributes is unsupported by isolated diff capture; refusing to change repository semantics'
  done
}

prepare_trusted_git_metadata() {
  local common_git_dir object_format repository_format=0
  git -C "$WT" rev-parse --absolute-git-dir >/dev/null || die 'unable to resolve trusted worktree Git metadata'
  BASE_SHA="$(git -C "$WT" rev-parse --verify 'HEAD^{commit}')" || die 'unable to resolve worktree base commit'
  object_format="$(git -C "$REPO" rev-parse --show-object-format 2>/dev/null || printf sha1)"
  case "$object_format" in sha1) ;; sha256) repository_format=1;; *) die "unsupported Git object format: $object_format";; esac
  common_git_dir="$(git -C "$REPO" rev-parse --git-common-dir)" || die 'unable to resolve common Git metadata'
  if [[ "$common_git_dir" == /* ]]; then
    common_git_dir="$(cd "$common_git_dir" 2>/dev/null && pwd -P)" || die 'unable to canonicalize common Git metadata'
  else
    common_git_dir="$(cd "$REPO/$common_git_dir" 2>/dev/null && pwd -P)" || die 'unable to canonicalize common Git metadata'
  fi
  COMMON_GIT_OBJECTS="$common_git_dir/objects"
  [[ "$COMMON_GIT_OBJECTS" != *:* && "$COMMON_GIT_OBJECTS" != *$'\n'* ]] \
    || die 'common Git object path is unsafe for isolated diff capture'
  [[ -f "$WT/.git" && ! -L "$WT/.git" ]] || die 'worktree .git pointer is not a regular file'
  reject_unrepresented_attribute_sources "$common_git_dir"
  WT_GIT_FILE_ID="$(file_identity "$WT/.git")"
  cp "$WT/.git" "$ART/worktree.git-pointer"
  SAFE_GIT_DIR="$ART/safe-git"
  mkdir -p "$SAFE_GIT_DIR/objects/info" "$SAFE_GIT_DIR/objects/pack" "$SAFE_GIT_DIR/refs/heads"
  printf '%s\n' \
    '[core]' \
    "  repositoryformatversion = $repository_format" \
    '  bare = false' \
    '  hooksPath = /dev/null' \
    '  fsmonitor = false' \
    > "$SAFE_GIT_DIR/config"
  if [[ "$object_format" == sha256 ]]; then
    printf '%s\n' '[extensions]' '  objectFormat = sha256' >> "$SAFE_GIT_DIR/config"
  fi
  copy_safe_git_setting core.autocrlf '^(true|false|input)$'
  copy_safe_git_setting core.eol '^(lf|crlf|native)$'
  copy_safe_git_setting core.safecrlf '^(true|false|warn)$'
  copy_safe_git_setting core.symlinks '^(true|false)$'
  copy_safe_git_setting core.ignorecase '^(true|false)$'
  copy_safe_git_setting core.precomposeunicode '^(true|false)$'
  copy_safe_git_setting core.filemode '^(true|false)$'
  printf 'ref: refs/heads/legion-safe\n' > "$SAFE_GIT_DIR/HEAD"
  safe_git read-tree "$BASE_SHA" \
    || die 'unable to initialize isolated diff index'
  trusted_attributes_have_filters \
    || die 'Git clean-filter attributes are unsupported by isolated diff capture; refusing to change repository semantics'
}

capture_trusted_diff() {
  local diff="$1"
  [[ -f "$WT/.git" && ! -L "$WT/.git" ]] || return 1
  [[ "$(file_identity "$WT/.git" 2>/dev/null || true)" == "$WT_GIT_FILE_ID" ]] || return 1
  cmp -s "$WT/.git" "$ART/worktree.git-pointer" || return 1
  trusted_attributes_have_filters || return 1
  safe_git add -A || return 1
  safe_git diff --cached --binary --no-ext-diff --no-textconv "$BASE_SHA" > "$diff"
}

start_handoff_broker() {
  local helper="$_self_dir/legion-handoff-broker.py" delegate="$_self_dir/../bin/legion-delegate" supervisor="$_self_dir/legion-process-supervisor.py" i supervisor_nonce broker_runtime
  [[ -x "$helper" && -x "$delegate" && -x "$supervisor" ]] || die 'trusted Legion handoff broker is unavailable'
  BROKER_RC=0
  BROKER_SOCKET_DIR="$(mktemp -d "${TMPDIR:-/tmp}/legion-broker.XXXXXX")" || die 'unable to allocate handoff broker socket directory'
  BROKER_SOCKET_DIR="$(cd "$BROKER_SOCKET_DIR" && pwd -P)" || die 'unable to canonicalize handoff broker socket directory'
  BROKER_SOCKET="$BROKER_SOCKET_DIR/broker.sock"
  BROKER_TOKEN="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
  BROKER_ROOT="$BROKER_SOCKET_DIR/runtime-root"
  CONTROL_EMPTY_DIR="$BROKER_SOCKET_DIR/control-empty"
  supervisor_nonce="$(python3 -c 'import secrets; print(secrets.token_hex(64))')"
  SUPERVISOR_DENY_CANARY="$BROKER_SOCKET_DIR/${supervisor_nonce:0:32}"
  SUPERVISOR_ALLOW_CANARY="$BROKER_SOCKET_DIR/${supervisor_nonce:32:32}"
  TARGET_SUPERVISOR_DENY_CANARY="$BROKER_SOCKET_DIR/${supervisor_nonce:64:32}"
  TARGET_SUPERVISOR_ALLOW_CANARY="$BROKER_SOCKET_DIR/${supervisor_nonce:96:32}"
  : > "$SUPERVISOR_DENY_CANARY"
  : > "$SUPERVISOR_ALLOW_CANARY"
  : > "$TARGET_SUPERVISOR_DENY_CANARY"
  : > "$TARGET_SUPERVISOR_ALLOW_CANARY"
  chmod 400 "$SUPERVISOR_DENY_CANARY" "$SUPERVISOR_ALLOW_CANARY" \
    "$TARGET_SUPERVISOR_DENY_CANARY" "$TARGET_SUPERVISOR_ALLOW_CANARY"
  mkdir -m 555 "$CONTROL_EMPTY_DIR"
  mkdir -p "$ART/broker-bin"
  cp "$helper" "$ART/broker-bin/legion-delegate"
  chmod 755 "$ART/broker-bin/legion-delegate"
  prepare_delegate_boundary
  broker_runtime="$(remaining_child_lease_seconds)"
  [[ "$broker_runtime" -ge 1 ]] \
    || terminalize_pre_provider_timeout 'child execution lease expired before handoff broker launch; no provider launched'
  python3 "$helper" serve --socket "$BROKER_SOCKET" --token "$BROKER_TOKEN" \
    --delegate "$delegate" --source-repo "$REPO" --broker-root "$BROKER_ROOT" --base-sha "$BASE_SHA" \
    --sandbox-bin "$FS_SANDBOX_BIN" --sandbox-kind "$FS_SANDBOX_KIND" \
    --supervisor "$supervisor" \
    --max-runtime-seconds "$broker_runtime" \
    --supervisor-deny-canary "$TARGET_SUPERVISOR_DENY_CANARY" \
    --supervisor-allow-canary "$TARGET_SUPERVISOR_ALLOW_CANARY" \
    --telemetry-dir "${LEGION_TELEMETRY_DIR:-}" --expected-parent "$RUN_ID" \
    > "$ART/broker.out" 2> "$ART/broker.err" &
  BROKER_PID=$!
  i=0
  while (( i < 100 )); do
    [[ -S "$BROKER_SOCKET" ]] && return 0
    kill -0 "$BROKER_PID" 2>/dev/null || break
    sleep 0.05
    i=$((i + 1))
  done
  stop_handoff_broker
  die "handoff broker failed to start; inspect $ART/broker.err"
}

reject_symlinked_runtime_roots() {
  local root="$REPO/.legion" candidate
  for candidate in "$root" "$root/runs" "$root/worktrees" "$ART" "$WT" "$root/.gitignore"; do
    [[ ! -L "$candidate" ]] || die "refusing symlinked Legion runtime path: $candidate"
  done
}

prepare_runtime_roots() {
  local root="$REPO/.legion"
  reject_symlinked_runtime_roots
  [[ ! -e "$ART" || -d "$ART" ]] || die "refusing non-directory Legion artifact path: $ART"
  if [[ -d "$ART" && -n "$(find "$ART" -mindepth 1 -maxdepth 1 \
      ! -name preflight.json ! -name "$ADAPTER_KIND-preflight.json" -print -quit 2>/dev/null)" ]]; then
    die "refusing non-empty Legion artifact directory: $ART"
  fi
  local receipt
  for receipt in "$ART/preflight.json" "$ART/$ADAPTER_KIND-preflight.json"; do
    [[ ! -e "$receipt" || ( -f "$receipt" && ! -L "$receipt" ) ]] \
      || die "refusing unsafe Legion preflight receipt: $receipt"
  done
  mkdir -p "$ART" "$root/worktrees" "$ART/tmp" "$ART/cache"
  if [[ ! -e "$root/.gitignore" ]]; then
    printf '*\n' > "$root/.gitignore"
  elif ! grep -qxF '*' "$root/.gitignore"; then
    printf '\n*\n' >> "$root/.gitignore"
  fi
}

write_worktree_ownership() {
  local record="$ART/worktree-owner.json" temp="$ART/.worktree-owner.tmp.$$"
  jq -cn --arg schema 'legion.worktree-owner.v1' --arg run "$RUN_ID" \
    --arg executor "$ADAPTER_KIND" --arg repo "$REPO" --arg worktree "$WT" \
    --arg branch "$BRANCH" --arg base "$BASE_SHA" \
    '{schema:$schema,run_id:$run,executor:$executor,repo:$repo,worktree:$worktree,branch:$branch,base_sha:$base}' \
    > "$temp" || return 1
  chmod 600 "$temp" || return 1
  mv -f "$temp" "$record"
}

run_provider() {
  local out="$1" err="$2"; shift 2
  build_fs_sandbox_command
  local supervisor="$_self_dir/legion-process-supervisor.py"
  [[ -x "$supervisor" ]] || die 'portable Legion process supervisor is unavailable'
  local launch_python
  launch_python="$(command -v python3 2>/dev/null || true)"
  [[ -n "$launch_python" && -x "$launch_python" ]] || die 'trusted Python runtime is unavailable for provider launch attestation'
  [[ -f "$PROVIDER_LAUNCH_WRAPPER" && ! -L "$PROVIDER_LAUNCH_WRAPPER" \
      && "$(file_identity "$PROVIDER_LAUNCH_WRAPPER" 2>/dev/null || true)" == "$PROVIDER_LAUNCH_WRAPPER_ID" ]] \
    || die 'provider launch attestation wrapper was modified before execution'
  [[ -f "$PROVIDER_EXEC_GATE" && ! -L "$PROVIDER_EXEC_GATE" \
      && "$(file_identity "$PROVIDER_EXEC_GATE" 2>/dev/null || true)" == "$PROVIDER_EXEC_GATE_ID" ]] \
    || die 'provider exec gate was modified before execution'
  local -a invocation=(env \
    -u DOCKER_HOST -u CONTAINER_HOST -u BUILDKIT_HOST -u SSH_AUTH_SOCK -u KUBECONFIG -u CONTAINERD_ADDRESS \
    "TMPDIR=$ART/tmp" "TMP=$ART/tmp" "TEMP=$ART/tmp" \
    "XDG_CACHE_HOME=$ART/cache" "PYTHONDONTWRITEBYTECODE=1" \
    "PATH=$SANITIZED_PROVIDER_PATH" \
    "LEGION_EXEC_GATE_EXPECTED_SHA256=$(jq -r '.identity.binary_sha256' "$LEGION_ADAPTER_PREFLIGHT_PATH")" \
    "LEGION_EXEC_GATE_ADMITTED_PATH=$PROVIDER_BIN" \
    "LEGION_HANDOFF_BROKER_SOCKET=$BROKER_SOCKET" "LEGION_HANDOFF_BROKER_TOKEN=$BROKER_TOKEN" \
    "HERMES_ENABLE_PROJECT_PLUGINS=0" "HERMES_ACCEPT_HOOKS=0")
  if [[ "$ADAPTER_KIND" == pi ]]; then
    invocation+=("PI_CODING_AGENT_DIR=$PI_PRIVATE_AGENT_DIR")
  else
    invocation+=("HERMES_HOME=$HERMES_PRIVATE_HOME")
  fi
  invocation+=("${FS_SANDBOX_COMMAND[@]}" "$launch_python" "$PROVIDER_LAUNCH_WRAPPER" \
    "$PROVIDER_LAUNCH_RECEIPT" "$PROVIDER_LAUNCH_TOKEN_FILE" "$PROVIDER_EXEC_GATE" -- "$@")
  local provider_runtime
  provider_runtime="$(remaining_child_lease_seconds)"
  [[ "$provider_runtime" -ge 1 ]] \
    || terminalize_pre_provider_timeout 'child execution lease expired during provider launch setup; no provider launched'
  PROVIDER_LAUNCH_TOKEN="$(python3 -c 'import secrets; print(secrets.token_hex(32))')" \
    || die 'unable to create provider launch attestation token'
  (umask 077; set -o noclobber; printf '%s\n' "$PROVIDER_LAUNCH_TOKEN" > "$PROVIDER_LAUNCH_TOKEN_FILE") \
    || die 'unable to persist provider launch attestation secret'
  local launch_gate="$ART/launch-gate.json"
  legion_adapter_prepare_supervisor_launch_gate "$launch_gate" \
    || die 'unable to prepare trusted supervisor launch gate'
  local -a supervisor_args=(python3 "$supervisor" --cwd "$WT"
    --max-runtime-seconds "$provider_runtime" --status-file "$ART/lease.json"
    --launch-gate-file "$launch_gate" --launch-gate-token "$LEGION_ADAPTER_LAUNCH_GATE_TOKEN"
    --descendant-signal-ready-file "$PROVIDER_LAUNCH_RECEIPT")
  if [[ "$FS_SANDBOX_KIND" == sandbox-exec ]]; then
    supervisor_args+=(--darwin-sandbox-deny-canary "$SUPERVISOR_DENY_CANARY" \
      --darwin-sandbox-allow-canary "$SUPERVISOR_ALLOW_CANARY")
  fi
  supervisor_args+=(-- "${invocation[@]}")
  SIGNAL_LEASE_STATUS="$ART/lease.json"
  begin_signal_launch
  abort_pending_signal_launch
  "${supervisor_args[@]}" >"$out" 2>"$err" &
  CHILD_PID=$!
  SIGNAL_CHILD_PID="$CHILD_PID"
  legion_adapter_complete_supervisor_launch_gate "$CHILD_PID" "$ART/lease.json" SIGNAL_LAUNCH_PENDING
  if [[ "$LEGION_ADAPTER_LAUNCH_GATE_OUTCOME" == started ]]; then
    legion_adapter_arm_signal_receipt "$ART" "$ADAPTER_KIND" "$ADAPTER_KIND" 1 \
      "$requested_model" "" \
      "$([[ "$ADAPTER_KIND" == pi ]] && printf '%s' "$THINKING")" \
      "$([[ "$ADAPTER_KIND" == pi ]] && printf '%s' "$THINKING")" \
      "$SANDBOX" "$started_at" "$start" "$out"
  elif [[ "$LEGION_ADAPTER_LAUNCH_GATE_OUTCOME" != launch_failed ]]; then
    kill -TERM "$CHILD_PID" 2>/dev/null || true
    wait "$CHILD_PID" 2>/dev/null || true
    CHILD_PID=""; KEEP=1
    write_state containment_failed
    [[ -z "$PRESET_RUN_ID" ]] || legion_disarm_adopted_run_guard
    legion_adapter_terminalize_launch_gate_containment "$ADAPTER_KIND" "$requested_model" \
      "$RUN_ID" "$LEGION_ADAPTER_PREFLIGHT_PATH" "$ART/lease.json" "$launch_gate" \
      "$WT_RECORD" "$provider_runtime"
    exit 70
  fi
  finish_signal_launch
  set +e; wait "$CHILD_PID"; PROVIDER_RC=$?; set -e
  CHILD_WAIT_RC="$PROVIDER_RC"
  CHILD_PID=""
}

cmd_run() {
  local task="" explicit_model="${PI_MODEL:-}" sandbox="workspace-write" base="HEAD" apply=0 start end duration
  local max_runtime_seconds=""
  ARCHETYPE="${LEGION_ARCHETYPE:-}"; PRESET_RUN_ID=""; THINKING="${LEGION_PI_THINKING:-${PI_THINKING:-}}"; PROVIDER_RC=0
  [[ "$ADAPTER_KIND" == hermes ]] && explicit_model="${HERMES_MODEL:-}"
  while [[ $# -gt 0 ]]; do case "$1" in
    --task) task="$2"; shift 2;;
    --task-file) [[ -r "$2" ]] || die "--task-file not readable: $2"; task="$(cat "$2")"; shift 2;; --model) explicit_model="$2"; shift 2;; --thinking) [[ "$ADAPTER_KIND" == pi ]] || die '--thinking is only supported by Pi'; THINKING="$2"; shift 2;;
    --archetype) ARCHETYPE="$2"; shift 2;; --repo) REPO="$2"; shift 2;; --base) base="$2"; shift 2;; --sandbox) sandbox="$2"; shift 2;;
    --run-id) PRESET_RUN_ID="$2"; shift 2;; --max-runtime-seconds) max_runtime_seconds="$2"; shift 2;; --apply) apply=1; shift;; --keep) KEEP=1; shift;; --quiet) QUIET=1; shift;; *) die "run: unknown arg '$1'";; esac; done
  # The OS sandbox matches canonical paths. On macOS, /tmp is a symlink to
  # /private/tmp, so a logical path would deny legitimate worktree writes.
  REPO="$(cd "${REPO:-$PWD}" && pwd -P)" || die 'run: repo does not exist'
  resolve_state "$REPO"; BASE="$base"; SANDBOX="$sandbox"
  case "$SANDBOX" in read-only|workspace-write) ;; *) die "invalid --sandbox '$SANDBOX' (read-only|workspace-write)";; esac
  [[ -n "$task" ]] || task="$(cat)"; [[ -n "$task" ]] || die 'run: empty task'
  [[ "$SANDBOX" == read-only ]] || legion_scan_task_text "$task"
  legion_require_top_level_executor "$ADAPTER_KIND" || return $?
  legion_adapter_resolve_lease "$ADAPTER_KIND" "$max_runtime_seconds" || die "$LEGION_ADAPTER_LEASE_REASON"
  MAX_RUNTIME_SECONDS="$LEGION_ADAPTER_MAX_RUNTIME_SECONDS"
  establish_child_lease_deadline
  [[ -z "$PRESET_RUN_ID" ]] || { declare -F legion_write_adapter_run_state >/dev/null 2>&1 || die 'run: --run-id requires lifecycle-state support'; legion_validate_run_id "$PRESET_RUN_ID" || die "run: invalid --run-id '$PRESET_RUN_ID'"; }
  MODEL="$explicit_model"; [[ -n "$MODEL" ]] || MODEL="$(legion_model_ref "${ADAPTER_KIND}_default")" || die "could not resolve ${ADAPTER_KIND}_default"
  if [[ "$ADAPTER_KIND" == pi && "$MODEL" =~ :(off|minimal|low|medium|high|xhigh|max)$ ]]; then
    [[ -n "$THINKING" ]] || THINKING="${BASH_REMATCH[1]}"; MODEL="${MODEL%:*}"
  fi
  MODEL="$(legion_provider_model "$ADAPTER_KIND" "$MODEL")"
  [[ "$ADAPTER_KIND" != pi || -z "$THINKING" ]] || valid_thinking "$THINKING" || die "invalid --thinking '$THINKING' (off|minimal|low|medium|high|xhigh|max)"
  local requested_model="$MODEL"
  RUN_ID="${PRESET_RUN_ID:-$(_run_id)}"; WT="$REPO/.legion/worktrees/$RUN_ID"; WT_RECORD="$WT"; ART="$REPO/.legion/runs/$RUN_ID"; BRANCH="legion/$ADAPTER_KIND-$RUN_ID"
  # Preflight writes its no-spend receipt under ART. Authenticate every parent
  # first so a repository-controlled runtime symlink cannot redirect that write.
  reject_symlinked_runtime_roots
  [[ -z "$PRESET_RUN_ID" ]] || legion_arm_adopted_run_guard "$RUN_ID" "$REPO" "$ART" "$WT" "$BRANCH" "$MODEL" "$SANDBOX" "$BASE" "$ARCHETYPE" "$THINKING"
  if ! legion_adapter_preflight "$ADAPTER_KIND" "$ART" "$SANDBOX" argv "$MODEL" \
      "$([[ "$ADAPTER_KIND" == pi ]] && printf '%s' "$THINKING")" 0 "$PROVIDER_BIN"; then
    local preflight_disposition terminal_status=refused
    preflight_disposition="$(legion_adapter_preflight_failure_disposition \
      "$LEGION_ADAPTER_PREFLIGHT_PATH")"
    case "$preflight_disposition" in
      timed_out) terminal_status=timed_out; write_state timed_out ;;
      containment_failed) terminal_status=containment_failed; write_state containment_failed ;;
      launch_failed) terminal_status=failed; write_state failed ;;
      *) write_state failed ;;
    esac
    [[ -z "$PRESET_RUN_ID" ]] || legion_disarm_adopted_run_guard
    jq -cn --arg run "$RUN_ID" --arg executor "$ADAPTER_KIND" --arg model "$MODEL" \
      --arg status "$terminal_status" \
      --arg reason "$LEGION_ADAPTER_PREFLIGHT_REASON" \
      --arg preflight "$LEGION_ADAPTER_PREFLIGHT_PATH" '
      {run_id:$run,status:$status,executor:$executor,model:$model,reason:$reason,
       preflight_receipt:$preflight,attempt_receipt:null,failure_receipt:null,
       usage:null,tokens:null,usage_status:"not_applicable",
       cost_usd:null,cost_status:"not_applicable"}'
    return 1
  fi
  PROVIDER_BIN="$(jq -r '.identity.executable_path' "$LEGION_ADAPTER_PREFLIGHT_PATH")"
  provider_ready || terminalize_pre_provider_launch_failure \
    "$ADAPTER_KIND CLI disappeared after successful admission; no provider launched"
  resolve_fs_sandbox
  git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git repo: $REPO"
  prepare_runtime_roots
  with_git_worktree_lock "$REPO" git -C "$REPO" worktree add -q -b "$BRANCH" "$WT" "$BASE" \
    || { write_state failed; die 'worktree add failed'; }
  WT_CREATED=1 BRANCH_CREATED=1
  prepare_trusted_git_metadata
  write_worktree_ownership || { write_state failed; die 'unable to persist worktree ownership receipt'; }
  prepare_provider_files
  prepare_private_provider_runtime
  write_state running; legion_activate_executor_context "$RUN_ID" "$ADAPTER_KIND"
  start_handoff_broker
  local out="$PROVIDER_OUT" err="$PROVIDER_ERR" usage_art="$PROVIDER_USAGE"; local -a command
  if [[ "$ADAPTER_KIND" == pi ]]; then
    command=("$PROVIDER_BIN" -p --mode json --no-session --no-approve --no-extensions --no-skills --no-prompt-templates --model "$MODEL")
    [[ -z "$THINKING" ]] || command+=(--thinking "$THINKING")
    [[ "$SANDBOX" == read-only ]] && command+=(--tools "read,grep,find,ls")
    command+=("$task")
  else
    # Keep repository rules/AGENTS.md, but exclude the user's tools, MCPs,
    # hooks, plugins, and mutable profile from non-interactive auto-approval.
    command=("$PROVIDER_BIN" --oneshot "$task" --usage-file "$usage_art" --model "$MODEL" \
      --ignore-user-config --toolsets "terminal,file")
  fi
  note "-> ${command[*]}"
  local started_at ended_at
  started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  start="$(date +%s000)"
  run_provider "$out" "$err" "${command[@]}"; end="$(date +%s000)"; duration=$((end-start))
  ended_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  stop_handoff_broker
  rm -f "$PROVIDER_LAUNCH_TOKEN_FILE"
  local usage='{}' result='' cost=0 status=ok diff="$ART/diff.patch" actual_model="$MODEL" observed_model="" terminal_ok=0 provider_files_ok=0
  if verify_provider_file "$out" "$PROVIDER_OUT_ID" \
      && verify_provider_file "$err" "$PROVIDER_ERR_ID" \
      && verify_provider_file "$usage_art" "$PROVIDER_USAGE_ID"; then
    provider_files_ok=1
  else
    status=error
    result="$ADAPTER_KIND modified or replaced a parent-owned provider artifact; refusing to consume it."
  fi
  if [[ "$provider_files_ok" == 1 && "$ADAPTER_KIND" == pi ]]; then
    usage="$(pi_usage "$out")"; result="$(pi_result "$out")"; pi_terminal_ok "$out" && terminal_ok=1 || true
    observed_model="$(pi_actual_model "$out")"; actual_model="$observed_model"; [[ -n "$actual_model" ]] || actual_model="$MODEL"
    cost="$(pi_cost "$out")"
  elif [[ "$provider_files_ok" == 1 ]]; then
    usage="$(hermes_usage "$usage_art")"; result="$(hermes_result "$out")"; hermes_terminal_ok "$out" "$usage_art" && terminal_ok=1 || true
    observed_model="$(hermes_actual_model "$usage_art")"; actual_model="$observed_model"; [[ -n "$actual_model" ]] || actual_model="$MODEL"
    cost="$(hermes_cost "$usage_art")"
  fi
  MODEL="$actual_model"
  [[ -n "$usage" ]] || usage='{}'
  local lease_reason="" containment_failed=0 launch_failed=0 launch_timed_out=0
  local provider_launch_unresolved=0 provider_launch_state="" provider_launch_evidence=''
  if legion_adapter_supervisor_cleanup_failed "$ART/lease.json"; then
    containment_failed=1
    legion_adapter_supervisor_cleanup_failed_before_launch "$ART/lease.json" \
      && launch_failed=1
    lease_reason="$(legion_adapter_supervisor_reason "$ART/lease.json") (evidence: $ART/lease.json; worktree retained: $WT_RECORD)"
  elif legion_adapter_supervisor_timed_out_before_launch "$ART/lease.json" "$PROVIDER_RC"; then
    launch_failed=1
    launch_timed_out=1
    lease_reason="$(legion_adapter_lease_reason "$ART/lease.json")"
  elif legion_adapter_supervisor_launch_failed "$ART/lease.json"; then
    launch_failed=1
    lease_reason="$(legion_adapter_supervisor_reason "$ART/lease.json" "provider launch failed before process creation")"
  fi
  if [[ "$launch_failed" != 1 ]]; then
    provider_launch_evidence="$(provider_launch_status)"
    provider_launch_state="$(jq -r '.status // "malformed"' \
      <<<"$provider_launch_evidence" 2>/dev/null || printf malformed)"
    case "$provider_launch_state" in
      launch_failed)
        launch_failed=1
        if jq -e --argjson timeout "$(python3 -c 'import errno; print(errno.ETIMEDOUT)')" \
            '.errno == $timeout' <<<"$provider_launch_evidence" >/dev/null 2>&1; then
          launch_timed_out=1
        fi
        lease_reason="$(provider_launch_reason "$provider_launch_evidence")"
        ;;
      started)
        if [[ "$containment_failed" != 1 ]] && legion_adapter_supervisor_timed_out "$ART/lease.json"; then
          lease_reason="$(legion_adapter_lease_reason "$ART/lease.json")"
        fi
        ;;
      pending|absent|malformed)
        provider_launch_unresolved=1
        containment_failed=1
        KEEP=1
        if [[ -n "$lease_reason" ]]; then
          lease_reason="$lease_reason; provider launch evidence: $provider_launch_state at $PROVIDER_LAUNCH_RECEIPT"
        else
          lease_reason="provider launch evidence remained $provider_launch_state after supervisor drain (evidence: $PROVIDER_LAUNCH_RECEIPT; supervisor: $ART/lease.json; worktree retained: $WT_RECORD)"
        fi
        ;;
    esac
  fi
  if [[ "$BROKER_RC" -ne 0 ]]; then
    status=failed
    result="${result:+$result$'\n'}handoff broker failed closed with exit $BROKER_RC; inspect $ART/broker.err"
    if [[ "$BROKER_RC" -eq 70 ]]; then
      containment_failed=1
      KEEP=1
      lease_reason="handoff broker reported incomplete descendant cleanup (evidence: $ART/broker.err; worktree retained: $WT_RECORD)"
    fi
  fi
  if ! jq -en --argjson value "$cost" '
    $value | type == "number" and (isnan | not) and (isinfinite | not) and . >= 0
  ' >/dev/null 2>&1; then cost=null; terminal_ok=0; fi
  if [[ "$containment_failed" -ne 1 ]] && ! capture_trusted_diff "$diff"; then
    status=error
    result="${result:+$result$'\n'}$ADAPTER_KIND modified trusted worktree metadata or diff capture failed; refusing unsandboxed Git evaluation."
  elif [[ "$containment_failed" -eq 1 ]]; then
    : > "$diff"
  fi
  [[ "$PROVIDER_RC" == 0 ]] || status=failed
  [[ "$status" != ok || "$terminal_ok" == 1 ]] || status=error
  # A successful exit alone is not a terminal receipt. Both providers must
  # produce a final answer (Pi's agent_end, Hermes's one-shot stdout) before
  # Legion can report an authoritative success.
  [[ "$status" != ok || -n "$result" ]] || status=error
  [[ "$SANDBOX" != read-only || ! -s "$diff" ]] || { status=error; result="${result:+$result$'\n'}Pi produced file changes during a read-only run; refusing to report ok."; }
  [[ "$status" != ok || -n "$result" || -s "$diff" ]] || { status=error; result="$ADAPTER_KIND completed without an authoritative terminal result or diff."; }
  if [[ "$containment_failed" == 1 ]]; then
    status=containment_failed
    KEEP=1
    result="$lease_reason"
  elif [[ "$launch_timed_out" == 1 ]]; then
    status=timed_out
    KEEP=0
    result="$lease_reason"
    usage=null
    cost=null
  elif [[ "$launch_failed" == 1 ]]; then
    status=failed
    result="$lease_reason"
    usage=null
    cost=null
  elif [[ -n "$lease_reason" ]]; then
    status=timed_out
    KEEP=0
    result="$lease_reason"
  fi
  printf '%s\n' "$result" > "$ART/last-message.txt"
  # Only read provenance from a VERIFIED artifact. provider_files_ok is cleared
  # when the provider replaced or symlinked a parent-owned file, and the whole
  # point of that guard is to refuse consuming it -- reading cost_status out of
  # an unverified, provider-selected JSON would walk straight past it. An
  # unverified run keeps the honest default: we do not know what it cost.
  local cost_provenance='{"cost_status":"unknown","cost_source":"none"}'
  if [[ "$provider_files_ok" == 1 && "$ADAPTER_KIND" == hermes ]]; then
    cost_provenance="$(hermes_cost_provenance "$usage_art")"
  fi
  local usage_status=unknown usage_source="" cost_status=unknown cost_source="" output_started=false
  if [[ "$launch_failed" == 1 ]]; then
    usage_status=not_applicable
    cost_status=not_applicable
  fi
  if [[ "$provider_files_ok" == 1 && "$ADAPTER_KIND" == pi ]] \
     && jq -s -e '[.[] | select(.type == "message_end" and .message.role == "assistant")
       | .message.content[]? | select(.type == "text" and ((.text // "") | length > 0))] | length > 0' \
       "$out" >/dev/null 2>&1; then
    output_started=true
  elif [[ "$provider_files_ok" == 1 && "$ADAPTER_KIND" == hermes ]] \
       && legion_adapter_output_started_file "$out"; then
    output_started=true
  fi
  if [[ "$provider_files_ok" == 1 && "$ADAPTER_KIND" == pi ]] \
     && jq -s -e '[.[] | select(.type == "message_end" and (.message.usage | type) == "object")] | length > 0' "$out" >/dev/null 2>&1; then
    usage_status=known; usage_source=pi-jsonl
    if pi_cost_known "$out"; then
      cost_status=known; cost_source=pi-jsonl
    fi
  elif [[ "$provider_files_ok" == 1 && "$ADAPTER_KIND" == hermes ]] \
       && hermes_terminal_ok "$out" "$usage_art"; then
    usage_status=known; usage_source=hermes-usage-file
    local hermes_cost_status hermes_cost_source
    hermes_cost_status="$(jq -r '.cost_status // "unknown"' "$usage_art")"
    hermes_cost_source="$(jq -r '.cost_source // "none"' "$usage_art")"
    if [[ "$hermes_cost_status" != unknown ]]; then
      # The common attempt schema records a numeric provider-reported value as
      # known; retain whether Hermes called it actual, estimated, or included
      # and the original source in the unrestricted provenance string.
      cost_status=known
      cost_source="hermes-usage-file:$hermes_cost_status:$hermes_cost_source"
    fi
  fi
  local terminal_status=succeeded failure_class=""
  local terminal_usage=null terminal_cost=null
  local terminal_usage_status="$usage_status" terminal_cost_status="$cost_status"
  if [[ "$status" != ok ]]; then
    terminal_status=failed
    if [[ "$status" == timed_out ]]; then
      terminal_status=timed_out
      failure_class=timed_out
    elif [[ "$status" == containment_failed ]]; then
      failure_class=internal
    elif [[ "$SANDBOX" == read-only && -s "$diff" ]]; then
      failure_class=policy_refused
    elif [[ "$PROVIDER_RC" -ne 0 ]]; then
      failure_class=provider
    elif [[ "$terminal_ok" != 1 ]]; then
      failure_class=malformed_event
    else
      failure_class=internal
    fi
  fi
  if [[ "$launch_failed" == 1 ]]; then
    LEGION_ADAPTER_ATTEMPT_PATH=""
    LEGION_ADAPTER_FAILURE_PATH=""
    terminal_usage_status=not_applicable
    terminal_cost_status=not_applicable
  else
    legion_adapter_write_attempt "$ART" "$ADAPTER_KIND" "$ADAPTER_KIND" 1 "$requested_model" "$observed_model" \
      "$([[ "$ADAPTER_KIND" == pi ]] && printf '%s' "$THINKING")" \
      "$([[ "$ADAPTER_KIND" == pi ]] && printf '%s' "$THINKING")" \
      "$SANDBOX" "$terminal_status" "$started_at" "$ended_at" "$duration" \
      "$usage" "$usage_status" "$usage_source" "$cost" "$cost_status" "$cost_source" \
      "$failure_class" false "$output_started" \
      "$([[ "$PROVIDER_RC" -eq 0 ]] || printf '%s' "$PROVIDER_RC")" "$result"
    # The attempt receipt is the canonical metering boundary. In particular,
    # the writer normalizes unknown provider values to null; do not leak the
    # adapter's pre-normalization {} / 0 placeholders into the terminal JSON.
    terminal_usage_status="$(jq -r '.usage_status' "$LEGION_ADAPTER_ATTEMPT_PATH")"
    terminal_cost_status="$(jq -r '.cost_status' "$LEGION_ADAPTER_ATTEMPT_PATH")"
    if [[ "$terminal_usage_status" == known ]]; then
      terminal_usage="$(python3 "$_self_dir/lib/exact-metering.py" get "$LEGION_ADAPTER_ATTEMPT_PATH" usage)"
    fi
    if [[ "$terminal_cost_status" == known ]]; then
      terminal_cost="$(jq -c '.cost_usd' "$LEGION_ADAPTER_ATTEMPT_PATH")"
    fi
    local artifacts; artifacts="$(jq -cn --arg worktree "$WT_RECORD" --arg diff "$diff" --arg stdout "$out" --arg stderr "$err" --arg usage "$usage_art" \
      --arg preflight "$LEGION_ADAPTER_PREFLIGHT_PATH" --arg attempt "$LEGION_ADAPTER_ATTEMPT_PATH" --arg failure "$LEGION_ADAPTER_FAILURE_PATH" \
      --arg reason "$lease_reason" --arg lease "$ART/lease.json" \
      --argjson cost_provenance "$cost_provenance" '{provider_attempt:true,worktree:$worktree,diff:$diff,stdout:$stdout,stderr:$stderr,usage_file:$usage,
        preflight_receipt:$preflight,attempt_receipt:$attempt,failure_receipt:(if $failure=="" then null else $failure end),
        lease_receipt:$lease} + $cost_provenance
        + (if $reason=="" then {} else {lease_reason:$reason} end)')"
    local span_model span_usage span_cost span_usage_status span_cost_status
    span_model="$(jq -r '.effective_model // .requested_model // "unknown"' "$LEGION_ADAPTER_ATTEMPT_PATH")"
    span_usage="$(python3 "$_self_dir/lib/exact-metering.py" get "$LEGION_ADAPTER_ATTEMPT_PATH" usage)"
    span_cost="$(jq -c '.cost_usd' "$LEGION_ADAPTER_ATTEMPT_PATH")"
    span_usage_status="$(jq -r '.usage_status' "$LEGION_ADAPTER_ATTEMPT_PATH")"
    span_cost_status="$(jq -r '.cost_status' "$LEGION_ADAPTER_ATTEMPT_PATH")"
    if ! SPAN_PROVIDER_MODEL="$span_model" legion_adapter_emit_normal_provider_span "$LEGION_ADAPTER_ATTEMPT_PATH" \
        "$status" "$duration" "$span_cost" "$span_usage" "$task" "$artifacts" \
        "$span_usage_status" "$span_cost_status"; then
      status=containment_failed
      PROVIDER_RC=70
      KEEP=1
      lease_reason="provider attempt receipt is durable but its span publication is uncertain; worktree and evidence retained"
      result="$lease_reason"
    fi
  fi
  legion_adapter_disarm_signal_receipt
  SIGNAL_CHILD_PID=""
  CHILD_WAIT_RC=0
  if [[ "$apply" == 1 && "$status" == ok && -s "$diff" ]]; then
    if git -C "$REPO" apply --check "$diff"; then git -C "$REPO" apply "$diff"; else note "diff did not apply cleanly; left in $diff"; fi
  fi
  local report="$WT_RECORD"; [[ "$KEEP" == 1 ]] || { cleanup_worktree; report='(removed; rerun with --keep to retain the worktree)'; }
  write_state "$status"; [[ -z "$PRESET_RUN_ID" ]] || legion_disarm_adopted_run_guard
  jq -cn --arg run "$RUN_ID" --arg status "$status" --arg executor "$ADAPTER_KIND" --arg model "$actual_model" --arg result "$result" --arg worktree "$report" --arg diff "$diff" --arg last "$ART/last-message.txt" \
    --arg preflight "$LEGION_ADAPTER_PREFLIGHT_PATH" --arg attempt "$LEGION_ADAPTER_ATTEMPT_PATH" --arg failure "$LEGION_ADAPTER_FAILURE_PATH" \
    --arg reason "$lease_reason" --arg lease "$ART/lease.json" \
    --arg provider_launch "$([[ ( "$launch_failed" == 1 || "$provider_launch_unresolved" == 1 ) && -f "$PROVIDER_LAUNCH_RECEIPT" ]] && printf '%s' "$PROVIDER_LAUNCH_RECEIPT")" \
    --arg usage_status "$terminal_usage_status" --arg cost_status "$terminal_cost_status" \
    --argjson usage "$terminal_usage" --argjson cost "$terminal_cost" --argjson rc "$PROVIDER_RC" \
    '{run_id:$run,status:$status,executor:$executor,model:$model,result:$result,worktree:$worktree,diff_path:$diff,last_message_path:$last,usage:$usage,cost_usd:$cost,provider_exit:$rc,
      tokens:$usage,usage_status:$usage_status,cost_status:$cost_status,
      preflight_receipt:$preflight,attempt_receipt:(if $attempt=="" then null else $attempt end),failure_receipt:(if $failure=="" then null else $failure end),lease_receipt:$lease,
      provider_launch_receipt:(if $provider_launch=="" then null else $provider_launch end)}
      + (if $reason=="" then {} else {reason:$reason} end)' | {
        if [[ -n "$LEGION_ADAPTER_ATTEMPT_PATH" ]]; then
          python3 "$_self_dir/lib/exact-metering.py" patch-attempt "$LEGION_ADAPTER_ATTEMPT_PATH"
        else
          cat
        fi
      }
  [[ "$status" == ok ]] || exit 1
}

usage() { printf '%s — isolated, metered %s diff adapter.\n\nUsage: %s run --task TASK [--model MODEL] [--repo DIR] [--sandbox read-only|workspace-write] [--base REF] [--run-id ID] [--max-runtime-seconds N] [--apply] [--keep]\n' "$ADAPTER" "$ADAPTER_KIND" "$ADAPTER"; }
case "${1:-}" in run) shift; cmd_run "$@";; ''|help|-h|--help) usage;; *) die "unknown command '$1'";; esac
