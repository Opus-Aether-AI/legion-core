#!/usr/bin/env bash
# legion-claude — delegate a scoped task to Claude headless, with automatic
# fallback to legion-delegate / Codex when Claude is unavailable or rate-limited.

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
# shellcheck source=lib/adapter-contract.sh
source "$_self_dir/lib/adapter-contract.sh"
_state_lib="$_self_dir/../../legion-observability/scripts/lib/state.sh"
if [[ -f "$_state_lib" ]]; then
  # shellcheck disable=SC1090
  # shellcheck disable=SC1091
  source "$_state_lib"
fi

CLAUDE_BIN="${CLAUDE_BIN:-claude}"
LEGION_CLAUDE_TMPDIR=""
LEGION_CLAUDE_LEASE_DEADLINE_NS=""
LEGION_CLAUDE_LEASE_RECEIPT=""
CHILD_PID=""
SIGNAL_LEASE_STATUS=""
SIGNAL_WORKTREE=""

die() { printf 'legion-claude: %s\n' "$*" >&2; exit 2; }
note() { [[ "${QUIET:-0}" == "1" ]] || printf '%s\n' "$*" >&2; }
cleanup_claude_on_exit() {
  declare -F legion_terminalize_adopted_run_on_exit >/dev/null 2>&1 \
    && legion_terminalize_adopted_run_on_exit
  [[ -z "$LEGION_CLAUDE_TMPDIR" ]] || rm -rf "$LEGION_CLAUDE_TMPDIR"
}
on_signal() {
  local signum="$1" child_rc=0 containment_reason=""
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
    containment_reason="$(legion_adapter_supervisor_reason "$SIGNAL_LEASE_STATUS") (evidence: $SIGNAL_LEASE_STATUS; worktree retained: $SIGNAL_WORKTREE)"
  elif [[ "$child_rc" -eq 70 ]]; then
    containment_reason="child supervisor exited 70 without a valid cleanup sidecar (evidence expected: $SIGNAL_LEASE_STATUS; worktree retained: $SIGNAL_WORKTREE)"
  fi
  if [[ -n "$containment_reason" ]]; then
    keep=1
    legion_adapter_fail_recorded_attempt "$LEGION_ADAPTER_SIGNAL_ART" claude \
      "$LEGION_ADAPTER_SIGNAL_ORDINAL" internal 70 "$containment_reason" || true
    if [[ -n "${preset_run_id:-}" ]]; then
      legion_write_adapter_run_state containment_failed "$RUN_ID" "$repo" \
        "$LEGION_ADAPTER_SIGNAL_ART" "${wt:-$repo}" "${branch:-}" "$model" "$sandbox" \
        "$base" "$archetype" "$effort" || true
      legion_disarm_adopted_run_guard
    fi
    exit 70
  fi
  exit $((128+signum))
}
trap cleanup_claude_on_exit EXIT
trap 'on_signal 2' INT
trap 'on_signal 15' TERM
trap 'on_signal 1' HUP

_now()    { date -u +%Y-%m-%dT%H:%M:%SZ; }
_today()  { date -u +%Y-%m-%d; }
_run_id() { legion_new_run_id; }

emit_span() {
  local executor="$1" model="$2" status="$3" dur="$4" cost="$5" usage="$6" task="$7" artifacts="$8"
  {
    mkdir -p "$LEGION_TELEMETRY_DIR"
    local trace_id="${LEGION_TRACE_ID:-${RUN_ID:-}}"
    local parent_id="${LEGION_PARENT_ID:-}"
    jq -cn \
      --arg schema "legion.span.v1" --arg ts "$(_now)" \
      --arg run_id "${RUN_ID:-}" --arg trace_id "$trace_id" --arg parent_id "$parent_id" \
      --arg executor "$executor" --arg model "$model" \
      --arg archetype "${archetype:-${LEGION_ARCHETYPE:-}}" \
      --arg target_type "${LEGION_TARGET_TYPE:-}" --arg target_name "${LEGION_TARGET_NAME:-}" \
      --arg status "$status" --argjson dur "${dur:-0}" --argjson cost "${cost:-0}" \
      --argjson usage "$usage" --arg task "$task" --argjson artifacts "$artifacts" '
      {schema:$schema, ts:$ts, run_id:$run_id, trace_id:$trace_id,
       parent_id:(if $parent_id=="" then null else $parent_id end),
       executor:$executor, model:$model, archetype:$archetype, task:$task, status:$status,
       target_type:(if $target_type=="" then null else $target_type end),
       target_name:(if $target_name=="" then null else $target_name end),
       duration_ms:$dur, cost_usd:$cost, tokens:$usage, artifacts:$artifacts}' \
      >> "$LEGION_TELEMETRY_DIR/$(_today).jsonl"
  } 2>/dev/null || true
}

usage_json() {
  local file="$1"
  local usage
  usage="$(jq -c '.usage // {}' "$file" 2>/dev/null || true)"
  [[ -n "$usage" ]] && printf '%s' "$usage" || printf '{}'
}

cost_from_usage() {
  local model="$1" usage="$2"
  local input output cache_read cache_write v
  input="$(jq -r '.input_tokens // 0' <<<"$usage" 2>/dev/null || printf '0')"
  output="$(jq -r '.output_tokens // 0' <<<"$usage" 2>/dev/null || printf '0')"
  cache_read="$(jq -r '.cache_read_input_tokens // 0' <<<"$usage" 2>/dev/null || printf '0')"
  cache_write="$(jq -r '.cache_creation_input_tokens // 0' <<<"$usage" 2>/dev/null || printf '0')"
  for v in input output cache_read cache_write; do
    [[ "${!v}" =~ ^[0-9]+$ ]] || printf -v "$v" '%s' 0
  done
  cost_for_model "$model" "$input" "$output" "$cache_read" "$cache_write"
}

has_low_claude_credit() {
  printf '%s' "${LEGION_LOW_CREDIT:-}" | grep -qi 'claude'
}

