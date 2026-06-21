#!/usr/bin/env bash
# legion-report — per-executor cost / success / latency from telemetry spans.
#   legion-report [--by executor|model|status] [--html]
set -euo pipefail

_self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LEGION_TELEMETRY_DIR="${LEGION_TELEMETRY_DIR:-$HOME/.claude/logs/legion/spans}"

by="executor"
do_html=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --by)   by="$2"; shift 2 ;;
    --html) do_html=1; shift ;;
    -h|--help) echo "usage: legion-report [--by executor|model|status] [--html]"; exit 0 ;;
    *) echo "legion-report: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

if [[ "$do_html" -eq 1 ]]; then
  python3 "$_self/legion-aggregate.py" --by "$by" --dir "$LEGION_TELEMETRY_DIR" \
    | python3 "$_self/legion-render.py" --html
else
  python3 "$_self/legion-aggregate.py" --by "$by" --dir "$LEGION_TELEMETRY_DIR" \
    | python3 "$_self/legion-render.py"
fi
