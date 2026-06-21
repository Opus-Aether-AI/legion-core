#!/usr/bin/env bash
# refresh.sh — daily cron-callable refresh of the cross-harness skill source.
#
# Pulls the latest legion-core source, re-syncs ~/.agents/skills/ symlinks,
# and (if claude CLI is present) refreshes the Claude marketplace cache.
#
# Installed by scripts/install.sh as a daily cron entry (see --cron-hour flag
# there). Safe to invoke manually any time.
#
# Exit codes:
#   0 — refresh succeeded (or repo already up to date)
#   1 — source clone missing (run install.sh first)
#   2 — git pull failed
#
# All non-fatal warnings are printed to stderr; cron silences stdout/stderr
# by default, so this only screams if something is truly broken.

set -euo pipefail

AGENTS_HOME="${AGENTS_HOME:-$HOME/.agents}"
SOURCE_CLONE="${SOURCE_CLONE:-$AGENTS_HOME/sources/legion-core}"
MARKETPLACE_SLUG="legion-core"

record_refresh_failure() {
    local summary="$1" evidence="${2:-}"
    local learn="${LEGION_SELF_LEARN_BIN:-$SOURCE_CLONE/legion-observability/bin/legion-self-learn}"
    [ -x "$learn" ] || return 0
    "$learn" record --entity plugin:legion-setup --summary "$summary" \
        --severity high --source "legion-refresh" --evidence "$evidence" >/dev/null 2>&1 || true
}

if [ ! -d "$SOURCE_CLONE/.git" ]; then
    printf 'legion refresh: source clone missing at %s\n' "$SOURCE_CLONE" >&2
    printf '  run: bash %s/scripts/install.sh\n' "$SOURCE_CLONE" >&2
    exit 1
fi

# 1) Pull latest source. Do not clobber local self-learning or operator edits.
if ! git -C "$SOURCE_CLONE" fetch origin --quiet 2>/dev/null; then
    printf 'legion refresh: git fetch failed\n' >&2
    exit 2
fi
dirty=0
if ! git -C "$SOURCE_CLONE" diff --quiet 2>/dev/null; then dirty=1; fi
if ! git -C "$SOURCE_CLONE" diff --cached --quiet 2>/dev/null; then dirty=1; fi
if [ "$dirty" = "1" ]; then
    printf 'legion refresh: source clone has local edits; fetched but skipped reset\n' >&2
else
    git -C "$SOURCE_CLONE" reset --hard origin/main --quiet
fi

# 2) Re-sync ~/.agents/skills/ symlinks (handles added/removed plugins)
if ! bash "$SOURCE_CLONE/scripts/install.sh" --refresh-symlinks --no-claude --no-cron 2>/dev/null; then
    printf 'legion refresh: symlink sync had warnings\n' >&2
    record_refresh_failure "Daily refresh symlink/Cursor bridge sync failed." "install.sh --refresh-symlinks returned nonzero"
fi

# 3) Refresh Claude marketplace catalog (best-effort; ignored if claude is missing)
if command -v claude >/dev/null 2>&1; then
    claude plugin marketplace update "$MARKETPLACE_SLUG" >/dev/null 2>&1 || \
        printf 'legion refresh: claude marketplace update failed (catalog may be stale)\n' >&2
fi

# 3.5) Static health check. legion-doctor only validates artifacts; it learns
# nothing itself — but --record-failures files each defect (a 404 MCP package, a
# block-scalar/blank description, a broken bridge) so the self-learning loop in
# step 4 mines them into hints. Best-effort: never blocks the refresh.
DOCTOR="$SOURCE_CLONE/legion-observability/bin/legion-doctor"
if [ -x "$DOCTOR" ]; then
    "$DOCTOR" --record-failures >/dev/null 2>&1 || \
        printf 'legion refresh: legion-doctor found issues (recorded for self-learning)\n' >&2
fi

# 4) Daily self-learning loop. Memory/proposals are safe to apply automatically;
# source mutations remain opt-in via `legion-self-learn run --apply-source`.
SELF_LEARN="$SOURCE_CLONE/legion-observability/bin/legion-self-learn"
if [ -x "$SELF_LEARN" ]; then
    if ! "$SELF_LEARN" run --repo "$SOURCE_CLONE" --apply-memory --quiet >/dev/null 2>&1; then
        printf 'legion refresh: self-learning loop failed (see ~/.claude/logs/legion/self-learn)\n' >&2
        record_refresh_failure "Daily self-learning loop failed." "legion-self-learn run --apply-memory returned nonzero"
    fi
fi

# 5) Auto-heal (OPT-IN: export LEGION_HEAL=1). Delegates a fix for each doctor
# finding to codex in an isolated worktree, gates it (doctor + bats + cross-model
# review), and opens a PR — never auto-merged. Off by default so the daily refresh
# stays read-only unless you opt in. Bounded by LEGION_HEAL_MAX (default 3).
HEAL="$SOURCE_CLONE/legion-observability/bin/legion-heal"
if [ "${LEGION_HEAL:-0}" = "1" ] && [ -x "$HEAL" ]; then
    if ! "$HEAL" run --repo "$SOURCE_CLONE" --max "${LEGION_HEAL_MAX:-3}" >/dev/null 2>&1; then
        printf 'legion refresh: auto-heal had failures (see PRs / ~/.claude/logs/legion)\n' >&2
    fi
fi

exit 0
