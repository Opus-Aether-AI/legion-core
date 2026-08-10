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
#   3 — update fetched, but local files made reconciliation unsafe
#
# All non-fatal warnings are printed to stderr; cron silences stdout/stderr
# by default, so this only screams if something is truly broken.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SCRIPT="${LEGION_INSTALL_SCRIPT:-$SCRIPT_DIR/install.sh}"
AGENTS_HOME="${AGENTS_HOME:-$HOME/.agents}"
SOURCE_CLONE="${SOURCE_CLONE:-$AGENTS_HOME/sources/legion-core}"
MARKETPLACE_SLUG="legion-core"
MARKETPLACE_REPO="${LEGION_REPO:-Opus-Aether-AI/legion-core}"
UPDATE_REF="${LEGION_UPDATE_REF:-}"
UPDATE_GIT_REF=""
UPDATE_REF_EXPLICIT=0
[ -n "$UPDATE_REF" ] && UPDATE_REF_EXPLICIT=1

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
    # install.sh owns the authenticated lookup: a private MARKETPLACE_REPO 404s
    # on anonymous requests, which would otherwise look like a missing release.
    lookup_status=0
    UPDATE_REF="$(bash "$INSTALL_SCRIPT" --resolve-latest-release 2>/dev/null)" || lookup_status=$?
    if [ "$lookup_status" = "3" ]; then
        printf 'legion refresh: could not reach the latest stable release of %s\n' "$MARKETPLACE_REPO" >&2
        printf '  a private repository answers anonymous requests with 404; authenticate with\n' >&2
        printf '  '"'"'gh auth login'"'"' or GITHUB_TOKEN, or set LEGION_UPDATE_REF explicitly\n' >&2
        record_refresh_failure "Daily refresh could not reach the latest stable release." \
            "release lookup for $MARKETPLACE_REPO was unreachable or unauthorized"
        exit 2
    fi
fi

if [ "$UPDATE_REF" = "main" ] && [ "$UPDATE_REF_EXPLICIT" = "1" ]; then
    UPDATE_GIT_REF="refs/heads/main"
elif bash "$INSTALL_SCRIPT" --validate-release-tag="$UPDATE_REF" >/dev/null 2>&1; then
    UPDATE_GIT_REF="refs/tags/${UPDATE_REF}"
elif [ "$UPDATE_REF_EXPLICIT" = "0" ]; then
    printf 'legion refresh: latest stable GitHub release must be an exact v-prefixed semantic version tag\n' >&2
    exit 2
else
    printf 'legion refresh: release ref must be main or an exact v-prefixed semantic version tag\n' >&2
    exit 2
fi

# Fetch the update ref explicitly because release-tag installs have a tag-only
# fetch refspec and therefore no origin/main.
if ! git -C "$SOURCE_CLONE" fetch origin "$UPDATE_GIT_REF" --depth 1 --quiet 2>/dev/null; then
    printf 'legion refresh: git fetch failed\n' >&2
    exit 2
fi
update_sha="$(git -C "$SOURCE_CLONE" rev-parse --verify 'FETCH_HEAD^{commit}' 2>/dev/null || true)"
if [ -z "$update_sha" ]; then
    printf 'legion refresh: fetched ref is not a commit: %s\n' "$UPDATE_REF" >&2
    exit 2
fi
if ! status_output="$(git -C "$SOURCE_CLONE" status --porcelain --untracked-files=all 2>/dev/null)"; then
    printf 'legion refresh: could not inspect source clone state; skipped reconciliation\n' >&2
    exit 3
fi
if [ -n "$status_output" ]; then
    printf 'legion refresh: source clone has local edits or untracked files; fetched but skipped reconciliation\n' >&2
    exit 3
fi
if ! git -C "$SOURCE_CLONE" checkout --quiet --detach --no-overwrite-ignore "$update_sha"; then
    printf 'legion refresh: update would overwrite local files; skipped reconciliation\n' >&2
    exit 3
fi

# 2) Re-sync ~/.agents/skills/ symlinks (handles added/removed plugins)
if ! LEGION_REF="$UPDATE_REF" bash "$SOURCE_CLONE/scripts/install.sh" --refresh-symlinks --no-claude --no-cron 2>/dev/null; then
    printf 'legion refresh: symlink sync had warnings\n' >&2
    record_refresh_failure "Daily refresh symlink/Cursor bridge sync failed." "install.sh --refresh-symlinks returned nonzero"
fi

