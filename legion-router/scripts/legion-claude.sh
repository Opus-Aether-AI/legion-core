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
_state_lib="$_self_dir/../../legion-observability/scripts/lib/state.sh"
if [[ -f "$_state_lib" ]]; then
  # shellcheck disable=SC1091
  source "$_state_lib"
fi

CLAUDE_BIN="${CLAUDE_BIN:-claude}"
LEGION_CLAUDE_TMPDIR=""

die() { printf 'legion-claude: %s\n' "$*" >&2; exit 2; }
note() { [[ "${QUIET:-0}" == "1" ]] || printf '%s\n' "$*" >&2; }

_now()    { date -u +%Y-%m-%dT%H:%M:%SZ; }
_today()  { date -u +%Y-%m-%d; }
_run_id() { printf '%s-%s' "$(date -u +%Y%m%d-%H%M%S)" "${RANDOM}${RANDOM}"; }

emit_span() {
  local executor="$1" model="$2" status="$3" dur="$4" cost="$5" usage="$6" task="$7" artifacts="$8"
  {
    mkdir -p "$LEGION_TELEMETRY_DIR"
    local trace_id="${LEGION_TRACE_ID:-${RUN_ID:-}}"
    local parent_id="${LEGION_PARENT_ID:-}"
    jq -cn \
      --arg schema "legion.span.v1" --arg ts "$(_now)" \
      --arg run_id "${RUN_ID:-}" --arg trace_id "$trace_id" --arg parent_id "$parent_id" \
      --arg executor "$executor" --arg model "$model" --arg archetype "${LEGION_ARCHETYPE:-}" \
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

is_limit_text() {
  printf '%s' "$1" | grep -qiE 'usage limit|rate.?limit|quota|exceeded|too many requests|overloaded|capacity|reached your'
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
  jq -cn \
    --arg run_id "$RUN_ID" --arg executor "$executor" --arg model "$model" \
    --arg status "$status" --arg result "$result" --argjson usage "$usage" \
    --argjson cost "${cost:-0}" --argjson fell_back "$fell_back" --arg reason "$reason" '
    {run_id:$run_id, executor:$executor, model:$model, status:$status, result:$result,
     usage:$usage, cost_usd:$cost, fell_back:$fell_back}
    + (if $reason == "" then {} else {fell_back_reason:$reason, reason:$reason} end)'
}

run_fallback() {
  local reason="$1" task="$2" model="$3" repo="$4"
  local delegate_bin out rc fallback_status fallback_model fallback_usage fallback_cost fallback_result last_path

  delegate_bin="$(resolve_delegate_bin)" || {
    emit_terminal_json "codex" "$model" "failed" "" "{}" 0 true "$reason"
    return 1
  }

  note "→ legion-delegate run --model $model"
  set +e
  if [[ "${QUIET:-0}" == "1" ]]; then
    out="$("$delegate_bin" run --model "$model" --task "$task" --repo "$repo" --quiet)"
  else
    out="$("$delegate_bin" run --model "$model" --task "$task" --repo "$repo")"
  fi
  rc=$?
  set -e

  fallback_status="$(jq -r '.status // "failed"' <<<"$out" 2>/dev/null || printf 'failed')"
  fallback_model="$(jq -r '.model // empty' <<<"$out" 2>/dev/null || true)"
  [[ -n "$fallback_model" ]] || fallback_model="$model"
  fallback_usage="$(jq -c '.usage // {}' <<<"$out" 2>/dev/null || printf '{}')"
  fallback_cost="$(jq -r '.cost_usd // 0' <<<"$out" 2>/dev/null || printf '0')"
  fallback_result="$(jq -r '.result // .last_message // empty' <<<"$out" 2>/dev/null || true)"

  if [[ -z "$fallback_result" ]]; then
    last_path="$(jq -r '.last_message_path // empty' <<<"$out" 2>/dev/null || true)"
    if [[ -n "$last_path" && -f "$last_path" ]]; then
      fallback_result="$(cat "$last_path")"
    fi
  fi

  emit_terminal_json "codex" "$fallback_model" "$fallback_status" "$fallback_result" "$fallback_usage" "$fallback_cost" true "$reason"
  return "$rc"
}

cmd_run() {
  local default_model default_fallback_model
  default_model="$(legion_model_ref claude_default)" || die "could not resolve claude_default in models.toml"
  default_fallback_model="$(legion_model_ref codex_workhorse)" || die "could not resolve codex_workhorse in models.toml"

  local task="" model="${LEGION_CLAUDE_MODEL:-${CLAUDE_MODEL:-$default_model}}" repo="$PWD" fallback_model="${LEGION_CLAUDE_FALLBACK_MODEL:-${CODEX_MODEL:-$default_fallback_model}}"
  local allow_fallback=1 tmpdir="" out_file="" err_file="" artifacts="{}"
  local start_ms=0 end_ms=0 dur=0 rc=0 is_error="false" result="" usage="{}" cost="0"
  local reason="" status="failed" low_credit=0 json_ok=0 combined_text=""
  local effort="" append_sys="" skip_perms=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --task) task="$2"; shift 2 ;;
      --model) model="$2"; shift 2 ;;
      --repo) repo="$2"; shift 2 ;;
      --quiet) QUIET=1; shift ;;
      --no-fallback) allow_fallback=0; shift ;;
      --fallback-model) fallback_model="$2"; shift 2 ;;
      --effort) effort="$2"; shift 2 ;;                       # reasoning effort passthrough
      --append-system-prompt) append_sys="$2"; shift 2 ;;     # extra system prompt passthrough
      --dangerously-skip-permissions) skip_perms=1; shift ;;  # autonomous headless runs (opt-in)
      *) die "run: unknown arg '$1'" ;;
    esac
  done

  [[ -n "$task" ]] || task="$(cat)"
  [[ -n "$task" ]] || die "run: empty task"
  repo="$(cd "$repo" && pwd)" || die "run: repo not found: $repo"
  if declare -F legion_resolve_state >/dev/null 2>&1; then
    legion_resolve_state "$repo"
  else
    export LEGION_STATE_ROOT="${LEGION_STATE_ROOT:-$HOME/.legion/projects/default}"
    export LEGION_TELEMETRY_DIR="${LEGION_TELEMETRY_DIR:-$LEGION_STATE_ROOT/spans}"
  fi
  RUN_ID="$(_run_id)"

  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/legion-claude.${RUN_ID}.XXXXXX")"
  LEGION_CLAUDE_TMPDIR="$tmpdir"
  out_file="$tmpdir/claude.out.json"
  err_file="$tmpdir/claude.err"
  artifacts="$(jq -cn --arg stdout "$out_file" --arg stderr "$err_file" '{stdout:$stdout, stderr:$stderr}')"
  trap 'rm -rf "$LEGION_CLAUDE_TMPDIR"' EXIT

  if has_low_claude_credit; then
    low_credit=1
  fi

  if ! command -v "$CLAUDE_BIN" >/dev/null 2>&1 || [[ "$low_credit" -eq 1 ]]; then
    reason="claude_unavailable"
    if [[ "$allow_fallback" -eq 1 ]]; then
      [[ "$low_credit" -eq 1 ]] && note "⚠ LEGION_LOW_CREDIT=claude: skipping Claude and falling back to $fallback_model"
      [[ "$low_credit" -eq 0 ]] && note "⚠ Claude CLI unavailable: falling back to $fallback_model"
      run_fallback "$reason" "$task" "$fallback_model" "$repo"
      return $?
    fi
    emit_span "claude" "$model" "failed" 0 0 "{}" "$task" "$artifacts"
    emit_terminal_json "claude" "$model" "failed" "" "{}" 0 false "$reason"
    return 1
  fi

  local -a claude_cmd=("$CLAUDE_BIN" -p --output-format json --model "$model")
  [[ -n "$effort" ]] && claude_cmd+=(--effort "$effort")
  [[ -n "$append_sys" ]] && claude_cmd+=(--append-system-prompt "$append_sys")
  [[ "$skip_perms" -eq 1 ]] && claude_cmd+=(--dangerously-skip-permissions)
  note "→ ${claude_cmd[*]}"
  start_ms="$(date +%s000)"
  set +e
  printf '%s' "$task" | "${claude_cmd[@]}" >"$out_file" 2>"$err_file"
  rc=${PIPESTATUS[1]}
  set -e
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
  fi

  combined_text="$result"
  if [[ -s "$err_file" ]]; then
    combined_text="${combined_text}"$'\n'"$(cat "$err_file")"
  fi

  if [[ "$rc" -eq 0 && "$json_ok" -eq 1 && "$is_error" != "true" ]]; then
    status="ok"
    emit_span "claude" "$model" "$status" "$dur" "$cost" "$usage" "$task" "$artifacts"
    emit_terminal_json "claude" "$model" "$status" "$result" "$usage" "$cost" false
    return 0
  fi

  if { [[ "$is_error" == "true" ]] || [[ "$rc" -ne 0 ]]; } && is_limit_text "$combined_text"; then
    reason="claude_limit"
  else
    reason="claude_error"
  fi

  if [[ "$allow_fallback" -eq 1 ]]; then
    note "⚠ Claude failed ($reason): falling back to $fallback_model"
    run_fallback "$reason" "$task" "$fallback_model" "$repo"
    return $?
  fi

  if [[ "$reason" == "claude_limit" ]]; then
    status="blocked"
  else
    status="failed"
  fi
  emit_span "claude" "$model" "$status" "$dur" 0 "$usage" "$task" "$artifacts"
  emit_terminal_json "claude" "$model" "$status" "$result" "$usage" 0 false "$reason"
  return 1
}

usage() {
  cat <<'EOF'
legion-claude — delegate a scoped task to Claude headless, with fallback to Codex.

Usage:
  legion-claude run --task "TASK" [--model MODEL] [--repo DIR] [--effort LEVEL]
                    [--append-system-prompt TEXT] [--dangerously-skip-permissions]
                    [--quiet] [--no-fallback] [--fallback-model MODEL]
  legion-claude run [--model MODEL] [--repo DIR] [...] < task.txt

--effort / --append-system-prompt / --dangerously-skip-permissions pass through to
`claude -p` (skip-permissions is for autonomous headless/cron runs — opt-in).
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
