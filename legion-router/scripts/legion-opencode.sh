#!/usr/bin/env bash
# legion-opencode — delegate a scoped task to opencode headless (`opencode run
# --format json`) and capture a metered Legion span + diff. opencode's JSON
# format is a JSONL EVENT STREAM (not one object): `message.updated` events carry
# an AssistantMessage with a PRECOMPUTED `cost` (USD) and nested `tokens`
# ({input,output,reasoning,cache:{read,write}}); text streams via
# `message.part.updated`. This mirrors legion-cursor.sh (worktree + diff + span)
# with opencode-specific invocation and parsing.

set -euo pipefail

_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
# shellcheck source=lib/cost.sh
source "$_self_dir/lib/cost.sh"
# shellcheck disable=SC1091
# shellcheck source=lib/model-config.sh
source "$_self_dir/lib/model-config.sh"
# shellcheck disable=SC1091
# shellcheck source=lib/executor-context.sh
source "$_self_dir/lib/executor-context.sh"
# shellcheck disable=SC1091
# shellcheck source=lib/run-id.sh
source "$_self_dir/lib/run-id.sh"
# shellcheck disable=SC1091
# shellcheck source=lib/task-scan.sh
source "$_self_dir/lib/task-scan.sh"
# shellcheck disable=SC1091
# shellcheck source=lib/adapter-contract.sh
source "$_self_dir/lib/adapter-contract.sh"
_state_lib="$_self_dir/../../legion-observability/scripts/lib/state.sh"
if [[ -f "$_state_lib" ]]; then
  # shellcheck disable=SC1090
  # shellcheck disable=SC1091
  source "$_state_lib"
fi

OPENCODE_BIN="${OPENCODE_BIN:-}"
CHILD_PID=""
SIGNAL_LEASE_STATUS=""
SIGNAL_WORKTREE=""
SIGNAL_CHILD_PID=""
SIGNAL_CHILD_RC=0
SIGNAL_LAUNCH_PENDING=""

