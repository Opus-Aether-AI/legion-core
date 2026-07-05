#!/usr/bin/env bash
# legion-report — per-executor cost / success / latency from telemetry spans.
#   legion-report [--by executor|model|status] [--html] [--json] [--trace latest|TRACE_ID]
set -euo pipefail

_self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$_self/lib/state.sh"

by="executor"
do_html=0
do_json=0
trace=""
action=""
target="latest"
while [[ $# -gt 0 ]]; do
  case "$1" in
    open|path) action="$1"; target="${2:-latest}"; shift; [[ $# -gt 0 ]] && shift || true ;;
    --by)   by="$2"; shift 2 ;;
    --html) do_html=1; shift ;;
    --json) do_json=1; shift ;;
    --trace) trace="$2"; shift 2 ;; # accepted for roadmap compatibility; aggregation still reads the telemetry dir
    -h|--help) echo "usage: legion-report [open|path latest] [--by executor|model|status] [--html] [--json] [--trace latest|TRACE_ID]"; exit 0 ;;
    *) echo "legion-report: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

legion_resolve_state "$PWD"
report_path="$LEGION_REPORTS_DIR/$target.html"

if [[ "$action" == "path" ]]; then
  printf '%s\n' "$report_path"
  exit 0
fi

if [[ "$action" == "open" ]]; then
  mkdir -p "$LEGION_REPORTS_DIR"
  python3 "$_self/legion-aggregate.py" --by "$by" --dir "$LEGION_TELEMETRY_DIR" \
    | python3 "$_self/legion-render.py" --html > "$report_path"
  if command -v open >/dev/null 2>&1; then
    open "$report_path" >/dev/null 2>&1 || true
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$report_path" >/dev/null 2>&1 || true
  fi
  printf '%s\n' "$report_path"
  exit 0
fi

if [[ "$do_json" -eq 1 ]]; then
  python3 "$_self/legion-aggregate.py" --by "$by" --dir "$LEGION_TELEMETRY_DIR"
elif [[ "$do_html" -eq 1 ]]; then
  python3 "$_self/legion-aggregate.py" --by "$by" --dir "$LEGION_TELEMETRY_DIR" \
    | python3 "$_self/legion-render.py" --html
else
  python3 "$_self/legion-aggregate.py" --by "$by" --dir "$LEGION_TELEMETRY_DIR" \
    | python3 "$_self/legion-render.py"
fi
