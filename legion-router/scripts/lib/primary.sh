#!/usr/bin/env bash
# legion primary-harness resolution (shared).
#
# The PRIMARY is the harness the operator is currently driving — the one for
# which a `self`-routed archetype means "do it inline, don't delegate." Legion
# is harness-symmetric, so this is NOT hardcoded to Claude/Opus.
#
# Resolution order (must stay in lockstep with `legion-route.py --primary`):
#   1. $LEGION_PRIMARY, if set (authoritative — the per-harness `-mode` setup
#      skills export this so a session's primary is unambiguous).
#   2. best-effort auto-detect from the harness's own env markers.
#   3. `claude` (back-compat default — legion began Claude-primary).
#
# Usage:  source .../lib/primary.sh; p="$(legion_primary)"

legion_primary() {
  if [[ -n "${LEGION_PRIMARY:-}" ]]; then
    printf '%s\n' "$LEGION_PRIMARY"
    return 0
  fi
  # Auto-detect is best-effort; explicit LEGION_PRIMARY is the reliable path.
  if [[ -n "${CLAUDECODE:-}" || -n "${CLAUDE_CODE_ENTRYPOINT:-}" ]]; then
    printf 'claude\n'; return 0
  fi
  if [[ -n "${CODEX_SANDBOX:-}" || -n "${CODEX_HOME:-}" || -n "${CODEX_THREAD_ID:-}" ]]; then
    printf 'codex\n'; return 0
  fi
  if [[ -n "${OPENCODE:-}" || -n "${OPENCODE_BIN:-}" || -n "${OPENCODE_SERVER:-}" ]]; then
    printf 'opencode\n'; return 0
  fi
  if [[ -n "${HERMES_HOME:-}" || -n "${HERMES_SESSION_ID:-}" ]]; then
    printf 'hermes\n'; return 0
  fi
  if [[ -n "${CURSOR_AGENT:-}" || -n "${CURSOR_TRACE_ID:-}" ]]; then
    printf 'cursor\n'; return 0
  fi
  printf 'claude\n'
}

# True when the resolved primary is $1.
legion_primary_is() { [[ "$(legion_primary)" == "$1" ]]; }
