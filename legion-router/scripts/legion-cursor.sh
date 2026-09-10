#!/usr/bin/env bash
# legion-cursor — delegate a scoped task to Cursor Agent headless and capture a
# metered Legion span. Cursor docs expose `agent -p` for headless automation; some
# installs also provide `cursor-agent`, so this wrapper supports both.

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

CURSOR_AGENT_BIN="${CURSOR_AGENT_BIN:-}"
CHILD_PID=""
SIGNAL_LEASE_STATUS=""
SIGNAL_WORKTREE=""
SIGNAL_CHILD_PID=""
SIGNAL_CHILD_RC=0

die() { printf 'legion-cursor: %s\n' "$*" >&2; exit 2; }
note() { [[ "${QUIET:-0}" == "1" ]] || printf '%s\n' "$*" >&2; }
on_signal() {
  local signum="$1" child_rc="$SIGNAL_CHILD_RC" containment_reason="" supervised_pid="${SIGNAL_CHILD_PID:-unknown}"
  trap - INT TERM HUP
  if [[ -n "$CHILD_PID" ]]; then
    kill -TERM "$CHILD_PID" 2>/dev/null || true
    wait "$CHILD_PID" 2>/dev/null || child_rc=$?
    CHILD_PID=""
  fi
  legion_adapter_write_signal_receipt "$signum"
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
    legion_adapter_fail_recorded_attempt "$LEGION_ADAPTER_SIGNAL_ART" cursor \
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
trap 'declare -F legion_terminalize_adopted_run_on_exit >/dev/null 2>&1 && legion_terminalize_adopted_run_on_exit' EXIT
trap 'on_signal 2' INT
trap 'on_signal 15' TERM
trap 'on_signal 1' HUP

_now()    { date -u +%Y-%m-%dT%H:%M:%SZ; }
_today()  { date -u +%Y-%m-%d; }
_run_id() { legion_new_run_id; }

resolve_cursor_bin() {
  if [[ -n "$CURSOR_AGENT_BIN" ]]; then
    command -v "$CURSOR_AGENT_BIN" 2>/dev/null && return 0
    return 1
  fi
  command -v agent 2>/dev/null && return 0
  command -v cursor-agent 2>/dev/null && return 0
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
      >> "$LEGION_TELEMETRY_DIR/$(_today).jsonl"
  } 2>/dev/null || true
}

