#!/usr/bin/env bash
# legion-telemetry — emit and validate legion.span.v1 telemetry spans.
#
# The one emitter every executor/runner/orchestrator uses, so spans are uniform.
#   legion-trace emit --executor codex --model gpt-5.5 --status ok \
#       [--run-id ID] [--trace-id ID] [--parent-id ID] [--cost 0.01] \
#       [--duration-ms 1200] [--task "..."] [--tokens '{...}'] [--artifacts '{...}']
#       [--target-type command --target-name feature]
#   legion-trace validate <file|->     # exit 1 if any line isn't a valid span
#
# Spans append to $LEGION_TELEMETRY_DIR/<date>.jsonl.

set -euo pipefail

_self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$_self/lib/state.sh"
legion_resolve_state "$PWD"

_now()   { date -u +%Y-%m-%dT%H:%M:%SZ; }
_today() { date -u +%Y-%m-%d; }

emit() {
  local executor="" model="" status="" run_id="" task="" trace_id="" parent_id=""
  local target_type="${LEGION_TARGET_TYPE:-}" target_name="${LEGION_TARGET_NAME:-}"
  local cost=0 dur=0 tokens="{}" artifacts="{}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --executor)    executor="$2"; shift 2 ;;
      --model)       model="$2"; shift 2 ;;
      --status)      status="$2"; shift 2 ;;
      --run-id)      run_id="$2"; shift 2 ;;
      --task)        task="$2"; shift 2 ;;
      --trace-id)    trace_id="$2"; shift 2 ;;
      --parent-id)   parent_id="$2"; shift 2 ;;
      --cost)        cost="$2"; shift 2 ;;
      --duration-ms) dur="$2"; shift 2 ;;
      --tokens)      tokens="$2"; shift 2 ;;
      --artifacts)   artifacts="$2"; shift 2 ;;
      --target-type) target_type="$2"; shift 2 ;;
      --target-name) target_name="$2"; shift 2 ;;
      *) echo "emit: unknown arg '$1'" >&2; return 2 ;;
    esac
  done
  [[ -n "$executor" && -n "$model" && -n "$status" ]] || {
    echo "emit: --executor, --model, --status are required" >&2; return 2; }
  [[ -n "$run_id" ]]   || run_id="$(_now)-$$"
  [[ -n "$trace_id" ]] || trace_id="$run_id"

  local span
  span="$(jq -cn \
    --arg ts "$(_now)" --arg run "$run_id" --arg trace "$trace_id" --arg parent "$parent_id" \
    --arg ex "$executor" --arg model "$model" --arg task "$task" --arg status "$status" \
    --arg target_type "$target_type" --arg target_name "$target_name" \
    --argjson dur "${dur:-0}" --argjson cost "${cost:-0}" \
    --argjson tokens "$tokens" --argjson artifacts "$artifacts" '
    {schema:"legion.span.v1", ts:$ts, run_id:$run, trace_id:$trace,
     parent_id:(if $parent=="" then null else $parent end),
     executor:$ex, model:$model, task:$task, status:$status,
     target_type:(if $target_type=="" then null else $target_type end),
     target_name:(if $target_name=="" then null else $target_name end),
     duration_ms:$dur, cost_usd:$cost, tokens:$tokens, artifacts:$artifacts}')"

  mkdir -p "$LEGION_TELEMETRY_DIR"
  printf '%s\n' "$span" >> "$LEGION_TELEMETRY_DIR/$(_today).jsonl"
  printf '%s\n' "$span"
}

validate() {
  local src="${1:-/dev/stdin}"
  [[ -z "$src" || "$src" == "-" ]] && src=/dev/stdin
  local bad=0 n=0 line
  # `|| [[ -n "$line" ]]` so a final line without a trailing newline is still checked
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    n=$((n + 1))
	    if ! printf '%s' "$line" | jq -e '
	        .schema == "legion.span.v1"
	        and (.ts | type == "string")
	        and (.run_id | type == "string")
	        and (.executor | type == "string")
	        and (.model | type == "string")
	        and (.status | IN("ok", "failed", "error", "over_budget", "blocked"))
	        and ((.duration_ms // 0) | type == "number" and . >= 0)
	        and ((.cost_usd // 0) | type == "number" and . >= 0)
	        and ((.target_type == null) or (.target_type | type == "string"))
	        and ((.target_name == null) or (.target_name | type == "string"))' >/dev/null 2>&1; then
      echo "invalid span (line $n): $line" >&2
      bad=$((bad + 1))
    fi
  done < "$src"
  if [[ "$bad" -ne 0 ]]; then
    echo "FAIL: $bad/$n span(s) invalid" >&2
    return 1
  fi
  echo "ok: $n span(s) valid"
}

cmd="${1:-}"
shift || true
case "$cmd" in
  emit)     emit "$@" ;;
  validate) validate "${1:-}" ;;
  *) echo "usage: legion-telemetry {emit --executor X --model Y --status S [...] | validate <file|->}" >&2; exit 2 ;;
esac
