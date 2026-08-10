#!/usr/bin/env bats

load 'helpers/setup'

setup() {
    setup_test_env
    export LEGION_STATE_ROOT="$TEST_TMPDIR/state"
    export LEGION_TELEMETRY_DIR="$TEST_TMPDIR/spans"
    export LEGION_REGISTRY_DIR="$LEGION_STATE_ROOT/registry"
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
    MOCK_CONTEXT_LOG="$context" run "$LEGION_CLAUDE" run --task "do the thing" \
      --archetype final-review --repo "$repo" --quiet
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.status == "ok"'
    echo "$output" | jq -e '.executor == "claude"'
    echo "$output" | jq -e '.result == "CLAUDE_OK_OUTPUT"'
    echo "$output" | jq -e '.fell_back == false'

    run bash -c "cat '$LEGION_TELEMETRY_DIR'/*.jsonl | jq -r '[.executor, .archetype] | @tsv'"
    [ "$status" -eq 0 ]
    [ "$output" = $'claude\tfinal-review' ]
    grep -Eq '^claude active=1 executor=1 depth=[1-9][0-9]* run=.+$' "$context"
}

@test "legion-claude: adopts a preallocated run id and closes its queued lifecycle" {
    local repo; repo="$(make_test_repo adopted-id)"
    local run_id="queued-slice-claude"
    mkdir -p "$LEGION_REGISTRY_DIR"
    jq -cn --arg run "$run_id" --arg repo "$repo" '
      {schema:"legion.run-state.v1",run_id:$run,trace_id:"fanout-trace",
       parent_id:"fanout-root",kind:"run",state_version:1,repo_root:$repo,
       lifecycle:{phase:"queued",started_at:"",updated_at:"2026-07-31T10:25:17Z"}}
    ' > "$LEGION_REGISTRY_DIR/$run_id.json"

    LEGION_TRACE_ID=fanout-trace LEGION_PARENT_ID=fanout-root \
      run "$LEGION_CLAUDE" run --task "do the thing" --repo "$repo" \
        --run-id "$run_id" --quiet

    [ "$status" -eq 0 ]
    echo "$output" | jq -e --arg run "$run_id" \
      '.run_id == $run and (.diff_path | endswith("/" + $run + "/diff.patch"))'
    jq -e '
      .run_id == "queued-slice-claude"
      and .trace_id == "fanout-trace"
      and .parent_id == "fanout-root"
      and .state_version >= 3
      and .lifecycle.phase == "ok"
      and (.lifecycle.started_at | length > 0)
    ' "$LEGION_REGISTRY_DIR/$run_id.json"
    run bash -c "cat '$LEGION_TELEMETRY_DIR'/*.jsonl | jq -e 'select(.executor == \"claude\" and .run_id == \"$run_id\")'"
    [ "$status" -eq 0 ]
}

