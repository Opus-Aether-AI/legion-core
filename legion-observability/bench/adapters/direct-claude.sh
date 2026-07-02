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

model="${CLAUDE_MODEL:-opus}"
args=(-p --permission-mode acceptEdits --output-format json --no-session-persistence --model "$model")
task="$(<"$task_file")"
tmp="$(mktemp "${TMPDIR:-/tmp}/direct-claude.XXXXXX")"
trap 'rm -f "'"$tmp"'"' EXIT

cd "$workspace"
start_ms="$(bench_now_ms)"
set +e
claude "${args[@]}" "$task" | tee "$tmp"
rc=${PIPESTATUS[0]}
# Stay under `set +e` for span post-processing (see direct-codex.sh).
end_ms="$(bench_now_ms)"
dur=$(( end_ms - start_ms ))

# Label the span with the model Claude actually reports when available, so the
# attribution is truthful even if the CLI default differs from CLAUDE_MODEL.
actual_model="$(jq -r '.model // .modelName // empty' "$tmp" 2>/dev/null || true)"
[[ -n "$actual_model" && "$actual_model" != "null" ]] && model="$actual_model"

usage="$(jq -c '.usage // {}' "$tmp" 2>/dev/null || printf '{}')"
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

bench_emit_span "claude" "$model" "$(bench_status_from_rc "$rc")" "$dur" "$usage" "$cost" "claude:${LEGION_BENCH_CASE_ID:-}"
exit "$rc"
