#!/usr/bin/env bats
# Tests for scripts/install.sh — exercised via its public CLI interface only.
# Every test runs in total isolation: $AGENTS_HOME and $HOME are redirected to
# bats-managed temp dirs, and claude/gh/crontab are mocked.

load 'helpers/setup'

setup() {
    setup_test_env
    make_source_clone marketplace-minimal.json
}

# ── Tracer bullet ────────────────────────────────────────────────────
# One test that proves the harness is wired correctly end-to-end:
# the installer can find the source clone, create symlinks for both
# top-level + nested plugins, and skip the Claude-only plugin.

@test "fresh install --refresh-symlinks creates 3 symlinks from the 3 fixture plugins" {
    run bash "$INSTALL_SH" --refresh-symlinks
    [ "$status" -eq 0 ]

    # plugin-with-skill → top-level symlink
    [ -L "$AGENTS_SKILLS_DIR/plugin-with-skill" ]
    [ -f "$AGENTS_SKILLS_DIR/plugin-with-skill/SKILL.md" ]

    # plugin-nested has 2 nested skills:
    #   - skills/alpha → "nested-alpha" (namespace prefixed)
    #   - skills/nested-beta → "nested-beta" (already has prefix, no double)
    [ -L "$AGENTS_SKILLS_DIR/nested-alpha" ]
    [ -L "$AGENTS_SKILLS_DIR/nested-beta" ]

    # plugin-claude-only has no SKILL.md anywhere → NOT symlinked
    [ ! -e "$AGENTS_SKILLS_DIR/plugin-claude-only" ]

    # Total: 3 symlinks (1 top-level + 2 nested)
    [ "$(agents_skills_count)" = "3" ]
}

# ── Flag parsing ─────────────────────────────────────────────────────

@test "--help prints usage and exits 0" {
    run bash "$INSTALL_SH" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"install.sh"* ]]
    [[ "$output" == *"Usage"* ]] || [[ "$output" == *"--no-claude"* ]]
}

@test "-h is an alias for --help" {
    run bash "$INSTALL_SH" -h
    [ "$status" -eq 0 ]
    [[ "$output" == *"install.sh"* ]]
}

@test "unknown flag exits 2 with an error message" {
    run bash "$INSTALL_SH" --nonexistent-flag
    [ "$status" -eq 2 ]
    [[ "$output" == *"Unknown flag"* ]]
}

@test "--list lists plugins and doesn't install anything" {
    run bash "$INSTALL_SH" --list
    [ "$status" -eq 0 ]
    [[ "$output" == *"plugin-with-skill"* ]]
    [[ "$output" == *"plugin-nested"* ]]
    # Should not have made any symlinks
    [ "$(agents_skills_count)" = "0" ]
}

# ── Idempotency ──────────────────────────────────────────────────────

@test "re-running --refresh-symlinks is idempotent (no changes second time)" {
    bash "$INSTALL_SH" --refresh-symlinks
    local before=$(ls -la "$AGENTS_SKILLS_DIR")

    run bash "$INSTALL_SH" --refresh-symlinks
    [ "$status" -eq 0 ]
    local after=$(ls -la "$AGENTS_SKILLS_DIR")

    # Symlink targets unchanged (mtime ignored, comparing names + targets)
    [ "$(agents_skills_count)" = "3" ]
    diff <(echo "$before" | awk '{print $9, $11}') <(echo "$after" | awk '{print $9, $11}')
}

# ── Collision protection ─────────────────────────────────────────────

