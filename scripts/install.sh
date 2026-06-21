#!/usr/bin/env bash
# install.sh — bootstrap the legion-core marketplace + cross-harness skills
#
# Adds the marketplace + installs plugins by profile, and (by default) also makes
# every skill available to Codex, Cursor, opencode, and any other harness that reads
# ~/.agents/skills/ — via symlinks into a single source clone. A daily cron entry
# keeps the clone fresh.
#
# Usage (after cloning the repo, since it's private):
#   bash scripts/install.sh all       # everything (default) — Claude + Codex + cron
#   bash scripts/install.sh opus      # only Opus-original plugins
#   bash scripts/install.sh vendored  # only vendored third-party
#   bash scripts/install.sh minimal   # legion-router + legion-observability only
#   bash scripts/install.sh --list    # show available plugins, don't install
#   bash scripts/install.sh PLUGIN    # install one named plugin
#
# Harness control (default: all enabled):
#   --no-claude           Skip `claude plugin install` (Codex-only setup)
#   --no-cross-harness    Skip ~/.agents/skills/ symlinks (Claude-only setup)
#   --no-codex-skills     Skip ~/.codex/skills/<name> symlinks (Codex-skill mirror)
#                         (alias: --no-codex-commands, kept for back-compat)
#   --no-cursor           Skip Cursor MCP/subagent bridge setup
#   --no-cron             Skip daily refresh cron entry
#   --cron-hour=N         Hour of day for refresh cron (default: 9)
#
# Maintenance:
#   bash scripts/install.sh --refresh-symlinks    # re-scan & sync ~/.agents/skills/ only
#
# Or via gh (no clone needed for first-time install):
#   gh api repos/Opus-Aether-AI/legion-core/contents/scripts/install.sh --jq '.content' | base64 -d | bash -s opus
#
# Requires: gh (authenticated), jq, git. claude CLI optional (only for Claude marketplace flow).
# Idempotent: re-running skips already-installed plugins and updates symlinks.

set -euo pipefail

MARKETPLACE_REPO="${LEGION_REPO:-Opus-Aether-AI/legion-core}"
MARKETPLACE_SLUG="legion-core"

AGENTS_HOME="${AGENTS_HOME:-$HOME/.agents}"
SOURCE_CLONE="$AGENTS_HOME/sources/legion-core"
SKILLS_DIR="$AGENTS_HOME/skills"
LEGION_BIN_DIR="$AGENTS_HOME/bin"        # managed symlink farm for plugin CLIs (on PATH)

# ── Colors ───────────────────────────────────────────────────────────
red()    { printf '\033[0;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
dim()    { printf '\033[0;90m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }

# ── Flag parsing ─────────────────────────────────────────────────────
DO_CLAUDE=1
DO_CROSS_HARNESS=1
DO_CODEX_SKILLS=1
DO_CURSOR=1
DO_CRON=1
CRON_HOUR=9
MODE=""

for arg in "$@"; do
    case "$arg" in
        --no-claude)         DO_CLAUDE=0 ;;
        --no-cross-harness)  DO_CROSS_HARNESS=0 ;;
        --no-codex-skills)   DO_CODEX_SKILLS=0 ;;
        --no-codex-commands) DO_CODEX_SKILLS=0 ;;  # deprecated alias, kept for back-compat
        --no-cursor)         DO_CURSOR=0 ;;
        --no-cron)           DO_CRON=0 ;;
        --cron-hour=*)       CRON_HOUR="${arg#--cron-hour=}" ;;
        --refresh-symlinks)  MODE="refresh-symlinks" ;;
        -h|--help|help)      MODE="help" ;;
        --list|-l|list)      MODE="list" ;;
        --*)                 red "Unknown flag: $arg"; exit 2 ;;
        *)                   [ -z "$MODE" ] && MODE="$arg" ;;
    esac
done
MODE="${MODE:-all}"

