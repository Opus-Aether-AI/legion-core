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
    echo "$output" | jq -e --arg model "$CURSOR_DEFAULT" '
      .status == "ok" and .executor == "cursor" and .model == $model
      and .usage_status == "known" and (.usage | type) == "object"
      and .cost_status == "known" and (.cost_usd | type) == "number"'
    jq -e '.schema == "legion.preflight.v1" and .status == "supported"' \
      "$(echo "$output" | jq -r .preflight_receipt)"
    local attempt span
    attempt="$(echo "$output" | jq -r .attempt_receipt)"
    jq -e '.schema == "legion.attempt.v1" and .terminal_status == "succeeded" and .usage_status == "known"' \
      "$attempt"
    local diff; diff="$(echo "$output" | jq -r .diff_path)"
    [ -s "$diff" ]
    grep -q "MOCK_CURSOR_CHANGE" "$diff"
    assert_mock_called agent "-p --output-format json --trust --force --model $CURSOR_DEFAULT"

    run bash -c "cat '$LEGION_TELEMETRY_DIR'/*.jsonl | jq -r .executor"
    [ "$output" = "cursor" ]
    span="$(cat "$LEGION_TELEMETRY_DIR"/*.jsonl | jq -c 'select(.executor == "cursor")')"
    jq -e --argjson attempt "$(cat "$attempt")" '
      .tokens == $attempt.usage and .usage_status == $attempt.usage_status
      and .cost_usd == $attempt.cost_usd and .cost_status == $attempt.cost_status
    ' <<<"$span"
    grep -Eq '^agent active=1 executor=1 depth=[1-9][0-9]* run=.+$' "$context"
}

@test "legion-cursor: provider failure reports unknown metering as nullable" {
    local repo; repo="$(make_test_repo failed-metering)"

    MOCK_CURSOR_FAIL=1 run "$LEGION_CURSOR" run --task "fail" --repo "$repo" --quiet

    [ "$status" -eq 1 ]
    echo "$output" | jq -e '
      .status == "failed"
      and .usage == null and .usage_status == "unknown"
      and .cost_usd == null and .cost_status == "unknown"'
}

@test "legion-cursor: terminal metering follows canonical normalization" {
    local repo attempt result
    repo="$(make_test_repo negative-metering)"

    MOCK_CURSOR_NEGATIVE_METERING=1 run "$LEGION_CURSOR" run \
      --task "do the thing" --repo "$repo" --quiet

    [ "$status" -eq 0 ]
    result="$(printf '%s\n' "$output" | tail -n 1)"
    echo "$result" | jq -e '.usage == null and .usage_status == "unknown"
      and .cost_usd == null and .cost_status == "unknown"'
    attempt="$(echo "$result" | jq -r .attempt_receipt)"
    jq -e --argjson terminal "$result" '
      .usage == $terminal.usage and .usage_status == $terminal.usage_status
      and .cost_usd == $terminal.cost_usd and .cost_status == $terminal.cost_status
    ' "$attempt"
}

@test "legion-cursor: resolves cursor-agent alias before shared preflight" {
    local repo alias_bin
    repo="$(make_test_repo cursor-agent-alias)"
    alias_bin="$TEST_TMPDIR/cursor-agent-only"
    mkdir -p "$alias_bin"
    cp "$BATS_TEST_DIRNAME/mocks/bin/agent" "$alias_bin/cursor-agent"
    chmod +x "$alias_bin/cursor-agent"

    PATH="$alias_bin:$(path_without agent)" run "$LEGION_CURSOR" run \
      --task "do the thing" --repo "$repo" --quiet

    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.status == "ok"'
    local resolved_alias; resolved_alias="$(cd "$alias_bin" && pwd -P)/cursor-agent"
    jq -e --arg binary "$resolved_alias" \
      '.schema == "legion.preflight.v1" and .identity.executable_path == $binary' \
      "$(echo "$output" | jq -r .preflight_receipt)"
    assert_mock_called agent "-p --output-format json"
}

