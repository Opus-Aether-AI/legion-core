#!/usr/bin/env bash
# Common setup helpers for install/refresh/uninstall tests.
#
# Source via:  load 'helpers/setup'
#
# Each test runs in total isolation:
#   - $AGENTS_HOME, $HOME, $PATH all redirected to temp dirs
#   - Mocks for claude/curl/gh/crontab replace the real CLIs
#   - System ~/.agents, ~/.codex, real crontab are NEVER touched

setup_test_env() {
    export TEST_TMPDIR="$BATS_TEST_TMPDIR"
    export AGENTS_HOME="$TEST_TMPDIR/agents"
    export HOME="$TEST_TMPDIR/home"
    export SOURCE_CLONE="$AGENTS_HOME/sources/legion-core"
    export AGENTS_SKILLS_DIR="$AGENTS_HOME/skills"
    export CODEX_SKILLS_DIR="$HOME/.codex/skills"
    export CODEX_COMMANDS_DIR="$HOME/.codex/commands"
    export FAKE_CRONTAB_FILE="$HOME/.fake-crontab"
    export MOCK_CALL_LOG="$TEST_TMPDIR/mock-calls.log"
    # Pin the primary harness so baseline-span / primary-resolution assertions are
    # deterministic no matter which harness the suite runs under (a Codex/opencode
    # session would otherwise flip the resolved primary and its baseline label).
    export LEGION_PRIMARY=claude
    # Independent fixture for the curl/gh API mocks — survives even when tests
    # delete the source clone (e.g., "fetch_plugins falls back to raw GitHub")
    export MOCK_GH_FIXTURE="$TEST_TMPDIR/mock-gh-marketplace.json"
    export MOCK_CURL_FIXTURE="$MOCK_GH_FIXTURE"

    mkdir -p "$AGENTS_HOME" "$HOME/.codex" "$HOME/.claude/plugins/cache"
    : > "$MOCK_CALL_LOG"

    # Mocks shadow selected CLIs (claude, curl, gh, crontab); real git/jq/mkdir remain.
    # The mocks dir is *prepended* so real PATH still works for everything else.
    export PATH="$BATS_TEST_DIRNAME/mocks/bin:$PATH"

    # Path to the real scripts under test
    export REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export INSTALL_SH="$REPO_ROOT/scripts/install.sh"
    export REFRESH_SH="$REPO_ROOT/scripts/refresh.sh"
    export UNINSTALL_SH="$REPO_ROOT/scripts/uninstall.sh"
}

# Build a synthetic source clone at $SOURCE_CLONE based on a marketplace fixture.
# $1: name of the fixture marketplace JSON (resolved against tests/fixtures/)
make_source_clone() {
    local fixture="${1:-marketplace-minimal.json}"
    local fixture_path="$BATS_TEST_DIRNAME/fixtures/$fixture"
    [ -f "$fixture_path" ] || {
        echo "FIXTURE MISSING: $fixture_path" >&2
        return 1
    }

    mkdir -p "$SOURCE_CLONE/.claude-plugin" "$SOURCE_CLONE/scripts"
    cp "$fixture_path" "$SOURCE_CLONE/.claude-plugin/marketplace.json"
    # Also seed the gh-API fixture so the mock can serve it independently
    cp "$fixture_path" "$MOCK_GH_FIXTURE"
    cp "$INSTALL_SH" "$REFRESH_SH" "$UNINSTALL_SH" "$SOURCE_CLONE/scripts/"
    chmod +x "$SOURCE_CLONE/scripts/"*.sh

    # Copy plugin fixture dirs referenced by the marketplace
    if [ -d "$BATS_TEST_DIRNAME/fixtures/plugins" ]; then
        for src in "$BATS_TEST_DIRNAME/fixtures/plugins"/*; do
            [ -d "$src" ] || continue
            cp -R "$src" "$SOURCE_CLONE/$(basename "$src")"
        done
    fi

    # Initialize as a git repo so install.sh's `git -C $SOURCE_CLONE fetch` doesn't fail
    (
        cd "$SOURCE_CLONE"
        git init --quiet --initial-branch=main 2>/dev/null || git init --quiet
        git -c user.email=test@test -c user.name=test add -A
        git -c user.email=test@test -c user.name=test commit -q -m "init test source clone"
        # Configure a fake 'origin' that points to ourselves so `git fetch origin` no-ops cleanly
        git remote add origin "$SOURCE_CLONE" 2>/dev/null || true
        git fetch origin --quiet 2>/dev/null || true
        git branch -u origin/main main 2>/dev/null || true
    )
}

# Record the contents of $MOCK_CALL_LOG for assertions
mock_calls() {
    cat "$MOCK_CALL_LOG" 2>/dev/null
}

# Did the mock for $1 get called with substring $2 in its args?
assert_mock_called() {
    local mock="$1"
    local substr="$2"
    if ! grep -F "$mock " "$MOCK_CALL_LOG" 2>/dev/null | grep -q -- "$substr"; then
        echo "expected mock '$mock' to be called with '$substr', but call log:" >&2
        cat "$MOCK_CALL_LOG" >&2
        return 1
    fi
}

assert_mock_not_called() {
    local mock="$1"
    if grep -qF "$mock " "$MOCK_CALL_LOG" 2>/dev/null; then
        echo "expected mock '$mock' NOT to be called, but it was:" >&2
        grep -F "$mock " "$MOCK_CALL_LOG" >&2
        return 1
    fi
}

# How many symlinks live in $AGENTS_SKILLS_DIR?
agents_skills_count() {
    find "$AGENTS_SKILLS_DIR" -maxdepth 1 -type l 2>/dev/null | wc -l | tr -d ' '
}

# How many symlinks live in $CODEX_SKILLS_DIR?
codex_skills_count() {
    find "$CODEX_SKILLS_DIR" -maxdepth 1 -type l 2>/dev/null | wc -l | tr -d ' '
}

# Build a PATH that hides a specific command while keeping everything else
# install.sh might call. Used by "preflight fails when X is missing" tests.
#
# Naive stripping of $PATH directories doesn't work — on Homebrew systems
# many commands share /opt/homebrew/bin, so stripping one strips them all.
# Instead, build a fresh sandbox bin dir with symlinks to every command we
# might need, omitting the one being hidden.
#
# Usage:  PATH=$(path_without claude) run bash ...
path_without() {
    local hidden_cmd="$1"
    local sandbox="$TEST_TMPDIR/sandbox-no-$hidden_cmd"
    [ -d "$sandbox" ] && { echo "$sandbox"; return 0; }   # cached
    mkdir -p "$sandbox"

    # All the system commands install.sh / refresh.sh / uninstall.sh use
    local needed=(
        bash sh env grep awk sed cat find mkdir ln rm rmdir ls printf echo
        chmod cp mv git base64 readlink jq dirname basename head tail tr sort
        uniq wc gzip cut tee xargs id date
        mktemp python3
        curl
    )
    for cmd in "${needed[@]}"; do
        [ "$cmd" = "$hidden_cmd" ] && continue
        local real
        real="$(command -v "$cmd" 2>/dev/null)" || continue
        ln -sf "$real" "$sandbox/$cmd"
    done

    # Add our mocks unless the hidden command is one of them
    local mocks="$BATS_TEST_DIRNAME/mocks/bin"
    for m in "$mocks"/*; do
        local name; name="$(basename "$m")"
        [ "$name" = "$hidden_cmd" ] && continue
        ln -sf "$m" "$sandbox/$name"
    done

    echo "$sandbox"
}