# True when the failure is "this Claude model would not or could not take the job"
# rather than "the job failed" — the two cases a same-vendor model chain exists to
# survive:
#
#   refusal          Fable 5.1 can decline a request outright (HTTP 200, a refusal
#                    stop reason). Retrying the SAME model is pointless; a sibling
#                    Claude model usually takes it.
#   model unreachable the account cannot run this model id at all.
#
# The CLI puts the explanation in `.result` — the model's own prose — so that text
# has to be read, but only AFTER two structural gates that a delegated task cannot
# forge from its own output. Without them, a task whose subject is refusals or
# model ids (reviewing this very file, say) would match its own words and silently
# reroute itself.
claude_model_declined() {
  local out_file="$1" err_file="$2"
  [[ -s "$out_file" ]] || return 1
  # Two STRUCTURAL gates before any text is considered, because the only text
  # available is `.result` — the model's own prose. A run whose subject is model
  # ids or refusals (reviewing this very file, say) must not reroute itself.
  #
  #   is_error         a successful run is never a decline, whatever it says
  #   terminal_reason  "api_error" means the CLI never got a usable turn; an
  #                    ordinary task failure carries a different reason
  #
  # The envelope shape is taken from the real CLI, not inferred: an unrouteable
  # model returns type=result, subtype=success, is_error=true,
  # terminal_reason=api_error, stop_reason=stop_sequence, with the explanation in
  # `.result`. Note subtype is "success" and stop_reason is unremarkable — keying
  # on either of those would miss every case this exists for.
  jq -e '
      (.is_error? == true)
      and ((.terminal_reason? // "" | tostring | ascii_downcase) == "api_error")
      and ((.result? // "" | tostring | ascii_downcase)
            | test("issue with the selected model|model_not_found|not_found_error|invalid_model|unsupported_model|may not exist or you may not have access|does not have access to (the )?model|refus(e|ed|al)"))
    ' "$out_file" >/dev/null 2>&1 && return 0
  # stderr carries no envelope, so it is matched textually — but only on
  # machine-emitted identity tokens, never on a bare word like "refusal".
  [[ -s "$err_file" ]] && grep -qiE \
    'model_not_found|not_found_error|invalid_model|unsupported_model|unknown model' \
    "$err_file"
}

is_limit_text() {
  printf '%s' "$1" | grep -qiE 'usage limit|rate.?limit|quota|exceeded|too many requests|overloaded|capacity|reached your'
}

claude_start_lease_deadline() {
  [[ -n "$LEGION_CLAUDE_LEASE_DEADLINE_NS" ]] && return 0
  LEGION_CLAUDE_LEASE_DEADLINE_NS="$(python3 - "$LEGION_ADAPTER_MAX_RUNTIME_SECONDS" <<'PY'
import sys
import time

print(time.monotonic_ns() + int(sys.argv[1]) * 1_000_000_000)
PY
)"
  # Descendant supervisors clamp their relative allowance to this exact
  # monotonic boundary, so rounding the shell-facing seconds up cannot extend
  # the total lease across model or executor transitions.
  export LEGION_CHILD_LEASE_DEADLINE_NS="$LEGION_CLAUDE_LEASE_DEADLINE_NS"
}

claude_remaining_lease_seconds() {
  python3 - "$LEGION_CLAUDE_LEASE_DEADLINE_NS" <<'PY'
import sys
import time

remaining = int(sys.argv[1]) - time.monotonic_ns()
# The supervisor accepts whole relative seconds but also clamps to the exported
# nanosecond deadline. Ceiling preserves usable sub-second time without allowing
# a retry or fallback to extend the absolute boundary.
print(max(0, (remaining + 999_999_999) // 1_000_000_000))
PY
}

archive_claude_fallback_receipts() {
  local art="$1" archive="$1/claude" path name
  mkdir -p "$archive"
  for path in "$art"/attempt-*.json "$art"/failure-*.json; do
    [[ -f "$path" ]] || continue
    name="${path##*/}"
    [[ "$name" =~ ^(attempt|failure)-[0-9]+\.json$ ]] || continue
    mv -f "$path" "$archive/$name"
  done
  if [[ -n "${LEGION_ADAPTER_ATTEMPT_PATH:-}" ]]; then
    name="${LEGION_ADAPTER_ATTEMPT_PATH##*/}"
    [[ -f "$archive/$name" ]] && LEGION_ADAPTER_ATTEMPT_PATH="$archive/$name"
  fi
  if [[ -n "${LEGION_ADAPTER_FAILURE_PATH:-}" ]]; then
    name="${LEGION_ADAPTER_FAILURE_PATH##*/}"
    [[ -f "$archive/$name" ]] && LEGION_ADAPTER_FAILURE_PATH="$archive/$name"
  fi
  # These are mutable aliases, not attempt evidence. The fallback owns them
  # once invoked; deleting them first prevents a preflight-only Codex failure
  # from falsely exposing the last Claude failure as its terminal receipt.
  rm -f "$art/attempt.json" "$art/failure.json"
}

resolve_delegate_bin() {
  if command -v legion-delegate >/dev/null 2>&1; then
    command -v legion-delegate
    return 0
  fi
  if [[ -x "$_self_dir/../bin/legion-delegate" ]]; then
    printf '%s\n' "$_self_dir/../bin/legion-delegate"
    return 0
  fi
  return 1
}

emit_terminal_json() {
  local executor="$1" model="$2" status="$3" result="$4" usage="$5" cost="$6" fell_back="$7" reason="${8:-}"
  # LEGION_CLAUDE_WORKTREE / _DIFF are set by cmd_run once a worktree exists, so a caller can
  # review the run as a diff instead of diffing the operator's tree by hand.
  jq -cn \
    --arg run_id "$RUN_ID" --arg executor "$executor" --arg model "$model" \
    --arg status "$status" --arg result "$result" --argjson usage "$usage" \
    --argjson cost "${cost:-0}" --argjson fell_back "$fell_back" --arg reason "$reason" \
    --arg wt "${LEGION_CLAUDE_WORKTREE:-}" --arg diff "${LEGION_CLAUDE_DIFF:-}" \
    --arg preflight "${LEGION_ADAPTER_PREFLIGHT_PATH:-}" \
    --arg attempt "${LEGION_ADAPTER_ATTEMPT_PATH:-}" \
    --arg failure "${LEGION_ADAPTER_FAILURE_PATH:-}" \
    --arg lease "${LEGION_CLAUDE_LEASE_RECEIPT:-}" '
    {run_id:$run_id, executor:$executor, model:$model, status:$status, result:$result,
     usage:$usage, cost_usd:$cost, fell_back:$fell_back,
     preflight_receipt:(if $preflight=="" then null else $preflight end),
     attempt_receipt:(if $attempt=="" then null else $attempt end),
     failure_receipt:(if $failure=="" then null else $failure end),
     lease_receipt:(if $lease=="" then null else $lease end)}
    + (if $reason == "" then {} else {fell_back_reason:$reason, reason:$reason} end)
    + (if $wt == "" then {} else {worktree:$wt} end)
    + (if $diff == "" then {} else {diff_path:$diff} end)'
}

run_fallback() {
  local reason="$1" task="$2" model="$3" repo="$4" sandbox="$5" base="$6"
  local delegate_bin out rc fallback_status fallback_model fallback_runtime fallback_result last_path
  local -a fallback_args
  local fallback_art="$repo/.legion/runs/$RUN_ID"
  local fallback_wt="$repo/.legion/worktrees/$RUN_ID"
  local fallback_branch="legion/delegate-$RUN_ID"

  archive_claude_fallback_receipts "$fallback_art"
  claude_start_lease_deadline
  fallback_runtime="$(claude_remaining_lease_seconds)"
  if [[ "$fallback_runtime" -lt 1 ]]; then
    reason="child execution lease expired after $LEGION_ADAPTER_MAX_RUNTIME_SECONDS seconds"
    [[ -z "${preset_run_id:-}" ]] || legion_write_adapter_run_state \
      timed_out "$RUN_ID" "$repo" "$fallback_art" "$fallback_wt" "$fallback_branch" \
      "$model" "$sandbox" "$base" "${archetype:-}" "${effort:-}"
    [[ -z "${preset_run_id:-}" ]] || legion_disarm_adopted_run_guard
    emit_terminal_json "claude" "$model" "timed_out" "$reason" "{}" 0 false "$reason"
    return 1
  fi

  delegate_bin="$(resolve_delegate_bin)" || {
    [[ -z "${preset_run_id:-}" ]] || legion_write_adapter_run_state \
      failed "$RUN_ID" "$repo" "$fallback_art" "$fallback_wt" "$fallback_branch" \
      "$model" "$sandbox" "$base" "${archetype:-}" "${effort:-}"
    [[ -z "${preset_run_id:-}" ]] || legion_disarm_adopted_run_guard
    emit_terminal_json "codex" "$model" "failed" "" "{}" 0 true "$reason"
    return 1
  }

  note "→ legion-delegate run --model $model --sandbox $sandbox --base $base"
  [[ -z "${preset_run_id:-}" ]] || legion_write_adapter_run_state \
    running "$RUN_ID" "$repo" "$fallback_art" "$fallback_wt" "$fallback_branch" \
    "$model" "$sandbox" "$base" "${archetype:-}" "${effort:-}"
  if [[ -n "${preset_run_id:-}" ]]; then
    legion_arm_adopted_run_guard "$RUN_ID" "$repo" "$fallback_art" "$fallback_wt" \
      "$fallback_branch" "$model" "$sandbox" "$base" "${archetype:-}" "${effort:-}"
  fi
  set +e
  fallback_args=(run --executor codex --model "$model" --task "$task" --repo "$repo"
    --sandbox "$sandbox" --base "$base" --run-id "$RUN_ID"
    --max-runtime-seconds "$fallback_runtime")
  [[ -z "${archetype:-}" ]] || fallback_args+=(--archetype "$archetype")
  [[ "${QUIET:-0}" != "1" ]] || fallback_args+=(--quiet)
  out="$("$delegate_bin" "${fallback_args[@]}")"
  rc=$?
  set -e

  fallback_status="$(jq -r 'if type == "object" then (.status // "failed") else "failed" end' <<<"$out" 2>/dev/null || printf 'failed')"
  fallback_model="$(jq -r 'if type == "object" then (.model // empty) else empty end' <<<"$out" 2>/dev/null || true)"
  [[ -n "$fallback_model" ]] || fallback_model="$model"
  fallback_result="$(jq -r 'if type == "object" then (.result // .last_message // empty) else empty end' <<<"$out" 2>/dev/null || true)"
  if [[ -z "$fallback_result" ]]; then
    last_path="$(jq -r 'if type == "object" then (.last_message_path // empty) else empty end' <<<"$out" 2>/dev/null || true)"
    if [[ -n "$last_path" && -f "$last_path" ]]; then
      fallback_result="$(cat "$last_path")"
    fi
  fi

  [[ -z "${preset_run_id:-}" ]] || legion_write_adapter_run_state \
    "$fallback_status" "$RUN_ID" "$repo" "$fallback_art" "$fallback_wt" "$fallback_branch" \
    "$fallback_model" "$sandbox" "$base" "${archetype:-}" "${effort:-}"
  [[ -z "${preset_run_id:-}" ]] || legion_disarm_adopted_run_guard
  if jq -e 'type == "object"' <<<"$out" >/dev/null 2>&1; then
    jq -c --arg fallback_reason "$reason" --arg fallback_result "$fallback_result" '
      . + {fell_back:true, fell_back_reason:$fallback_reason}
      | if ((.reason? // "") == "") then .reason=$fallback_reason else . end
      | if ((.result? // "") == "") and ($fallback_result != "")
        then .result=$fallback_result else . end
    ' <<<"$out"
  else
    emit_terminal_json "codex" "$fallback_model" "failed" "" "{}" 0 true "$reason"
    rc=1
  fi
  return "$rc"
}

cmd_run() {
  local default_model="" default_fallback_model=""
  local attempt_model="" claude_chain_note=""
  local task="" model="${LEGION_CLAUDE_MODEL:-${CLAUDE_MODEL:-}}" repo="$PWD" fallback_model="${LEGION_CLAUDE_FALLBACK_MODEL:-${CODEX_MODEL:-}}"
  local fallback_models="${LEGION_CLAUDE_FALLBACK_MODELS:-}"
  local allow_fallback=1 tmpdir="" out_file="" err_file="" artifacts="{}"
  local start_ms=0 end_ms=0 dur=0 rc=0 is_error="false" result="" usage="{}" cost="0"
  local reason="" status="failed" low_credit=0 json_ok=0 combined_text=""
  local effort="" append_sys="" skip_perms=0
  local premium_consent="${LEGION_ALLOW_PREMIUM_CREDIT:-0}"
  local max_runtime_seconds=""
  local base="HEAD" do_apply=0 keep=0 sandbox="" archetype="${LEGION_ARCHETYPE:-}" preset_run_id=""
  local base_commit=""
  local wt="" branch="" wt_report="" diff_path="" diff_rc=0
  local read_only_violation=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --task) task="$2"; shift 2 ;;
      # The task can exceed ARG_MAX once a diff or a long spec is in it.
      # --task-file carries the same value out of band; last flag wins.
      --task-file)
        [[ -r "$2" ]] || die "--task-file not readable: $2"
        task="$(cat "$2")"; shift 2 ;;
      --model) model="$2"; shift 2 ;;
      --repo) repo="$2"; shift 2 ;;
      --quiet) QUIET=1; shift ;;
      --no-fallback) allow_fallback=0; shift ;;
      --fallback-model) fallback_model="$2"; shift 2 ;;
      # Same-vendor Claude alternates, comma-separated, tried in order BEFORE the
      # cross-executor --fallback-model. Distinct flags because they are different
      # escapes: this one keeps the lineage, that one leaves it.
      --fallback-models) fallback_models="$2"; shift 2 ;;
      --effort) effort="$2"; shift 2 ;;                       # reasoning effort passthrough
      --append-system-prompt) append_sys="$2"; shift 2 ;;     # extra system prompt passthrough
      --dangerously-skip-permissions) skip_perms=1; shift ;;  # autonomous headless runs (opt-in)
      --allow-premium-credit|--explicit-consent) premium_consent=1; shift ;;
      --base) base="$2"; shift 2 ;;                           # worktree base ref
      --apply) do_apply=1; shift ;;                           # apply the returned diff to the repo
      --keep) keep=1; shift ;;                                # retain the worktree after the run
      --sandbox) sandbox="$2"; shift 2 ;;                     # accepted for diff-contract parity
      --archetype) archetype="$2"; shift 2 ;;                 # accepted for diff-contract parity
      --run-id) preset_run_id="$2"; shift 2 ;;                # adopt fanout's queued identity
      --max-runtime-seconds) max_runtime_seconds="$2"; shift 2 ;;
      *) die "run: unknown arg '$1'" ;;
    esac
  done
  if [[ -n "$preset_run_id" ]]; then
    declare -F legion_write_adapter_run_state >/dev/null 2>&1 \
      || die "run: --run-id requires adapter lifecycle-state support"
    legion_validate_run_id "$preset_run_id" \
      || die "run: invalid --run-id '$preset_run_id'"
  fi
  repo="$(cd "$repo" && pwd)" || die "run: repo not found: $repo"
  if declare -F legion_resolve_state >/dev/null 2>&1; then
    legion_resolve_state "$repo"
  else
    export LEGION_STATE_ROOT="${LEGION_STATE_ROOT:-$HOME/.legion/projects/default}"
    export LEGION_TELEMETRY_DIR="${LEGION_TELEMETRY_DIR:-$LEGION_STATE_ROOT/spans}"
  fi
  RUN_ID="${preset_run_id:-$(_run_id)}"
  wt="$repo/.legion/worktrees/$RUN_ID"
  branch="legion/claude-$RUN_ID"
  if [[ -n "$preset_run_id" ]]; then
    legion_arm_adopted_run_guard "$RUN_ID" "$repo" "$repo/.legion/runs/$RUN_ID" \
      "$wt" "$branch" "$model" "${sandbox:-workspace-write}" "$base" "$archetype" "$effort"
  fi
  default_model="$(legion_model_ref claude_default)" || die "could not resolve claude_default in models.toml"
  default_fallback_model="$(legion_model_ref codex_workhorse)" || die "could not resolve codex_workhorse in models.toml"
  [[ -n "$model" ]] || model="$default_model"
  [[ -n "$fallback_model" ]] || fallback_model="$default_fallback_model"
  [[ -n "$sandbox" ]] || sandbox="workspace-write"
  case "$sandbox" in
    read-only|workspace-write) ;;
    *) die "invalid --sandbox '$sandbox' (read-only|workspace-write)" ;;
  esac
  : "${archetype:-}"

  if [[ -n "$preset_run_id" ]]; then
    legion_arm_adopted_run_guard "$RUN_ID" "$repo" "$repo/.legion/runs/$RUN_ID" \
      "$wt" "$branch" "$model" "$sandbox" "$base" "$archetype" "$effort"
  fi

  [[ -n "$task" ]] || task="$(cat)"
  [[ -n "$task" ]] || die "run: empty task"
  legion_require_top_level_executor "claude" || return $?
  legion_adapter_resolve_lease claude "$max_runtime_seconds" || die "$LEGION_ADAPTER_LEASE_REASON"

  local contract_art="$repo/.legion/runs/$RUN_ID"
  if ! legion_adapter_preflight claude "$contract_art" "$sandbox" stdin "$model" "$effort" \
      "$premium_consent" "$CLAUDE_BIN"; then
    # An unavailable CLI may safely route to the already-configured alternate;
    # incompatible policy/model/billing requests are terminal refusals and may
    # not spend through a different provider.
    if [[ "$LEGION_ADAPTER_PREFLIGHT_STATUS" == unavailable && "$allow_fallback" -eq 1 ]]; then
      reason=claude_unavailable
      run_fallback "$reason" "$task" "$fallback_model" "$repo" "$sandbox" "$base"
      return $?
    fi
    [[ -z "$preset_run_id" ]] || legion_write_adapter_run_state \
      failed "$RUN_ID" "$repo" "$contract_art" "$wt" "$branch" "$model" "$sandbox" \
      "$base" "$archetype" "$effort"
    [[ -z "$preset_run_id" ]] || legion_disarm_adopted_run_guard
    emit_terminal_json claude "$model" refused "$LEGION_ADAPTER_PREFLIGHT_REASON" '{}' 0 false admission_refused
    return 1
  fi
  CLAUDE_BIN="$(jq -r '.identity.executable_path' "$LEGION_ADAPTER_PREFLIGHT_PATH")"
  if [[ "$skip_perms" -eq 1 ]]; then
    [[ -z "$preset_run_id" ]] || legion_write_adapter_run_state \
      failed "$RUN_ID" "$repo" "$contract_art" "$wt" "$branch" "$model" "$sandbox" \
      "$base" "$archetype" "$effort"
    [[ -z "$preset_run_id" ]] || legion_disarm_adopted_run_guard
    emit_terminal_json claude "$model" refused \
      "unattended Claude runs forbid --dangerously-skip-permissions" '{}' 0 false permission_policy_refused
    return 1
  fi

  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/legion-claude.${RUN_ID}.XXXXXX")"
  LEGION_CLAUDE_TMPDIR="$tmpdir"
  out_file="$tmpdir/claude.out.json"
  err_file="$tmpdir/claude.err"
  artifacts="$(jq -cn --arg stdout "$out_file" --arg stderr "$err_file" '{stdout:$stdout, stderr:$stderr}')"

  if has_low_claude_credit; then
    low_credit=1
  fi

  if [[ "$low_credit" -eq 1 ]]; then
    reason="claude_unavailable"
    if [[ "$allow_fallback" -eq 1 ]]; then
      [[ "$low_credit" -eq 1 ]] && note "⚠ LEGION_LOW_CREDIT=claude: skipping Claude and falling back to $fallback_model"
      run_fallback "$reason" "$task" "$fallback_model" "$repo" "$sandbox" "$base"
      return $?
    fi
    emit_span "claude" "$model" "failed" 0 0 "{}" "$task" "$artifacts"
    [[ -z "$preset_run_id" ]] || legion_write_adapter_run_state \
      failed "$RUN_ID" "$repo" "$repo/.legion/runs/$RUN_ID" "" "" \
      "$model" "$sandbox" "$base" "$archetype" "$effort"
    [[ -z "$preset_run_id" ]] || legion_disarm_adopted_run_guard
    emit_terminal_json "claude" "$model" "failed" "" "{}" 0 false "$reason"
    return 1
  fi

  # Isolate the run. Previously claude inherited the caller's working directory, so a delegated
  # run edited whatever tree the operator happened to be standing in — `--repo` only ever fed the
  # state paths. A worktree makes the work reviewable as a diff, like every other coding executor.
  if ! git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    note "⚠ repository is not a git worktree"
    emit_span "claude" "$model" "failed" 0 0 "{}" "$task" "$artifacts"
    emit_terminal_json "claude" "$model" "failed" "" "{}" 0 false "worktree_setup_failed"
    return 1
  fi
  mkdir -p "$repo/.legion/worktrees"
  if git -C "$repo" worktree add -q -b "$branch" "$wt" "$base" 2>/dev/null; then
    # Artifacts live under the repo's run dir, not tmpdir — the EXIT trap deletes tmpdir, and
    # the diff is the reviewable output of the run.
    mkdir -p "$repo/.legion/runs/$RUN_ID"
    diff_path="$repo/.legion/runs/$RUN_ID/diff.patch"
    [[ -z "$preset_run_id" ]] || legion_write_adapter_run_state \
      running "$RUN_ID" "$repo" "$repo/.legion/runs/$RUN_ID" "$wt" "$branch" \
      "$model" "$sandbox" "$base" "$archetype" "$effort"
    # Pinned while the worktree is still pristine: the executor may commit,
    # and after that HEAD is no longer the starting point.
    base_commit="$(git -C "$wt" rev-parse --verify --quiet HEAD 2>/dev/null || true)"
    note "→ claude worktree $wt (branch $branch, base $base)"
  else
    note "⚠ worktree add failed"
    emit_span "claude" "$model" "failed" 0 0 "{}" "$task" "$artifacts"
    [[ -z "$preset_run_id" ]] || legion_write_adapter_run_state \
      failed "$RUN_ID" "$repo" "$repo/.legion/runs/$RUN_ID" "$wt" "$branch" \
      "$model" "$sandbox" "$base" "$archetype" "$effort"
    [[ -z "$preset_run_id" ]] || legion_disarm_adopted_run_guard
    emit_terminal_json "claude" "$model" "failed" "" "{}" 0 false "worktree_setup_failed"
    return 1
  fi

  # Same-vendor model chain: the routed model first, then the archetype's
  # fallback_refs. Only a refusal or an unreachable model advances it — a real
  # failure stops on the model that produced it, so the chain is never burned
  # hiding a genuine error. The loop wraps ONLY the CLI invocation: worktree diff
  # capture and result parsing below run once, against whichever model answered.
  local -a claude_model_chain=("$model")
  if [[ -n "$fallback_models" ]]; then
    local _fb_model
    while IFS= read -r _fb_model; do
      [[ -n "$_fb_model" ]] || continue
      [[ " ${claude_model_chain[*]} " == *" $_fb_model "* ]] && continue   # dedup
      claude_model_chain+=("$_fb_model")
      # printf '%s\n', not '%s': without the trailing newline the final field is
      # unterminated, `read` returns false on it, and the loop body never runs for
      # the LAST model. A single-entry chain — which is every archetype with one
      # fallback_ref — would silently degrade to no chain at all.
    done < <(printf '%s\n' "$fallback_models" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  fi

  start_ms="$(date +%s000)"
  local chain_len="${#claude_model_chain[@]}" chain_idx=0 declined_final=0 chain_cost=0
  local any_output_started=0 permission_refused=0 chain_admission_refused=0
  local lease_timed_out=0 containment_failed=0 lease_reason=""
  for attempt_model in "${claude_model_chain[@]}"; do
    chain_idx=$(( chain_idx + 1 ))
    model="$attempt_model"
    if [[ "$chain_idx" -gt 1 ]]; then
      local previous_attempt_id="$LEGION_ADAPTER_PREVIOUS_ATTEMPT_ID"
      if ! legion_adapter_preflight claude "$contract_art" "$sandbox" stdin "$model" "$effort" \
          "$premium_consent" "$CLAUDE_BIN"; then
        LEGION_ADAPTER_PREVIOUS_ATTEMPT_ID="$previous_attempt_id"
        chain_admission_refused=1
        break
      fi
      LEGION_ADAPTER_PREVIOUS_ATTEMPT_ID="$previous_attempt_id"
    fi
    local -a claude_cmd=("$CLAUDE_BIN" -p --output-format json --model "$model")
    if [[ "$sandbox" == "read-only" ]]; then
      claude_cmd+=(--permission-mode plan)
    else
      # Headless runs cannot answer prompts. dontAsk denies any tool that would
      # require interaction instead of hanging or escalating permissions.
      claude_cmd+=(--permission-mode dontAsk)
    fi
    [[ -n "$effort" ]] && claude_cmd+=(--effort "$effort")
    [[ -n "$append_sys" ]] && claude_cmd+=(--append-system-prompt "$append_sys")
    claude_start_lease_deadline
    local attempt_runtime
    attempt_runtime="$(claude_remaining_lease_seconds)"
    if [[ "$attempt_runtime" -lt 1 ]]; then
      lease_timed_out=1
      lease_reason="child execution lease expired after $LEGION_ADAPTER_MAX_RUNTIME_SECONDS seconds"
      break
    fi
    note "→ ${claude_cmd[*]}"
    local attempt_started_at attempt_ended_at attempt_start_ms attempt_end_ms attempt_duration
    attempt_started_at="$(_now)"; attempt_start_ms="$(date +%s000)"
    local lease_status="$contract_art/lease-$chain_idx.json"
    SIGNAL_LEASE_STATUS="$lease_status"
    SIGNAL_WORKTREE="${wt:-$repo}"
    legion_adapter_arm_signal_receipt "$contract_art" claude anthropic "$chain_idx" \
      "$attempt_model" "" "$effort" "$effort" "$sandbox" "$attempt_started_at" \
      "$attempt_start_ms" "$out_file"
    set +e
    (
      legion_activate_executor_context "$RUN_ID" claude
      cd "${wt:-$repo}"
      exec python3 "$LEGION_ADAPTER_SUPERVISOR" --cwd "${wt:-$repo}" \
        --max-runtime-seconds "$attempt_runtime" \
        --status-file "$lease_status" -- "${claude_cmd[@]}"
    ) < <(printf '%s' "$task") >"$out_file" 2>"$err_file" &
    CHILD_PID=$!
    wait "$CHILD_PID"; rc=$?
    CHILD_PID=""
    SIGNAL_LEASE_STATUS=""
    SIGNAL_WORKTREE=""
    set -e
    attempt_end_ms="$(date +%s000)"; attempt_ended_at="$(_now)"
    attempt_duration=$((attempt_end_ms-attempt_start_ms))
    local attempt_is_error attempt_result attempt_usage attempt_cost attempt_effective
    local attempt_usage_status=unknown attempt_usage_source="" attempt_cost_status=unknown attempt_cost_source=""
    local attempt_output_started=false attempt_failure=provider attempt_retryable=false attempt_terminal=failed
    attempt_is_error="$(jq -r 'if has("is_error") then .is_error else true end' "$out_file" 2>/dev/null || printf true)"
    attempt_result="$(jq -r '.result // empty' "$out_file" 2>/dev/null || true)"
    attempt_usage="$(usage_json "$out_file")"
    attempt_cost="$(cost_from_usage "$attempt_model" "$attempt_usage" 2>/dev/null || printf 0)"
    attempt_effective="$(jq -r '.model // empty' "$out_file" 2>/dev/null || true)"
    if jq -e '.usage | type == "object"' "$out_file" >/dev/null 2>&1; then
      attempt_usage_status=known; attempt_usage_source=claude-result
      if jq -e '.total_cost_usd | numbers' "$out_file" >/dev/null 2>&1; then
        attempt_cost="$(jq -r '.total_cost_usd' "$out_file")"
        attempt_cost_status=known; attempt_cost_source=claude-result
      elif cost_model_has_pricing "$attempt_model"; then
        attempt_cost_status=known; attempt_cost_source=legion-cost-table
      fi
    fi
    if [[ "$attempt_is_error" != true && -n "$attempt_result" ]]; then
      attempt_output_started=true; any_output_started=1
    fi
    local attempt_combined="$attempt_result"
    [[ ! -s "$err_file" ]] || attempt_combined="${attempt_combined}"$'\n'"$(cat "$err_file")"
    if legion_adapter_supervisor_cleanup_failed "$lease_status"; then
      containment_failed=1
      keep=1
      LEGION_CLAUDE_LEASE_RECEIPT="$lease_status"
      lease_reason="$(legion_adapter_supervisor_reason "$lease_status") (evidence: $lease_status; worktree retained: ${wt:-$repo})"
      attempt_failure=internal
    elif legion_adapter_supervisor_timed_out "$lease_status"; then
      lease_timed_out=1
      lease_reason="child execution lease expired after $LEGION_ADAPTER_MAX_RUNTIME_SECONDS seconds"
      attempt_terminal=timed_out; attempt_failure=timed_out
    elif [[ "$rc" -eq 0 && "$attempt_is_error" != true ]] && ! claude_model_declined "$out_file" "$err_file"; then
      attempt_terminal=succeeded; attempt_failure=""
    elif claude_model_declined "$out_file" "$err_file"; then
      attempt_failure=unavailable; attempt_retryable=true
    elif is_limit_text "$attempt_combined"; then
      attempt_failure=quota; attempt_retryable=true
    elif printf '%s' "$attempt_combined" | grep -qiE 'permission (prompt|required|denied)|requires? (user )?approval|not granted permission'; then
      attempt_failure=policy_refused; permission_refused=1
    elif ! jq -e . "$out_file" >/dev/null 2>&1; then
      attempt_failure=malformed_event
    fi
    [[ "$attempt_output_started" != true ]] || attempt_retryable=false
    legion_adapter_write_attempt "$contract_art" claude anthropic "$chain_idx" \
      "$attempt_model" "$attempt_effective" "$effort" "$effort" "$sandbox" \
      "$attempt_terminal" "$attempt_started_at" "$attempt_ended_at" "$attempt_duration" "$attempt_usage" \
      "$attempt_usage_status" "$attempt_usage_source" "$attempt_cost" \
      "$attempt_cost_status" "$attempt_cost_source" "$attempt_failure" "$attempt_retryable" \
      "$attempt_output_started" "$([[ "$rc" -eq 0 ]] || printf '%s' "$rc")" \
      "${lease_reason:-$attempt_result}"
    legion_adapter_disarm_signal_receipt
    [[ "$lease_timed_out" -ne 1 && "$containment_failed" -ne 1 ]] || break
    if [[ "$permission_refused" -eq 1 || "$any_output_started" -eq 1 ]]; then
      declined_final=0
      break
    fi
    if ! claude_model_declined "$out_file" "$err_file"; then
      declined_final=0
      break
    fi
    # Every model so far has declined. If this was the last one, the chain is
    # exhausted and the run must NOT report success: a refusal comes back as a
    # well-formed 200 with rc 0 and is_error false, so without this flag the
    # refusal text would be handed back as the result of a "successful" run.
    declined_final=1
    # A decline still burns input tokens — the prompt was sent and read. Only the
    # LAST attempt's stdout survives (each iteration overwrites out_file), so bank
    # this attempt's cost now or it disappears from the record entirely. On a large
    # prompt at frontier rates that is real money silently unaccounted for, in a
    # system whose whole point is honest cost attribution.
    local _declined_usage _declined_cost
    _declined_usage="$(usage_json "$out_file")"
    _declined_cost="$(cost_from_usage "$model" "$_declined_usage" 2>/dev/null || printf '0')"
    chain_cost="$(awk -v a="$chain_cost" -v b="$_declined_cost" 'BEGIN{printf "%.6f", a + b}')"
    claude_chain_note="${claude_chain_note}${claude_chain_note:+; }$model"
    if [[ "$chain_idx" -lt "$chain_len" ]]; then
      note "⚠ $model declined the task or is unreachable — trying the next Claude model"
    else
      note "⚠ $model declined the task or is unreachable — no Claude models left in the chain"
    fi
  done
  # Which models were skipped, and why, has to survive into the record. Only the
  # LAST attempt's stdout is kept (each iteration overwrites it), so without this
  # a run that quietly cost two model calls is indistinguishable from one that
  # cost a single call on the second model. Same limitation as the codex fallback
  # loop in delegate.sh, which also reports only its final attempt's usage.
  [[ -n "$claude_chain_note" ]] && note "model chain: declined by $claude_chain_note → answered by $model"
  [[ "$lease_timed_out" -ne 1 ]] || keep=0
  [[ "$containment_failed" -ne 1 ]] || keep=1

  if [[ -n "$wt" ]]; then
    if [[ "$containment_failed" -ne 1 ]]; then
      git -C "$wt" add -A 2>/dev/null || diff_rc=1
    # Diff against the worktree's STARTING commit, not HEAD. `diff --cached` alone
    # compares the index to HEAD, so an executor that COMMITS its work yields an
    # empty patch -- HEAD already holds it, nothing is staged, and the run reports
    # ok having lost everything. legion-pi-hermes already pins a base sha for this
    # reason; delegate.sh was fixed in #182 after a benchmark scored 0 on work that
    # had actually been done.
      git -C "$wt" diff --cached ${base_commit:+"$base_commit"} >"$diff_path" 2>/dev/null || diff_rc=1
    else
      : > "$diff_path"
    fi
    [[ "$diff_rc" -ne 0 ]] && note "⚠ could not capture a diff from $wt"
    if [[ "$lease_timed_out" -ne 1 && "$containment_failed" -ne 1 && "$sandbox" == "read-only" && -s "$diff_path" ]]; then
      read_only_violation=1
      note "⚠ Claude produced file changes during a read-only run; refusing the result"
      legion_adapter_fail_recorded_attempt "$contract_art" claude "$chain_idx" \
        policy_refused "" "Claude produced file changes during a read-only run"
    fi
    if [[ "$lease_timed_out" -ne 1 && "$containment_failed" -ne 1 && "$do_apply" -eq 1 && "$read_only_violation" -eq 0 && -s "$diff_path" ]]; then
      if git -C "$repo" apply --check "$diff_path" 2>/dev/null; then
        git -C "$repo" apply "$diff_path" && note "diff applied to $repo"
      else
        note "diff did not apply cleanly; left in $diff_path"
      fi
    fi
    wt_report="$wt"
    if [[ "$keep" -ne 1 ]]; then
      # The worktree goes; the patch stays. It already lives outside the worktree.
      git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1 || true
      git -C "$repo" branch -D "$branch" >/dev/null 2>&1 || true
      git -C "$repo" worktree prune >/dev/null 2>&1 || true
      wt_report="(removed; rerun with --keep to retain the worktree)"
    fi
    artifacts="$(jq -cn --arg stdout "$out_file" --arg stderr "$err_file" \
      --arg wt "$wt_report" --arg diff "$diff_path" --arg declined "$claude_chain_note" \
      --arg preflight "$LEGION_ADAPTER_PREFLIGHT_PATH" --arg attempt "$LEGION_ADAPTER_ATTEMPT_PATH" \
      --arg failure "$LEGION_ADAPTER_FAILURE_PATH" \
      '{stdout:$stdout, stderr:$stderr, worktree:$wt, diff:$diff,
        preflight_receipt:$preflight,
        attempt_receipt:(if $attempt=="" then null else $attempt end),
        failure_receipt:(if $failure=="" then null else $failure end)}
       + (if $declined == "" then {} else {declined_models:$declined} end)')"
    export LEGION_CLAUDE_WORKTREE="$wt_report" LEGION_CLAUDE_DIFF="$diff_path"
  fi
  end_ms="$(date +%s000)"
  dur=$(( end_ms - start_ms ))

  if jq -e . "$out_file" >/dev/null 2>&1; then
    json_ok=1
    is_error="$(jq -r '.is_error // false' "$out_file" 2>/dev/null || printf 'false')"
    result="$(jq -r '.result // ""' "$out_file" 2>/dev/null || true)"
    usage="$(usage_json "$out_file")"
    if jq -e '.total_cost_usd | numbers' "$out_file" >/dev/null 2>&1; then
      cost="$(jq -r '.total_cost_usd' "$out_file")"
    else
      cost="$(cost_from_usage "$model" "$usage" 2>/dev/null || printf '0')"
    fi
    # Add what the declined attempts already burned. Both figures the CLI can give
    # us — total_cost_usd and the usage-derived one — describe the LAST attempt
    # only, because out_file was overwritten each time round the chain. `usage`
    # stays the answering model's, since mixing token counts across models would
    # make the per-model rollups meaningless; only the dollars aggregate.
    if [[ "$chain_cost" != "0" ]]; then
      cost="$(awk -v a="$cost" -v b="$chain_cost" 'BEGIN{printf "%.6f", a + b}')"
    fi
  fi

  combined_text="$result"
  if [[ -s "$err_file" ]]; then
    combined_text="${combined_text}"$'\n'"$(cat "$err_file")"
  fi

  if [[ "$containment_failed" -eq 1 ]]; then
    reason="containment_failed"
    status="containment_failed"
    result="$lease_reason"
    emit_span "claude" "$model" "$status" "$dur" "$cost" "$usage" "$task" "$artifacts"
    [[ -z "$preset_run_id" ]] || legion_write_adapter_run_state \
      "$status" "$RUN_ID" "$repo" "$repo/.legion/runs/$RUN_ID" "$wt_report" "$branch" \
      "$model" "$sandbox" "$base" "$archetype" "$effort"
    [[ -z "$preset_run_id" ]] || legion_disarm_adopted_run_guard
    emit_terminal_json "claude" "$model" "$status" "$result" "$usage" "$cost" false "$reason"
    return 1
  fi

  if [[ "$lease_timed_out" -eq 1 ]]; then
    reason="$lease_reason"
    status="timed_out"
    result="$lease_reason"
    emit_span "claude" "$model" "$status" "$dur" "$cost" "$usage" "$task" "$artifacts"
    [[ -z "$preset_run_id" ]] || legion_write_adapter_run_state \
      "$status" "$RUN_ID" "$repo" "$repo/.legion/runs/$RUN_ID" "$wt_report" "$branch" \
      "$model" "$sandbox" "$base" "$archetype" "$effort"
    [[ -z "$preset_run_id" ]] || legion_disarm_adopted_run_guard
    emit_terminal_json "claude" "$model" "$status" "$result" "$usage" "$cost" false "$reason"
    return 1
  fi

  if [[ "$chain_admission_refused" -eq 1 ]]; then
    reason="admission_refused"
    status="failed"
    result="$LEGION_ADAPTER_PREFLIGHT_REASON"
    emit_span "claude" "$model" "$status" "$dur" "$cost" "$usage" "$task" "$artifacts"
    [[ -z "$preset_run_id" ]] || legion_write_adapter_run_state \
      "$status" "$RUN_ID" "$repo" "$repo/.legion/runs/$RUN_ID" "$wt_report" "$branch" \
      "$model" "$sandbox" "$base" "$archetype" "$effort"
    [[ -z "$preset_run_id" ]] || legion_disarm_adopted_run_guard
    emit_terminal_json "claude" "$model" "$status" "$result" "$usage" "$cost" false "$reason"
    return 1
  fi

  if [[ "$read_only_violation" -eq 1 ]]; then
    reason="read_only_violation"
    status="failed"
    [[ -n "$result" ]] && result="${result}"$'\n'
    result="${result}Claude produced file changes during a read-only run."
    emit_span "claude" "$model" "$status" "$dur" "$cost" "$usage" "$task" "$artifacts"
    [[ -z "$preset_run_id" ]] || legion_write_adapter_run_state \
      "$status" "$RUN_ID" "$repo" "$repo/.legion/runs/$RUN_ID" "$wt_report" "$branch" \
      "$model" "$sandbox" "$base" "$archetype" "$effort"
    [[ -z "$preset_run_id" ]] || legion_disarm_adopted_run_guard
    emit_terminal_json "claude" "$model" "$status" "$result" "$usage" "$cost" false "$reason"
    return 1
  fi

  # declined_final gates the success path: a refusal returns rc 0, valid JSON and
  # is_error false, so an exhausted chain would otherwise report ok and hand back
  # the refusal text as the run's result.
  if [[ "$rc" -eq 0 && "$json_ok" -eq 1 && "$is_error" != "true" && "$declined_final" -eq 0 ]]; then
    status="ok"
    emit_span "claude" "$model" "$status" "$dur" "$cost" "$usage" "$task" "$artifacts"
    [[ -z "$preset_run_id" ]] || legion_write_adapter_run_state \
      "$status" "$RUN_ID" "$repo" "$repo/.legion/runs/$RUN_ID" "$wt_report" "$branch" \
      "$model" "$sandbox" "$base" "$archetype" "$effort"
    [[ -z "$preset_run_id" ]] || legion_disarm_adopted_run_guard
    emit_terminal_json "claude" "$model" "$status" "$result" "$usage" "$cost" false
    return 0
  fi

  if [[ "$declined_final" -eq 1 ]]; then
    # Distinct from claude_error: nothing went wrong mechanically, every model
    # in the chain declined or was unreachable. Downstream can tell "the work
    # failed" from "this vendor would not take the work".
    reason="claude_declined"
  elif { [[ "$is_error" == "true" ]] || [[ "$rc" -ne 0 ]]; } && is_limit_text "$combined_text"; then
    reason="claude_limit"
  else
    reason="claude_error"
  fi

  if [[ "$allow_fallback" -eq 1 && "$any_output_started" -eq 0 && "$permission_refused" -eq 0 ]]; then
    status="$([[ "$reason" == "claude_limit" ]] && printf blocked || printf failed)"
    archive_claude_fallback_receipts "$contract_art"
    artifacts="$(jq -c \
      --arg attempt "${LEGION_ADAPTER_ATTEMPT_PATH:-}" \
      --arg failure "${LEGION_ADAPTER_FAILURE_PATH:-}" '
      .attempt_receipt=(if $attempt=="" then null else $attempt end)
      | .failure_receipt=(if $failure=="" then null else $failure end)
    ' <<<"$artifacts")"
    emit_span "claude" "$model" "$status" "$dur" "$cost" "$usage" "$task" "$artifacts"
    note "⚠ Claude failed ($reason): falling back to $fallback_model"
    run_fallback "$reason" "$task" "$fallback_model" "$repo" "$sandbox" "$base"
    return $?
  fi

  if [[ "$permission_refused" -eq 1 ]]; then
    reason="permission_policy_refused"
  elif [[ "$any_output_started" -eq 1 && "$reason" != "" ]]; then
    reason="${reason}_after_output"
  fi

  if [[ "$reason" == "claude_limit" ]]; then
    status="blocked"
  else
    status="failed"
  fi
  emit_span "claude" "$model" "$status" "$dur" "$cost" "$usage" "$task" "$artifacts"
  [[ -z "$preset_run_id" ]] || legion_write_adapter_run_state \
    "$status" "$RUN_ID" "$repo" "$repo/.legion/runs/$RUN_ID" "$wt_report" "$branch" \
    "$model" "$sandbox" "$base" "$archetype" "$effort"
  [[ -z "$preset_run_id" ]] || legion_disarm_adopted_run_guard
  emit_terminal_json "claude" "$model" "$status" "$result" "$usage" "$cost" false "$reason"
  return 1
}