# 3) Refresh the Claude marketplace and reconcile only installed Legion
# plugins. Missing plugins are deliberately ignored; an installed plugin that
# cannot reach the marketplace version is a failed refresh.
refresh_status=0
marketplace_source_for_ref() {
    case "$MARKETPLACE_REPO" in
        ./*|../*|/*) printf '%s\n' "$MARKETPLACE_REPO" ;;
        http://*|https://*|git@*|file://*) printf '%s#%s\n' "$MARKETPLACE_REPO" "$UPDATE_REF" ;;
        *) printf '%s@%s\n' "$MARKETPLACE_REPO" "$UPDATE_REF" ;;
    esac
}

reconcile_claude_plugins() {
    local marketplace_source
    marketplace_source="$(marketplace_source_for_ref)"
    if ! claude plugin marketplace add "$marketplace_source" >/dev/null 2>&1; then
        printf 'legion refresh: could not bind Claude marketplace to %s\n' "$UPDATE_REF" >&2
        return 1
    fi
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
        local installed_version
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

# 4) Evidence-linked learning. Normalize recent cross-harness sessions into
# redacted sessions, episodes, decisions, linked outcomes, behavior/code scores,
# and cross-project learning laws. It is report/proposal only during refresh.
EVIDENCE_LEARN="${LEGION_EVIDENCE_LEARN_BIN:-$SOURCE_CLONE/legion-observability/bin/legion-learn}"
if [ "${LEGION_EVIDENCE_LEARN:-1}" = "1" ] && [ -x "$EVIDENCE_LEARN" ]; then
    if ! "$EVIDENCE_LEARN" analyze --repo "$SOURCE_CLONE" \
        --lookback-days "${LEGION_SESSION_LEARN_DAYS:-3}" \
        --max-file-mb "${LEGION_SESSION_LEARN_MAX_FILE_MB:-8}" \
        --max-files "${LEGION_EVIDENCE_LEARN_MAX_FILES:-100}" \
        --max-total-mb "${LEGION_EVIDENCE_LEARN_MAX_TOTAL_MB:-64}" \
        --max-events "${LEGION_EVIDENCE_LEARN_MAX_EVENTS:-20000}" >/dev/null 2>&1; then
        printf 'legion refresh: evidence-linked learning scan failed (legacy learning still running)\n' >&2
        record_refresh_failure "Daily evidence-linked learning scan failed." "legion-learn analyze returned nonzero"
    fi
fi

# 5) Compatibility outcome mining. This keeps the existing bounded correction
# categories available while v2 laws feed the same self-learning proposal lane.
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

# 6) Daily self-learning loop. Memory and the bounded typed improvement queue are
# safe to write automatically; this command never mutates source.
SELF_LEARN="$SOURCE_CLONE/legion-observability/bin/legion-self-learn"
if [ -x "$SELF_LEARN" ]; then
    if ! "$SELF_LEARN" run --repo "$SOURCE_CLONE" --apply-memory --quiet >/dev/null 2>&1; then
        printf 'legion refresh: self-learning loop failed (see ~/.claude/logs/legion/self-learn)\n' >&2
        record_refresh_failure "Daily self-learning loop failed." "legion-self-learn run --apply-memory returned nonzero"
    fi
fi

# 7) Review-only source improvements (OPT-IN). The default is off. `dry-run`
# builds, repeats gates, and obtains an immutable independent review; `draft`
# additionally opens an idempotent draft PR. The candidate base defaults to the
# remote main tip so stable release-tag installs never have to move their own
# detached checkout. No mode can merge or deploy.
IMPROVE_MODE="${LEGION_IMPROVE_MODE:-off}"
IMPROVE="$SOURCE_CLONE/legion-observability/bin/legion-improve"
case "$IMPROVE_MODE" in
    off) ;;
    dry-run|draft)
        if [ -x "$IMPROVE" ]; then
            # cron runs with a bare PATH (/usr/bin:/bin), so `gh` is not
            # resolvable even when it is installed. Legion binaries are already
            # invoked by absolute path; extend the search for the third-party
            # tools the publish hop needs so a draft run does not fail with
            # gh_unavailable on every scheduled refresh.
            PATH="$PATH:$HOME/.agents/bin:/opt/homebrew/bin:/usr/local/bin"
            export PATH
            if ! "$IMPROVE" queue --repo "$SOURCE_CLONE" \
                --base-ref "${LEGION_IMPROVE_BASE_REF:-main}" \
                --mode "$IMPROVE_MODE" \
                --max "${LEGION_IMPROVE_MAX:-1}" \
                --evaluation-repeats "${LEGION_IMPROVE_REPEATS:-2}" \
                --json >/dev/null 2>&1; then
                printf 'legion refresh: review-only improvement queue had failures\n' >&2
                record_refresh_failure "Daily review-only improvement queue failed." "legion-improve queue returned nonzero"
            fi
        fi
        ;;
    *)
        printf 'legion refresh: invalid LEGION_IMPROVE_MODE=%s (expected off, dry-run, or draft)\n' "$IMPROVE_MODE" >&2
        record_refresh_failure "Daily improvement mode was invalid." "$IMPROVE_MODE"
        ;;
esac

# 8) Auto-heal (OPT-IN: export LEGION_HEAL=1). Delegates a fix for each doctor
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
