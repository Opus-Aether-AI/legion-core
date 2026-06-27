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

args=(exec --json -s workspace-write -C "$workspace" --skip-git-repo-check -)
if [[ -n "${CODEX_MODEL:-}" ]]; then
  args=(exec --json -m "$CODEX_MODEL" -s workspace-write -C "$workspace" --skip-git-repo-check -)
fi

model="${CODEX_MODEL:-gpt-5.4}"
tmp="$(mktemp "${TMPDIR:-/tmp}/direct-codex.XXXXXX")"
trap 'rm -f "'"$tmp"'"' EXIT

start_ms="$(bench_now_ms)"
set +e
codex "${args[@]}" < "$task_file" | tee "$tmp"
rc=${PIPESTATUS[0]}
set -e
end_ms="$(bench_now_ms)"
dur=$(( end_ms - start_ms ))

usage="$(codex_usage "$tmp")"
input_tokens="$(jq -r '.input_tokens // 0' <<<"$usage" 2>/dev/null || printf '0')"
cached_input_tokens="$(jq -r '.cached_input_tokens // 0' <<<"$usage" 2>/dev/null || printf '0')"
output_tokens="$(jq -r '.output_tokens // 0' <<<"$usage" 2>/dev/null || printf '0')"
reasoning_output_tokens="$(jq -r '.reasoning_output_tokens // 0' <<<"$usage" 2>/dev/null || printf '0')"
for value_name in input_tokens cached_input_tokens output_tokens reasoning_output_tokens; do
  [[ "${!value_name}" =~ ^[0-9]+$ ]] || printf -v "$value_name" '%s' 0
done
billed_in=$(( input_tokens - cached_input_tokens ))
(( billed_in < 0 )) && billed_in=0
billed_out=$(( output_tokens + reasoning_output_tokens ))
cost="$(cost_for_model "$model" "$billed_in" "$billed_out" "$cached_input_tokens" 0 2>/dev/null || printf '0')"

bench_emit_span "codex" "$model" "$(bench_status_from_rc "$rc")" "$dur" "$usage" "$cost" "codex:${LEGION_BENCH_CASE_ID:-}"
exit "$rc"
