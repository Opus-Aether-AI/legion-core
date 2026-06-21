#!/usr/bin/env bats
# Tests for install.sh's bin→PATH wiring (setup_bin_path).
#
# Claude Code surfaces a plugin's *skills* but not its bin/, so every
# legion-*/opus-* SKILL.md that calls its CLI bare would be "command not
# found" without this wiring. These tests prove the managed ~/.agents/bin/
# symlink farm is created, prunes correctly, and skips extensioned helpers.

load 'helpers/setup'

setup() {
    setup_test_env
    make_source_clone marketplace-minimal.json
    export LEGION_BIN_DIR="$AGENTS_HOME/bin"
}

# How many symlinks live in $LEGION_BIN_DIR?
bin_count() {
    find "$LEGION_BIN_DIR" -maxdepth 1 -type l 2>/dev/null | wc -l | tr -d ' '
}

@test "bin-path: --refresh-symlinks links the fixture plugin's extensionless CLI" {
    run bash "$INSTALL_SH" --refresh-symlinks
    [ "$status" -eq 0 ]
    [ -L "$LEGION_BIN_DIR/legion-testcli" ]
    # The symlink resolves to the plugin's bin and is runnable
    run "$LEGION_BIN_DIR/legion-testcli"
    [ "$status" -eq 0 ]
    [[ "$output" == *"legion-testcli ok"* ]]
}

@test "bin-path: extensioned helpers (*.py) are NOT linked onto PATH" {
    run bash "$INSTALL_SH" --refresh-symlinks
    [ "$status" -eq 0 ]
    [ ! -e "$LEGION_BIN_DIR/helper.py" ]
    # Exactly one CLI from the fixture set (only plugin-with-skill ships a bin/)
    [ "$(bin_count)" = "1" ]
}

@test "bin-path: a manifest records linked bins for later pruning" {
    run bash "$INSTALL_SH" --refresh-symlinks
    [ "$status" -eq 0 ]
    local manifest="$AGENTS_HOME/.managed-by-legion-core/bins.txt"
    [ -f "$manifest" ]
    grep -qxF "legion-testcli" "$manifest"
    ! grep -qxF "helper.py" "$manifest"
}

@test "bin-path: re-running is idempotent (same single bin)" {
    bash "$INSTALL_SH" --refresh-symlinks
    run bash "$INSTALL_SH" --refresh-symlinks
    [ "$status" -eq 0 ]
    [ "$(bin_count)" = "1" ]
    [ -L "$LEGION_BIN_DIR/legion-testcli" ]
}

@test "bin-path: a stale bin is pruned when its plugin loses the CLI" {
    bash "$INSTALL_SH" --refresh-symlinks
    [ -L "$LEGION_BIN_DIR/legion-testcli" ]
    # Simulate the plugin dropping its bin/ in a later release
    rm -rf "$SOURCE_CLONE/plugin-with-skill/bin"
    run bash "$INSTALL_SH" --refresh-symlinks
    [ "$status" -eq 0 ]
    [ ! -e "$LEGION_BIN_DIR/legion-testcli" ]
    [ "$(bin_count)" = "0" ]
}

@test "bin-path: a pre-existing real file (non-symlink) is not clobbered" {
    mkdir -p "$LEGION_BIN_DIR"
    echo "hand-written" > "$LEGION_BIN_DIR/legion-testcli"
    run bash "$INSTALL_SH" --refresh-symlinks
    [ "$status" -eq 0 ]
    [ ! -L "$LEGION_BIN_DIR/legion-testcli" ]
    grep -qxF "hand-written" "$LEGION_BIN_DIR/legion-testcli"
    [[ "$output" == *"skipped"* ]]
}

@test "bin-path: PATH guidance is printed when the bin dir is not on PATH" {
    run bash "$INSTALL_SH" --refresh-symlinks
    [ "$status" -eq 0 ]
    [[ "$output" == *"export PATH="* ]]
}

@test "bin-path: full install wires bins too (not just --refresh-symlinks)" {
    run bash "$INSTALL_SH" all --no-claude --no-cron
    [ "$status" -eq 0 ]
    [ -L "$LEGION_BIN_DIR/legion-testcli" ]
}

@test "bin-path: reports 'already on PATH' when the bin dir is on PATH" {
    run env PATH="$LEGION_BIN_DIR:$PATH" bash "$INSTALL_SH" all --no-claude --no-cron
    [ "$status" -eq 0 ]
    [[ "$output" == *"already on PATH"* ]]
    [[ "$output" != *"NOT on PATH yet"* ]]
}
