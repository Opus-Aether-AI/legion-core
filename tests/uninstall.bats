#!/usr/bin/env bats
# Tests for scripts/uninstall.sh — symmetric removal of install.sh's effects.

load 'helpers/setup'

setup() {
    setup_test_env
    make_source_clone marketplace-minimal.json
    # Establish the installed state we're uninstalling from
    bash "$INSTALL_SH" all --no-claude
}

@test "default uninstall removes ~/.agents/skills/ symlinks + cron, leaves source clone" {
    [ "$(agents_skills_count)" = "3" ]
    [ -f "$FAKE_CRONTAB_FILE" ]

    run bash "$UNINSTALL_SH"
    [ "$status" -eq 0 ]

    # Symlinks gone from both ~/.agents/skills/ and ~/.codex/skills/
    [ "$(agents_skills_count)" = "0" ]
    [ "$(codex_skills_count)" = "0" ]

    # Cron entry removed
    if [ -f "$FAKE_CRONTAB_FILE" ]; then
        if grep -q "legion-core-refresh" "$FAKE_CRONTAB_FILE"; then
            false
        fi
    fi

    # Source clone preserved (--purge needed to remove)
    [ -d "$SOURCE_CLONE/.git" ]
}

@test "--purge also removes the source clone" {
    [ -d "$SOURCE_CLONE/.git" ]

    run bash "$UNINSTALL_SH" --purge
    [ "$status" -eq 0 ]

    [ ! -d "$SOURCE_CLONE" ]
}

@test "--cron-only removes only the cron entry, leaves symlinks" {
    run bash "$UNINSTALL_SH" --cron-only
    [ "$status" -eq 0 ]

    # Cron entry removed
    if [ -f "$FAKE_CRONTAB_FILE" ]; then
        if grep -q "legion-core-refresh" "$FAKE_CRONTAB_FILE"; then
            false
        fi
    fi

    # Symlinks intact
    [ "$(agents_skills_count)" = "3" ]
}

@test "--symlinks-only removes symlinks but leaves cron" {
    run bash "$UNINSTALL_SH" --symlinks-only
    [ "$status" -eq 0 ]

    [ "$(agents_skills_count)" = "0" ]
    [ "$(codex_skills_count)" = "0" ]

    # Cron entry survives
    [ -f "$FAKE_CRONTAB_FILE" ]
    grep -q "legion-core-refresh" "$FAKE_CRONTAB_FILE"
}

@test "uninstall preserves non-managed symlinks in ~/.agents/skills/" {
    # User has a manually-created symlink we didn't manage
    ln -s /tmp "$AGENTS_SKILLS_DIR/my-manual-skill"

    run bash "$UNINSTALL_SH"
    [ "$status" -eq 0 ]

    # Our managed ones are gone, the manual one survives
    [ -L "$AGENTS_SKILLS_DIR/my-manual-skill" ]
    [ ! -e "$AGENTS_SKILLS_DIR/plugin-with-skill" ]
}

@test "uninstall preserves unrelated crontab entries" {
    # Pre-existing entry from another tool
    printf '%s\n%s\n' "# my other cron" "0 6 * * * /some/other/script" >> "$FAKE_CRONTAB_FILE"

    run bash "$UNINSTALL_SH" --cron-only
    [ "$status" -eq 0 ]

    grep -q "my other cron" "$FAKE_CRONTAB_FILE"
    grep -q "/some/other/script" "$FAKE_CRONTAB_FILE"
    if grep -q "legion-core-refresh" "$FAKE_CRONTAB_FILE"; then
        false
    fi
}

@test "--claude also removes claude marketplace + plugins" {
    # setup() ran install with --no-claude, so the mock state has no marketplace.
    # Populate it directly to simulate a real install having registered it.
    echo "legion-core" > "$HOME/.mock-claude-marketplaces"
    mkdir -p "$HOME/.claude/plugins/cache/legion-core/plugin-with-skill/0.1.0"

    run bash "$UNINSTALL_SH" --claude
    [ "$status" -eq 0 ]

    assert_mock_called claude "marketplace remove legion"
}

@test "uninstall is idempotent (re-running after removal is a clean no-op)" {
    bash "$UNINSTALL_SH"

    # Second uninstall — should not error
    run bash "$UNINSTALL_SH"
    [ "$status" -eq 0 ]
}

@test "uninstall handles missing manifest gracefully" {
    # Wipe state so uninstall has nothing to read
    rm -rf "$AGENTS_HOME/.managed-by-legion-core"

    run bash "$UNINSTALL_SH"
    if [ "$status" -ne 0 ]; then
        echo "uninstall exited with status $status. Output:"
        echo "$output"
        false
    fi
    [[ "$output" == *"nothing to remove"* ]] || [[ "$output" == *"no manifest"* ]]
}

@test "uninstall --help prints usage" {
    run bash "$UNINSTALL_SH" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"uninstall.sh"* ]]
}

@test "uninstall --all does everything (purge + claude)" {
    echo "legion-core" > "$HOME/.mock-claude-marketplaces"

    run bash "$UNINSTALL_SH" --all
    [ "$status" -eq 0 ]
    [ ! -d "$SOURCE_CLONE" ]
    assert_mock_called claude "marketplace remove"
}

@test "uninstall rejects unknown flags with exit 2" {
    run bash "$UNINSTALL_SH" --not-a-real-flag
    [ "$status" -eq 2 ]
    [[ "$output" == *"Unknown flag"* ]]
}

@test "uninstall --purge handles already-removed source clone gracefully" {
    rm -rf "$SOURCE_CLONE"
    run bash "$UNINSTALL_SH" --purge
    [ "$status" -eq 0 ]
    [[ "$output" == *"not present"* ]]
}

@test "uninstall --claude reports when marketplace not registered" {
    # Clear mock state — no marketplace registered
    rm -f "$HOME/.mock-claude-marketplaces"

    run bash "$UNINSTALL_SH" --claude
    [ "$status" -eq 0 ]
    [[ "$output" == *"not registered"* ]]
}

@test "uninstall --claude skips when claude CLI not installed" {
    PATH="$(path_without claude)" run bash "$UNINSTALL_SH" --claude
    [ "$status" -eq 0 ]
    [[ "$output" == *"claude CLI not found"* ]]
}

@test "uninstall cleans up legacy ~/.codex/commands/ wrappers from earlier versions" {
    # Simulate an older install.sh that wrote command wrappers
    local marker='<!-- legion-core-managed: do not edit; regenerated by install.sh -->'
    mkdir -p "$HOME/.codex/commands"
    cat > "$HOME/.codex/commands/handoff.md" <<EOF
---
description: 'legacy stub'
---

$marker

Legacy wrapper body
EOF
    # Hand-written commands without our marker should NOT be touched
    echo "user content" > "$HOME/.codex/commands/user-command.md"

    # Track it in a legacy manifest
    mkdir -p "$AGENTS_HOME/.managed-by-legion-core"
    echo "handoff" > "$AGENTS_HOME/.managed-by-legion-core/codex-commands.txt"

    run bash "$UNINSTALL_SH"
    [ "$status" -eq 0 ]

    [ ! -f "$HOME/.codex/commands/handoff.md" ]
    [ -f "$HOME/.codex/commands/user-command.md" ]
}
