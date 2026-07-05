#!/usr/bin/env bash
# legion-report — per-executor cost / success / latency from telemetry spans.
#   legion-report [--by executor|model|status] [--html] [--json] [--trace latest|TRACE_ID]
set -euo pipefail

_self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${LEGION_STATE_ROOT:-}" ]]; then
  export LEGION_TELEMETRY_DIR="${LEGION_TELEMETRY_DIR:-$LEGION_STATE_ROOT/spans}"
else
  export LEGION_TELEMETRY_DIR="${LEGION_TELEMETRY_DIR:-$HOME/.claude/logs/legion/spans}"
fi

by="executor"
do_html=0
do_json=0
trace=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --by)   by="$2"; shift 2 ;;
    --html) do_html=1; shift ;;
    --json) do_json=1; shift ;;
    --trace) trace="$2"; shift 2 ;; # accepted for roadmap compatibility; aggregation still reads the telemetry dir
    -h|--help) echo "usage: legion-report [--by executor|model|status] [--html] [--json] [--trace latest|TRACE_ID]"; exit 0 ;;
    *) echo "legion-report: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

if [[ "$do_json" -eq 1 ]]; then
  python3 "$_self/legion-aggregate.py" --by "$by" --dir "$LEGION_TELEMETRY_DIR"
elif [[ "$do_html" -eq 1 ]]; then
  python3 "$_self/legion-aggregate.py" --by "$by" --dir "$LEGION_TELEMETRY_DIR" \
    | python3 "$_self/legion-render.py" --html
else
  python3 "$_self/legion-aggregate.py" --by "$by" --dir "$LEGION_TELEMETRY_DIR" \
    | python3 "$_self/legion-render.py"
fi
