#!/usr/bin/env bash
set -euo pipefail

repo="${LEGION_BENCH_REPO:?LEGION_BENCH_REPO required}"
workspace="${LEGION_BENCH_WORKSPACE:?LEGION_BENCH_WORKSPACE required}"
task_file="${LEGION_BENCH_TASK_FILE:?LEGION_BENCH_TASK_FILE required}"

if [[ -n "${LEGION_BENCH_REAL_HOME:-}" ]]; then
  export HOME="$LEGION_BENCH_REAL_HOME"
fi

if [[ ! -d "$workspace/.git" ]]; then
  git -C "$workspace" init -q
  printf '%s\n' "__pycache__/" "*.py[cod]" > "$workspace/.gitignore"
  git -C "$workspace" add .
  git -C "$workspace" -c user.email=bench@example.com -c user.name=bench commit -qm init
fi

"$repo/legion-router/bin/legion-delegate" run \
  --archetype "${LEGION_BENCH_ARCHETYPE:-implement-feature}" \
  --sandbox workspace-write \
  --repo "$workspace" \
  --apply \
  --untrusted \
  < "$task_file"
