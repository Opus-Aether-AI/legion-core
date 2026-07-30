#!/usr/bin/env bats

load 'helpers/setup'

setup() {
    setup_test_env
    export LEGION_TELEMETRY_DIR="$TEST_TMPDIR/spans"
    export LEGION_COSTS_FILE="$REPO_ROOT/legion-router/config/costs.json"
    export LEGION_CLAUDE="$REPO_ROOT/legion-router/bin/legion-claude"
    CLAUDE_DEFAULT="$("$REPO_ROOT/legion-router/bin/legion-route" --model-ref claude_default)"
}

make_test_repo() {
    local d="$TEST_TMPDIR/repo-${1:-a}"
    mkdir -p "$d"
    git -C "$d" init -q
    git -C "$d" config user.email t@t.c
    git -C "$d" config user.name t
    printf 'export const value = 1\n' > "$d/foo.ts"
    git -C "$d" add -A
    git -C "$d" -c user.email=t@t.c -c user.name=t commit -qm init
    echo "$d"
}

@test "legion-claude: happy path uses claude and emits a claude span" {
    local repo; repo="$(make_test_repo ok1)"
    local context="$TEST_TMPDIR/context.log"
    MOCK_CONTEXT_LOG="$context" run "$LEGION_CLAUDE" run --task "do the thing" --repo "$repo" --quiet
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.status == "ok"'
    echo "$output" | jq -e '.executor == "claude"'
    echo "$output" | jq -e '.result == "CLAUDE_OK_OUTPUT"'
    echo "$output" | jq -e '.fell_back == false'

    run bash -c "cat '$LEGION_TELEMETRY_DIR'/*.jsonl | jq -r .executor"
    [ "$status" -eq 0 ]
    [ "$output" = "claude" ]
    grep -Eq '^claude active=1 executor=1 depth=[1-9][0-9]* run=.+$' "$context"
}

@test "legion-claude: passes --effort/--append-system-prompt/--dangerously-skip-permissions through to claude" {
    local repo; repo="$(make_test_repo passthru)"
    run "$LEGION_CLAUDE" run --task "do it" --repo "$repo" \
        --effort high --append-system-prompt "be safe" --dangerously-skip-permissions --quiet
    [ "$status" -eq 0 ]
    assert_mock_called claude "--effort high"
    assert_mock_called claude "--append-system-prompt be safe"
    assert_mock_called claude "--dangerously-skip-permissions"
}

@test "legion-claude: usage limit falls back to codex" {
    local repo; repo="$(make_test_repo fb1)"
    MOCK_CLAUDE_LIMIT=1 run "$LEGION_CLAUDE" run --task "do the thing" --repo "$repo" --quiet
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.status == "ok"'
    echo "$output" | jq -e '.executor == "codex"'
    echo "$output" | jq -e '.result == "GPT_FALLBACK"'
    echo "$output" | jq -e '.fell_back == true'
    echo "$output" | jq -e '.fell_back_reason == "claude_limit"'
}

@test "legion-claude: missing claude on PATH falls back directly" {
    local repo; repo="$(make_test_repo fb2)"
    PATH="$(path_without claude)" run "$LEGION_CLAUDE" run --task "do the thing" --repo "$repo" --quiet
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.executor == "codex"'
    echo "$output" | jq -e '.fell_back == true'
    echo "$output" | jq -e '.fell_back_reason == "claude_unavailable"'
}

@test "legion-claude: LEGION_LOW_CREDIT=claude skips claude entirely" {
    local repo; repo="$(make_test_repo fb3)"
    LEGION_LOW_CREDIT=claude run "$LEGION_CLAUDE" run --task "do the thing" --repo "$repo" --quiet
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.executor == "codex"'
    echo "$output" | jq -e '.fell_back_reason == "claude_unavailable"'
    assert_mock_not_called claude
}

@test "legion-claude: worktree setup failure fails closed before invoking Claude" {
    local repo; repo="$(make_test_repo worktree-fail)"
    run "$LEGION_CLAUDE" run --task "do the thing" --repo "$repo" \
        --base "refs/does-not-exist" --quiet
    [ "$status" -eq 1 ]
    echo "$output" | jq -e \
        '.status == "failed" and .reason == "worktree_setup_failed" and .fell_back == false'
    assert_mock_not_called claude
    assert_mock_not_called legion-delegate
    run bash -c "cat '$LEGION_TELEMETRY_DIR'/*.jsonl | jq -e 'select(.executor == \"claude\" and .status == \"failed\")'"
    [ "$status" -eq 0 ]
}

@test "legion-claude: non-git repo fails closed before invoking Claude" {
    local repo="$TEST_TMPDIR/not-git"
    mkdir -p "$repo"
    run "$LEGION_CLAUDE" run --task "do the thing" --repo "$repo" --quiet
    [ "$status" -eq 1 ]
    echo "$output" | jq -e \
        '.status == "failed" and .reason == "worktree_setup_failed" and .fell_back == false'
    assert_mock_not_called claude
}

@test "legion-claude: --no-fallback blocks on usage limit" {
    local repo; repo="$(make_test_repo blk1)"
    MOCK_CLAUDE_LIMIT=1 run "$LEGION_CLAUDE" run --task "do the thing" --repo "$repo" --quiet --no-fallback
    [ "$status" -eq 1 ]
    echo "$output" | jq -e '.status == "blocked"'
    echo "$output" | jq -e '.reason == "claude_limit"'
    echo "$output" | jq -e '.fell_back == false'
}

@test "legion-claude: reads task from stdin when --task omitted" {
    local repo; repo="$(make_test_repo stdin1)"
    run bash -c "printf 'stdin task' | '$LEGION_CLAUDE' run --repo '$repo' --quiet"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.status == "ok"'
    assert_mock_called claude "output-format json --model $CLAUDE_DEFAULT"
}
