#!/usr/bin/env bash
set -euo pipefail

workspace="${LEGION_BENCH_WORKSPACE:?LEGION_BENCH_WORKSPACE required}"
task_file="${LEGION_BENCH_TASK_FILE:?LEGION_BENCH_TASK_FILE required}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "$script_dir/_span.sh"

if [[ -n "${LEGION_BENCH_REAL_HOME:-}" ]]; then
  export HOME="$LEGION_BENCH_REAL_HOME"
fi

args=(--print --output-format json --force --trust --workspace "$workspace")
if [[ -n "${CURSOR_MODEL:-}" ]]; then
  args+=(--model "$CURSOR_MODEL")
fi

model="${CURSOR_MODEL:-cursor-auto}"
task="$(<"$task_file")"
tmp="$(mktemp "${TMPDIR:-/tmp}/cursor-agent.XXXXXX")"
trap 'rm -f "'"$tmp"'"' EXIT

start_ms="$(bench_now_ms)"
set +e
cursor-agent "${args[@]}" "$task" | tee "$tmp"
rc=${PIPESTATUS[0]}
# Stay under `set +e` for span post-processing (see direct-codex.sh).
end_ms="$(bench_now_ms)"
dur=$(( end_ms - start_ms ))

# Label the span with the model cursor-agent actually reports when available.
actual_model="$(jq -r '.model // .metadata.model // empty' "$tmp" 2>/dev/null || true)"
[[ -n "$actual_model" && "$actual_model" != "null" ]] && model="$actual_model"

# cursor-agent reports usage with camelCase keys (inputTokens/outputTokens/
# cacheReadTokens/cacheWriteTokens). Normalize to the canonical snake_case
# token keys so both the emitted span and the harness token aggregator
# (_span_token_total) count them.
raw_usage="$(jq -c '.usage // .tokens // {}' "$tmp" 2>/dev/null || printf '{}')"
usage="$(jq -c '{
  input_tokens: (.input_tokens // .inputTokens // 0),
  output_tokens: (.output_tokens // .outputTokens // 0),
  cache_read_input_tokens: (.cache_read_input_tokens // .cacheReadTokens // .cached_input_tokens // 0),
  cache_creation_input_tokens: (.cache_creation_input_tokens // .cacheWriteTokens // 0)
}' <<<"$raw_usage" 2>/dev/null || printf '{}')"
# Cursor Agent runs on a Cursor subscription with no per-call USD price, so the
# bundled cursor pricing row is $0; cost stays 0 (unmetered) unless cursor-agent
# itself reports total_cost_usd. Tokens are still captured for work-volume parity.
if jq -e '.total_cost_usd | numbers' "$tmp" >/dev/null 2>&1; then
  cost="$(jq -r '.total_cost_usd' "$tmp" 2>/dev/null || printf '0')"
else
  input_tokens="$(jq -r '.input_tokens // 0' <<<"$usage" 2>/dev/null || printf '0')"
  output_tokens="$(jq -r '.output_tokens // 0' <<<"$usage" 2>/dev/null || printf '0')"
  cache_read_input_tokens="$(jq -r '.cache_read_input_tokens // 0' <<<"$usage" 2>/dev/null || printf '0')"
  cache_creation_input_tokens="$(jq -r '.cache_creation_input_tokens // 0' <<<"$usage" 2>/dev/null || printf '0')"
  for value_name in input_tokens output_tokens cache_read_input_tokens cache_creation_input_tokens; do
    [[ "${!value_name}" =~ ^[0-9]+$ ]] || printf -v "$value_name" '%s' 0
  done
  cost="$(cost_for_model "$model" "$input_tokens" "$output_tokens" "$cache_read_input_tokens" "$cache_creation_input_tokens" 2>/dev/null || printf '0')"
fi

bench_emit_span "cursor" "$model" "$(bench_status_from_rc "$rc")" "$dur" "$usage" "$cost" "cursor:${LEGION_BENCH_CASE_ID:-}"
exit "$rc"