@test "pre-existing non-symlink directory at target is preserved (not clobbered)" {
    # User had a real directory at the target name (e.g., from npx-skills)
    mkdir -p "$AGENTS_SKILLS_DIR/plugin-with-skill"
    echo "user-content" > "$AGENTS_SKILLS_DIR/plugin-with-skill/marker.txt"

    run bash "$INSTALL_SH" --refresh-symlinks
    [ "$status" -eq 0 ]

    # The real dir survived; no symlink created over it
    [ ! -L "$AGENTS_SKILLS_DIR/plugin-with-skill" ]
    [ -d "$AGENTS_SKILLS_DIR/plugin-with-skill" ]
    [ -f "$AGENTS_SKILLS_DIR/plugin-with-skill/marker.txt" ]
    grep -q "user-content" "$AGENTS_SKILLS_DIR/plugin-with-skill/marker.txt"

    # The other 2 nested ones still get symlinked
    [ -L "$AGENTS_SKILLS_DIR/nested-alpha" ]
    [ -L "$AGENTS_SKILLS_DIR/nested-beta" ]

    # Warning surfaced in stderr/stdout
    [[ "$output" == *"plugin-with-skill"* ]] && [[ "$output" == *"skipped"* ]]
}

@test "pre-existing managed symlink is replaced (idempotent install)" {
    # Stage: simulate a previous install
    bash "$INSTALL_SH" --refresh-symlinks
    local first_target=$(readlink "$AGENTS_SKILLS_DIR/plugin-with-skill")

    # Re-run install — should replace the symlink without errors
    run bash "$INSTALL_SH" --refresh-symlinks
    [ "$status" -eq 0 ]

    # Symlink still exists and points at the source
    [ -L "$AGENTS_SKILLS_DIR/plugin-with-skill" ]
    [ "$(readlink "$AGENTS_SKILLS_DIR/plugin-with-skill")" = "$first_target" ]
}

# ── Pruning ──────────────────────────────────────────────────────────

@test "stale symlinks are pruned when a plugin is removed from the marketplace" {
    # First install creates 3 symlinks
    bash "$INSTALL_SH" --refresh-symlinks
    [ "$(agents_skills_count)" = "3" ]

    # Simulate upstream removing plugin-with-skill from the marketplace
    local m="$SOURCE_CLONE/.claude-plugin/marketplace.json"
    jq '.plugins |= map(select(.name != "plugin-with-skill"))' "$m" > "$m.tmp"
    mv "$m.tmp" "$m"
    rm -rf "$SOURCE_CLONE/plugin-with-skill"

    run bash "$INSTALL_SH" --refresh-symlinks
    [ "$status" -eq 0 ]

    # Stale symlink pruned, others remain
    [ ! -e "$AGENTS_SKILLS_DIR/plugin-with-skill" ]
    [ -L "$AGENTS_SKILLS_DIR/nested-alpha" ]
    [ -L "$AGENTS_SKILLS_DIR/nested-beta" ]
    [ "$(agents_skills_count)" = "2" ]
}

# ── ~/.codex/skills/ mirror ──────────────────────────────────────────

@test "--refresh-symlinks mirrors symlinks into ~/.codex/skills/ too" {
    run bash "$INSTALL_SH" --refresh-symlinks
    [ "$status" -eq 0 ]

    [ -L "$CODEX_SKILLS_DIR/plugin-with-skill" ]
    [ -L "$CODEX_SKILLS_DIR/nested-alpha" ]
    [ -L "$CODEX_SKILLS_DIR/nested-beta" ]
    [ "$(codex_skills_count)" = "3" ]

    # Mirror points to the same source target as ~/.agents/skills/
    [ "$(readlink "$CODEX_SKILLS_DIR/plugin-with-skill")" = "$(readlink "$AGENTS_SKILLS_DIR/plugin-with-skill")" ]
}

@test "--no-codex-skills disables the ~/.codex/skills/ mirror" {
    # `--no-codex-skills` only meaningfully applies during a full install.
    # During --refresh-symlinks we still mirror; so test via the main flow.
    run bash "$INSTALL_SH" all --no-claude --no-cron --no-codex-skills
    [ "$status" -eq 0 ]
    [ "$(codex_skills_count)" = "0" ]
    # ~/.agents/skills/ still populated
    [ "$(agents_skills_count)" = "3" ]
}

