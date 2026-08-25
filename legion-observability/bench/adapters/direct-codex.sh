#!/usr/bin/env bash
set -euo pipefail

workspace="${LEGION_BENCH_WORKSPACE:?LEGION_BENCH_WORKSPACE required}"
task_file="${LEGION_BENCH_TASK_FILE:?LEGION_BENCH_TASK_FILE required}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "$script_dir/_span.sh"
# shellcheck disable=SC1091
# shellcheck source=../../../legion-router/scripts/lib/model-config.sh
source "$script_dir/../../../legion-router/scripts/lib/model-config.sh"

if [[ -n "${LEGION_BENCH_REAL_HOME:-}" ]]; then
  export HOME="$LEGION_BENCH_REAL_HOME"
fi

# Use the same configured Codex default as Legion routes. Set CODEX_MODEL for
# controlled comparisons.
default_model="$(legion_model_ref codex_workhorse)" || {
  printf 'direct-codex: could not resolve codex_workhorse in models.toml\n' >&2
  exit 2
}
model="${CODEX_MODEL:-$default_model}"
# Reasoning effort is half of any model comparison and was not expressible here,
# so a cheap model could only ever be measured at whatever effort Codex defaults
# to -- which is not how Legion runs it. routing.toml drives the workhorse at
# `high` and the cheap role at `low`, so comparing the two models without also
# controlling this measures the pair of settings, not the pair of models.
args=(exec --json -m "$model" -s workspace-write -C "$workspace" --skip-git-repo-check)
if [[ -n "${CODEX_REASONING_EFFORT:-}" ]]; then
  case "$CODEX_REASONING_EFFORT" in
    low|medium|high|max) ;;
    *) printf 'direct-codex: bad CODEX_REASONING_EFFORT %s (low|medium|high|max)\n' \
         "$CODEX_REASONING_EFFORT" >&2; exit 2 ;;
  esac
  args+=(-c "model_reasoning_effort=$CODEX_REASONING_EFFORT")
fi
args+=(-)

tmp="$(mktemp "${TMPDIR:-/tmp}/direct-codex.XXXXXX")"
trap 'rm -f "'"$tmp"'"' EXIT

start_ms="$(bench_now_ms)"
set +e
codex "${args[@]}" < "$task_file" | tee "$tmp"
rc=${PIPESTATUS[0]}
# Stay under `set +e` for span post-processing: a missing/failing jq must not
# abort the adapter or replace the CLI's real exit code. The script ends with
# an explicit `exit "$rc"`, and every parse below is guarded.
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