usage() {
  cat <<'EOF'
legion-claude — delegate a scoped task to Claude headless, with fallback to Codex.

Usage:
  legion-claude run --task "TASK" | --task-file F [--model MODEL] [--repo DIR] [--effort LEVEL]
                    [--base REF] [--run-id ID] [--max-runtime-seconds N] [--apply] [--keep]
                    [--sandbox read-only|workspace-write] [--archetype NAME]
                    [--append-system-prompt TEXT] [--allow-premium-credit]
                    [--quiet] [--no-fallback] [--fallback-model MODEL]
  legion-claude run [--model MODEL] [--repo DIR] [...] < task.txt

The run happens in a git worktree under <repo>/.legion/worktrees/ and returns a diff at
<repo>/.legion/runs/<run-id>/diff.patch, so it never edits the caller's working tree.
--keep retains the worktree; --apply applies the diff to the repo.
Read-only runs use Claude plan mode and fail if the worktree still changes.

--effort and --append-system-prompt pass through to `claude -p`.
Premium-credit Fable models require --allow-premium-credit (or
LEGION_ALLOW_PREMIUM_CREDIT=1). Unattended runs always deny permission prompts;
--dangerously-skip-permissions is retained only as a fail-closed compatibility
flag and never reaches Claude.
Defaults resolve from legion-router/config/models.toml.
EOF
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    run) shift; cmd_run "$@" ;;
    ""|-h|--help|help) usage ;;
    *) die "unknown command '$cmd'" ;;
  esac
}

main "$@"
