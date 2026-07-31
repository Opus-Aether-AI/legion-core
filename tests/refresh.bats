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

@test "refresh.sh defaults to the latest stable release tag instead of main" {
    make_source_clone marketplace-minimal.json
    (
        cd "$SOURCE_CLONE"
        printf 'main-only change\n' > main-only.txt
        git add main-only.txt
        git -c user.email=test@test -c user.name=test commit -q -m "main only"
    )
    local release_sha="$(git -C "$SOURCE_CLONE" rev-parse v0.0.0-test)"
    export MOCK_RELEASE_TAG=v0.0.0-test

    run bash "$REFRESH_SH"
    [ "$status" -eq 0 ]
    [ "$(git -C "$SOURCE_CLONE" rev-parse HEAD)" = "$release_sha" ]
}

@test "refresh.sh fails closed when no safe latest release can be resolved" {
    make_source_clone marketplace-minimal.json
    export MOCK_RELEASE_RESPONSE='{}'

    run bash "$REFRESH_SH"
    [ "$status" -eq 2 ]
    [[ "$output" == *"must be an exact v-prefixed semantic version tag"* ]]
}

@test "refresh.sh rejects a non-version latest release response" {
    make_source_clone marketplace-minimal.json
    export MOCK_RELEASE_TAG=main

    run bash "$REFRESH_SH"
    [ "$status" -eq 2 ]
    [[ "$output" == *"must be an exact v-prefixed semantic version tag"* ]]
}

@test "refresh.sh rejects invalid explicit SemVer before using it as a Git ref" {
    make_source_clone marketplace-minimal.json

    LEGION_UPDATE_REF=v1.2.3-01 run bash "$REFRESH_SH"
    [ "$status" -eq 2 ]
    [[ "$output" == *"release ref must be main or an exact"* ]]
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

    LEGION_UPDATE_REF=main run bash "$REFRESH_SH"
    [ "$status" -eq 0 ]

    # The stale symlink is gone
    [ ! -e "$AGENTS_SKILLS_DIR/plugin-with-skill" ]
    [ "$(agents_skills_count)" = "2" ]
}

@test "refresh.sh advances a release-tag clone without origin/main" {
    make_source_clone marketplace-minimal.json
    (
        cd "$SOURCE_CLONE"
        git tag v0.0.1-test
        git config --unset-all remote.origin.fetch
        git config --add remote.origin.fetch '+refs/tags/v0.0.1-test:refs/tags/v0.0.1-test'
        git update-ref -d refs/remotes/origin/main
    )
    export MOCK_RELEASE_TAG=v0.0.1-test

    run bash "$REFRESH_SH"
    [ "$status" -eq 0 ]
    [ "$(git -C "$SOURCE_CLONE" rev-parse HEAD)" = "$(git -C "$SOURCE_CLONE" rev-parse main)" ]
}

@test "refresh.sh fetches an exact version tag when a branch has the same name" {
    make_source_clone marketplace-minimal.json
    make_ambiguous_release_ref
    local tag_sha
    tag_sha="$(git -C "$SOURCE_CLONE" rev-parse refs/tags/v0.0.1-test)"

    LEGION_UPDATE_REF=v0.0.1-test run bash "$REFRESH_SH"
    [ "$status" -eq 0 ]
    [ "$(git -C "$SOURCE_CLONE" rev-parse HEAD)" = "$tag_sha" ]
    [ ! -e "$SOURCE_CLONE/ambiguous-branch-only.txt" ]
}

@test "refresh.sh preserves tracked edits, skips reconciliation, and exits incomplete" {
    make_source_clone marketplace-minimal.json
    echo "operator edit" >> "$SOURCE_CLONE/plugin-with-skill/SKILL.md"

    run bash "$REFRESH_SH"
    [ "$status" -eq 3 ]
    [[ "$output" == *"skipped reconciliation"* ]]
    grep -q "operator edit" "$SOURCE_CLONE/plugin-with-skill/SKILL.md"
    assert_mock_not_called claude
}

@test "refresh.sh preserves untracked files, skips reconciliation, and exits incomplete" {
    make_source_clone marketplace-minimal.json
    printf 'operator notes\n' > "$SOURCE_CLONE/operator-notes.txt"

    run bash "$REFRESH_SH"
    [ "$status" -eq 3 ]
    [[ "$output" == *"untracked files"* ]]
    grep -q "operator notes" "$SOURCE_CLONE/operator-notes.txt"
    assert_mock_not_called claude
}