die() { printf 'legion-opencode: %s\n' "$*" >&2; exit 2; }
note() { [[ "${QUIET:-0}" == "1" ]] || printf '%s\n' "$*" >&2; }
on_signal() {
  local signum="$1" child_rc="$SIGNAL_CHILD_RC" containment_reason="" supervised_pid="${SIGNAL_CHILD_PID:-unknown}"
  trap - INT TERM HUP
  if [[ -n "$CHILD_PID" ]]; then
    kill -TERM "$CHILD_PID" 2>/dev/null || true
    wait "$CHILD_PID" 2>/dev/null || child_rc=$?
    CHILD_PID=""
  fi
  legion_adapter_write_signal_receipt "$signum" "$child_rc" "$SIGNAL_LEASE_STATUS"
  if legion_adapter_supervisor_cleanup_failed "$SIGNAL_LEASE_STATUS" \
      || { [[ -f "$SIGNAL_LEASE_STATUS" ]] && jq -e \
        '.schema == "legion.child-execution-lease.v1" and .status == "containment_failed"' \
        "$SIGNAL_LEASE_STATUS" >/dev/null 2>&1; }; then
    containment_reason="$(legion_adapter_supervisor_reason "$SIGNAL_LEASE_STATUS") (evidence: $SIGNAL_LEASE_STATUS; supervisor pid: $supervised_pid; worktree retained: $SIGNAL_WORKTREE)"
  elif [[ "$child_rc" -eq 70 ]]; then
    containment_reason="child supervisor exited 70 without a valid cleanup sidecar (evidence expected: $SIGNAL_LEASE_STATUS; worktree retained: $SIGNAL_WORKTREE)"
  fi
  if [[ -n "$containment_reason" ]]; then
    keep=1
    legion_adapter_fail_recorded_attempt "$LEGION_ADAPTER_SIGNAL_ART" opencode \
      "$LEGION_ADAPTER_SIGNAL_ORDINAL" internal 70 "$containment_reason" || true
    if [[ -n "${preset_run_id:-}" ]]; then
      legion_write_adapter_run_state containment_failed "$RUN_ID" "$repo" \
        "$LEGION_ADAPTER_SIGNAL_ART" "$SIGNAL_WORKTREE" "$branch" "$model" "$sandbox" \
        "$base" "$archetype" "" || true
      legion_disarm_adopted_run_guard
    fi
    legion_adapter_emit_signal_span "${span_task:-}" "$SIGNAL_LEASE_STATUS" || true
    exit 70
  fi
  if ! legion_adapter_emit_signal_span "${span_task:-}" "$SIGNAL_LEASE_STATUS"; then
    keep=1
    containment_reason="provider attempt receipt is durable but its signal-path span publication is uncertain (evidence: $LEGION_ADAPTER_SIGNAL_ART/attempt-$LEGION_ADAPTER_SIGNAL_ORDINAL.json; worktree retained: $SIGNAL_WORKTREE)"
    legion_adapter_fail_recorded_attempt "$LEGION_ADAPTER_SIGNAL_ART" opencode \
      "$LEGION_ADAPTER_SIGNAL_ORDINAL" internal 70 "$containment_reason" || true
    if [[ -n "${preset_run_id:-}" ]]; then
      legion_write_adapter_run_state containment_failed "$RUN_ID" "$repo" \
        "$LEGION_ADAPTER_SIGNAL_ART" "$SIGNAL_WORKTREE" "$branch" "$model" "$sandbox" \
        "$base" "$archetype" "" || true
      legion_disarm_adopted_run_guard
    fi
    exit 70
  fi
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
      "$LEGION_ADAPTER_MAX_RUNTIME_SECONDS" "$pending"; then
    trap - INT TERM HUP
    keep=1
    note "provider launch cancelled before Popen, but no-launch evidence could not be persisted; retaining containment"
    if [[ -n "${preset_run_id:-}" ]]; then
      legion_write_adapter_run_state containment_failed "$RUN_ID" "$repo" "$art" \
        "$SIGNAL_WORKTREE" "$branch" "$model" "$sandbox" "$base" "$archetype" "" || true
      legion_disarm_adopted_run_guard
    fi
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
trap 'declare -F legion_terminalize_adopted_run_on_exit >/dev/null 2>&1 && legion_terminalize_adopted_run_on_exit' EXIT
trap 'on_signal 2' INT
trap 'on_signal 15' TERM
trap 'on_signal 1' HUP

_now()    { date -u +%Y-%m-%dT%H:%M:%SZ; }
_today()  { date -u +%Y-%m-%d; }
_run_id() { legion_new_run_id; }

# Resolve the opencode binary. PIN $HOME/.opencode/bin first: a stray `opencode`
# on PATH (e.g. OpenWork's bundled build) is a different, incompatible binary.
resolve_opencode_bin() {
  if [[ -n "$OPENCODE_BIN" ]]; then
    command -v "$OPENCODE_BIN" 2>/dev/null && return 0
    [[ -x "$OPENCODE_BIN" ]] && { printf '%s\n' "$OPENCODE_BIN"; return 0; }
    return 1
  fi
  [[ -x "$HOME/.opencode/bin/opencode" ]] && { printf '%s\n' "$HOME/.opencode/bin/opencode"; return 0; }
  command -v opencode 2>/dev/null && return 0
  return 1
}

require_git_repo() {
  git -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git repo: $1"
}

validate_sandbox() {
  case "$1" in
    read-only|workspace-write) return 0 ;;
    *) die "invalid --sandbox '$1' (read-only|workspace-write)" ;;
  esac
}

scan_task_text() {
  legion_scan_task_text "$1"
}

emit_span() {
  local executor="$1" model="$2" status="$3" dur="$4" cost="$5" usage="$6" task="$7" artifacts="$8"
  local usage_status="${9:-known}" cost_status="${10:-known}"
  {
    mkdir -p "$LEGION_TELEMETRY_DIR"
    local trace_id="${LEGION_TRACE_ID:-${RUN_ID:-}}"
    local parent_id="${LEGION_PARENT_ID:-}"
    jq -cn \
      --arg schema "legion.span.v1" --arg ts "$(_now)" \
      --arg run_id "${RUN_ID:-}" --arg trace_id "$trace_id" --arg parent_id "$parent_id" \
      --arg executor "$executor" --arg model "$model" --arg archetype "${archetype:-}" \
      --arg target_type "${LEGION_TARGET_TYPE:-}" --arg target_name "${LEGION_TARGET_NAME:-}" \
      --arg status "$status" --argjson dur "${dur:-0}" --argjson cost "${cost:-null}" \
      --argjson usage "${usage:-null}" --arg usage_status "$usage_status" \
      --arg cost_status "$cost_status" --arg task "$task" --argjson artifacts "$artifacts" '
      {schema:$schema, ts:$ts, run_id:$run_id, trace_id:$trace_id,
       parent_id:(if $parent_id=="" then null else $parent_id end),
       executor:$executor, model:$model, archetype:$archetype, task:$task, status:$status,
       target_type:(if $target_type=="" then null else $target_type end),
       target_name:(if $target_name=="" then null else $target_name end),
       duration_ms:$dur, cost_usd:$cost, cost_status:$cost_status,
       tokens:$usage, usage_status:$usage_status, artifacts:$artifacts}' \
      >> "$LEGION_TELEMETRY_DIR/$(legion_adapter_span_date).jsonl"
  } 2>/dev/null || true
}