# ── Preflight ────────────────────────────────────────────────────────
preflight() {
    if [ "$DO_CLAUDE" = "1" ] && ! command -v claude >/dev/null 2>&1; then
        yellow "claude CLI not found — skipping Claude marketplace flow (--no-claude implied)."
        DO_CLAUDE=0
    fi
    if ! command -v jq >/dev/null 2>&1; then
        red "jq required. Install with: brew install jq  (or apt-get install jq)"
        exit 1
    fi
    if ! command -v gh >/dev/null 2>&1; then
        red "gh required (repo is private). Install: brew install gh && gh auth login"
        exit 1
    fi
    if ! gh auth status >/dev/null 2>&1; then
        red "gh not authenticated. Run: gh auth login"
        exit 1
    fi
    if [ "$DO_CROSS_HARNESS" = "1" ] && ! command -v git >/dev/null 2>&1; then
        red "git required for cross-harness symlinks. Install git or pass --no-cross-harness."
        exit 1
    fi
}

# ── Add marketplace (idempotent) ─────────────────────────────────────
add_marketplace() {
    [ "$DO_CLAUDE" = "1" ] || return 0
    if claude plugin marketplace list 2>/dev/null | grep -q "$MARKETPLACE_SLUG"; then
        dim "Marketplace already added: $MARKETPLACE_SLUG"
    else
        bold "Adding marketplace: $MARKETPLACE_REPO"
        claude plugin marketplace add "$MARKETPLACE_REPO"
    fi
    bold "Refreshing marketplace cache..."
    claude plugin marketplace update "$MARKETPLACE_SLUG" >/dev/null
}

# ── Fetch plugin list (from local clone if available, else GH API) ───
fetch_plugins() {
    if [ -f "$SOURCE_CLONE/.claude-plugin/marketplace.json" ]; then
        cat "$SOURCE_CLONE/.claude-plugin/marketplace.json"
    else
        gh api "repos/${MARKETPLACE_REPO}/contents/.claude-plugin/marketplace.json?ref=main" \
            --jq '.content' | base64 -d
    fi
}

list_all() {
    fetch_plugins | jq -r '.plugins[].name'
}

list_opus() {
    fetch_plugins | jq -r '.plugins[] | select(.source | type == "string" and (startswith("./vendored/") | not)) | .name'
}

list_vendored() {
    fetch_plugins | jq -r '.plugins[] | select(.source | type == "string" and startswith("./vendored/")) | .name'
}

# ── Install single Claude plugin ─────────────────────────────────────
install_one() {
    local plugin="$1"
    ALREADY_INSTALLED=0
    if [ -d "$HOME/.claude/plugins/cache/$MARKETPLACE_SLUG/$plugin" ]; then
        dim "  ↺ $plugin (already installed)"
        ALREADY_INSTALLED=1
        return 0
    fi
    if claude plugin install "$plugin@$MARKETPLACE_SLUG" --scope user 2>&1 | grep -q "✔"; then
        green "  ✔ $plugin"
    else
        red "  ✘ $plugin (failed)"
        return 1
    fi
}

# ── Install many Claude plugins ──────────────────────────────────────
install_many() {
    [ "$DO_CLAUDE" = "1" ] || { dim "Skipping Claude plugin install (--no-claude)"; return 0; }
    local plugins=("$@")
    local total="${#plugins[@]}"
    bold ""
    bold "Installing $total plugins via Claude marketplace..."
    local installed=0 skipped=0 fail=0
    for p in "${plugins[@]}"; do
        if install_one "$p"; then
            if [ "${ALREADY_INSTALLED:-0}" = "1" ]; then
                skipped=$((skipped + 1))
            else
                installed=$((installed + 1))
            fi
        else
            fail=$((fail + 1))
        fi
    done
    echo ""
    bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    [ "$installed" -gt 0 ] && green "  $installed newly installed"
    [ "$skipped" -gt 0 ] && dim "  $skipped already installed (skipped)"
    [ "$fail" -gt 0 ] && red "  $fail failed"
    echo ""
}

