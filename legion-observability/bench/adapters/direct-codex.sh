#!/usr/bin/env bash
set -euo pipefail

workspace="${LEGION_BENCH_WORKSPACE:?LEGION_BENCH_WORKSPACE required}"
task_file="${LEGION_BENCH_TASK_FILE:?LEGION_BENCH_TASK_FILE required}"

args=(exec --json -s workspace-write -C "$workspace" --skip-git-repo-check -)
if [[ -n "${CODEX_MODEL:-}" ]]; then
  args=(exec --json -m "$CODEX_MODEL" -s workspace-write -C "$workspace" --skip-git-repo-check -)
fi

codex "${args[@]}" < "$task_file"