# Parse the opencode JSONL event stream into a compact result (one jq pass).
# OpenCode <=1.2 emitted message.updated/message.part.updated events; 1.3 emits
# top-level text/step_finish/error events. Accept both contracts so an installed
# CLI upgrade cannot silently turn a failed run into an empty success.
#
# Streaming updates can repeat an id. Take the last state per id, then sum across
# distinct assistant messages/steps so a multi-turn run is never double-counted.
# Tolerant of stray non-JSON stdout lines (e.g. a plugin's console.log poisoning
# the stream): each line is parsed with `fromjson?`, so one bad line costs at most
# that event, not the whole run's cost/result. Token counters are parsed
# separately with integer-exact Python, never jq arithmetic.
parse_opencode_output() {
  local file="$1" out
  out="$(jq -s -R -c '
    [ splits("\n") | select(length > 0) | fromjson? ] as $events
    | ([ $events[] | select(.type=="message.updated" and (.properties.info.role? == "assistant"))
         | .properties.info ] | group_by(.id) | map(.[-1])) as $msgs
    | ([ $events[] | select(.type=="step_finish" and (.part.type? == "step-finish"))
         | .part ] | group_by(.id) | map(.[-1])) as $steps
    | ([ $events[] | select(.type=="message.part.updated" and (.properties.part.type? == "text")) ]
         | group_by(.properties.part.id) | map(.[-1].properties.part.text)) as $legacy_text
    | ([ $events[] | select(.type=="text" and (.part.type? == "text")) ]
         | group_by(.part.id) | map(.[-1].part.text)) as $current_text
    | ([ $events[] | select(.type=="error") ] | last) as $error
    | {
        cost:  (([$msgs[].cost] | add // 0) + ([$steps[].cost] | add // 0)),
        model: ($msgs | last
                 | if . == null or ((.providerID // "") == "") or ((.modelID // "") == "") then ""
                   else (.providerID + "/" + .modelID) end),
        result: ([$legacy_text[], $current_text[]] | map(select(. != null and . != "")) | join("\n")),
        event_count: ($events | length),
        recognized_event_count: ([ $events[] | select(.type == "message.updated"
          or .type == "message.part.updated" or .type == "step_start"
          or .type == "step_finish" or .type == "text" or .type == "error") ] | length),
        has_error: ($error != null),
        error: (if $error == null then null else {
          name: ($error.error.name // "OpenCodeError"),
          message: ($error.error.data.message // $error.error.message // "opencode emitted an error event"),
          status_code: ($error.error.data.statusCode // $error.error.statusCode // null)
        } end)
      }' "$file" 2>/dev/null)" || out=""
  [[ -n "$out" ]] && printf '%s' "$out" || printf '{"cost":0,"model":"","usage":{},"result":"","event_count":0,"recognized_event_count":0,"has_error":false,"error":null}'
}

cmd_run() {
  local default_model=""
  local task="" span_task="" model="${LEGION_OPENCODE_MODEL:-${OPENCODE_MODEL:-}}" repo="$PWD" base="HEAD" sandbox="workspace-write"
  local archetype="${LEGION_ARCHETYPE:-}"
  local do_apply=0 keep=0 oc_bin="" start_ms=0 end_ms=0 dur=0 rc=0 preset_run_id=""
  local max_runtime_seconds=""
  local base_commit=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --task) task="$2"; shift 2 ;;
      # The task can exceed ARG_MAX once a diff or a long spec is in it.
      # --task-file carries the same value out of band; last flag wins.
      --task-file)
        [[ -r "$2" ]] || die "--task-file not readable: $2"
        task="$(cat "$2")"; shift 2 ;;
      --model) model="$2"; shift 2 ;;
      --archetype) archetype="$2"; shift 2 ;;
      --repo) repo="$2"; shift 2 ;;
      --base) base="$2"; shift 2 ;;
      --sandbox) sandbox="$2"; shift 2 ;;
      --run-id) preset_run_id="$2"; shift 2 ;;
      --max-runtime-seconds) max_runtime_seconds="$2"; shift 2 ;;
      --apply) do_apply=1; shift ;;
      --keep) keep=1; shift ;;
      --quiet) QUIET=1; shift ;;
      *) die "run: unknown arg '$1'" ;;
    esac
  done

  if [[ -n "$preset_run_id" ]]; then
    declare -F legion_write_adapter_run_state >/dev/null 2>&1 \
      || die "run: --run-id requires adapter lifecycle-state support"
    legion_validate_run_id "$preset_run_id" \
      || die "run: invalid --run-id '$preset_run_id'"
  fi
  repo="$(cd "$repo" && pwd)" || die "run: repo does not exist: $repo"
  if declare -F legion_resolve_state >/dev/null 2>&1; then
    legion_resolve_state "$repo"
  else
    export LEGION_STATE_ROOT="${LEGION_STATE_ROOT:-$HOME/.legion/projects/default}"
    export LEGION_TELEMETRY_DIR="${LEGION_TELEMETRY_DIR:-$LEGION_STATE_ROOT/spans}"
  fi
  RUN_ID="${preset_run_id:-$(_run_id)}"
  local wt="$repo/.legion/worktrees/$RUN_ID"
  local art="$repo/.legion/runs/$RUN_ID"
  local branch="legion/opencode-$RUN_ID"
  if [[ -n "$preset_run_id" ]]; then
    legion_arm_adopted_run_guard "$RUN_ID" "$repo" "$art" "$wt" "$branch" \
      "$model" "$sandbox" "$base" "$archetype" ""
  fi
  default_model="$(legion_model_ref opencode_default)" || die "could not resolve opencode_default in models.toml"
  [[ -n "$model" ]] || model="$default_model"
  if [[ -n "$preset_run_id" ]]; then
    legion_arm_adopted_run_guard "$RUN_ID" "$repo" "$art" "$wt" "$branch" \
      "$model" "$sandbox" "$base" "$archetype" ""
  fi
  require_git_repo "$repo"
  [[ -n "$task" ]] || task="$(cat)"
  [[ -n "$task" ]] || die "run: empty task"
  # Keep the complete task out of telemetry process argv. The artifact is
  # written before provider launch and survives a retained containment run.
  span_task="task artifact: $art/task.txt"
  legion_require_top_level_executor "opencode" || return $?
  legion_adapter_resolve_lease opencode "$max_runtime_seconds" || die "$LEGION_ADAPTER_LEASE_REASON"
  validate_sandbox "$sandbox"
  [[ "$sandbox" == "read-only" ]] || scan_task_text "$task"
  local preflight_binary="$OPENCODE_BIN"
  [[ -n "$preflight_binary" || ! -x "$HOME/.opencode/bin/opencode" ]] \
    || preflight_binary="$HOME/.opencode/bin/opencode"
  if ! legion_adapter_preflight opencode "$art" "$sandbox" stdin "$model" "" 0 "$preflight_binary"; then
    local preflight_disposition
    preflight_disposition="$(legion_adapter_preflight_failure_disposition \
      "$LEGION_ADAPTER_PREFLIGHT_PATH")"
    local terminal_status=refused lifecycle_status=failed
    case "$preflight_disposition" in
      timed_out) terminal_status=timed_out; lifecycle_status=timed_out ;;
      containment_failed) terminal_status=containment_failed; lifecycle_status=containment_failed ;;
      launch_failed) terminal_status=failed ;;
    esac
    [[ -z "$preset_run_id" ]] || legion_write_adapter_run_state \
      "$lifecycle_status" "$RUN_ID" "$repo" "$art" "$wt" "$branch" "$model" "$sandbox" \
      "$base" "$archetype"
    [[ -z "$preset_run_id" ]] || legion_disarm_adopted_run_guard
    jq -cn --arg run "$RUN_ID" --arg model "$model" --arg status "$terminal_status" \
      --arg reason "$LEGION_ADAPTER_PREFLIGHT_REASON" \
      --arg preflight "$LEGION_ADAPTER_PREFLIGHT_PATH" '
      {run_id:$run,status:$status,executor:"opencode",model:$model,reason:$reason,
       preflight_receipt:$preflight,attempt_receipt:null,failure_receipt:null,
       usage:null,usage_status:"not_applicable",
       cost_usd:null,cost_status:"not_applicable"}'
    return 1
  fi
  oc_bin="$(jq -r '.identity.executable_path' "$LEGION_ADAPTER_PREFLIGHT_PATH")"
  printf '%s' "$task" | python3 -c '
