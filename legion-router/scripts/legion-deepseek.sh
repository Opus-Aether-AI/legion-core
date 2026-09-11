#!/usr/bin/env bash
# legion-deepseek — delegate a scoped task to DeepSeek Harness (`dsh`) and
# capture a metered Legion span + diff. Mirrors legion-opencode.sh (worktree +
# diff + span) with dsh-specific invocation.
#
# WHY THE INVOCATION LOOKS LIKE THIS
#
# dsh is a plugin harness whose CLI registers only `plugin` and `web`; there is
# no `dsh run`. Headless execution lives in the @deepseek-ai/dsh-headless
# bundle, described by its own package as "a direct core Agent/Session runner
# over dsh-base with no Host, HTTP, or browser layer", which takes one task and
# drives it to quiescence. A bundle is reached the way every dsh app is reached:
#
#   dsh --profile <name> [args...]     # args are forwarded to the profile's app
#
# So this adapter runs `dsh --profile "$DSH_PROFILE" <task>` inside the
# worktree. The profile is NOT shipped by dsh -- its presets are code, cordis,
# minimal and standard, none of which load the headless bundle -- so a working
# integration requires a profile that does. LEGION_DSH_PROFILE (or DSH_PROFILE)
# names it; `legion-doctor` reports the executor unusable until dsh is installed
# and that profile resolves, rather than failing at delegation time.
#
# WHAT IS DELIBERATELY NOT CLAIMED
#
# dsh at 0.1.1-rc.2 is a developer preview and publishes no headless output
# contract: no JSON envelope, no documented token or cost fields (a
# dsh-token-meter package exists but exposes nothing through this path). This
# adapter therefore reports ZERO usage and lets Legion's cost table price
# nothing, rather than inventing numbers that would flow into cost reports and
# routing decisions. The diff is the deliverable and is computed by Legion from
# the worktree, exactly as for every `contract = "diff"` executor -- which is
# why the missing output contract does not block delegation, only metering.

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

DSH_BIN="${DSH_BIN:-}"
DSH_PROFILE="${LEGION_DSH_PROFILE:-${DSH_PROFILE:-legion-headless}}"
CHILD_PID=""
SIGNAL_LEASE_STATUS=""
SIGNAL_WORKTREE=""
SIGNAL_CHILD_PID=""
SIGNAL_CHILD_RC=0
SIGNAL_LAUNCH_PENDING=""

die() { printf 'legion-deepseek: %s\n' "$*" >&2; exit 2; }
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
    legion_adapter_fail_recorded_attempt "$LEGION_ADAPTER_SIGNAL_ART" deepseek \
      "$LEGION_ADAPTER_SIGNAL_ORDINAL" internal 70 "$containment_reason" || true
    if [[ -n "${preset_run_id:-}" ]]; then
      legion_write_adapter_run_state containment_failed "$RUN_ID" "$repo" \
        "$LEGION_ADAPTER_SIGNAL_ART" "$SIGNAL_WORKTREE" "$branch" "$model" "$sandbox" \
        "$base" "$archetype" "" || true
      legion_disarm_adopted_run_guard
    fi
    legion_adapter_emit_signal_span "${task:-}" "$SIGNAL_LEASE_STATUS" || true
    exit 70
  fi
  legion_adapter_emit_signal_span "${task:-}" "$SIGNAL_LEASE_STATUS" || true
  exit $((128+signum))
}
begin_signal_launch() {
  SIGNAL_LAUNCH_PENDING=""
  trap 'SIGNAL_LAUNCH_PENDING=2' INT
  trap 'SIGNAL_LAUNCH_PENDING=15' TERM
  trap 'SIGNAL_LAUNCH_PENDING=1' HUP
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

resolve_dsh_bin() {
  if [[ -n "$DSH_BIN" ]]; then
    command -v "$DSH_BIN" 2>/dev/null && return 0
    [[ -x "$DSH_BIN" ]] && { printf '%s\n' "$DSH_BIN"; return 0; }
    return 1
  fi
  command -v dsh 2>/dev/null && return 0
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
  declare -F legion_scan_task_text >/dev/null 2>&1 || return 0
  legion_scan_task_text "$1"
}

emit_span() {
  local executor="$1" model="$2" status="$3" dur="$4" cost="$5" usage="$6" task="$7" artifacts="$8"
  local usage_status="${9:-unknown}" cost_status="${10:-unknown}"
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
      >> "$LEGION_TELEMETRY_DIR/$(_today).jsonl"
  } 2>/dev/null || true
}

