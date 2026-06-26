#!/usr/bin/env bats
# Tests for scripts/refresh.sh — the cron-callable daily refresh.

load 'helpers/setup'

setup() {
    setup_test_env
}

@test "refresh.sh exits 1 when source clone is missing" {
    # No make_source_clone call → $SOURCE_CLONE doesn't exist
    run bash "$REFRESH_SH"
    [ "$status" -eq 1 ]
    [[ "$output" == *"source clone missing"* ]]
}

@test "refresh.sh exits 0 on a healthy install" {
    make_source_clone marketplace-minimal.json
    # Establish initial state by running install once
    bash "$INSTALL_SH" --refresh-symlinks

    run bash "$REFRESH_SH"
    [ "$status" -eq 0 ]

    # Symlinks remain populated after refresh
    [ "$(agents_skills_count)" = "3" ]
}

@test "refresh.sh pulls latest from upstream + re-syncs symlinks" {
    make_source_clone marketplace-minimal.json
    bash "$INSTALL_SH" --refresh-symlinks
    [ "$(agents_skills_count)" = "3" ]

    # Simulate upstream change: remove plugin-with-skill from marketplace.json
    # and from disk (in the source clone, then commit so git pull picks it up)
    local m="$SOURCE_CLONE/.claude-plugin/marketplace.json"
    jq '.plugins |= map(select(.name != "plugin-with-skill"))' "$m" > "$m.tmp"
    mv "$m.tmp" "$m"
    rm -rf "$SOURCE_CLONE/plugin-with-skill"
    (
        cd "$SOURCE_CLONE"
        git -c user.email=test@test -c user.name=test add -A
        git -c user.email=test@test -c user.name=test commit -q -m "remove plugin"
    )

    run bash "$REFRESH_SH"
    [ "$status" -eq 0 ]

    # The stale symlink is gone
    [ ! -e "$AGENTS_SKILLS_DIR/plugin-with-skill" ]
    [ "$(agents_skills_count)" = "2" ]
}

@test "refresh.sh skips reset when source clone has local edits" {
    make_source_clone marketplace-minimal.json
    echo "operator edit" >> "$SOURCE_CLONE/plugin-with-skill/SKILL.md"

    run bash "$REFRESH_SH"
    [ "$status" -eq 0 ]
    [[ "$output" == *"local edits"* ]]
    grep -q "operator edit" "$SOURCE_CLONE/plugin-with-skill/SKILL.md"
}

@test "refresh.sh records symlink sync failures for self-learning" {
    make_source_clone marketplace-minimal.json
    mkdir -p "$SOURCE_CLONE/legion-observability/bin"
    cat > "$SOURCE_CLONE/scripts/install.sh" <<'SH'
#!/usr/bin/env bash
exit 1
SH
    cat > "$SOURCE_CLONE/legion-observability/bin/legion-self-learn" <<'SH'
#!/usr/bin/env bash
printf 'self-learn %s\n' "$*" >> "$MOCK_CALL_LOG"
SH
    chmod +x "$SOURCE_CLONE/scripts/install.sh" "$SOURCE_CLONE/legion-observability/bin/legion-self-learn"

    run bash "$REFRESH_SH"
    [ "$status" -eq 0 ]
    [[ "$output" == *"symlink sync had warnings"* ]]
    grep -qF "Daily refresh symlink/Cursor bridge sync failed." "$MOCK_CALL_LOG"
}

@test "refresh.sh calls claude plugin marketplace update (best-effort)" {
    make_source_clone marketplace-minimal.json
    bash "$INSTALL_SH" --refresh-symlinks

    run bash "$REFRESH_SH"
    [ "$status" -eq 0 ]
    assert_mock_called claude "marketplace update legion"
}

@test "refresh.sh runs daily self-learning memory loop when present" {
    make_source_clone marketplace-minimal.json
    mkdir -p "$SOURCE_CLONE/legion-observability/bin"
    cat > "$SOURCE_CLONE/legion-observability/bin/legion-self-learn" <<'SH'
#!/usr/bin/env bash
printf 'self-learn %s\n' "$*" >> "$MOCK_CALL_LOG"
SH
    chmod +x "$SOURCE_CLONE/legion-observability/bin/legion-self-learn"
    (
        cd "$SOURCE_CLONE"
        git -c user.email=test@test -c user.name=test add -A
        git -c user.email=test@test -c user.name=test commit -q -m "add self learn"
    )

    run bash "$REFRESH_SH"
    [ "$status" -eq 0 ]
    grep -qF "self-learn run --repo $SOURCE_CLONE --apply-memory --quiet" "$MOCK_CALL_LOG"
}

@test "refresh.sh records session feedback before self-learning" {
    make_source_clone marketplace-minimal.json
    mkdir -p "$SOURCE_CLONE/legion-observability/bin"
    cat > "$SOURCE_CLONE/legion-observability/bin/legion-session-learn" <<'SH'
#!/usr/bin/env bash
printf 'session-learn %s\n' "$*" >> "$MOCK_CALL_LOG"
SH
    cat > "$SOURCE_CLONE/legion-observability/bin/legion-self-learn" <<'SH'
#!/usr/bin/env bash
printf 'self-learn %s\n' "$*" >> "$MOCK_CALL_LOG"
SH
    chmod +x \
        "$SOURCE_CLONE/legion-observability/bin/legion-session-learn" \
        "$SOURCE_CLONE/legion-observability/bin/legion-self-learn"
    (
        cd "$SOURCE_CLONE"
        git -c user.email=test@test -c user.name=test add -A
        git -c user.email=test@test -c user.name=test commit -q -m "add learning bins"
    )

    run bash "$REFRESH_SH"
    [ "$status" -eq 0 ]
    grep -qF "session-learn --lookback-days 3 --max-file-mb 8 --record" "$MOCK_CALL_LOG"
    grep -qF "self-learn run --repo $SOURCE_CLONE --apply-memory --quiet" "$MOCK_CALL_LOG"

    session_line="$(grep -nF "session-learn --lookback-days" "$MOCK_CALL_LOG" | cut -d: -f1)"
    self_line="$(grep -nF "self-learn run --repo" "$MOCK_CALL_LOG" | cut -d: -f1)"
    [ "$session_line" -lt "$self_line" ]
}

@test "refresh.sh records self-learning failures" {
    make_source_clone marketplace-minimal.json
    mkdir -p "$SOURCE_CLONE/legion-observability/bin"
    cat > "$SOURCE_CLONE/legion-observability/bin/legion-self-learn" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "run" ]; then
    exit 1
fi
printf 'self-learn %s\n' "$*" >> "$MOCK_CALL_LOG"
SH
    chmod +x "$SOURCE_CLONE/legion-observability/bin/legion-self-learn"

    run bash "$REFRESH_SH"
    [ "$status" -eq 0 ]
    [[ "$output" == *"self-learning loop failed"* ]]
    grep -qF "Daily self-learning loop failed." "$MOCK_CALL_LOG"
}

@test "refresh.sh exits 2 when git fetch fails" {
    make_source_clone marketplace-minimal.json
    # Break the origin so git fetch fails
    (cd "$SOURCE_CLONE" && git remote set-url origin "/does/not/exist")

    run bash "$REFRESH_SH"
    [ "$status" -eq 2 ]
    [[ "$output" == *"git fetch failed"* ]] || [[ "$stderr" == *"git fetch failed"* ]] || true
}
