#!/usr/bin/env bash
set -euo pipefail

workspace="${LEGION_BENCH_WORKSPACE:?LEGION_BENCH_WORKSPACE required}"
task_file="${LEGION_BENCH_TASK_FILE:?LEGION_BENCH_TASK_FILE required}"

if [[ -n "${LEGION_BENCH_REAL_HOME:-}" ]]; then
  export HOME="$LEGION_BENCH_REAL_HOME"
fi

args=(--print --force --trust --workspace "$workspace")
if [[ -n "${CURSOR_MODEL:-}" ]]; then
  args+=(--model "$CURSOR_MODEL")
fi

cursor-agent "${args[@]}" "$(cat "$task_file")"