@test "legion-cursor: timeout reaps a setsid child and terminalizes exactly once" {
    local repo run_id pid_file child attempt failure
    repo="$(make_test_repo lease-timeout)"
    run_id="cursor-lease-timeout"
    pid_file="$TEST_TMPDIR/cursor-lease-child.pid"

    MOCK_CURSOR_DELAY=30 MOCK_CURSOR_DETACH_DELAY=1 \
      MOCK_CURSOR_DELAY_PID_FILE="$pid_file" \
      run "$LEGION_CURSOR" run --task "wait forever" --repo "$repo" \
        --run-id "$run_id" --max-runtime-seconds 1 --keep --quiet

    [ "$status" -eq 1 ]
    echo "$output" | jq -e '
      .status == "timed_out"
      and (.reason | contains("child execution lease expired after 1 seconds"))
    '
    attempt="$(echo "$output" | jq -r .attempt_receipt)"
    failure="$(echo "$output" | jq -r .failure_receipt)"
    jq -e '.terminal_status == "timed_out" and .failure.class == "timed_out"' "$attempt"
    jq -e '.class == "timed_out" and .retryable == false' "$failure"
    [ "$(find "$(dirname "$attempt")" -name 'attempt-*.json' | wc -l | tr -d ' ')" -eq 1 ]
    [ "$(find "$(dirname "$attempt")" -name 'failure-*.json' | wc -l | tr -d ' ')" -eq 1 ]
    [ ! -d "$repo/.legion/worktrees/$run_id" ]
    ! git -C "$repo" show-ref --verify --quiet "refs/heads/legion/cursor-$run_id"
    jq -e '.lifecycle.phase == "timed_out"' "$LEGION_REGISTRY_DIR/$run_id.json"
    child="$(cat "$pid_file")"
    ! kill -0 "$child" 2>/dev/null
    cat "$LEGION_TELEMETRY_DIR"/*.jsonl | jq -e 'select(.status == "timed_out")'
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
    # The terminal envelope uses `error`, while the receipt-bound provider
    # span uses the canonical failed attempt outcome.
    [ "$output" = "failed" ]
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
    local run_id="queued-cursor-missing-cli"
    mkdir -p "$LEGION_REGISTRY_DIR"
    jq -cn --arg run "$run_id" --arg repo "$repo" '
      {schema:"legion.run-state.v1",run_id:$run,trace_id:"fanout-trace",
       parent_id:"fanout-root",kind:"run",state_version:1,repo_root:$repo,
       lifecycle:{phase:"queued",started_at:"",updated_at:"2026-07-31T10:25:17Z"}}
    ' > "$LEGION_REGISTRY_DIR/$run_id.json"

    PATH="$(path_without agent)" run "$LEGION_CURSOR" run --task "x" \
      --repo "$repo" --run-id "$run_id" --quiet
    [ "$status" -eq 1 ]
    echo "$output" | jq -e '
      .status == "refused" and (.reason | contains("binary not found"))
      and .attempt_receipt == null and .failure_receipt == null
      and .usage == null and .usage_status == "not_applicable"
      and .cost_usd == null and .cost_status == "not_applicable"'
    assert_mock_not_called agent
    [ ! -d "$repo/.legion/worktrees" ]
    jq -e '
      .run_id == "queued-cursor-missing-cli"
      and .state_version >= 2
      and .lifecycle.phase == "failed"
    ' "$LEGION_REGISTRY_DIR/$run_id.json"
}

@test "legion-cursor: missing headless credentials refuses before provider resolution or launch" {
    local repo; repo="$(make_test_repo no-key)"
    unset CURSOR_API_KEY
    run "$LEGION_CURSOR" run --task "x" --repo "$repo" --quiet
    [ "$status" -eq 1 ]
    echo "$output" | jq -e '
      .status == "refused" and (.reason | contains("missing required configuration"))
      and .attempt_receipt == null and .failure_receipt == null
      and .usage == null and .usage_status == "not_applicable"
      and .cost_usd == null and .cost_status == "not_applicable"'
    assert_mock_not_called agent
    [ ! -d "$repo/.legion/worktrees" ]
}