@test "--no-codex-commands is a back-compat alias for --no-codex-skills" {
    run bash "$INSTALL_SH" all --no-claude --no-cron --no-codex-commands
    [ "$status" -eq 0 ]
    [ "$(codex_skills_count)" = "0" ]
}

# ── Marketplace install (claude) ─────────────────────────────────────

@test "default install registers the marketplace + installs plugins via mock claude" {
    run bash "$INSTALL_SH" all --no-cron
    [ "$status" -eq 0 ]

    # Mock claude was called with `marketplace add` + per-plugin `install`
    assert_mock_called claude "marketplace add Opus-Aether-AI/legion-core"
    assert_mock_called claude "plugin install plugin-with-skill@legion-core"
    assert_mock_called claude "plugin install plugin-nested@legion-core"
    assert_mock_called claude "plugin install plugin-claude-only@legion-core"
}

@test "--no-claude skips all claude CLI invocations" {
    run bash "$INSTALL_SH" all --no-claude --no-cron
    [ "$status" -eq 0 ]
    assert_mock_not_called claude
    # Symlinks still created
    [ "$(agents_skills_count)" = "3" ]
}

# ── --no-cross-harness ───────────────────────────────────────────────

@test "--no-cross-harness skips ~/.agents/skills/ symlinks" {
    run bash "$INSTALL_SH" all --no-claude --no-cron --no-cross-harness
    [ "$status" -eq 0 ]
    [ "$(agents_skills_count)" = "0" ]
    [ "$(codex_skills_count)" = "0" ]
}

@test "all opt-outs combined: install becomes a near-no-op" {
    run bash "$INSTALL_SH" all --no-claude --no-cross-harness --no-codex-skills --no-cron
    [ "$status" -eq 0 ]
    [ "$(agents_skills_count)" = "0" ]
    [ "$(codex_skills_count)" = "0" ]
    [ ! -f "$FAKE_CRONTAB_FILE" ]
    assert_mock_not_called claude
    [[ "$output" == *"Done"* ]]
}

@test "--no-cursor skips Cursor native setup" {
    mkdir -p "$SOURCE_CLONE/legion-setup/bin"
    cat > "$SOURCE_CLONE/legion-setup/bin/legion-cursor-setup" <<'SH'
#!/usr/bin/env bash
printf 'cursor-setup %s\n' "$*" >> "$MOCK_CALL_LOG"
SH
    chmod +x "$SOURCE_CLONE/legion-setup/bin/legion-cursor-setup"

    run bash "$INSTALL_SH" all --no-claude --no-cron --no-cursor
    [ "$status" -eq 0 ]
    if grep -F "cursor-setup" "$MOCK_CALL_LOG"; then false; fi
}

@test "source clone with local edits: install fetches but skips reset" {
    bash "$INSTALL_SH" --refresh-symlinks   # establish clone
    # Hand-edit a tracked file in the source clone
    echo "user-edit" >> "$SOURCE_CLONE/plugin-with-skill/SKILL.md"

    run bash "$INSTALL_SH" all --no-claude --no-cron
    [ "$status" -eq 0 ]
    [[ "$output" == *"local edits"* ]]
    # Edit survives
    grep -q "user-edit" "$SOURCE_CLONE/plugin-with-skill/SKILL.md"
}

# ── Cursor native setup / bridge ─────────────────────────────────────

@test "install invokes Cursor native setup when available" {
    mkdir -p "$SOURCE_CLONE/legion-setup/bin"
    cat > "$SOURCE_CLONE/legion-setup/bin/legion-cursor-setup" <<'SH'
#!/usr/bin/env bash
printf 'cursor-setup %s\n' "$*" >> "$MOCK_CALL_LOG"
SH
    chmod +x "$SOURCE_CLONE/legion-setup/bin/legion-cursor-setup"

    run bash "$INSTALL_SH" all --no-claude --no-cron
    [ "$status" -eq 0 ]
    [[ "$output" == *"Cursor native setup"* ]]
    grep -qF "cursor-setup all" "$MOCK_CALL_LOG"
}

