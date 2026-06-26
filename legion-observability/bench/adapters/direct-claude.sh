#!/usr/bin/env bash
set -euo pipefail

workspace="${LEGION_BENCH_WORKSPACE:?LEGION_BENCH_WORKSPACE required}"
task_file="${LEGION_BENCH_TASK_FILE:?LEGION_BENCH_TASK_FILE required}"

args=(-p --permission-mode acceptEdits --output-format json --no-session-persistence)
if [[ -n "${CLAUDE_MODEL:-}" ]]; then
  args+=(--model "$CLAUDE_MODEL")
fi

cd "$workspace"
claude "${args[@]}" "$(cat "$task_file")"
