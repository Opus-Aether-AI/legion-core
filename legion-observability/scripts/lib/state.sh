#!/usr/bin/env bash
# Shared shell helper for resolving Legion runtime state.

legion_resolve_state() {
  local repo="${1:-$PWD}"
  local here py
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  py="${LEGION_STATE_PY:-$here/legion_state.py}"
  if [[ -f "$py" ]] && command -v python3 >/dev/null 2>&1; then
    # shellcheck disable=SC1090
    source <(python3 "$py" --repo "$repo" --shell)
    return 0
  fi

  export LEGION_STATE_ROOT="${LEGION_STATE_ROOT:-$HOME/.legion/projects/default}"
  export LEGION_TELEMETRY_DIR="${LEGION_TELEMETRY_DIR:-$LEGION_STATE_ROOT/spans}"
  export LEGION_REGISTRY_DIR="${LEGION_REGISTRY_DIR:-$LEGION_STATE_ROOT/registry}"
  export LEGION_REPOS_FILE="${LEGION_REPOS_FILE:-$LEGION_STATE_ROOT/repos.jsonl}"
  export LEGION_BENCH_DIR="${LEGION_BENCH_DIR:-$LEGION_STATE_ROOT/bench}"
  export LEGION_REPORTS_DIR="${LEGION_REPORTS_DIR:-$LEGION_STATE_ROOT/reports}"
}
