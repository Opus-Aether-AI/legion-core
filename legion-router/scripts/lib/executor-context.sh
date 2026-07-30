#!/usr/bin/env bash
# Shared delegated-executor context. Repository policies use these variables to
# distinguish a primary/orchestrator from a child that must implement directly.

legion_executor_context_active() {
  local depth="${LEGION_DEPTH:-0}"
  [[ "${LEGION_ACTIVE:-0}" == "1" || "${LEGION_EXECUTOR:-0}" == "1" ]] && return 0
  [[ "$depth" =~ ^[0-9]+$ && "$depth" -gt 0 ]]
}

legion_require_top_level_executor() {
  local executor="${1:-executor}"
  if legion_executor_context_active; then
    printf 'legion-%s: nested Legion delegation is blocked; implement the assigned slice directly\n' \
      "$executor" >&2
    return 2
  fi
}

legion_activate_executor_context() {
  local run_id="${1:-}" inherited_depth="${LEGION_DEPTH:-0}"
  [[ "$inherited_depth" =~ ^[0-9]+$ ]] || inherited_depth=0
  export LEGION_ACTIVE=1
  export LEGION_EXECUTOR=1
  export LEGION_DEPTH="$((inherited_depth + 1))"
  export LEGION_RUN_ID="$run_id"
}
