#!/usr/bin/env bash
# legion-telemetry — emit and validate legion.span.v1 telemetry spans.
#
# The one emitter every executor/runner/orchestrator uses, so spans are uniform.
#   legion-trace emit --executor codex --model "$(legion-route --model-ref codex_workhorse)" --status ok \
#       [--run-id ID] [--trace-id ID] [--parent-id ID] [--cost 0.01] \
#       [--duration-ms 1200] [--task "..."] [--tokens '{...}'] [--artifacts '{...}']
#       [--archetype implement-feature] [--target-type command --target-name feature]
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
  local archetype="${LEGION_ARCHETYPE:-}"
  local target_type="${LEGION_TARGET_TYPE:-}" target_name="${LEGION_TARGET_NAME:-}"
  local cost=null dur=0 tokens=null artifacts="{}"
  local cost_status="" usage_status="" known_cost=null known_cost_attempts=0
  local known_usage=null known_usage_attempts=0
  local cost_set=0 tokens_set=0 known_cost_set=0 known_usage_set=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --executor)    executor="$2"; shift 2 ;;
      --model)       model="$2"; shift 2 ;;
      --status)      status="$2"; shift 2 ;;
      --run-id)      run_id="$2"; shift 2 ;;
      --task)        task="$2"; shift 2 ;;
      --trace-id)    trace_id="$2"; shift 2 ;;
      --parent-id)   parent_id="$2"; shift 2 ;;
      --archetype)   archetype="$2"; shift 2 ;;
      --cost)        cost="$2"; cost_set=1; shift 2 ;;
      --cost-status) cost_status="$2"; shift 2 ;;
      --known-cost) known_cost="$2"; known_cost_set=1; shift 2 ;;
      --known-cost-attempts) known_cost_attempts="$2"; shift 2 ;;
      --duration-ms) dur="$2"; shift 2 ;;
      --tokens)      tokens="$2"; tokens_set=1; shift 2 ;;
      --usage-status) usage_status="$2"; shift 2 ;;
      --known-usage) known_usage="$2"; known_usage_set=1; shift 2 ;;
      --known-usage-attempts) known_usage_attempts="$2"; shift 2 ;;
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

  if [[ -z "$cost_status" ]]; then
    [[ "$cost_set" -eq 1 ]] && cost_status=known || cost_status=unknown
  fi
  if [[ -z "$usage_status" ]]; then
    [[ "$tokens_set" -eq 1 ]] && usage_status=known || usage_status=unknown
  fi
  if [[ "$known_cost_set" -eq 1 && "$cost_status" != partial ]]; then
    echo "emit: --known-cost requires --cost-status partial" >&2
    return 2
  fi
  if [[ "$known_usage_set" -eq 1 && "$usage_status" != partial ]]; then
    echo "emit: --known-usage requires --usage-status partial" >&2
    return 2
  fi

  local span
  if ! span="$(jq -cn \
    --arg ts "$(_now)" --arg run "$run_id" --arg trace "$trace_id" --arg parent "$parent_id" \
    --arg ex "$executor" --arg model "$model" --arg archetype "$archetype" \
    --arg task "$task" --arg status "$status" \
    --arg target_type "$target_type" --arg target_name "$target_name" \
    --argjson dur "${dur:-0}" --argjson cost "${cost:-null}" \
    --arg cost_status "$cost_status" --argjson known_cost "${known_cost:-null}" \
    --argjson known_cost_attempts "${known_cost_attempts:-0}" \
    --argjson tokens "${tokens:-null}" --arg usage_status "$usage_status" \
    --argjson known_usage "${known_usage:-null}" \
    --argjson known_usage_attempts "${known_usage_attempts:-0}" \
    --argjson artifacts "$artifacts" '
    {schema:"legion.span.v1", ts:$ts, run_id:$run, trace_id:$trace,
     parent_id:(if $parent=="" then null else $parent end),
     executor:$ex, model:$model,
     archetype:(if $archetype=="" then null else $archetype end),
     task:$task, status:$status,
     target_type:(if $target_type=="" then null else $target_type end),
     target_name:(if $target_name=="" then null else $target_name end),
     duration_ms:$dur, cost_usd:$cost, cost_status:$cost_status,
     tokens:$tokens, usage_status:$usage_status, artifacts:$artifacts}
    + (if $cost_status == "partial" then
         {known_cost_usd:$known_cost,known_cost_attempts:$known_cost_attempts}
       else {} end)
    + (if $usage_status == "partial" then
         {known_usage:$known_usage,known_usage_attempts:$known_usage_attempts}
       else {} end)')"; then
    echo "emit: metering and artifact values must be valid JSON" >&2
    return 2
  fi

  if ! printf '%s\n' "$span" | validate - >/dev/null; then
    echo "emit: span fields violate legion.span.v1" >&2
    return 2
  fi

  mkdir -p "$LEGION_TELEMETRY_DIR"
  if [[ -n "${LEGION_ADAPTER_SPAN_DATE:-}" && ! "$LEGION_ADAPTER_SPAN_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    echo "emit: invalid pinned telemetry date" >&2
    return 2
  fi
  printf '%s\n' "$span" >> "$LEGION_TELEMETRY_DIR/${LEGION_ADAPTER_SPAN_DATE:-$(_today)}.jsonl"
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
	        def nonnegative_number: type == "number" and isfinite and . >= 0;
	        def nonnegative_integer: nonnegative_number and . == floor;
	        def positive_integer: type == "number" and isfinite and . >= 1 and . == floor;
	        def valid_usage_object:
	          type == "object"
	          and all(to_entries[]; .value | nonnegative_integer);
	        def valid_cost_companions:
	          ((has("known_cost_usd") | not) or .known_cost_usd == null
	            or (.known_cost_usd | nonnegative_number))
	          and ((has("known_cost_attempts") | not)
	            or (.known_cost_attempts | nonnegative_integer));
	        def valid_usage_companions:
	          ((has("known_usage") | not) or .known_usage == null
	            or (.known_usage | valid_usage_object))
	          and ((has("known_usage_attempts") | not)
	            or (.known_usage_attempts | nonnegative_integer));
	        def valid_cost_provenance:
	          if has("cost_status") | not then
	            (has("cost_usd") | not) or (.cost_usd == null) or (.cost_usd | nonnegative_number)
	          elif .cost_status == "known" then
	            (.cost_usd | nonnegative_number)
	          elif .cost_status == "partial" then
	            .cost_usd == null
	            and (.known_cost_usd | nonnegative_number)
	            and (.known_cost_attempts | positive_integer)
	          elif (.cost_status == "unknown" or .cost_status == "not_applicable") then
	            .cost_usd == null and ((has("known_cost_usd") | not) or .known_cost_usd == null)
	          else false end;
	        def valid_usage_provenance:
	          if has("usage_status") | not then
	            (has("tokens") | not) or (.tokens == null) or (.tokens | valid_usage_object)
	          elif .usage_status == "known" then
	            (.tokens | valid_usage_object)
	          elif .usage_status == "partial" then
	            .tokens == null
	            and (.known_usage | valid_usage_object)
	            and (.known_usage_attempts | positive_integer)
	          elif (.usage_status == "unknown" or .usage_status == "not_applicable") then
	            .tokens == null and ((has("known_usage") | not) or .known_usage == null)
	          else false end;
	        .schema == "legion.span.v1"
	        and (.ts | type == "string")
	        and (.run_id | type == "string")
	        and (.executor | type == "string")
	        and (.model | type == "string")
	        and ((has("attempt_id") | not) or .attempt_id == null
	          or ((.attempt_id | type) == "string" and (.attempt_id | length) >= 1))
	        and ((has("attempt_ordinal") | not) or .attempt_ordinal == null
	          or (.attempt_ordinal | positive_integer))
	        and ((.archetype == null) or (.archetype | type == "string"))
	        and (.status | IN("ok", "failed", "error", "over_budget", "blocked", "refused", "timed_out", "containment_failed"))
	        and ((.duration_ms // 0) | type == "number" and . >= 0)
	        and valid_cost_provenance
	        and valid_usage_provenance
	        and valid_cost_companions
	        and valid_usage_companions
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
