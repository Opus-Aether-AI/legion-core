#!/usr/bin/env bash
set -euo pipefail

repo="${LEGION_BENCH_REPO:?LEGION_BENCH_REPO required}"
workspace="${LEGION_BENCH_WORKSPACE:?LEGION_BENCH_WORKSPACE required}"
task_file="${LEGION_BENCH_TASK_FILE:?LEGION_BENCH_TASK_FILE required}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
# shellcheck source=../../../legion-router/scripts/lib/model-config.sh
source "$script_dir/../../../legion-router/scripts/lib/model-config.sh"

if [[ -n "${LEGION_BENCH_REAL_HOME:-}" ]]; then
  export HOME="$LEGION_BENCH_REAL_HOME"
fi

if [[ ! -d "$workspace/.git" ]]; then
  git -C "$workspace" init -q
  printf '%s\n' "__pycache__/" "*.py[cod]" > "$workspace/.gitignore"
  git -C "$workspace" add .
  git -C "$workspace" -c user.email=bench@example.com -c user.name=bench commit -qm init
fi

default_model="$(legion_model_ref cursor_default)" || {
  printf 'legion-cursor adapter: could not resolve cursor_default in models.toml\n' >&2
  exit 2
}
model="${CURSOR_MODEL:-${LEGION_CURSOR_MODEL:-$default_model}}"

"$repo/legion-router/bin/legion-cursor" run \
  --archetype "${LEGION_BENCH_ARCHETYPE:-implement-feature}" \
  --model "$model" \
  --sandbox workspace-write \
  --repo "$workspace" \
  --apply \
  < "$task_file"