# ── Cross-harness: clone source + symlink into ~/.agents/skills/ ─────
setup_source_clone() {
    mkdir -p "$AGENTS_HOME/sources"
    if [ -d "$SOURCE_CLONE/.git" ]; then
        # Refuse to clobber a user's local edits with `reset --hard origin/main`.
        # If the working tree or index is dirty, fetch but skip the reset and
        # leave the user to reconcile.
        local dirty=0
        if ! git -C "$SOURCE_CLONE" diff --quiet 2>/dev/null; then dirty=1; fi
        if ! git -C "$SOURCE_CLONE" diff --cached --quiet 2>/dev/null; then dirty=1; fi

        if [ "$dirty" = "1" ]; then
            yellow "Source clone has local edits — fetching but not resetting."
            yellow "  (Commit, stash, or 'git restore .' in $SOURCE_CLONE to allow auto-refresh next run.)"
            git -C "$SOURCE_CLONE" fetch origin --quiet
        else
            dim "Source clone exists — pulling latest"
            git -C "$SOURCE_CLONE" fetch origin --quiet
            git -C "$SOURCE_CLONE" reset --hard origin/main --quiet
        fi
    else
        bold "Cloning $MARKETPLACE_REPO → $SOURCE_CLONE"
        gh repo clone "$MARKETPLACE_REPO" "$SOURCE_CLONE" -- --depth 1 --quiet
    fi
}

