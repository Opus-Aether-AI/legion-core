#!/usr/bin/env bash
set -euo pipefail

workspace="${LEGION_BENCH_WORKSPACE:?LEGION_BENCH_WORKSPACE required}"
task_file="${LEGION_BENCH_TASK_FILE:?LEGION_BENCH_TASK_FILE required}"

if [[ -n "${LEGION_BENCH_REAL_HOME:-}" ]]; then
  export HOME="$LEGION_BENCH_REAL_HOME"
fi

args=(exec --json -s workspace-write -C "$workspace" --skip-git-repo-check -)
if [[ -n "${CODEX_MODEL:-}" ]]; then
  args=(exec --json -m "$CODEX_MODEL" -s workspace-write -C "$workspace" --skip-git-repo-check -)
fi

codex "${args[@]}" < "$task_file"