@test "legion-claude: preserves a preallocated run id through Codex fallback" {
    local repo; repo="$(make_test_repo adopted-fallback)"
    local run_id="queued-fallback-claude"
    mkdir -p "$LEGION_REGISTRY_DIR"
    jq -cn --arg run "$run_id" --arg repo "$repo" '
      {schema:"legion.run-state.v1",run_id:$run,trace_id:"fanout-trace",
       parent_id:"fanout-root",kind:"run",state_version:1,repo_root:$repo,
       lifecycle:{phase:"queued",started_at:"",updated_at:"2026-07-31T10:25:17Z"}}
    ' > "$LEGION_REGISTRY_DIR/$run_id.json"

    LEGION_TRACE_ID=fanout-trace LEGION_PARENT_ID=fanout-root MOCK_CLAUDE_LIMIT=1 \
      run "$LEGION_CLAUDE" run --task "do the thing" --repo "$repo" \
        --run-id "$run_id" --quiet

    [ "$status" -eq 0 ]
    echo "$output" | jq -e --arg run "$run_id" \
      '.run_id == $run and .executor == "codex" and .fell_back == true'
    assert_mock_called legion-delegate "--run-id $run_id"
    jq -e '
      .run_id == "queued-fallback-claude"
      and .state_version >= 3
      and .lifecycle.phase == "ok"
    ' "$LEGION_REGISTRY_DIR/$run_id.json"
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

@test "legion-claude: read-only sandbox uses plan mode" {
    local repo; repo="$(make_test_repo readonly-plan)"
    run "$LEGION_CLAUDE" run --task "inspect only" --repo "$repo" \
        --sandbox read-only --quiet
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.status == "ok"'
    assert_mock_called claude "--permission-mode plan"
}

@test "legion-claude: read-only sandbox rejects unexpected writes without fallback" {
    local repo; repo="$(make_test_repo readonly-write)"
    MOCK_CLAUDE_WRITE=1 run "$LEGION_CLAUDE" run --task "inspect only" --repo "$repo" \
        --sandbox read-only --apply --quiet
    [ "$status" -eq 1 ]
    echo "$output" | jq -e \
        '.status == "failed" and .reason == "read_only_violation" and .fell_back == false'
    [ ! -e "$repo/claude-unexpected.txt" ]
    assert_mock_not_called legion-delegate
}

@test "legion-claude: usage limit falls back to codex" {
    local repo; repo="$(make_test_repo fb1)"
    local base; base="$(git -C "$repo" rev-parse HEAD)"
    MOCK_CLAUDE_LIMIT=1 run "$LEGION_CLAUDE" run --task "do the thing" --repo "$repo" \
        --sandbox read-only --base "$base" --archetype final-review --quiet
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.status == "ok"'
    echo "$output" | jq -e '.executor == "codex"'
    echo "$output" | jq -e '.result == "GPT_FALLBACK"'
    echo "$output" | jq -e '.fell_back == true'
    echo "$output" | jq -e '.fell_back_reason == "claude_limit"'
    run bash -c "cat '$LEGION_TELEMETRY_DIR'/*.jsonl | jq -s \
      '[.[] | select(.executor == \"claude\" and .status == \"blocked\")] | length'"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
    run bash -c "cat '$LEGION_TELEMETRY_DIR'/*.jsonl | jq -e \
      'select(.executor == \"claude\" and .archetype == \"final-review\")'"
    [ "$status" -eq 0 ]
    assert_mock_called legion-delegate "--sandbox read-only"
    assert_mock_called legion-delegate "--base $base"
    assert_mock_called legion-delegate "--executor codex"
    assert_mock_called legion-delegate "--archetype final-review"
}

@test "legion-claude: direct adapter refuses delegated executor context" {
    local repo; repo="$(make_test_repo nested)"
    LEGION_EXECUTOR=1 run "$LEGION_CLAUDE" run --task "do the thing" --repo "$repo" --quiet
    [ "$status" -eq 2 ]
    [[ "$output" == *"nested Legion delegation is blocked"* ]]
    assert_mock_not_called claude
    assert_mock_not_called legion-delegate
}

@test "legion-claude: missing claude on PATH falls back directly" {
    local repo; repo="$(make_test_repo fb2)"
    local base; base="$(git -C "$repo" rev-parse HEAD)"
    PATH="$(path_without claude)" run "$LEGION_CLAUDE" run --task "do the thing" --repo "$repo" \
        --sandbox read-only --base "$base" --quiet
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.executor == "codex"'
    echo "$output" | jq -e '.fell_back == true'
    echo "$output" | jq -e '.fell_back_reason == "claude_unavailable"'
    assert_mock_called legion-delegate "--sandbox read-only"
    assert_mock_called legion-delegate "--base $base"
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
    local run_id="queued-claude-non-git"
    mkdir -p "$repo"
    mkdir -p "$LEGION_REGISTRY_DIR"
    jq -cn --arg run "$run_id" --arg repo "$repo" '
      {schema:"legion.run-state.v1",run_id:$run,trace_id:"fanout-trace",
       parent_id:"fanout-root",kind:"run",state_version:1,repo_root:$repo,
       lifecycle:{phase:"queued",started_at:"",updated_at:"2026-07-31T10:25:17Z"}}
    ' > "$LEGION_REGISTRY_DIR/$run_id.json"

    run "$LEGION_CLAUDE" run --task "do the thing" --repo "$repo" \
      --run-id "$run_id" --quiet
    [ "$status" -eq 1 ]
    echo "$output" | jq -e \
        '.status == "failed" and .reason == "worktree_setup_failed" and .fell_back == false'
    assert_mock_not_called claude
    jq -e '
      .run_id == "queued-claude-non-git"
      and .state_version >= 2
      and .lifecycle.phase == "failed"
    ' "$LEGION_REGISTRY_DIR/$run_id.json"
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
