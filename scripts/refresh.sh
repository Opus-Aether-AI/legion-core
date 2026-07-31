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
#   2 — safe release resolution or git fetch failed
#
# All non-fatal warnings are printed to stderr; cron silences stdout/stderr
# by default, so this only screams if something is truly broken.

set -euo pipefail

AGENTS_HOME="${AGENTS_HOME:-$HOME/.agents}"
SOURCE_CLONE="${SOURCE_CLONE:-$AGENTS_HOME/sources/legion-core}"
MARKETPLACE_SLUG="legion-core"
MARKETPLACE_REPO="${LEGION_REPO:-Opus-Aether-AI/legion-core}"
UPDATE_REF="${LEGION_UPDATE_REF:-}"

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

# 1) Resolve a stable release by default. `LEGION_UPDATE_REF` is deliberately
# the only path to mutable main (or a specific rollback tag).
if [ -z "$UPDATE_REF" ]; then
    release_json="$(curl -fsSL "https://api.github.com/repos/${MARKETPLACE_REPO}/releases/latest" 2>/dev/null || true)"
    UPDATE_REF="$(printf '%s' "$release_json" \
        | jq -r 'select(type == "object" and .draft == false and .prerelease == false) | .tag_name // empty' \
            2>/dev/null || true)"
    if [ -z "$UPDATE_REF" ] || ! git check-ref-format --allow-onelevel "refs/tags/${UPDATE_REF}"; then
        printf 'legion refresh: could not resolve latest stable GitHub release tag; set LEGION_UPDATE_REF explicitly to override\n' >&2
        exit 2
    fi
fi

# Fetch the update ref explicitly because release-tag installs have a tag-only
# fetch refspec and therefore no origin/main.
if ! git -C "$SOURCE_CLONE" fetch origin "$UPDATE_REF" --depth 1 --quiet 2>/dev/null; then
    printf 'legion refresh: git fetch failed\n' >&2
    exit 2
fi
update_sha="$(git -C "$SOURCE_CLONE" rev-parse --verify 'FETCH_HEAD^{commit}' 2>/dev/null || true)"
if [ -z "$update_sha" ]; then
    printf 'legion refresh: fetched ref is not a commit: %s\n' "$UPDATE_REF" >&2
    exit 2
fi
dirty=0
if ! git -C "$SOURCE_CLONE" diff --quiet 2>/dev/null; then dirty=1; fi
if ! git -C "$SOURCE_CLONE" diff --cached --quiet 2>/dev/null; then dirty=1; fi
if [ "$dirty" = "1" ]; then
    printf 'legion refresh: source clone has local edits; fetched but skipped reset\n' >&2
else
    git -C "$SOURCE_CLONE" reset --hard "$update_sha" --quiet
fi

# 2) Re-sync ~/.agents/skills/ symlinks (handles added/removed plugins)
if ! bash "$SOURCE_CLONE/scripts/install.sh" --refresh-symlinks --no-claude --no-cron 2>/dev/null; then
    printf 'legion refresh: symlink sync had warnings\n' >&2
    record_refresh_failure "Daily refresh symlink/Cursor bridge sync failed." "install.sh --refresh-symlinks returned nonzero"
fi

# 3) Refresh the Claude marketplace and reconcile only installed Legion
# plugins. Missing plugins are deliberately ignored; an installed plugin that
# cannot reach the marketplace version is a failed refresh.
refresh_status=0
reconcile_claude_plugins() {
    if ! claude plugin marketplace update "$MARKETPLACE_SLUG" >/dev/null 2>&1; then
        printf 'legion refresh: claude marketplace update failed\n' >&2
        return 1
    fi

    local failed=0
    while IFS=$'\t' read -r plugin version; do
        local cache_dir="$HOME/.claude/plugins/cache/$MARKETPLACE_SLUG/$plugin"
        [ -d "$cache_dir" ] || continue

        if ! claude plugin update "$plugin@$MARKETPLACE_SLUG" --scope user >/dev/null 2>&1; then
            printf 'legion refresh: failed to update installed plugin %s\n' "$plugin" >&2
            failed=1
            continue
        fi
        installed_version="$(claude plugin list 2>/dev/null \
            | awk -v id="$plugin@$MARKETPLACE_SLUG" 'index($0, id) { found=1; next } found && $1 == "Version:" { print $2; exit }')"
        if [ "$installed_version" != "$version" ]; then
            printf 'legion refresh: installed plugin %s is not at marketplace version %s (reported %s)\n' \
                "$plugin" "$version" "${installed_version:-unknown}" >&2
            failed=1
        fi
    done < <(jq -r '.plugins[] | "\(.name)\t\(.version)"' "$SOURCE_CLONE/.claude-plugin/marketplace.json")

    return "$failed"
}

if command -v claude >/dev/null 2>&1; then
    if ! reconcile_claude_plugins; then
        printf 'legion refresh: plugin reconciliation failed\n' >&2
        refresh_status=1
    fi
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

# 4) Session feedback mining. This turns recent user corrections/review gotchas
# from Claude/Codex/Cursor logs into self-learning outcomes before synthesis.
SESSION_LEARN="${LEGION_SESSION_LEARN_BIN:-$SOURCE_CLONE/legion-observability/bin/legion-session-learn}"
if [ "${LEGION_SESSION_LEARN:-1}" = "1" ] && [ -x "$SESSION_LEARN" ]; then
    if ! "$SESSION_LEARN" --repo "$SOURCE_CLONE" \
        --lookback-days "${LEGION_SESSION_LEARN_DAYS:-3}" \
        --session-limit "${LEGION_SESSION_LEARN_LIMIT:-100}" \
        --max-file-mb "${LEGION_SESSION_LEARN_MAX_FILE_MB:-8}" \
        --record >/dev/null 2>&1; then
        printf 'legion refresh: session learning scan failed (self-learning still running)\n' >&2
        record_refresh_failure "Daily session learning scan failed." "legion-session-learn --record returned nonzero"
    fi
fi

# 5) Daily self-learning loop. Memory/proposals are safe to apply automatically;
# source mutations remain opt-in via `legion-self-learn run --apply-source`.
SELF_LEARN="$SOURCE_CLONE/legion-observability/bin/legion-self-learn"
if [ -x "$SELF_LEARN" ]; then
    if ! "$SELF_LEARN" run --repo "$SOURCE_CLONE" --apply-memory --quiet >/dev/null 2>&1; then
        printf 'legion refresh: self-learning loop failed (see ~/.claude/logs/legion/self-learn)\n' >&2
        record_refresh_failure "Daily self-learning loop failed." "legion-self-learn run --apply-memory returned nonzero"
    fi
fi

# 6) Auto-heal (OPT-IN: export LEGION_HEAL=1). Delegates a fix for each doctor
# finding to codex in an isolated worktree, gates it (doctor + bats + cross-model
# review), and opens a PR — never auto-merged. Off by default so the daily refresh
# stays read-only unless you opt in. Bounded by LEGION_HEAL_MAX (default 3).
HEAL="$SOURCE_CLONE/legion-observability/bin/legion-heal"
if [ "${LEGION_HEAL:-0}" = "1" ] && [ -x "$HEAL" ]; then
    if ! "$HEAL" run --repo "$SOURCE_CLONE" --max "${LEGION_HEAL_MAX:-3}" >/dev/null 2>&1; then
        printf 'legion refresh: auto-heal had failures (see PRs / ~/.claude/logs/legion)\n' >&2
    fi
fi

exit "$refresh_status"