@test "install records Cursor native setup warnings to self-learning" {
    mkdir -p "$SOURCE_CLONE/legion-setup/bin" "$SOURCE_CLONE/legion-observability/bin"
    cat > "$SOURCE_CLONE/legion-setup/bin/legion-cursor-setup" <<'SH'
#!/usr/bin/env bash
printf 'cursor-setup %s\n' "$*" >> "$MOCK_CALL_LOG"
exit 1
SH
    cat > "$SOURCE_CLONE/legion-observability/bin/legion-self-learn" <<'SH'
#!/usr/bin/env bash
printf 'self-learn %s\n' "$*" >> "$MOCK_CALL_LOG"
SH
    chmod +x "$SOURCE_CLONE/legion-setup/bin/legion-cursor-setup" "$SOURCE_CLONE/legion-observability/bin/legion-self-learn"

    run bash "$INSTALL_SH" all --no-claude --no-cron
    [ "$status" -eq 0 ]
    [[ "$output" == *"Cursor setup reported warnings"* ]]
    grep -qF "Installer Cursor native setup reported warnings." "$MOCK_CALL_LOG"
}

@test "install falls back to Cursor agent bridge when native setup wrapper is missing" {
    mkdir -p "$SOURCE_CLONE/legion-setup/scripts"
    cat > "$SOURCE_CLONE/legion-setup/scripts/legion-cursor-bridge.py" <<'PY'
#!/usr/bin/env python3
print('{"count": 2}')
PY
    chmod +x "$SOURCE_CLONE/legion-setup/scripts/legion-cursor-bridge.py"

    run bash "$INSTALL_SH" all --no-claude --no-cron
    [ "$status" -eq 0 ]
    [[ "$output" == *"Cursor agent bridge"* ]]
    [[ "$output" == *"bridged 2 Cursor agents"* ]]
    [ -d "$HOME/.cursor/agents" ]
}

@test "install records Cursor agent bridge failures to self-learning" {
    mkdir -p "$SOURCE_CLONE/legion-setup/scripts" "$SOURCE_CLONE/legion-observability/bin"
    cat > "$SOURCE_CLONE/legion-setup/scripts/legion-cursor-bridge.py" <<'PY'
#!/usr/bin/env python3
print('not json')
PY
    cat > "$SOURCE_CLONE/legion-observability/bin/legion-self-learn" <<'SH'
#!/usr/bin/env bash
printf 'self-learn %s\n' "$*" >> "$MOCK_CALL_LOG"
SH
    chmod +x "$SOURCE_CLONE/legion-setup/scripts/legion-cursor-bridge.py" "$SOURCE_CLONE/legion-observability/bin/legion-self-learn"

    run bash "$INSTALL_SH" all --no-claude --no-cron
    [ "$status" -eq 0 ]
    [[ "$output" == *"Cursor agent bridge failed"* ]]
    grep -qF "Installer Cursor agent bridge failed." "$MOCK_CALL_LOG"
}

# ── Profile filtering ────────────────────────────────────────────────

@test "single plugin name installs only that one plugin" {
    run bash "$INSTALL_SH" plugin-with-skill --no-cron
    [ "$status" -eq 0 ]
    assert_mock_called claude "plugin install plugin-with-skill@legion-core"
    # Other plugins not installed via marketplace
    if grep -F "plugin install plugin-nested@" "$MOCK_CALL_LOG"; then
        false
    fi
}

# ── Cron ─────────────────────────────────────────────────────────────

@test "default install does not add cron and prints the opt-in hint" {
    run bash "$INSTALL_SH" all --no-claude
    [ "$status" -eq 0 ]
    [ ! -f "$FAKE_CRONTAB_FILE" ]
    [[ "$output" == *"Re-run with --cron or LEGION_INSTALL_CRON=1"* ]]
}

