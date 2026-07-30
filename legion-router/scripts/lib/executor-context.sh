#!/usr/bin/env bash
# Shared delegated-executor context. Repository policies use these variables to
# distinguish a primary/orchestrator from a child that must implement directly.

legion_activate_executor_context() {
  local run_id="${1:-}" inherited_depth="${LEGION_DEPTH:-0}"
  [[ "$inherited_depth" =~ ^[0-9]+$ ]] || inherited_depth=0
  export LEGION_ACTIVE=1
  export LEGION_EXECUTOR=1
  export LEGION_DEPTH="$((inherited_depth + 1))"
  export LEGION_RUN_ID="$run_id"
}