setup_skill_symlinks() {
    mkdir -p "$SKILLS_DIR"
    local plugins_json
    plugins_json="$(fetch_plugins)"
    local count=0
    local nested_count=0
    local claude_only=0
    local skipped=0

    # Track which symlinks we manage so we can prune stale ones later
    local managed_dir="$AGENTS_HOME/.managed-by-legion-core"
    mkdir -p "$managed_dir"
    local manifest="$managed_dir/skills.txt"
    : > "$manifest.new"

    while IFS=$'\t' read -r name source; do
        # Only handle plugins whose source is a local string path. Object-shaped
        # sources (e.g. git-subdir) get installed via the Claude marketplace
        # flow only — we don't symlink them here.
        if [ "${source:0:2}" != "./" ]; then
            dim "  · $name (non-local source — Claude marketplace only)"
            skipped=$((skipped + 1))
            continue
        fi
        local plugin_dir="$SOURCE_CLONE/${source#./}"

        if [ -f "$plugin_dir/SKILL.md" ]; then
            # Top-level SKILL.md → symlink at ~/.agents/skills/<name>
            local link="$SKILLS_DIR/$name"
            if [ -L "$link" ]; then
                rm "$link"
            elif [ -e "$link" ]; then
                yellow "  · $name (existing non-symlink at $link — skipped to avoid clobber)"
                skipped=$((skipped + 1))
                continue
            fi
            ln -s "$plugin_dir" "$link"
            echo "$name" >> "$manifest.new"
            count=$((count + 1))
        elif [ -d "$plugin_dir/skills" ]; then
            # Nested layout: plugin contains skills/<name>/SKILL.md (e.g. vercel-plugin)
            local namespace
            namespace=$(jq -r '.name // empty' "$plugin_dir/.claude-plugin/plugin.json" 2>/dev/null)
            [ -n "$namespace" ] || namespace="${name%-plugin}"

            local found_any=0
            for skill_dir in "$plugin_dir/skills"/*; do
                [ -d "$skill_dir" ] || continue
                [ -f "$skill_dir/SKILL.md" ] || continue
                found_any=1
                local skill_name
                skill_name=$(basename "$skill_dir")

                # Dedup namespace prefix: if skill name already starts with "<namespace>-",
                # keep it; otherwise prepend it. So vercel-plugin/skills/vercel-firewall
                # → "vercel-firewall" (no dup), and vercel-plugin/skills/auth → "vercel-auth".
                local link_name
                if [ "${skill_name#${namespace}-}" != "$skill_name" ] || [ "$skill_name" = "$namespace" ]; then
                    link_name="$skill_name"
                else
                    link_name="${namespace}-${skill_name}"
                fi

                local link="$SKILLS_DIR/$link_name"
                if [ -L "$link" ]; then
                    rm "$link"
                elif [ -e "$link" ]; then
                    yellow "  · $link_name (existing non-symlink — skipped)"
                    skipped=$((skipped + 1))
                    continue
                fi
                ln -s "$skill_dir" "$link"
                echo "$link_name" >> "$manifest.new"
                nested_count=$((nested_count + 1))
            done
            if [ "$found_any" = "0" ]; then
                dim "  · $name (no SKILL.md found at any depth — Claude-only)"
                claude_only=$((claude_only + 1))
            fi
        else
            # No SKILL.md anywhere → plugin contributes hooks/agents/commands/MCP only
            dim "  · $name (Claude-only: no cross-harness skill content)"
            claude_only=$((claude_only + 1))
        fi
    done < <(echo "$plugins_json" | jq -r '.plugins[] | "\(.name)\t\(.source)"')

    # Prune symlinks for plugins no longer in marketplace
    if [ -f "$manifest" ]; then
        local pruned=0
        while IFS= read -r old_name; do
            if ! grep -qxF "$old_name" "$manifest.new"; then
                local stale_link="$SKILLS_DIR/$old_name"
                if [ -L "$stale_link" ]; then
                    rm "$stale_link"
                    pruned=$((pruned + 1))
                fi
            fi
        done < "$manifest"
        [ "$pruned" -gt 0 ] && yellow "  ⨯ pruned $pruned stale symlinks"
    fi
    mv "$manifest.new" "$manifest"

    local total=$((count + nested_count))
    green "  ✔ symlinked $total skills into $SKILLS_DIR/ ($count top-level + $nested_count nested)"
    [ "$claude_only" -gt 0 ] && dim "  · $claude_only plugins are Claude-Code-only (hooks/agents/commands/MCP — no SKILL.md content)"
    [ "$skipped" -gt 0 ] && yellow "  · $skipped skipped (collisions or non-local sources)"
    return 0
}

setup_cross_harness() {
    [ "$DO_CROSS_HARNESS" = "1" ] || return 0
    bold ""
    bold "Cross-harness setup (~/.agents/skills/ for Claude, Codex, Cursor, opencode, etc.)"
    setup_source_clone
    setup_skill_symlinks
    setup_bin_path
}

# ── CLI bins on PATH: symlink each plugin's bin/<cmd> into ~/.agents/bin/ ─
#
# Claude Code surfaces a plugin's *skills* but does NOT put its bin/ on the
# shell PATH. Every legion-*/opus-* SKILL.md calls its CLI bare
# (`legion-delegate …`, `legion-doctor`, `opus-overnight …`), so without this
# those are "command not found". We farm every extensionless executable (the
# public CLI surface) into one managed dir and tell the user to add it to PATH.
# Extensioned helpers (awspex's *.py) are internal — skipped.
setup_bin_path() {
    mkdir -p "$LEGION_BIN_DIR"
    local managed_dir="$AGENTS_HOME/.managed-by-legion-core"
    mkdir -p "$managed_dir"
    local manifest="$managed_dir/bins.txt"
    : > "$manifest.new"

    bold ""
    bold "CLI bins on PATH ($LEGION_BIN_DIR)"

    local count=0 skipped=0
    while IFS=$'\t' read -r name source; do
        [ "${source:0:2}" = "./" ] || continue          # local-source plugins only
        local bindir="$SOURCE_CLONE/${source#./}/bin"
        [ -d "$bindir" ] || continue
        for f in "$bindir"/*; do
            [ -f "$f" ] || continue
            local cmd; cmd="$(basename "$f")"
            case "$cmd" in *.*) continue ;; esac          # skip *.py/*.sh helpers
            chmod +x "$f" 2>/dev/null || true
            local link="$LEGION_BIN_DIR/$cmd"
            if [ -L "$link" ]; then
                rm "$link"
            elif [ -e "$link" ]; then
                yellow "  · $cmd (existing non-symlink at $link — skipped)"
                skipped=$((skipped + 1))
                continue
            fi
            ln -s "$f" "$link"
            echo "$cmd" >> "$manifest.new"
            count=$((count + 1))
        done
    done < <(fetch_plugins | jq -r '.plugins[] | "\(.name)\t\(.source)"')

    # Prune bins for plugins/CLIs no longer present
    if [ -f "$manifest" ]; then
        local pruned=0
        while IFS= read -r old_cmd; do
            if ! grep -qxF "$old_cmd" "$manifest.new"; then
                if [ -L "$LEGION_BIN_DIR/$old_cmd" ]; then
                    rm "$LEGION_BIN_DIR/$old_cmd"
                    pruned=$((pruned + 1))
                fi
            fi
        done < "$manifest"
        [ "$pruned" -gt 0 ] && yellow "  ⨯ pruned $pruned stale bins"
    fi
    mv "$manifest.new" "$manifest"

    green "  ✔ linked $count CLI bins into $LEGION_BIN_DIR/"
    [ "$skipped" -gt 0 ] && yellow "  · $skipped skipped (collisions)"
    case ":${PATH}:" in
        *":$LEGION_BIN_DIR:"*) dim "  · already on PATH" ;;
        *) yellow "  · NOT on PATH yet — add this line to ~/.zshenv for agent shells,"
           yellow "    or ~/.zshrc / ~/.bashrc for interactive terminals:"
           yellow "        export PATH=\"$LEGION_BIN_DIR:\$PATH\"" ;;
    esac
    return 0
}

# ── Codex skills mirror: symlink into ~/.codex/skills/<name> ────────
#
# Codex CLI 0.133 discovers skills from $CODEX_HOME/skills/ (= ~/.codex/skills/
# by default). The earlier symlinks at ~/.agents/skills/ are picked up by some
# Codex versions and by npx-skills, but the canonical Codex path is
# ~/.codex/skills/. We mirror our symlinks here for redundancy so /skills
# selector and $name mention syntax surface every plugin reliably.
#
# Codex does NOT have a custom-slash-command mechanism — files in
# ~/.codex/commands/ or ~/.codex/prompts/ are ignored by 0.133. Users invoke
# skills via:  $name  |  /skills selector  |  auto-trigger by description match.

setup_codex_skills() {
    [ "$DO_CODEX_SKILLS" = "1" ] || return 0
    [ "$DO_CROSS_HARNESS" = "1" ] || { dim "Codex skills mirror requires cross-harness setup — skipping."; return 0; }

    local codex_dir="$HOME/.codex/skills"
    mkdir -p "$codex_dir"

    bold ""
    bold "Codex skills mirror (~/.codex/skills/<name>)"

    local managed_dir="$AGENTS_HOME/.managed-by-legion-core"
    mkdir -p "$managed_dir"
    local manifest="$managed_dir/codex-skills.txt"
    : > "$manifest.new"

    local count=0 skipped=0
    local skills_manifest="$managed_dir/skills.txt"
    [ -f "$skills_manifest" ] || { yellow "  · skills manifest missing — run --refresh-symlinks first"; return 0; }

    while IFS= read -r name; do
        local target_link="$SKILLS_DIR/$name"
        # Resolve the actual source path (the ~/.agents/skills/ symlink's target)
        local target
        target=$(readlink "$target_link" 2>/dev/null)
        [ -n "$target" ] || { skipped=$((skipped + 1)); continue; }

        local link="$codex_dir/$name"

        # Same collision rule as ~/.agents/skills/: only replace existing symlinks,
        # leave real directories (Codex's own .system/ subtree, hand-installed skills) alone.
        if [ -L "$link" ]; then
            rm "$link"
        elif [ -e "$link" ]; then
            yellow "  · $name (existing non-symlink at $link — skipped to avoid clobber)"
            skipped=$((skipped + 1))
            continue
        fi

        ln -s "$target" "$link"
        echo "$name" >> "$manifest.new"
        count=$((count + 1))
    done < "$skills_manifest"

    # Prune stale symlinks for skills no longer in our manifest
    if [ -f "$manifest" ]; then
        local pruned=0
        while IFS= read -r old_name; do
            if ! grep -qxF "$old_name" "$manifest.new"; then
                local stale="$codex_dir/$old_name"
                if [ -L "$stale" ]; then
                    rm "$stale"
                    pruned=$((pruned + 1))
                fi
            fi
        done < "$manifest"
        [ "$pruned" -gt 0 ] && yellow "  ⨯ pruned $pruned stale symlinks"
    fi
    mv "$manifest.new" "$manifest"

    green "  ✔ symlinked $count skills into $codex_dir/"
    [ "$skipped" -gt 0 ] && dim "  · $skipped skipped"
    return 0
}

# ── Cursor bridge: MCPs + native subagents ───────────────────────────
#
# Cursor does not read Codex SKILL.md directories directly. It does support
# MCP via ~/.cursor/mcp.json, user subagents via ~/.cursor/agents/*.md, and
# AGENTS.md in repos. Legion bridges commands/agents into Cursor subagents and
# adds a legion-skill-runner subagent that can load mirrored SKILL.md files from
# ~/.agents/skills on demand.
setup_cursor_agents() {
    [ "$DO_CURSOR" = "1" ] || return 0
    [ "$DO_CROSS_HARNESS" = "1" ] || { dim "Cursor bridge requires cross-harness setup — skipping."; return 0; }

    local bridge="$SOURCE_CLONE/legion-setup/scripts/legion-cursor-bridge.py"
    [ -f "$bridge" ] || { dim "Cursor bridge helper missing — skipping (available after Legion update)."; return 0; }
    command -v python3 >/dev/null 2>&1 || { yellow "  · python3 missing — skipping Cursor agent bridge"; return 0; }

    local cursor_agents="${CURSOR_AGENTS:-$HOME/.cursor/agents}"
    mkdir -p "$cursor_agents"

    bold ""
    bold "Cursor agent bridge (~/.cursor/agents)"
    local out count
    out="$(python3 "$bridge" --root "$SOURCE_CLONE" --out "$cursor_agents" --skills-dir "$SKILLS_DIR" 2>/dev/null || true)"
    if [ -z "$out" ] || ! echo "$out" | jq -e 'has("count")' >/dev/null 2>&1; then
        yellow "  · Cursor agent bridge failed"
        local learn="${SOURCE_CLONE}/legion-observability/bin/legion-self-learn"
        if [ -x "$learn" ]; then
            "$learn" record --entity plugin:legion-setup \
                --summary "Installer Cursor agent bridge failed." \
                --severity high --source "install.sh" --evidence "$out" >/dev/null 2>&1 || true
        fi
        return 0
    fi
    count="$(echo "$out" | jq -r '.count')"
    green "  ✔ bridged $count Cursor agents/commands/skill-loader into $cursor_agents/"
}

setup_cursor_native() {
    [ "$DO_CURSOR" = "1" ] || return 0
    [ "$DO_CROSS_HARNESS" = "1" ] || { dim "Cursor native setup requires cross-harness setup — skipping."; return 0; }

    local setup="$SOURCE_CLONE/legion-setup/bin/legion-cursor-setup"
    [ -x "$setup" ] || { setup_cursor_agents; return 0; }

    bold ""
    bold "Cursor native setup (MCP + subagents)"
    LEGION_MARKETPLACE_ROOT="$SOURCE_CLONE" AGENTS_HOME="$AGENTS_HOME" "$setup" all || \
        {
            yellow "  · Cursor setup reported warnings; run: legion-setup cursor verify"
            local learn="${SOURCE_CLONE}/legion-observability/bin/legion-self-learn"
            if [ -x "$learn" ]; then
                "$learn" record --entity plugin:legion-setup \
                    --summary "Installer Cursor native setup reported warnings." \
                    --severity high --source "install.sh" --evidence "legion-cursor-setup all returned nonzero" >/dev/null 2>&1 || true
            fi
        }
}

# ── Cron: daily refresh ──────────────────────────────────────────────
CRON_TAG="# legion-core-refresh"

setup_cron() {
    [ "$DO_CRON" = "1" ] || return 0
    [ "$DO_CROSS_HARNESS" = "1" ] || { dim "Cron refresh requires cross-harness setup — skipping."; return 0; }

    local refresh_script="$SOURCE_CLONE/scripts/refresh.sh"
    if [ ! -x "$refresh_script" ]; then
        yellow "  · refresh.sh not yet executable — skipping cron install (will work after next refresh)"
        return 0
    fi

    local cron_line="0 $CRON_HOUR * * * $refresh_script >/dev/null 2>&1 $CRON_TAG"

    bold ""
    bold "Daily refresh cron"

    if crontab -l 2>/dev/null | grep -qF "$CRON_TAG"; then
        local current_crontab
        # `grep -vF` returns 1 when no lines match (e.g., our tag was the ONLY
        # line). With set -o pipefail that would kill the script, so swallow.
        current_crontab="$(crontab -l 2>/dev/null | grep -vF "$CRON_TAG" || true)"
        if [ -n "$current_crontab" ]; then
            printf '%s\n%s\n' "$current_crontab" "$cron_line" | crontab -
        else
            printf '%s\n' "$cron_line" | crontab -
        fi
        green "  ✔ updated existing cron entry (runs daily at ${CRON_HOUR}:00)"
    else
        local current_crontab
        current_crontab="$(crontab -l 2>/dev/null || true)"
        if [ -n "$current_crontab" ]; then
            printf '%s\n%s\n' "$current_crontab" "$cron_line" | crontab -
        else
            printf '%s\n' "$cron_line" | crontab -
        fi
        green "  ✔ added cron entry (runs daily at ${CRON_HOUR}:00)"
    fi
    dim "       to remove later: bash $SOURCE_CLONE/scripts/uninstall.sh --cron-only"
}

# ── List mode ────────────────────────────────────────────────────────
print_list() {
    add_marketplace >/dev/null 2>&1 || true
    bold ""
    bold "Opus-original plugins (source: ./<dir>)"
    echo ""
    fetch_plugins | jq -r '.plugins[] | select(.source | type == "string" and (startswith("./vendored/") | not)) | "  \(.name)  —  \(.description | .[0:80])\(if (.description | length) > 80 then "…" else "" end)"'
    echo ""
    bold "Vendored plugins (auto-synced from upstream)"
    echo ""
    fetch_plugins | jq -r '.plugins[] | select(.source | type == "string" and startswith("./vendored/")) | "  \(.name)  —  \(.source)"'
    echo ""
}

# ── Help ─────────────────────────────────────────────────────────────
print_help() {
    sed -n '/^# install.sh/,/^# Idempotent/p' "$0" | sed 's/^# \?//'
}

# ── Refresh-only mode (called by refresh.sh cron tick) ───────────────
refresh_symlinks_only() {
    [ -d "$SOURCE_CLONE" ] || { red "Source clone missing at $SOURCE_CLONE — run install first."; exit 1; }
    setup_skill_symlinks
    setup_codex_skills
    setup_cursor_agents
    setup_bin_path
}

# ── Preflight runs for all real modes ────────────────────────────────
case "$MODE" in
    help)             print_help; exit 0 ;;
    list)             preflight; print_list; exit 0 ;;
    refresh-symlinks) refresh_symlinks_only; exit 0 ;;
esac

preflight

case "$MODE" in
    all)
        add_marketplace
        PLUGINS=(); while IFS= read -r line; do PLUGINS+=("$line"); done < <(list_all)
        setup_cross_harness
        setup_codex_skills
        setup_cursor_native
        install_many "${PLUGINS[@]}"
        setup_cron
        ;;
    opus)
        add_marketplace
        PLUGINS=(); while IFS= read -r line; do PLUGINS+=("$line"); done < <(list_opus)
        setup_cross_harness
        setup_codex_skills
        setup_cursor_native
        install_many "${PLUGINS[@]}"
        setup_cron
        ;;
    vendored)
        add_marketplace
        PLUGINS=(); while IFS= read -r line; do PLUGINS+=("$line"); done < <(list_vendored)
        setup_cross_harness
        setup_codex_skills
        setup_cursor_native
        install_many "${PLUGINS[@]}"
        setup_cron
        ;;
    minimal)
        add_marketplace
        setup_cross_harness
        setup_codex_skills
        setup_cursor_native
        install_many legion-router legion-observability
        setup_cron
        ;;
    *)
        # Single plugin name
        add_marketplace
        setup_cross_harness
        setup_codex_skills
        setup_cursor_native
        install_one "$MODE"
        setup_cron
        ;;
esac

bold "Done."
if [ "$DO_CROSS_HARNESS" = "1" ]; then
    dim "Skills available at: $SKILLS_DIR/   (Claude Code, Codex, Cursor skill-runner, opencode, npx-skills all read this)"
    dim "CLI bins available at: $LEGION_BIN_DIR/   (legion-delegate, legion-doctor, opus-overnight, …)"
    dim "Cursor bridge available at: ~/.cursor/agents/ and ~/.cursor/mcp.json"
    case ":${PATH}:" in
        *":$LEGION_BIN_DIR:"*) ;;
        *) yellow "Add to PATH so the CLIs resolve in agent shells too:"
           yellow "  export PATH=\"$LEGION_BIN_DIR:\$PATH\""
           yellow "Use ~/.zshenv for zsh agent shells, or ~/.zshrc / ~/.bashrc for interactive terminals." ;;
    esac
fi
