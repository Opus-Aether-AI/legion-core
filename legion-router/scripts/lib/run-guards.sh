#!/usr/bin/env bash
# Run guards shared by legion-delegate and every adapter: executor health and
# spending caps. Sourced, never executed. Every helper is best-effort -- a guard
# that cannot run must not take a run down with it -- except the two decisions
# legion-delegate makes before dispatch (health check, day cap), which report
# their verdict through the return code.
#
#   legion_health_check <executor>         rc 0 available, 1 unavailable; JSON on stdout
#   legion_health_pick <exclude>           first healthy fallback executor, or ""
#   legion_budget_day_check                rc 0 under the day cap, 3 when it is spent
#   legion_budget_run_cap                  per-run cap in USD ("0" = off)
#   legion_budget_cap_status <status> <cost>   ok -> over_budget above the run cap
#   legion_guard_span <executor> <status> <cost> <artifacts>
#       Called by emit_span before writing a span. Sets LEGION_GUARD_STATUS and
#       LEGION_GUARD_ARTIFACTS: the per-run cap turns ok into over_budget, a
#       health fallback taken for this run is recorded in the artifacts, and the
#       run's outcome is folded into the executor's health record.
#       LEGION_GUARD_ERROR_TEXT, when the adapter sets it, is the provider error
#       the run ended with (never task output); LEGION_GUARD_REASON_HINT names
#       the cause outright when the adapter knows it.

_legion_guards_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_legion_health_py="$_legion_guards_lib_dir/../legion-health.py"
_legion_budget_py="$_legion_guards_lib_dir/../legion-budget.py"

legion_health_enabled() {
  case "$(printf '%s' "${LEGION_HEALTH:-on}" | tr '[:upper:]' '[:lower:]')" in
    off|0|false|no) return 1 ;;
  esac
  return 0
}

legion_health_check() {
  local executor="$1" out rc=0
  if ! legion_health_enabled || [[ ! -f "$_legion_health_py" ]]; then
    printf '{"executor":"%s","available":true}\n' "$executor"
    return 0
  fi
  if [[ "${LEGION_HEALTH_PROBE:-1}" == "0" ]]; then
    out="$(python3 "$_legion_health_py" check "$executor" --no-probe 2>/dev/null)" || rc=$?
  else
    out="$(python3 "$_legion_health_py" check "$executor" 2>/dev/null)" || rc=$?
  fi
  if [[ -n "$out" ]]; then
    printf '%s\n' "$out"
  else
    printf '{"executor":"%s","available":true}\n' "$executor"
  fi
  # Anything but an explicit "unavailable" (a crash, a missing python) is not
  # evidence of an outage, and must not strand work.
  [[ "$rc" -eq 1 ]] && return 1
  return 0
}

legion_health_pick() {
  legion_health_enabled || return 0
  python3 "$_legion_health_py" pick --exclude "$1" 2>/dev/null || true
}

legion_budget_run_cap() {
  if [[ -n "${LEGION_RUN_BUDGET_USD:-}" ]]; then
    printf '%s\n' "$LEGION_RUN_BUDGET_USD"
    return 0
  fi
  python3 "$_legion_budget_py" caps --field run_usd 2>/dev/null || printf '0\n'
}

legion_budget_day_check() {
  local rc=0
  python3 "$_legion_budget_py" check 2>/dev/null || rc=$?
  [[ "$rc" -eq 3 ]] && return 3
  return 0
}

# legion_budget_cap_status <status> <cost>: the run's status after the per-run
# cap. Adapters call it BEFORE deciding whether to apply their diff, so the cap
# changes what happens to the work, not only what the span says.
legion_budget_cap_status() {
  local status="$1" cost="${2:-0}"
  if [[ "$status" == "ok" ]] && _legion_over_cap "$cost" "$(legion_budget_run_cap)"; then
    printf 'over_budget\n'
  else
    printf '%s\n' "$status"
  fi
}

_legion_over_cap() {
  awk -v c="${1:-0}" -v k="${2:-0}" 'BEGIN { exit !((k + 0) > 0 && (c + 0) > (k + 0)) }'
}