usage_json() {
  local file="$1"
  local usage
  # cursor-agent reports camelCase token keys (inputTokens/outputTokens/
  # cacheReadTokens/cacheWriteTokens). Normalize to the canonical snake_case
  # keys so spans aggregate in legion-aggregate / legion-bench token totals.
  usage="$(jq -c '
    (.usage // .tokens // {}) as $u
    | {
        input_tokens: ($u.input_tokens // $u.inputTokens // 0),
        output_tokens: ($u.output_tokens // $u.outputTokens // 0),
        cache_read_input_tokens: ($u.cache_read_input_tokens // $u.cacheReadTokens // $u.cached_input_tokens // 0),
        cache_creation_input_tokens: ($u.cache_creation_input_tokens // $u.cacheWriteTokens // 0)
      }' "$file" 2>/dev/null || true)"
  [[ -n "$usage" ]] && printf '%s' "$usage" || printf '{}'
}

result_text() {
  local file="$1"
  if jq -e . "$file" >/dev/null 2>&1; then
    jq -r '.result // .text // .response // .message // ""' "$file" 2>/dev/null || true
  else
    cat "$file" 2>/dev/null || true
  fi
}

cost_from_output() {
  local file="$1" model="$2" usage="$3"
  if jq -e '.total_cost_usd | numbers' "$file" >/dev/null 2>&1; then
    jq -r '.total_cost_usd' "$file"
    return 0
  fi
  local input output cache_read cache_write
  input="$(jq -r '.input_tokens // 0' <<<"$usage" 2>/dev/null || printf '0')"
  output="$(jq -r '.output_tokens // 0' <<<"$usage" 2>/dev/null || printf '0')"
  cache_read="$(jq -r '.cache_read_input_tokens // .cached_input_tokens // 0' <<<"$usage" 2>/dev/null || printf '0')"
  cache_write="$(jq -r '.cache_creation_input_tokens // 0' <<<"$usage" 2>/dev/null || printf '0')"
  cost_for_model "$model" "$input" "$output" "$cache_read" "$cache_write" 2>/dev/null || printf '0'
}

actual_model_from_output() {
  local file="$1" fallback="$2" got=""
  got="$(jq -r '.model // .metadata.model // .response.model // empty' "$file" 2>/dev/null || true)"
  [[ -n "$got" && "$got" != "null" ]] && printf '%s' "$got" || printf '%s' "$fallback"
}

cmd_run() {
  local default_model=""
  local task="" model="${LEGION_CURSOR_MODEL:-${CURSOR_MODEL:-}}" repo="$PWD" base="HEAD" sandbox="workspace-write"
  local archetype="${LEGION_ARCHETYPE:-}"
  local do_apply=0 keep=0 agent_bin="" start_ms=0 end_ms=0 dur=0 rc=0 preset_run_id=""
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
  local branch="legion/cursor-$RUN_ID"
  if [[ -n "$preset_run_id" ]]; then
    legion_arm_adopted_run_guard "$RUN_ID" "$repo" "$art" "$wt" "$branch" \
      "$model" "$sandbox" "$base" "$archetype" ""
  fi
  default_model="$(legion_model_ref cursor_default)" || die "could not resolve cursor_default in models.toml"
  [[ -n "$model" ]] || model="$default_model"
  if [[ -n "$preset_run_id" ]]; then
    legion_arm_adopted_run_guard "$RUN_ID" "$repo" "$art" "$wt" "$branch" \
      "$model" "$sandbox" "$base" "$archetype" ""
  fi
  require_git_repo "$repo"
  [[ -n "$task" ]] || task="$(cat)"
  [[ -n "$task" ]] || die "run: empty task"
  legion_require_top_level_executor "cursor" || return $?
  legion_adapter_resolve_lease cursor "$max_runtime_seconds" || die "$LEGION_ADAPTER_LEASE_REASON"
  validate_sandbox "$sandbox"
  [[ "$sandbox" == "read-only" ]] || scan_task_text "$task"
  # Resolve the documented aliases before admission so the shared preflight
  # fingerprints the exact executable that will be launched. Passing an empty
  # override made it check the registry's `agent` even when only the supported
  # `cursor-agent` alias was installed.
  if ! agent_bin="$(resolve_cursor_bin)"; then
    agent_bin="${CURSOR_AGENT_BIN:-agent}"
  fi
  if ! legion_adapter_preflight cursor "$art" "$sandbox" argv "$model" "" 0 "$agent_bin"; then
    [[ -z "$preset_run_id" ]] || legion_write_adapter_run_state \
      failed "$RUN_ID" "$repo" "$art" "$wt" "$branch" "$model" "$sandbox" \
      "$base" "$archetype"
    [[ -z "$preset_run_id" ]] || legion_disarm_adopted_run_guard
    jq -cn --arg run "$RUN_ID" --arg model "$model" \
      --arg reason "$LEGION_ADAPTER_PREFLIGHT_REASON" \
      --arg preflight "$LEGION_ADAPTER_PREFLIGHT_PATH" '
      {run_id:$run,status:"refused",executor:"cursor",model:$model,reason:$reason,
       preflight_receipt:$preflight,attempt_receipt:null,failure_receipt:null,
       usage:{},cost_usd:0}'
    return 1
  fi
  agent_bin="$(jq -r '.identity.executable_path' "$LEGION_ADAPTER_PREFLIGHT_PATH")"
  legion_write_runtime_gitignore "$repo"

  note "-> cursor worktree $wt (branch $branch, base $base)"
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

  local out_file="$art/cursor.out.json"
  local err_file="$art/cursor.err"
  local -a cmd
  cmd=("$agent_bin" -p --output-format json --trust)
  if [[ "$sandbox" == "read-only" ]]; then
    cmd+=(--mode plan)
  else
    cmd+=(--force)
  fi
  [[ -n "$model" ]] && cmd+=(--model "$model")
  # cursor-agent takes its prompt positionally and documents no stdin form, so
  # this hop remains bounded by ARG_MAX. Say so before the kernel does: the
  # failure is otherwise a bare "Argument list too long" from deep in a
  # delegation.
  # ${#task} counts CHARACTERS; MAX_ARG_STRLEN and ARG_MAX are byte limits, so a
  # multibyte task can blow the real ceiling while the character count looks safe.
  local task_bytes
  task_bytes="$(printf '%s' "$task" | wc -c | tr -d ' ')"
  if [[ "$task_bytes" -gt 100000 ]]; then
    note "⚠ task is $task_bytes bytes; cursor takes its prompt on argv and may exceed ARG_MAX"
  fi
  cmd+=("$task")

  # Headless mode needs an API key. An interactive `agent login` session does
  # not grant `-p` access, and the CLI's own message ("run 'agent login'") sends
  # you back to the thing you already did.
  #
  # This must NOT rely on `note`: fan-out and the prompt-based review fallback
  # always pass --quiet, which makes note a no-op -- so the explanation would be
  # missing from exactly the paths that motivated it. Record it and attach it to
  # the returned result instead.
  local cursor_auth_hint=""
  if [[ -z "${CURSOR_API_KEY:-}" ]]; then
    cursor_auth_hint="CURSOR_API_KEY is unset; cursor headless runs require it even when '$agent_bin status' reports a login"
    note "⚠ $cursor_auth_hint"
  fi
  legion_activate_executor_context "$RUN_ID" cursor
  note "-> ${cmd[*]}"
  local started_at ended_at output_started=false
  local lease_status="$art/lease.json"
  SIGNAL_LEASE_STATUS="$lease_status"
  SIGNAL_WORKTREE="$wt"
  started_at="$(_now)"
  start_ms="$(date +%s000)"
  legion_adapter_arm_signal_receipt "$art" cursor cursor 1 "$model" "" "" "" \
    "$sandbox" "$started_at" "$start_ms" "$out_file"
  set +e
  ( cd "$wt" && exec python3 "$LEGION_ADAPTER_SUPERVISOR" --cwd "$wt" \
      --max-runtime-seconds "$LEGION_ADAPTER_MAX_RUNTIME_SECONDS" \
      --status-file "$lease_status" -- "${cmd[@]}" ) >"$out_file" 2>"$err_file" &
  CHILD_PID=$!
  SIGNAL_CHILD_PID="$CHILD_PID"
  wait "$CHILD_PID"; rc=$?
  SIGNAL_CHILD_RC="$rc"
  CHILD_PID=""
  set -e
  end_ms="$(date +%s000)"; dur=$(( end_ms - start_ms )); ended_at="$(_now)"

  local usage cost result actual_model observed_model diff_rc=0 status="ok"
  usage="$(usage_json "$out_file")"
  observed_model="$(actual_model_from_output "$out_file" "")"
  actual_model="$observed_model"; [[ -n "$actual_model" ]] || actual_model="$model"
  cost="$(cost_from_output "$out_file" "$actual_model" "$usage")"
  result="$(result_text "$out_file")"
  local containment_failed=0
  legion_adapter_supervisor_cleanup_failed "$lease_status" && containment_failed=1
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
  elif legion_adapter_supervisor_timed_out "$lease_status"; then
    status="timed_out"
    keep=0
    result="$(legion_adapter_lease_reason "$lease_status")"
  elif [[ "$rc" -ne 0 ]]; then
    status="failed"
  fi
  [[ "$diff_rc" -ne 0 && "$status" == "ok" ]] && status="error"
  if [[ "$sandbox" == "read-only" && -s "$art/diff.patch" && "$status" == "ok" ]]; then
    status="error"
    [[ -n "$result" ]] && result="${result}"$'\n'
    result="${result}Cursor produced file changes during a read-only run; refusing to apply or report ok."
  fi
  printf '%s\n' "$result" > "$art/last-message.txt"
  [[ -n "$result" ]] && output_started=true
  local usage_status=unknown usage_source="" cost_status=unknown cost_source=""
  if jq -e '((.usage // .tokens) | type) == "object"' "$out_file" >/dev/null 2>&1; then
    usage_status=known; usage_source=cursor-json
    if jq -e '.total_cost_usd | numbers' "$out_file" >/dev/null 2>&1; then
      cost_status=known; cost_source=cursor-json
    elif cost_model_has_pricing "$actual_model"; then
      cost_status=known; cost_source=legion-cost-table
    fi
  fi
  local terminal_status=succeeded failure_class=""
  if [[ "$status" != ok ]]; then
    terminal_status=failed
    if [[ "$status" == timed_out ]]; then
      terminal_status=timed_out
      failure_class=timed_out
    elif [[ "$status" == containment_failed ]]; then
      failure_class=internal
    elif [[ "$sandbox" == read-only && -s "$art/diff.patch" ]]; then
      failure_class=policy_refused
    elif [[ "$rc" -ne 0 ]]; then
      failure_class=provider
    else
      failure_class=internal
    fi
  fi
  legion_adapter_write_attempt "$art" cursor cursor 1 "$model" "$observed_model" "" "" \
    "$sandbox" "$terminal_status" "$started_at" "$ended_at" "$dur" \
    "$usage" "$usage_status" "$usage_source" "$cost" "$cost_status" "$cost_source" \
    "$failure_class" false "$output_started" "$([[ "$rc" -eq 0 ]] || printf '%s' "$rc")" "$result"
  legion_adapter_disarm_signal_receipt
  SIGNAL_CHILD_PID=""
  SIGNAL_CHILD_RC=0
  SIGNAL_LEASE_STATUS=""
  SIGNAL_WORKTREE=""

  local artifacts
  artifacts="$(jq -cn --arg wt "$wt" --arg diff "$art/diff.patch" --arg last "$art/last-message.txt" \
    --arg stdout "$out_file" --arg stderr "$err_file" \
    --arg preflight "$LEGION_ADAPTER_PREFLIGHT_PATH" --arg attempt "$LEGION_ADAPTER_ATTEMPT_PATH" \
    --arg failure "$LEGION_ADAPTER_FAILURE_PATH" \
    '{worktree:$wt, diff:$diff, last_message:$last, stdout:$stdout, stderr:$stderr,
      preflight_receipt:$preflight,attempt_receipt:$attempt,
      failure_receipt:(if $failure=="" then null else $failure end)}')"
  local span_usage span_cost span_usage_status span_cost_status
  span_usage="$(jq -c '.usage' "$LEGION_ADAPTER_ATTEMPT_PATH")"
  span_cost="$(jq -c '.cost_usd' "$LEGION_ADAPTER_ATTEMPT_PATH")"
  span_usage_status="$(jq -r '.usage_status' "$LEGION_ADAPTER_ATTEMPT_PATH")"
  span_cost_status="$(jq -r '.cost_status' "$LEGION_ADAPTER_ATTEMPT_PATH")"
  emit_span "cursor" "$actual_model" "$status" "$dur" "$span_cost" "$span_usage" "$task" "$artifacts" \
    "$span_usage_status" "$span_cost_status"

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

  # A failed run that had no API key almost certainly failed FOR that reason, and
  # cursor's own stderr stays in an internal artifact the caller never reads.
  local auth_note=""
  [[ "$status" == "ok" ]] || auth_note="$cursor_auth_hint"

  jq -cn --arg run "$RUN_ID" --arg status "$status" --arg model "$actual_model" \
    --arg wt "$wt_report" --arg diff "$art/diff.patch" --arg last "$art/last-message.txt" \
    --arg result "$result" --arg auth_note "$auth_note" \
    --arg preflight "$LEGION_ADAPTER_PREFLIGHT_PATH" --arg attempt "$LEGION_ADAPTER_ATTEMPT_PATH" \
    --arg failure "$LEGION_ADAPTER_FAILURE_PATH" \
    --arg reason "$([[ "$status" == timed_out ]] && legion_adapter_lease_reason "$lease_status" || [[ "$status" == containment_failed ]] && legion_adapter_supervisor_reason "$lease_status")" \
    --arg lease "$lease_status" \
    --argjson usage "$usage" --argjson cost "${cost:-0}" --argjson rc "$rc" '
    {run_id:$run, status:$status, executor:"cursor", model:$model, cursor_exit:$rc,
     result:$result, worktree:$wt, diff_path:$diff, last_message_path:$last,
     usage:$usage, cost_usd:$cost,preflight_receipt:$preflight,attempt_receipt:$attempt,
     failure_receipt:(if $failure=="" then null else $failure end),lease_receipt:$lease}
    + (if $reason=="" then {} else {reason:$reason} end)
    + (if $auth_note == "" then {} else {auth_error:$auth_note} end)'
  [[ "$status" == "ok" ]] || exit 1
}

usage() {
  cat <<'EOF'
legion-cursor — delegate a scoped task to Cursor Agent headless.

Usage:
  legion-cursor run --task "TASK" | --task-file F [--model MODEL] [--archetype NAME] [--repo DIR] [--base REF] [--run-id ID] [--max-runtime-seconds N]
                    [--sandbox read-only|workspace-write] [--apply] [--keep] [--quiet]
  legion-cursor run [--repo DIR] < task.txt

Set CURSOR_AGENT_BIN to override the agent binary. By default Legion tries
`agent`, then `cursor-agent`. The default model resolves from
legion-router/config/models.toml.
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