@test "--cron adds a daily refresh cron entry tagged with our marker" {
    run bash "$INSTALL_SH" all --no-claude --cron
    [ "$status" -eq 0 ]
    [ -f "$FAKE_CRONTAB_FILE" ]
    grep -q "# legion-core-refresh" "$FAKE_CRONTAB_FILE"
    grep -q "0 9 \* \* \*" "$FAKE_CRONTAB_FILE"
}

@test "--no-cron skips the crontab entry" {
    run bash "$INSTALL_SH" all --no-claude --no-cron
    [ "$status" -eq 0 ]
    [ ! -f "$FAKE_CRONTAB_FILE" ]
}

@test "--cron-hour=N uses N as the hour" {
    run bash "$INSTALL_SH" all --no-claude --cron --cron-hour=3
    [ "$status" -eq 0 ]
    grep -q "0 3 \* \* \*" "$FAKE_CRONTAB_FILE"
    if grep -q "0 9 \* \* \*" "$FAKE_CRONTAB_FILE"; then false; fi
}

@test "cron entry preserves unrelated pre-existing crontab lines" {
    printf '%s\n' "# my other cron" "0 6 * * * /some/other/script" > "$FAKE_CRONTAB_FILE"

    run bash "$INSTALL_SH" all --no-claude --cron
    [ "$status" -eq 0 ]
    grep -q "my other cron" "$FAKE_CRONTAB_FILE"
    grep -q "/some/other/script" "$FAKE_CRONTAB_FILE"
    grep -q "legion-core-refresh" "$FAKE_CRONTAB_FILE"
}

@test "re-running install replaces the cron entry, not duplicates it" {
    bash "$INSTALL_SH" all --no-claude --cron
    bash "$INSTALL_SH" all --no-claude --cron --cron-hour=4

    # Exactly one entry with our tag
    [ "$(grep -c "legion-core-refresh" "$FAKE_CRONTAB_FILE")" = "1" ]
    # The new hour wins
    grep -q "0 4 \* \* \*" "$FAKE_CRONTAB_FILE"
}

# ── Profile filtering ────────────────────────────────────────────────

@test "profile 'minimal' attempts to install legion-router + legion-observability" {
    # These won't exist in our fixture; the mock claude still records the call
    run bash "$INSTALL_SH" minimal --no-cron
    [ "$status" -eq 0 ]
    assert_mock_called claude "plugin install legion-router@legion-core"
    assert_mock_called claude "plugin install legion-observability@legion-core"
}

# ── Idempotent install — already-installed branch ───────────────────

@test "running install twice marks plugins as already installed (skips claude install)" {
    bash "$INSTALL_SH" all --no-cron   # First install — populates cache
    # Wipe the call log so we only see the second install's invocations
    : > "$MOCK_CALL_LOG"

    run bash "$INSTALL_SH" all --no-cron
    [ "$status" -eq 0 ]
    [[ "$output" == *"already installed"* ]]

    # No `plugin install` calls in the second run
    if grep -F "plugin install plugin-with-skill" "$MOCK_CALL_LOG"; then false; fi
}

@test "add_marketplace reports 'already added' on second run" {
    bash "$INSTALL_SH" all --no-cron --no-cross-harness  # marketplace registered
    : > "$MOCK_CALL_LOG"

    run bash "$INSTALL_SH" all --no-cron --no-cross-harness
    [ "$status" -eq 0 ]
    [[ "$output" == *"already added"* ]]
}

# ── Preflight failures (missing tools) ──────────────────────────────

@test "preflight fails when jq is not on PATH" {
    PATH="$(path_without jq)" run bash "$INSTALL_SH" all
    [ "$status" -eq 1 ]
    [[ "$output" == *"jq required"* ]]
}