legion_guard_span() {
  local executor="$1" status="$2" cost="${3:-0}" artifacts="${4:-}" cap="" hint="" stderr_file=""
  [[ -n "$artifacts" ]] || artifacts='{}'
  LEGION_GUARD_STATUS="$status"
  LEGION_GUARD_ARTIFACTS="$artifacts"
  if [[ "$status" == "ok" || "$status" == "over_budget" ]]; then
    cap="$(legion_budget_run_cap)"
    if _legion_over_cap "$cost" "$cap"; then
      LEGION_GUARD_STATUS="over_budget"
      LEGION_GUARD_ARTIFACTS="$(jq -c --argjson cap "$cap" --argjson cost "${cost:-0}" \
        '. + {budget:{run_usd_cap:$cap, cost_usd:$cost, exceeded:true}}' \
        <<<"$LEGION_GUARD_ARTIFACTS" 2>/dev/null || printf '%s' "$LEGION_GUARD_ARTIFACTS")"
    fi
  fi
  # Only the run legion-delegate rerouted carries the note; a nested run in the
  # same environment has a different RUN_ID.
  if [[ -n "${LEGION_HEALTH_FALLBACK_FROM:-}" && -n "${RUN_ID:-}" \
        && "${LEGION_HEALTH_FALLBACK_RUN:-}" == "$RUN_ID" ]]; then
    LEGION_GUARD_ARTIFACTS="$(jq -c --arg from "$LEGION_HEALTH_FALLBACK_FROM" \
      --arg reason "${LEGION_HEALTH_FALLBACK_REASON:-unavailable}" --arg to "$executor" \
      '. + {health_fallback:{from:$from, to:$to, reason:$reason}}' \
      <<<"$LEGION_GUARD_ARTIFACTS" 2>/dev/null || printf '%s' "$LEGION_GUARD_ARTIFACTS")"
  fi
  legion_health_enabled || return 0
  [[ -f "$_legion_health_py" ]] || return 0
  # An adapter that reports "blocked" for itself has hit a provider limit
  # (legion-claude: claude_limit); legion-route's own blocked spans are not runs.
  [[ "$status" == "blocked" && "$executor" != legion-* ]] && hint="no_quota"
  # An adapter that knows the cause names it (legion-cursor: missing_key).
  [[ -n "${LEGION_GUARD_REASON_HINT:-}" && "$LEGION_GUARD_STATUS" != "ok" ]] && hint="$LEGION_GUARD_REASON_HINT"
  stderr_file="$(jq -r '.stderr // empty' <<<"$artifacts" 2>/dev/null || true)"
  local -a observe_args=(observe "$executor" --run-status "$LEGION_GUARD_STATUS")
  [[ -n "$hint" ]] && observe_args+=(--reason-hint "$hint")
  [[ -n "$stderr_file" && -f "$stderr_file" ]] && observe_args+=(--file "$stderr_file")
  [[ -n "${LEGION_GUARD_ERROR_TEXT:-}" ]] && observe_args+=(--text "$LEGION_GUARD_ERROR_TEXT")
  case "$executor" in
    legion-*|orchestrator|*-baseline) return 0 ;;
  esac
  python3 "$_legion_health_py" "${observe_args[@]}" >/dev/null 2>&1 || true
  return 0
}

# legion_health_mark_unavailable <executor> [file...]
# For a caller that already knows the executor could not serve the request
# (the review walk's unavailability check): record the reason the files name,
# or probe_failed when they name none.
legion_health_mark_unavailable() {
  legion_health_enabled || return 0
  [[ -f "$_legion_health_py" ]] || return 0
  local executor="$1" file
  shift
  local -a args=(observe "$executor" --run-status failed --default-reason probe_failed)
  for file in "$@"; do
    [[ -n "$file" && -f "$file" ]] && args+=(--file "$file")
  done
  python3 "$_legion_health_py" "${args[@]}" >/dev/null 2>&1 || true
}