@test "refresh.sh preserves an ignored checkout collision and skips reconciliation" {
    make_source_clone marketplace-minimal.json
    make_ignored_checkout_collision

    LEGION_UPDATE_REF=v0.0.1-test run bash "$REFRESH_SH"
    [ "$status" -eq 3 ]
    [[ "$output" == *"would overwrite local files"* ]]
    [ "$(cat "$SOURCE_CLONE/release-collision.txt")" = "operator content" ]
    assert_mock_not_called claude
}

@test "refresh.sh fails closed when Git cannot inspect source status" {
    make_source_clone marketplace-minimal.json
    local failing_git
    failing_git="$(make_failing_git_wrapper status)"

    PATH="$failing_git:$PATH" run bash "$REFRESH_SH"
    [ "$status" -eq 3 ]
    [[ "$output" == *"could not inspect source clone state"* ]]
    assert_mock_not_called claude
}

@test "refresh.sh rejects a fetched object that cannot resolve to a commit" {
    make_source_clone marketplace-minimal.json
    local failing_git
    failing_git="$(make_failing_git_wrapper rev-parse)"

    PATH="$failing_git:$PATH" run bash "$REFRESH_SH"
    [ "$status" -eq 2 ]
    [[ "$output" == *"fetched ref is not a commit"* ]]
    assert_mock_not_called claude
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
    (
        cd "$SOURCE_CLONE"
        git -c user.email=test@test -c user.name=test add -A
        git -c user.email=test@test -c user.name=test commit -q -m "add failing sync"
    )

    LEGION_UPDATE_REF=main run bash "$REFRESH_SH"
    [ "$status" -eq 0 ]
    [[ "$output" == *"symlink sync had warnings"* ]]
    grep -qF "Daily refresh symlink/Cursor bridge sync failed." "$MOCK_CALL_LOG"
}

@test "refresh.sh calls claude plugin marketplace update" {
    make_source_clone marketplace-minimal.json
    bash "$INSTALL_SH" --refresh-symlinks

    run bash "$REFRESH_SH"
    [ "$status" -eq 0 ]
    assert_mock_called claude "marketplace add Opus-Aether-AI/legion-core@v0.0.0-test"
    assert_mock_called claude "marketplace update legion"
}

@test "refresh.sh fails when the Claude marketplace cannot be rebound to the stable tag" {
    make_source_clone marketplace-minimal.json
    export MOCK_CLAUDE_MARKETPLACE_ADD_FAIL=1

    run bash "$REFRESH_SH"
    [ "$status" -ne 0 ]
    [[ "$output" == *"could not bind Claude marketplace"* ]]
    [[ "$output" == *"plugin reconciliation failed"* ]]
}

@test "refresh.sh updates each installed Legion plugin after refreshing the marketplace" {
    make_source_clone marketplace-minimal.json
    bash "$INSTALL_SH" all --no-cron
    : > "$MOCK_CALL_LOG"

    run bash "$REFRESH_SH"
    [ "$status" -eq 0 ]
    assert_mock_called claude "plugin update plugin-with-skill@legion-core"
    assert_mock_called claude "plugin update plugin-nested@legion-core"
    assert_mock_called claude "plugin update plugin-claude-only@legion-core"
}

@test "refresh.sh fails when an installed Legion plugin cannot be updated" {
    make_source_clone marketplace-minimal.json
    bash "$INSTALL_SH" all --no-cron
    export MOCK_CLAUDE_UPDATE_FAIL=1

    run bash "$REFRESH_SH"
    [ "$status" -ne 0 ]
    [[ "$output" == *"plugin reconciliation failed"* ]]
}