cmd_run() {
  local default_model=""
  local task="" model="${LEGION_DEEPSEEK_MODEL:-${DSH_MODEL:-}}" repo="$PWD" base="HEAD" sandbox="workspace-write"
  local requested_model="$model"
  local archetype="${LEGION_ARCHETYPE:-}"
  local do_apply=0 keep=0 dsh_bin="" start_ms=0 end_ms=0 dur=0 rc=0 preset_run_id=""
  local max_runtime_seconds=""
  local base_commit=""
  local reported_model="unknown"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --task) task="$2"; shift 2 ;;
      # The task can exceed ARG_MAX once a diff or a long spec is in it.
      --task-file)
        [[ -r "$2" ]] || die "--task-file not readable: $2"
        task="$(cat "$2")"; shift 2 ;;
      --model) model="$2"; requested_model="$2"; shift 2 ;;
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
  local branch="legion/deepseek-$RUN_ID"
  default_model="$(legion_model_ref deepseek_default)" || die "could not resolve deepseek_default in models.toml"
  [[ -n "$model" ]] || model="$default_model"
  # dsh exposes no effective-model contract and this adapter does not pass a
  # model selector to the provider. Keep lifecycle, spans, and every top-level
  # result opaque instead of presenting the routing placeholder as observed.
  model="$reported_model"
  if [[ -n "$preset_run_id" ]]; then
    legion_arm_adopted_run_guard "$RUN_ID" "$repo" "$art" "$wt" "$branch" \
      "$model" "$sandbox" "$base" "$archetype" ""
  fi
  require_git_repo "$repo"
  [[ -n "$task" ]] || task="$(cat)"
  [[ -n "$task" ]] || die "run: empty task"
  legion_require_top_level_executor "deepseek" || return $?
  legion_adapter_resolve_lease deepseek "$max_runtime_seconds" || die "$LEGION_ADAPTER_LEASE_REASON"
  validate_sandbox "$sandbox"
  [[ "$sandbox" == "read-only" ]] || scan_task_text "$task"
  if ! legion_adapter_preflight deepseek "$art" "$sandbox" argv \
      "$requested_model" "" 0 "$DSH_BIN"; then
    [[ -z "$preset_run_id" ]] || legion_write_adapter_run_state \
      failed "$RUN_ID" "$repo" "$art" "$wt" "$branch" "$model" "$sandbox" \
      "$base" "$archetype"
    [[ -z "$preset_run_id" ]] || legion_disarm_adopted_run_guard
    jq -cn --arg run "$RUN_ID" --arg model "$model" \
      --arg reason "$LEGION_ADAPTER_PREFLIGHT_REASON" \
      --arg preflight "$LEGION_ADAPTER_PREFLIGHT_PATH" '
      {run_id:$run,executor:"deepseek",model:$model,status:"refused",reason:$reason,
       preflight_receipt:$preflight,attempt_receipt:null,failure_receipt:null,
       usage:null,tokens:null,usage_status:"not_applicable",
       cost_usd:null,cost_status:"not_applicable"}'
    return 1
  fi
  dsh_bin="$(jq -r '.identity.executable_path' "$LEGION_ADAPTER_PREFLIGHT_PATH")"
  legion_write_runtime_gitignore "$repo"

  note "-> deepseek worktree $wt (branch $branch, base $base)"
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

  local out_file="$art/deepseek.out.txt"
  local err_file="$art/deepseek.err"
  local -a cmd
  cmd=("$dsh_bin" --profile "$DSH_PROFILE")
  # read-only has no dsh equivalent: the headless bundle carries whatever tools
  # its profile loads, and there is no documented flag that withholds the write
  # and bash tools. Shared preflight therefore rejects read-only before this
  # launch path is reachable instead of pretending a post-hoc diff check is a
  # sandbox.
  legion_activate_executor_context "$RUN_ID" deepseek
  note "-> ${cmd[*]} (task on argv, $(printf '%s' "$task" | wc -c | tr -d ' ') bytes)"
  local started_at ended_at output_started=false failure_class="" terminal_status=succeeded
  local lease_status="$art/lease.json"
  SIGNAL_LEASE_STATUS="$lease_status"
  SIGNAL_WORKTREE="$wt"
  started_at="$(_now)"
  start_ms="$(date +%s000)"
  set +e
  begin_signal_launch
  ( cd "$wt" && exec python3 "$LEGION_ADAPTER_SUPERVISOR" --cwd "$wt" \
      --max-runtime-seconds "$LEGION_ADAPTER_MAX_RUNTIME_SECONDS" \
      --status-file "$lease_status" -- "${cmd[@]}" "$task" ) >"$out_file" 2>"$err_file" &
  CHILD_PID=$!
  SIGNAL_CHILD_PID="$CHILD_PID"
  legion_adapter_arm_signal_receipt "$art" deepseek dsh 1 "$requested_model" "" "" "" \
    "$sandbox" "$started_at" "$start_ms" "$out_file"
  finish_signal_launch
  wait "$CHILD_PID"; rc=$?
  SIGNAL_CHILD_RC="$rc"
  CHILD_PID=""
  set -e
  end_ms="$(date +%s000)"; dur=$(( end_ms - start_ms )); ended_at="$(_now)"

  # dsh publishes no headless usage contract. Preserve that as unknown/null all
  # the way through spans and aggregation; zero would falsely mean a measured
  # free run.
  local usage=null cost=null result="" diff_rc=0 status="ok"
  result="$(cat "$out_file" 2>/dev/null || true)"

  local containment_failed=0
  legion_adapter_supervisor_cleanup_failed "$lease_status" && containment_failed=1
  if [[ "$containment_failed" -ne 1 ]]; then
    git -C "$wt" add -A 2>/dev/null || diff_rc=1
  # Diff against the worktree's STARTING commit, not HEAD -- an executor that
  # commits its work would otherwise produce an empty patch.
    git -C "$wt" diff --cached ${base_commit:+"$base_commit"} >"$art/diff.patch" 2>/dev/null || diff_rc=1
  else
    : > "$art/diff.patch"
  fi
  if [[ "$containment_failed" -eq 1 ]]; then
    status="containment_failed"
    keep=1
    result="$(legion_adapter_supervisor_reason "$lease_status") (evidence: $lease_status; worktree retained: $wt)"
  elif legion_adapter_supervisor_timed_out "$lease_status"; then
    status="timed_out"
    keep=0
    result="$(legion_adapter_lease_reason "$lease_status")"
  elif [[ "$rc" -ne 0 ]]; then
    status="failed"
  fi
  [[ "$diff_rc" -ne 0 && "$status" == "ok" ]] && status="error"
  if [[ "$sandbox" == "read-only" && "$status" == "ok" ]] \
     && ! git -C "$wt" diff --cached --quiet 2>/dev/null; then
    status="error"
    [[ -n "$result" ]] && result="${result}"$'\n'
    result="${result}deepseek produced file changes during a read-only run; refusing to apply or report ok."
  fi
  if [[ "$status" == "ok" && -z "$result" && ! -s "$art/diff.patch" ]]; then
    status="error"
    result="dsh completed without a result or a captured diff; refusing to report an empty success."
  fi
  printf '%s\n' "$result" > "$art/last-message.txt"
  legion_adapter_output_started_file "$out_file" && output_started=true
  if [[ "$status" != ok ]]; then
    terminal_status=failed
    if [[ "$status" == timed_out ]]; then
      terminal_status=timed_out; failure_class=timed_out
    elif [[ "$status" == containment_failed ]]; then
      failure_class=internal
    elif [[ "$rc" -ne 0 ]]; then failure_class=provider; else failure_class=malformed_event; fi
  fi
  legion_adapter_write_attempt "$art" deepseek dsh 1 "$requested_model" "" "" "" \
    "$sandbox" "$terminal_status" "$started_at" "$ended_at" "$dur" \
    null unknown '' null unknown '' "$failure_class" false "$output_started" \
    "$([[ "$rc" -eq 0 ]] || printf '%s' "$rc")" "$result"
  local artifacts
  artifacts="$(jq -cn --arg wt "$wt" --arg diff "$art/diff.patch" --arg last "$art/last-message.txt" \
    --arg stdout "$out_file" --arg stderr "$err_file" --arg profile "$DSH_PROFILE" \
    --arg preflight "$LEGION_ADAPTER_PREFLIGHT_PATH" --arg attempt "$LEGION_ADAPTER_ATTEMPT_PATH" \
    --arg failure "$LEGION_ADAPTER_FAILURE_PATH" \
    '{provider_attempt:true,worktree:$wt, diff:$diff, last_message:$last, stdout:$stdout, stderr:$stderr,
      dsh_profile:$profile,preflight_receipt:$preflight,attempt_receipt:$attempt,
      failure_receipt:(if $failure=="" then null else $failure end)}')"
  legion_adapter_emit_normal_provider_span "$LEGION_ADAPTER_ATTEMPT_PATH" \
    "deepseek" "$reported_model" "$status" "$dur" "$cost" "$usage" "$task" "$artifacts" \
    unknown unknown
  legion_adapter_disarm_signal_receipt
  SIGNAL_CHILD_PID=""
  SIGNAL_CHILD_RC=0
  SIGNAL_LEASE_STATUS=""
  SIGNAL_WORKTREE=""

  if [[ "$do_apply" == "1" && "$status" == "ok" && -s "$art/diff.patch" ]]; then
    if git -C "$repo" apply --check "$art/diff.patch" 2>/dev/null; then
      git -C "$repo" apply "$art/diff.patch" && note "✓ diff applied to $repo"
    else
      note "⚠ diff does not apply cleanly to $repo; left unapplied"
    fi
  fi

  if [[ "$keep" != "1" ]]; then
    # stdout too, not just stderr: `git branch -D` announces "Deleted branch ..."
    # on STDOUT, and this function's stdout is the JSON receipt its caller parses.
    git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
    git -C "$repo" branch -D "$branch" >/dev/null 2>&1 || true
  fi

  [[ -z "$preset_run_id" ]] || legion_write_adapter_run_state \
    "$status" "$RUN_ID" "$repo" "$art" "$wt" "$branch" "$model" "$sandbox" \
    "$base" "$archetype"
  [[ -z "$preset_run_id" ]] || legion_disarm_adopted_run_guard

  jq -cn --arg run_id "$RUN_ID" --arg executor deepseek --arg model "$reported_model" \
    --arg status "$status" --arg diff "$art/diff.patch" --arg last "$art/last-message.txt" \
    --arg wt "$wt" --argjson usage "$usage" --argjson cost "$cost" \
    --arg preflight "$LEGION_ADAPTER_PREFLIGHT_PATH" --arg attempt "$LEGION_ADAPTER_ATTEMPT_PATH" \
    --arg failure "$LEGION_ADAPTER_FAILURE_PATH" \
    --arg reason "$([[ "$status" == timed_out ]] && legion_adapter_lease_reason "$lease_status" || [[ "$status" == containment_failed ]] && legion_adapter_supervisor_reason "$lease_status")" \
    --arg lease "$lease_status" \
    '{run_id:$run_id, executor:$executor, model:$model, status:$status,
      diff_path:$diff, last_message:$last, worktree:$wt,
      usage:$usage,tokens:$usage,usage_status:"unknown",
      cost_usd:$cost,cost_status:"unknown",
      preflight_receipt:$preflight,attempt_receipt:$attempt,
      failure_receipt:(if $failure=="" then null else $failure end),lease_receipt:$lease}
      + (if $reason=="" then {} else {reason:$reason} end)'
  [[ "$status" == "ok" ]]
}

usage_text() {
  cat <<'USAGE'
legion-deepseek — delegate a scoped task to DeepSeek Harness (dsh)

  legion-deepseek run [--task T | --task-file F] [--model M] [--repo DIR]
                      [--base REF] [--sandbox read-only|workspace-write]
                      [--archetype A] [--max-runtime-seconds N] [--apply] [--keep] [--quiet]

Environment:
  DSH_BIN              path to the dsh binary (default: dsh on PATH)
  LEGION_DSH_PROFILE   dsh profile that loads @deepseek-ai/dsh-headless
                       (default: legion-headless). dsh ships no such preset;
                       see docs for authoring one.
USAGE
}

main() {
  case "${1:-}" in
    run) shift; cmd_run "$@" ;;
    -h|--help|help|"") usage_text ;;
    *) die "unknown command '$1'" ;;
  esac
}

main "$@"