import os
import shutil
import sys
fd = os.open(sys.argv[1], os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
with os.fdopen(fd, "wb") as output:
    shutil.copyfileobj(sys.stdin.buffer, output)
' "$art/task.txt"
  legion_write_runtime_gitignore "$repo"

  note "-> opencode worktree $wt (branch $branch, base $base)"
  if ! git -C "$repo" worktree add -q -b "$branch" "$wt" "$base"; then
    [[ -z "$preset_run_id" ]] || legion_write_adapter_run_state \
      failed "$RUN_ID" "$repo" "$art" "$wt" "$branch" "$model" "$sandbox" \
      "$base" "$archetype"
    [[ -z "$preset_run_id" ]] || legion_disarm_adopted_run_guard
    die "worktree add failed"
  fi
  [[ -z "$preset_run_id" ]] || legion_write_adapter_run_state \
    running "$RUN_ID" "$repo" "$art" "$wt" "$branch" "$model" "$sandbox" \
    "$base" "$archetype"
  # Pinned while the worktree is still pristine: the executor may commit,
  # and after that HEAD is no longer the starting point.
  base_commit="$(git -C "$wt" rev-parse --verify --quiet HEAD 2>/dev/null || true)"

  local out_file="$art/opencode.out.jsonl"
  local err_file="$art/opencode.err"
  local -a cmd
  cmd=("$oc_bin" run --format json)
  [[ -n "$model" ]] && cmd+=(-m "$model")
  [[ -n "${LEGION_OPENCODE_VARIANT:-}" ]] && cmd+=(--variant "$LEGION_OPENCODE_VARIANT")
  # read-only maps to the non-writing `plan` agent (mirrors cursor's --mode plan).
  [[ "$sandbox" == "read-only" ]] && cmd+=(--agent plan)
  # The task goes on STDIN, not argv. `opencode run` with no message argument
  # reads its prompt from stdin, and a task carrying a diff or a long spec
  # exceeds ARG_MAX -- moving it off the dispatcher's command line only to put
  # it back on the provider's would fix nothing.
  legion_activate_executor_context "$RUN_ID" opencode
  note "-> ${cmd[*]} (task on stdin, $(printf '%s' "$task" | wc -c | tr -d ' ') bytes)"
  local started_at ended_at output_started=false
  local lease_status="$art/lease.json" launch_gate="$art/launch-gate.json"
  SIGNAL_LEASE_STATUS="$lease_status"
  SIGNAL_WORKTREE="$wt"
  legion_adapter_prepare_supervisor_launch_gate "$launch_gate" \
    || die 'unable to prepare trusted supervisor launch gate'
  started_at="$(_now)"
  start_ms="$(date +%s000)"
  set +e
  begin_signal_launch
  abort_pending_signal_launch
  ( cd "$wt" && exec python3 "$LEGION_ADAPTER_SUPERVISOR" --cwd "$wt" \
    --max-runtime-seconds "$LEGION_ADAPTER_MAX_RUNTIME_SECONDS" \
    --status-file "$lease_status" \
    --launch-gate-file "$launch_gate" --launch-gate-token "$LEGION_ADAPTER_LAUNCH_GATE_TOKEN" \
    -- "${cmd[@]}" ) \
    < <(printf '%s' "$task") >"$out_file" 2>"$err_file" &
  CHILD_PID=$!
  SIGNAL_CHILD_PID="$CHILD_PID"
  legion_adapter_complete_supervisor_launch_gate "$CHILD_PID" "$lease_status" SIGNAL_LAUNCH_PENDING
  if [[ "$LEGION_ADAPTER_LAUNCH_GATE_OUTCOME" == started ]]; then
    legion_adapter_arm_signal_receipt "$art" opencode opencode 1 "$model" "" "" "" \
      "$sandbox" "$started_at" "$start_ms" "$out_file"
  elif [[ "$LEGION_ADAPTER_LAUNCH_GATE_OUTCOME" != launch_failed ]]; then
    kill -TERM "$CHILD_PID" 2>/dev/null || true
    wait "$CHILD_PID" 2>/dev/null || true
    CHILD_PID=""; keep=1
    legion_write_adapter_run_state containment_failed "$RUN_ID" "$repo" "$art" \
      "$wt" "$branch" "$model" "$sandbox" "$base" "$archetype" "" || true
    legion_disarm_adopted_run_guard
    legion_adapter_terminalize_launch_gate_containment opencode "$model" "$RUN_ID" \
      "$LEGION_ADAPTER_PREFLIGHT_PATH" "$lease_status" "$launch_gate" "$wt" \
      "$LEGION_ADAPTER_MAX_RUNTIME_SECONDS"
    exit 70
  fi
  finish_signal_launch
  wait "$CHILD_PID"; rc=$?
  SIGNAL_CHILD_RC="$rc"
  CHILD_PID=""
  set -e
  end_ms="$(date +%s000)"; dur=$(( end_ms - start_ms )); ended_at="$(_now)"

  local parsed usage cost result actual_model observed_model opencode_error has_error recognized_events diff_rc=0 status="ok"
  parsed="$(parse_opencode_output "$out_file")"
  usage="$(python3 "$_self_dir/lib/provider-usage.py" opencode "$out_file")"
  cost="$(jq -r '.cost // 0' <<<"$parsed" 2>/dev/null || printf '0')"
  observed_model="$(jq -r '.model // ""' <<<"$parsed" 2>/dev/null || printf '')"
  [[ "$observed_model" != "/" ]] || observed_model=""
  actual_model="$observed_model"; [[ -n "$actual_model" ]] || actual_model="$model"
  result="$(jq -r '.result // ""' <<<"$parsed" 2>/dev/null || printf '')"
  has_error="$(jq -r '.has_error // false' <<<"$parsed" 2>/dev/null || printf 'false')"
  opencode_error="$(jq -r '.error.message // ""' <<<"$parsed" 2>/dev/null || printf '')"
  recognized_events="$(jq -r '.recognized_event_count // 0' <<<"$parsed" 2>/dev/null || printf '0')"

  # opencode omits `cost` for models it can't price (custom / some local providers).
  # When the precomputed cost is 0 but tokens were used, fall back to Legion's own
  # cost table so the span isn't metered at $0 (mirrors legion-cursor.sh).
  if awk -v c="$cost" 'BEGIN{exit !((c+0)==0)}'; then
    local _in _out _cr _cw
    _in="$(jq -r '.input_tokens // 0' <<<"$usage" 2>/dev/null || echo 0)"
    _out="$(jq -r '.output_tokens // 0' <<<"$usage" 2>/dev/null || echo 0)"
    _cr="$(jq -r '.cache_read_input_tokens // 0' <<<"$usage" 2>/dev/null || echo 0)"
    _cw="$(jq -r '.cache_creation_input_tokens // 0' <<<"$usage" 2>/dev/null || echo 0)"
    if [[ "$_in" != "0" || "$_out" != "0" ]]; then
      cost="$(cost_for_model "$actual_model" "$_in" "$_out" "$_cr" "$_cw" 2>/dev/null || echo 0)"
    fi
  fi

  local containment_failed=0 launch_failed=0 launch_timed_out=0
  legion_adapter_supervisor_cleanup_failed "$lease_status" && containment_failed=1
  legion_adapter_supervisor_launch_failed "$lease_status" && launch_failed=1
  legion_adapter_supervisor_timed_out_before_launch "$lease_status" "$rc" \
    && launch_timed_out=1
  if [[ "$containment_failed" -ne 1 ]]; then
    git -C "$wt" add -A 2>/dev/null || diff_rc=1
  # Diff against the worktree's STARTING commit, not HEAD. `diff --cached` alone
  # compares the index to HEAD, so an executor that COMMITS its work yields an
  # empty patch -- HEAD already holds it, nothing is staged, and the run reports
  # ok having lost everything. legion-pi-hermes already pins a base sha for this
  # reason; delegate.sh was fixed in #182 after a benchmark scored 0 on work that
  # had actually been done.
    git -C "$wt" diff --cached ${base_commit:+"$base_commit"} >"$art/diff.patch" 2>/dev/null || diff_rc=1
  else
    : > "$art/diff.patch"
  fi
  if [[ "$containment_failed" -eq 1 ]]; then
    status="containment_failed"
    keep=1
    result="$(legion_adapter_supervisor_reason "$lease_status") (evidence: $lease_status; worktree retained: $wt)"
  elif [[ "$launch_timed_out" -eq 1 ]]; then
    status="timed_out"
    keep=0
    result="$(legion_adapter_lease_reason "$lease_status")"
    usage=null
    cost=null
  elif [[ "$launch_failed" -eq 1 ]]; then
    status="failed"
    result="$(legion_adapter_supervisor_reason "$lease_status" "provider launch failed before process creation")"
    usage=null
    cost=null
  elif legion_adapter_supervisor_timed_out "$lease_status"; then
    status="timed_out"
    keep=0
    result="$(legion_adapter_lease_reason "$lease_status")"
  elif [[ "$rc" -ne 0 ]]; then
    status="failed"
  fi
  if [[ "$status" != "timed_out" && "$status" != "containment_failed" && "$has_error" == "true" ]]; then
    status="failed"
    [[ -n "$result" ]] && result="${result}"$'\n'
    result="${result}opencode error: ${opencode_error:-unknown error}"
  elif [[ "$recognized_events" == "0" && "$status" == "ok" ]]; then
    status="error"
    result="opencode returned no recognized JSONL events; inspect the captured stdout/stderr artifacts."
  fi
  [[ "$diff_rc" -ne 0 && "$status" == "ok" ]] && status="error"
  # Reject a read-only run only if it changed files OUTSIDE .opencode/plans/.
  # opencode's (experimental) plan mode writes its plan there via the write tool;
  # that's the plan output, not an edit to the target repo, so it must not trip the
  # no-write backstop. The default plan agent writes nothing at all.
  if [[ "$sandbox" == "read-only" && "$status" == "ok" ]] \
     && ! git -C "$wt" diff --cached --quiet -- . ':!.opencode/plans' 2>/dev/null; then
    status="error"
    [[ -n "$result" ]] && result="${result}"$'\n'
    result="${result}opencode produced file changes during a read-only run; refusing to apply or report ok."
  fi
  if [[ "$status" == "ok" && -z "$result" && ! -s "$art/diff.patch" ]]; then
    status="error"
    result="opencode completed without a result or a captured diff; refusing to report an empty success."
  fi
  printf '%s\n' "$result" > "$art/last-message.txt"
  if jq -R -s -e '[splits("\n") | fromjson? | select(
      (.type=="message.part.updated" and .properties.part.type? == "text" and ((.properties.part.text // "") | length > 0))
      or (.type=="text" and .part.type? == "text" and ((.part.text // "") | length > 0)))] | length > 0' \
      "$out_file" >/dev/null 2>&1; then
    output_started=true
  fi
  local usage_status=unknown usage_source="" cost_status=unknown cost_source=""
  if jq -R -s -e '[splits("\n") | fromjson? | select(
      (.type=="message.updated" and (.properties.info.role? == "assistant") and (.properties.info.tokens? | type)=="object")
      or (.type=="step_finish" and (.part.tokens? | type)=="object"))] | length > 0' \
      "$out_file" >/dev/null 2>&1; then
    usage_status=known; usage_source=opencode-jsonl
  fi
  if jq -R -s -e '[splits("\n") | fromjson? | select(
      (.type=="message.updated" and (.properties.info.cost? | numbers))
      or (.type=="step_finish" and (.part.cost? | numbers)))] | length > 0' \
      "$out_file" >/dev/null 2>&1; then
    cost_status=known; cost_source=opencode-jsonl
  fi
  local terminal_status=succeeded failure_class=""
  if [[ "$status" != ok ]]; then
    terminal_status=failed
    if [[ "$status" == timed_out ]]; then
      terminal_status=timed_out
      failure_class=timed_out
    elif [[ "$status" == containment_failed ]]; then
      failure_class=internal
    elif [[ "$sandbox" == read-only ]] \
       && ! git -C "$wt" diff --cached --quiet -- . ':!.opencode/plans' 2>/dev/null; then
      failure_class=policy_refused
    elif [[ "$rc" -ne 0 || "$has_error" == true ]]; then
      failure_class=provider
    elif [[ "$recognized_events" == 0 ]]; then
      failure_class=malformed_event
    else
      failure_class=internal
    fi
  fi
  local terminal_usage=null terminal_cost=null
  local terminal_usage_status=not_applicable terminal_cost_status=not_applicable
  local publication_reason=""
  if [[ "$launch_failed" -eq 1 ]]; then
    LEGION_ADAPTER_ATTEMPT_PATH=""
    LEGION_ADAPTER_FAILURE_PATH=""
  else
    legion_adapter_write_attempt "$art" opencode opencode 1 "$model" "$observed_model" "" "" \
      "$sandbox" "$terminal_status" "$started_at" "$ended_at" "$dur" \
      "$usage" "$usage_status" "$usage_source" "$cost" "$cost_status" "$cost_source" \
      "$failure_class" false "$output_started" "$([[ "$rc" -eq 0 ]] || printf '%s' "$rc")" "$result"
    terminal_usage="$(jq -c '.usage' "$LEGION_ADAPTER_ATTEMPT_PATH")"
    terminal_cost="$(jq -c '.cost_usd' "$LEGION_ADAPTER_ATTEMPT_PATH")"
    terminal_usage_status="$(jq -r '.usage_status' "$LEGION_ADAPTER_ATTEMPT_PATH")"
    terminal_cost_status="$(jq -r '.cost_status' "$LEGION_ADAPTER_ATTEMPT_PATH")"
    local artifacts
    artifacts="$(jq -cn --arg wt "$wt" --arg diff "$art/diff.patch" --arg last "$art/last-message.txt" \
      --arg stdout "$out_file" --arg stderr "$err_file" \
      --arg preflight "$LEGION_ADAPTER_PREFLIGHT_PATH" --arg attempt "$LEGION_ADAPTER_ATTEMPT_PATH" \
      --arg failure "$LEGION_ADAPTER_FAILURE_PATH" \
      '{provider_attempt:true,worktree:$wt, diff:$diff, last_message:$last, stdout:$stdout, stderr:$stderr,
        preflight_receipt:$preflight,attempt_receipt:$attempt,
        failure_receipt:(if $failure=="" then null else $failure end)}')"
    local span_usage span_cost span_usage_status span_cost_status
    span_usage="$(jq -c '.usage' "$LEGION_ADAPTER_ATTEMPT_PATH")"
    span_cost="$(jq -c '.cost_usd' "$LEGION_ADAPTER_ATTEMPT_PATH")"
    span_usage_status="$(jq -r '.usage_status' "$LEGION_ADAPTER_ATTEMPT_PATH")"
    span_cost_status="$(jq -r '.cost_status' "$LEGION_ADAPTER_ATTEMPT_PATH")"
    if ! legion_adapter_emit_normal_provider_span "$LEGION_ADAPTER_ATTEMPT_PATH" \
        "opencode" "$actual_model" "$status" "$dur" "$span_cost" "$span_usage" "$span_task" "$artifacts" \
        "$span_usage_status" "$span_cost_status"; then
      status=containment_failed
      rc=70
      keep=1
      publication_reason="provider attempt receipt is durable but its span publication is uncertain; worktree and evidence retained"
      result="$publication_reason"
    fi
  fi
  legion_adapter_disarm_signal_receipt
  SIGNAL_CHILD_PID=""
  SIGNAL_CHILD_RC=0
  SIGNAL_LEASE_STATUS=""
  SIGNAL_WORKTREE=""

  if [[ "$do_apply" -eq 1 && "$status" == "ok" && -s "$art/diff.patch" ]]; then
    if git -C "$repo" apply --check "$art/diff.patch" 2>/dev/null; then
      git -C "$repo" apply "$art/diff.patch" && note "diff applied to $repo"
    else
      note "diff did not apply cleanly; left in $art/diff.patch"
    fi
  fi

  local wt_report="$wt"
  if [[ "$keep" -eq 0 ]]; then
    git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
    git -C "$repo" branch -D "$branch" >/dev/null 2>&1 || true
    git -C "$repo" worktree prune >/dev/null 2>&1 || true
    wt_report="(removed; rerun with --keep to retain the worktree)"
  fi

  [[ -z "$preset_run_id" ]] || legion_write_adapter_run_state \
    "$status" "$RUN_ID" "$repo" "$art" "$wt_report" "$branch" "$actual_model" \
    "$sandbox" "$base" "$archetype"
  [[ -z "$preset_run_id" ]] || legion_disarm_adopted_run_guard

  local receipt_reason=""
  if [[ -n "$publication_reason" ]]; then
    receipt_reason="$publication_reason"
  elif [[ "$status" == timed_out ]]; then
    receipt_reason="$(legion_adapter_lease_reason "$lease_status")"
  elif [[ "$status" == containment_failed || "$launch_failed" -eq 1 ]]; then
    receipt_reason="$(legion_adapter_supervisor_reason "$lease_status")"
  fi
  jq -cn --arg run "$RUN_ID" --arg status "$status" --arg model "$actual_model" \
    --arg wt "$wt_report" --arg diff "$art/diff.patch" --arg last "$art/last-message.txt" \
    --arg result "$result" --arg opencode_error "$opencode_error" \
    --arg preflight "$LEGION_ADAPTER_PREFLIGHT_PATH" --arg attempt "$LEGION_ADAPTER_ATTEMPT_PATH" \
    --arg failure "$LEGION_ADAPTER_FAILURE_PATH" \
    --arg reason "$receipt_reason" \
    --arg lease "$lease_status" \
    --arg usage_status "$terminal_usage_status" --arg cost_status "$terminal_cost_status" \
    --argjson usage "$terminal_usage" --argjson cost "$terminal_cost" --argjson rc "$rc" '
    {run_id:$run, status:$status, executor:"opencode", model:$model, opencode_exit:$rc,
     result:$result, opencode_error:(if $opencode_error == "" then null else $opencode_error end),
     worktree:$wt, diff_path:$diff, last_message_path:$last,
     usage:$usage,usage_status:$usage_status,
     cost_usd:$cost,cost_status:$cost_status,
     preflight_receipt:$preflight,
     attempt_receipt:(if $attempt=="" then null else $attempt end),
     failure_receipt:(if $failure=="" then null else $failure end),lease_receipt:$lease}
     + (if $reason=="" then {} else {reason:$reason} end)'
  [[ "$status" == "ok" ]] || exit 1
}

usage() {
  cat <<'EOF'
legion-opencode — delegate a scoped task to opencode headless.

Usage:
  legion-opencode run --task "TASK" | --task-file F [--model provider/model] [--archetype NAME] [--repo DIR] [--run-id ID] [--max-runtime-seconds N]
                      [--base REF] [--sandbox read-only|workspace-write] [--apply] [--keep] [--quiet]
  legion-opencode run [--repo DIR] < task.txt

Model is provider/model; the default resolves from
legion-router/config/models.toml (opencode_default). Set OPENCODE_BIN to override
the binary; Legion pins $HOME/.opencode/bin/opencode first. LEGION_OPENCODE_VARIANT
sets the reasoning variant (high|max|minimal).
EOF
}

main() {
  local subcmd="${1:-}"
  case "$subcmd" in
    run) shift; cmd_run "$@" ;;
    ""|-h|--help|help) usage ;;
    *) die "unknown command '$subcmd'" ;;
  esac
}

main "$@"
