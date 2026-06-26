#!/usr/bin/env bash
set -euo pipefail

workspace="${LEGION_BENCH_WORKSPACE:?LEGION_BENCH_WORKSPACE required}"
task_file="${LEGION_BENCH_TASK_FILE:?LEGION_BENCH_TASK_FILE required}"

args=(--print --force --trust --workspace "$workspace")
if [[ -n "${CURSOR_MODEL:-}" ]]; then
  args+=(--model "$CURSOR_MODEL")
fi

cursor-agent "${args[@]}" "$(cat "$task_file")"