@test "refresh.sh fails when an installed Legion plugin remains version-drifted" {
    make_source_clone marketplace-minimal.json
    bash "$INSTALL_SH" all --no-cron
    rm -rf "$HOME/.claude/plugins/cache/legion-core"/*/0.1.0
    export MOCK_CLAUDE_PLUGIN_VERSION=0.0.9

    run bash "$REFRESH_SH"
    [ "$status" -ne 0 ]
    [[ "$output" == *"is not at marketplace version"* ]]
}

@test "refresh.sh fails when the Claude marketplace cannot be refreshed" {
    make_source_clone marketplace-minimal.json
    export MOCK_CLAUDE_MARKETPLACE_UPDATE_FAIL=1

    run bash "$REFRESH_SH"
    [ "$status" -ne 0 ]
    [[ "$output" == *"plugin reconciliation failed"* ]]
}

@test "refresh.sh does not require absent Legion plugins to be installed" {
    make_source_clone marketplace-minimal.json

    run bash "$REFRESH_SH"
    [ "$status" -eq 0 ]
    if grep -F 'claude plugin update ' "$MOCK_CALL_LOG"; then false; fi
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

    LEGION_UPDATE_REF=main run bash "$REFRESH_SH"
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

    LEGION_UPDATE_REF=main run bash "$REFRESH_SH"
    [ "$status" -eq 0 ]
    grep -qF "session-learn --repo $SOURCE_CLONE --lookback-days 3 --session-limit 100 --max-file-mb 8 --record" "$MOCK_CALL_LOG"
    grep -qF "self-learn run --repo $SOURCE_CLONE --apply-memory --quiet" "$MOCK_CALL_LOG"

    session_line="$(grep -nF "session-learn --repo" "$MOCK_CALL_LOG" | cut -d: -f1)"
    self_line="$(grep -nF "self-learn run --repo" "$MOCK_CALL_LOG" | cut -d: -f1)"
    [ "$session_line" -lt "$self_line" ]
}

@test "refresh.sh records session feedback failures and continues" {
    make_source_clone marketplace-minimal.json
    mkdir -p "$SOURCE_CLONE/legion-observability/bin"
    cat > "$SOURCE_CLONE/legion-observability/bin/legion-session-learn" <<'SH'
#!/usr/bin/env bash
exit 1
SH
    cat > "$SOURCE_CLONE/legion-observability/bin/refresh-recorder" <<'SH'
#!/usr/bin/env bash
printf 'refresh-record %s\n' "$*" >> "$MOCK_CALL_LOG"
SH
    chmod +x \
        "$SOURCE_CLONE/legion-observability/bin/legion-session-learn" \
        "$SOURCE_CLONE/legion-observability/bin/refresh-recorder"
    (
        cd "$SOURCE_CLONE"
        git -c user.email=test@test -c user.name=test add -A
        git -c user.email=test@test -c user.name=test commit -q -m "add failing session learner"
    )

    LEGION_UPDATE_REF=main \
        LEGION_SELF_LEARN_BIN="$SOURCE_CLONE/legion-observability/bin/refresh-recorder" \
        run bash "$REFRESH_SH"
    [ "$status" -eq 0 ]
    [[ "$output" == *"session learning scan failed"* ]]
    grep -qF "Daily session learning scan failed." "$MOCK_CALL_LOG"
}

@test "refresh.sh reports doctor and opt-in auto-heal failures without clobbering the refresh" {
    make_source_clone marketplace-minimal.json
    mkdir -p "$SOURCE_CLONE/legion-observability/bin"
    cat > "$SOURCE_CLONE/legion-observability/bin/legion-doctor" <<'SH'
#!/usr/bin/env bash
exit 1
SH
    cat > "$SOURCE_CLONE/legion-observability/bin/legion-heal" <<'SH'
#!/usr/bin/env bash
exit 1
SH
    chmod +x \
        "$SOURCE_CLONE/legion-observability/bin/legion-doctor" \
        "$SOURCE_CLONE/legion-observability/bin/legion-heal"
    (
        cd "$SOURCE_CLONE"
        git -c user.email=test@test -c user.name=test add -A
        git -c user.email=test@test -c user.name=test commit -q -m "add failing health tools"
    )

    LEGION_UPDATE_REF=main LEGION_HEAL=1 run bash "$REFRESH_SH"
    [ "$status" -eq 0 ]
    [[ "$output" == *"legion-doctor found issues"* ]]
    [[ "$output" == *"auto-heal had failures"* ]]
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
    (
        cd "$SOURCE_CLONE"
        git -c user.email=test@test -c user.name=test add -A
        git -c user.email=test@test -c user.name=test commit -q -m "add failing self learn"
    )

    LEGION_UPDATE_REF=main run bash "$REFRESH_SH"
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
