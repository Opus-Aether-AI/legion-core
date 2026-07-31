#!/usr/bin/env bats

load 'helpers/setup'

setup() {
    setup_test_env
    export LEGION_STATE_ROOT="$TEST_TMPDIR/state"
    export LEGION_TELEMETRY_DIR="$TEST_TMPDIR/spans"
    export LEGION_REGISTRY_DIR="$LEGION_STATE_ROOT/registry"
    export LEGION_CURSOR="$REPO_ROOT/legion-router/bin/legion-cursor"
    CURSOR_DEFAULT="$("$REPO_ROOT/legion-router/bin/legion-route" --model-ref cursor_default)"
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

@test "legion-cursor: happy path uses Cursor Agent, captures diff, emits span" {
    local repo; repo="$(make_test_repo ok1)"
    local context="$TEST_TMPDIR/context.log"
    MOCK_CONTEXT_LOG="$context" run "$LEGION_CURSOR" run --task "do the thing" --repo "$repo" --quiet
    [ "$status" -eq 0 ]
    echo "$output" | jq -e --arg model "$CURSOR_DEFAULT" '.status == "ok" and .executor == "cursor" and .model == $model'
    local diff; diff="$(echo "$output" | jq -r .diff_path)"
    [ -s "$diff" ]
    grep -q "MOCK_CURSOR_CHANGE" "$diff"
    assert_mock_called agent "-p --output-format json --trust --force --model $CURSOR_DEFAULT"

    run bash -c "cat '$LEGION_TELEMETRY_DIR'/*.jsonl | jq -r .executor"
    [ "$output" = "cursor" ]
    grep -Eq '^agent active=1 executor=1 depth=[1-9][0-9]* run=.+$' "$context"
}

@test "legion-cursor: adopts a preallocated run id and closes its queued lifecycle" {
    local repo; repo="$(make_test_repo adopted-id)"
    local run_id="queued-slice-cursor"
    mkdir -p "$LEGION_REGISTRY_DIR"
    jq -cn --arg run "$run_id" --arg repo "$repo" '
      {schema:"legion.run-state.v1",run_id:$run,trace_id:"fanout-trace",
       parent_id:"fanout-root",kind:"run",state_version:1,repo_root:$repo,
       lifecycle:{phase:"queued",started_at:"",updated_at:"2026-07-31T10:25:17Z"}}
    ' > "$LEGION_REGISTRY_DIR/$run_id.json"

    LEGION_TRACE_ID=fanout-trace LEGION_PARENT_ID=fanout-root \
      run "$LEGION_CURSOR" run --task "do the thing" --repo "$repo" \
        --run-id "$run_id" --quiet

    [ "$status" -eq 0 ]
    echo "$output" | jq -e --arg run "$run_id" \
      '.run_id == $run and (.diff_path | endswith("/" + $run + "/diff.patch"))'
    jq -e '
      .run_id == "queued-slice-cursor"
      and .trace_id == "fanout-trace"
      and .parent_id == "fanout-root"
      and .state_version >= 3
      and .lifecycle.phase == "ok"
      and (.lifecycle.started_at | length > 0)
    ' "$LEGION_REGISTRY_DIR/$run_id.json"
    run bash -c "cat '$LEGION_TELEMETRY_DIR'/*.jsonl | jq -e 'select(.executor == \"cursor\" and .run_id == \"$run_id\")'"
    [ "$status" -eq 0 ]
}

@test "legion-cursor: closes a preallocated lifecycle when worktree setup fails" {
    local repo; repo="$(make_test_repo worktree-fail)"
    local run_id="queued-cursor-worktree-fail"
    mkdir -p "$LEGION_REGISTRY_DIR"
    jq -cn --arg run "$run_id" --arg repo "$repo" '
      {schema:"legion.run-state.v1",run_id:$run,trace_id:"fanout-trace",
       parent_id:"fanout-root",kind:"run",state_version:1,repo_root:$repo,
       lifecycle:{phase:"queued",started_at:"",updated_at:"2026-07-31T10:25:17Z"}}
    ' > "$LEGION_REGISTRY_DIR/$run_id.json"
    git -C "$repo" branch "legion/cursor-$run_id"

    LEGION_TRACE_ID=fanout-trace LEGION_PARENT_ID=fanout-root \
      run "$LEGION_CURSOR" run --task "do the thing" --repo "$repo" \
        --run-id "$run_id" --quiet

    [ "$status" -eq 2 ]
    [[ "$output" == *"worktree add failed"* ]]
    jq -e '
      .run_id == "queued-cursor-worktree-fail"
      and .trace_id == "fanout-trace"
      and .parent_id == "fanout-root"
      and .state_version >= 2
      and .lifecycle.phase == "failed"
    ' "$LEGION_REGISTRY_DIR/$run_id.json"
}

@test "legion-cursor: read-only sandbox does not force writes" {
    local repo; repo="$(make_test_repo ro1)"
    run "$LEGION_CURSOR" run --task "inspect only" --repo "$repo" --sandbox read-only --quiet
    [ "$status" -eq 0 ]
    assert_mock_called agent "-p --output-format json --trust --mode plan --model $CURSOR_DEFAULT inspect only"
    [ ! -s "$(echo "$output" | jq -r .diff_path)" ]
}

@test "legion-cursor: read-only sandbox rejects unexpected writes" {
    local repo; repo="$(make_test_repo ro-write)"
    MOCK_CURSOR_WRITE_IN_PLAN=1 run "$LEGION_CURSOR" run --task "inspect only" \
        --repo "$repo" --sandbox read-only --apply --quiet
    [ "$status" -eq 1 ]
    echo "$output" | jq -e '.status == "error"'
    [ ! -f "$repo/MOCK_CURSOR_CHANGE.txt" ]
    run bash -c "cat '$LEGION_TELEMETRY_DIR'/*.jsonl | jq -r .status"
    [ "$output" = "error" ]
}

@test "legion-cursor: --apply applies the captured diff to the repo" {
    local repo; repo="$(make_test_repo app1)"
    run "$LEGION_CURSOR" run --task "edit" --repo "$repo" --apply --quiet
    [ "$status" -eq 0 ]
    [ -f "$repo/MOCK_CURSOR_CHANGE.txt" ]
}

@test "legion-cursor: write runs reject dangerous task text" {
    local repo; repo="$(make_test_repo danger1)"
    run "$LEGION_CURSOR" run --task "rm -rf / and git push --force" --repo "$repo" --quiet
    [ "$status" -eq 2 ]
    [[ "$output" == *"dangerous/injection"* ]]
    assert_mock_not_called agent
}

@test "legion-cursor: direct adapter refuses delegated executor context" {
    local repo; repo="$(make_test_repo nested)"
    LEGION_DEPTH=1 run "$LEGION_CURSOR" run --task "do the thing" --repo "$repo" --quiet
    [ "$status" -eq 2 ]
    [[ "$output" == *"nested Legion delegation is blocked"* ]]
    assert_mock_not_called agent
}

@test "legion-cursor: missing Cursor Agent CLI fails clearly" {
    local repo; repo="$(make_test_repo miss1)"
    PATH="$(path_without agent)" run "$LEGION_CURSOR" run --task "x" --repo "$repo" --quiet
    [ "$status" -eq 2 ]
    [[ "$output" == *"Cursor Agent CLI not found"* ]]
}
