#!/usr/bin/env bash
# Shared shell helper for resolving Legion runtime state.

legion_resolve_state() {
  local repo="${1:-$PWD}"
  local here py
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  py="${LEGION_STATE_PY:-$here/legion_state.py}"
  if [[ -f "$py" ]] && command -v python3 >/dev/null 2>&1; then
    # Capture-then-eval instead of `source <(python3 …)`. Process substitution +
    # the `source`/`.` builtin is unreliable on bash 3.2 (the macOS system bash
    # that `#!/usr/bin/env bash` resolves to when no newer bash is installed):
    # `source` reopens the /dev/fd pipe by name and races the writer, so under
    # non-interactive / backgrounded / piped stdio it sources NOTHING and leaves
    # the LEGION_* vars unset — which then aborts callers under `set -u` and leaks
    # the writer's "BrokenPipeError: [Errno 32] Broken pipe" to stderr. A plain
    # command substitution fully drains the child's stdout before we eval it.
    # legion_state.py shell-quotes every value, so eval of its `export …` lines is safe.
    local _legion_state_exports
    if _legion_state_exports="$(python3 "$py" --repo "$repo" --shell)" \
       && [[ -n "$_legion_state_exports" ]]; then
      eval "$_legion_state_exports"
      return 0
    fi
  fi

  export LEGION_STATE_ROOT="${LEGION_STATE_ROOT:-$HOME/.legion/projects/default}"
  export LEGION_TELEMETRY_DIR="${LEGION_TELEMETRY_DIR:-$LEGION_STATE_ROOT/spans}"
  export LEGION_REGISTRY_DIR="${LEGION_REGISTRY_DIR:-$LEGION_STATE_ROOT/registry}"
  export LEGION_REPOS_FILE="${LEGION_REPOS_FILE:-$LEGION_STATE_ROOT/repos.jsonl}"
  export LEGION_BENCH_DIR="${LEGION_BENCH_DIR:-$LEGION_STATE_ROOT/bench}"
  export LEGION_REPORTS_DIR="${LEGION_REPORTS_DIR:-$LEGION_STATE_ROOT/reports}"
}
