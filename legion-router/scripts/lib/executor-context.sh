#!/usr/bin/env bash
# Shared delegated-executor context. Repository policies use these variables to
# distinguish a primary/orchestrator from a child that must implement directly.

_legion_context_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_legion_executor_registry="$_legion_context_dir/../../../legion-observability/scripts/legion_executor_registry.py"

legion_executor_family() {
  local executor="${1:-}"
  [[ -n "$executor" && -r "$_legion_executor_registry" ]] || return 1
  python3 "$_legion_executor_registry" --family "$executor" 2>/dev/null
}

legion_executor_worktree_cwd() {
  local physical_cwd
  physical_cwd="$(builtin pwd -P 2>/dev/null)" || return 1

  case "$physical_cwd/" in
    */.legion/worktrees/*) return 0 ;;
    *) return 1 ;;
  esac
}

legion_executor_context_active() {
  local depth="${LEGION_DEPTH:-0}"
  [[ "${LEGION_ACTIVE:-0}" == "1" || "${LEGION_EXECUTOR:-0}" == "1" ]] && return 0
  [[ "$depth" =~ ^[0-9]+$ && "$depth" -gt 0 ]] && return 0
  legion_executor_worktree_cwd
}

legion_require_top_level_executor() {
  local executor="${1:-executor}"
  if legion_executor_context_active; then
    # A worker may make one explicitly-routed, cross-harness handoff through
    # legion-delegate. The dispatcher sets this short-lived approval only after
    # validating the source/target pair, depth, task scan, and sandbox. Direct
    # adapter calls still fail closed, which keeps raw nested invocations from
    # escaping Legion's worktree/telemetry contract.
    if legion_cross_harness_handoff_allowed "$executor"; then
      return 0
    fi
    printf 'legion-%s: nested Legion delegation is blocked; implement the assigned slice directly\n' \
      "$executor" >&2
    return 2
  fi
}

legion_cross_harness_handoff_allowed() {
  [[ "${LEGION_CROSS_HARNESS_HANDOFF:-0}" == "1" ]] || return 1
  legion_cross_harness_pair_allowed "$1"
}

legion_cross_harness_pair_allowed() {
  local target="${1:-}" source="${LEGION_EXECUTOR_NAME:-}"
  local depth="${LEGION_DEPTH:-0}" max_depth="${LEGION_MAX_DEPTH:-2}"
  local source_family target_family
  source_family="$(legion_executor_family "$source")" || return 1
  target_family="$(legion_executor_family "$target")" || return 1
  [[ "$source_family" != "$target_family" ]] || return 1
  [[ "$depth" =~ ^[0-9]+$ && "$max_depth" =~ ^[1-9][0-9]*$ ]] || return 1
  (( depth < max_depth ))
}

legion_activate_executor_context() {
  local run_id="${1:-}" executor_name="${2:-}" inherited_depth="${LEGION_DEPTH:-0}"
  [[ "$inherited_depth" =~ ^[0-9]+$ ]] || inherited_depth=0
  export LEGION_ACTIVE=1
  export LEGION_EXECUTOR=1
  export LEGION_DEPTH="$((inherited_depth + 1))"
  export LEGION_RUN_ID="$run_id"
  [[ -n "$executor_name" ]] && export LEGION_EXECUTOR_NAME="$executor_name"
  # Approval belongs to the dispatcher→adapter boundary only. A newly started
  # worker must explicitly return through legion-delegate for another handoff.
  unset LEGION_CROSS_HARNESS_HANDOFF
}