@test "preflight fails when gh is not on PATH" {
    PATH="$(path_without gh)" run bash "$INSTALL_SH" all
    [ "$status" -eq 1 ]
    [[ "$output" == *"gh required"* ]]
}

@test "preflight fails when git is not on PATH (with cross-harness on)" {
    # Skip if running test path has no system git (uncommon)
    command -v git >/dev/null || skip "git not available"
    PATH="$(path_without git)" run bash "$INSTALL_SH" all
    [ "$status" -eq 1 ]
    [[ "$output" == *"git required"* ]]
}

@test "preflight auto-disables --no-claude when claude CLI is missing" {
    PATH="$(path_without claude)" run bash "$INSTALL_SH" all --no-cron
    [ "$status" -eq 0 ]
    [[ "$output" == *"claude CLI not found"* ]]
}

@test "preflight fails when gh is not authenticated" {
    # Make gh's auth status return failure for this test
    local broken_gh="$TEST_TMPDIR/broken-gh"
    mkdir -p "$broken_gh"
    cat > "$broken_gh/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >> "${MOCK_CALL_LOG:-/dev/null}"
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
    echo "not authenticated" >&2
    exit 1
fi
exit 0
EOF
    chmod +x "$broken_gh/gh"

    local mocks_dir="$BATS_TEST_DIRNAME/mocks/bin"
    local clean_path="${PATH//$mocks_dir:/}"
    PATH="$broken_gh:$clean_path" run bash "$INSTALL_SH" all
    [ "$status" -eq 1 ]
    [[ "$output" == *"gh not authenticated"* ]]
}

# ── fetch_plugins fallback to gh API ────────────────────────────────

@test "fetch_plugins falls back to gh API when source clone is missing" {
    # Remove the clone — install should still work via gh
    rm -rf "$SOURCE_CLONE"
    # But fetch_plugins is only called during --list or during all/opus/... profile install
    # When the clone is gone, setup_source_clone will try to clone via gh.
    # Test --list which only needs fetch_plugins.

    run bash "$INSTALL_SH" --list
    [ "$status" -eq 0 ]
    [[ "$output" == *"plugin-with-skill"* ]]
    # Should have called `gh api` (we removed the local file)
    assert_mock_called gh "api repos/Opus-Aether-AI/legion-core/contents/.claude-plugin/marketplace.json"
}

# ── Nested skill collision ──────────────────────────────────────────

@test "pre-existing non-symlink at nested skill target is preserved" {
    # Pre-create a real directory at where the nested symlink would go
    mkdir -p "$AGENTS_SKILLS_DIR/nested-alpha"
    echo "user-content" > "$AGENTS_SKILLS_DIR/nested-alpha/marker.txt"

    run bash "$INSTALL_SH" --refresh-symlinks
    [ "$status" -eq 0 ]

    [ ! -L "$AGENTS_SKILLS_DIR/nested-alpha" ]
    [ -f "$AGENTS_SKILLS_DIR/nested-alpha/marker.txt" ]
    [[ "$output" == *"nested-alpha"* ]] && [[ "$output" == *"skipped"* ]]
}

# ── Codex mirror collision ──────────────────────────────────────────

@test "pre-existing non-symlink in ~/.codex/skills/ is preserved" {
    mkdir -p "$CODEX_SKILLS_DIR/plugin-with-skill"
    echo "codex-existing" > "$CODEX_SKILLS_DIR/plugin-with-skill/marker.txt"

    run bash "$INSTALL_SH" --refresh-symlinks
    [ "$status" -eq 0 ]

    [ ! -L "$CODEX_SKILLS_DIR/plugin-with-skill" ]
    [ -f "$CODEX_SKILLS_DIR/plugin-with-skill/marker.txt" ]
}

# ── Pruning Codex skills mirror ──────────────────────────────────────

