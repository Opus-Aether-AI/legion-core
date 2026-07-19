#!/usr/bin/env bash

_bench_span_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_bench_repo_root="$(cd "$_bench_span_dir/../../.." && pwd)"
_bench_cost_lib="$_bench_repo_root/legion-router/scripts/lib/cost.sh"
_bench_codex_json_lib="$_bench_repo_root/legion-router/scripts/lib/codex-json.sh"

if [[ -f "$_bench_cost_lib" ]]; then
  # shellcheck disable=SC1090,SC1091
  source "$_bench_cost_lib"
fi

if [[ -f "$_bench_codex_json_lib" ]]; then
  # shellcheck disable=SC1090,SC1091
  source "$_bench_codex_json_lib"
fi

if ! declare -F cost_for_model >/dev/null 2>&1; then
  cost_for_model() {
    printf '0\n'
  }
fi

if ! declare -F codex_usage >/dev/null 2>&1; then
  codex_usage() {
    printf '%s\n' '{"input_tokens":0,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0}'
  }
fi

bench_now_ms() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import time; print(int(time.time() * 1000))'
    return 0
  fi

  printf '%s\n' "$(( $(date +%s) * 1000 ))"
}

bench_emit_span() {
  local executor="${1:-}"
  local model="${2:-}"
  local status="${3:-}"
  local duration_ms="${4:-0}"
  local usage_json="${5:-}"
  local cost_usd="${6:-0}"
  local task="${7:-}"

  [[ -n "$usage_json" ]] || usage_json='{}'

  {
    local _log_root
    _log_root="$(python3 "$_bench_span_dir/../../scripts/legion_state.py" --log-root 2>/dev/null || { [ -d "$HOME/.claude/logs/legion" ] && printf '%s' "$HOME/.claude/logs/legion" || printf '%s' "${LEGION_LOG_ROOT:-$HOME/.legion/logs}"; })"
    local telemetry_dir="${LEGION_TELEMETRY_DIR:-$_log_root/spans}"
    local telemetry_day
    local run_id="${LEGION_BENCH_RUN_ID:-${RUN_ID:-}}"
    local tokens='{}'

    [[ "$duration_ms" =~ ^[0-9]+$ ]] || duration_ms=0
    [[ "$cost_usd" =~ ^-?[0-9]+([.][0-9]+)?$ ]] || cost_usd=0
    if jq -ce 'type == "object"' >/dev/null 2>&1 <<<"$usage_json"; then
      tokens="$usage_json"
    fi

    telemetry_day="$(date -u +%Y-%m-%d)"
    mkdir -p "$telemetry_dir"
    jq -cn \
      --arg schema "legion.span.v1" \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg run_id "$run_id" \
      --arg trace_id "$run_id" \
      --arg executor "$executor" \
      --arg model "$model" \
      --arg task "$task" \
      --arg status "$status" \
      --argjson duration_ms "$duration_ms" \
      --argjson cost_usd "$cost_usd" \
      --argjson tokens "$tokens" \
      '
      {
        schema: $schema,
        ts: $ts,
        run_id: $run_id,
        trace_id: $trace_id,
        parent_id: null,
        executor: $executor,
        model: $model,
        archetype: null,
        task: $task,
        status: $status,
        target_type: null,
        target_name: null,
        duration_ms: $duration_ms,
        cost_usd: $cost_usd,
        tokens: $tokens,
        artifacts: {}
      }
      ' >> "$telemetry_dir/$telemetry_day.jsonl"
  } 2>/dev/null || true
}

bench_status_from_rc() {
  local rc="${1:-1}"

  if [[ "$rc" -eq 0 ]]; then
    printf 'ok\n'
    return 0
  fi

  printf 'failed\n'
}