@test "install_one reports failure when claude plugin install returns error" {
    # Stub claude with one that fails for `plugin install`. Crucially,
    # symlinks must be removed BEFORE writing via `cat >`, or the
    # redirection follows the link and overwrites the real mock.
    local broken_mocks="$TEST_TMPDIR/mocks-broken-install"
    mkdir -p "$broken_mocks"
    # Symlink everything except claude (which we'll write manually)
    for m in "$BATS_TEST_DIRNAME/mocks/bin"/*; do
        [ "$(basename "$m")" = "claude" ] && continue
        ln -sf "$m" "$broken_mocks/$(basename "$m")"
    done
    # Write the broken claude as a regular file
    cat > "$broken_mocks/claude" <<EOF
#!/usr/bin/env bash
echo "claude \$*" >> "\$MOCK_CALL_LOG"
if [ "\$1" = "plugin" ] && [ "\$2" = "install" ]; then
    echo "✘ install failed (mocked)" >&2
    exit 1
fi
exec "$BATS_TEST_DIRNAME/mocks/bin/claude" "\$@"
EOF
    chmod +x "$broken_mocks/claude"

    local clean_path="${PATH//$BATS_TEST_DIRNAME\/mocks\/bin:/}"
    PATH="$broken_mocks:$clean_path" run bash "$INSTALL_SH" all --no-cron
    [ "$status" -eq 0 ]
    [[ "$output" == *"failed"* ]]
}

@test "setup_source_clone calls gh repo clone when source dir is missing" {
    # Remove the local clone — fresh-machine scenario
    rm -rf "$SOURCE_CLONE"
    # gh mock's "repo clone" reads $MOCK_GH_CLONE_SOURCE
    export MOCK_GH_CLONE_SOURCE="$SOURCE_CLONE.fixture-backup"
    # Use the original fixture as the "remote"
    mkdir -p "$SOURCE_CLONE.fixture-backup/.claude-plugin"
    cp "$BATS_TEST_DIRNAME/fixtures/marketplace-minimal.json" "$SOURCE_CLONE.fixture-backup/.claude-plugin/marketplace.json"
    cp -R "$BATS_TEST_DIRNAME/fixtures/plugins/"* "$SOURCE_CLONE.fixture-backup/"

    run bash "$INSTALL_SH" all --no-claude --no-cron
    [ "$status" -eq 0 ]
    assert_mock_called gh "repo clone Opus-Aether-AI/legion-core"
    [ -d "$SOURCE_CLONE" ]
}

@test "setup_cron warns when refresh.sh is not executable yet" {
    # Strip exec bit + commit the change so install.sh's git reset preserves it.
    chmod -x "$SOURCE_CLONE/scripts/refresh.sh"
    (cd "$SOURCE_CLONE" && \
        git -c user.email=test@test -c user.name=test add -A && \
        git -c user.email=test@test -c user.name=test commit -q --allow-empty -m "remove +x" && \
        git fetch origin --quiet 2>/dev/null && \
        git reset --hard HEAD --quiet)

    run bash "$INSTALL_SH" all --no-claude --cron
    [ "$status" -eq 0 ]
    [[ "$output" == *"not yet executable"* ]]
}

@test "stale ~/.codex/skills/ symlinks are pruned when plugin is removed" {
    bash "$INSTALL_SH" --refresh-symlinks
    [ -L "$CODEX_SKILLS_DIR/plugin-with-skill" ]

    # Remove from upstream
    local m="$SOURCE_CLONE/.claude-plugin/marketplace.json"
    jq '.plugins |= map(select(.name != "plugin-with-skill"))' "$m" > "$m.tmp"
    mv "$m.tmp" "$m"
    rm -rf "$SOURCE_CLONE/plugin-with-skill"

    run bash "$INSTALL_SH" --refresh-symlinks
    [ "$status" -eq 0 ]
    [ ! -e "$CODEX_SKILLS_DIR/plugin-with-skill" ]
}
