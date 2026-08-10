#!/usr/bin/env bats

load 'helpers/setup'

setup() {
    setup_test_env
    export LEGION_STATE_ROOT="$TEST_TMPDIR/state"
    export LEGION_TELEMETRY_DIR="$TEST_TMPDIR/spans"
    export LEGION_REGISTRY_DIR="$LEGION_STATE_ROOT/registry"
    export LEGION_OPENCODE="$REPO_ROOT/legion-router/bin/legion-opencode"
    OPENCODE_DEFAULT="$("$REPO_ROOT/legion-router/bin/legion-route" --model-ref opencode_default)"
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

@test "legion-opencode: happy path runs opencode headless, captures diff, emits span" {
    local repo; repo="$(make_test_repo ok1)"
    local context="$TEST_TMPDIR/context.log"
    MOCK_CONTEXT_LOG="$context" run "$LEGION_OPENCODE" run --task "do the thing" --repo "$repo" --quiet
    [ "$status" -eq 0 ]
    echo "$output" | jq -e --arg m "$OPENCODE_DEFAULT" '.status == "ok" and .executor == "opencode" and .model == $m'
    local diff; diff="$(echo "$output" | jq -r .diff_path)"
    [ -s "$diff" ]
    grep -q "mock-opencode-change" "$diff"
    assert_mock_called opencode "run --format json -m $OPENCODE_DEFAULT"

    run bash -c "cat '$LEGION_TELEMETRY_DIR'/*.jsonl | jq -r .executor"
    [ "$output" = "opencode" ]
    grep -Eq '^opencode active=1 executor=1 depth=[1-9][0-9]* run=.+$' "$context"
}

@test "legion-opencode: adopts a preallocated run id and closes its queued lifecycle" {
    local repo; repo="$(make_test_repo adopted-id)"
    local run_id="queued-slice-opencode"
    mkdir -p "$LEGION_REGISTRY_DIR"
    jq -cn --arg run "$run_id" --arg repo "$repo" '
      {schema:"legion.run-state.v1",run_id:$run,trace_id:"fanout-trace",
       parent_id:"fanout-root",kind:"run",state_version:1,repo_root:$repo,
       lifecycle:{phase:"queued",started_at:"",updated_at:"2026-07-31T10:25:17Z"}}
    ' > "$LEGION_REGISTRY_DIR/$run_id.json"

    LEGION_TRACE_ID=fanout-trace LEGION_PARENT_ID=fanout-root \
      run "$LEGION_OPENCODE" run --task "do the thing" --repo "$repo" \
        --run-id "$run_id" --quiet

    [ "$status" -eq 0 ]
    echo "$output" | jq -e --arg run "$run_id" \
      '.run_id == $run and (.diff_path | endswith("/" + $run + "/diff.patch"))'
    jq -e '
      .run_id == "queued-slice-opencode"
      and .trace_id == "fanout-trace"
      and .parent_id == "fanout-root"
      and .state_version >= 3
      and .lifecycle.phase == "ok"
      and (.lifecycle.started_at | length > 0)
    ' "$LEGION_REGISTRY_DIR/$run_id.json"
    run bash -c "cat '$LEGION_TELEMETRY_DIR'/*.jsonl | jq -e 'select(.executor == \"opencode\" and .run_id == \"$run_id\")'"
    [ "$status" -eq 0 ]
}

@test "legion-opencode: closes a preallocated lifecycle when worktree setup fails" {
    local repo; repo="$(make_test_repo worktree-fail)"
    local run_id="queued-opencode-worktree-fail"
    mkdir -p "$LEGION_REGISTRY_DIR"
    jq -cn --arg run "$run_id" --arg repo "$repo" '
      {schema:"legion.run-state.v1",run_id:$run,trace_id:"fanout-trace",
       parent_id:"fanout-root",kind:"run",state_version:1,repo_root:$repo,
       lifecycle:{phase:"queued",started_at:"",updated_at:"2026-07-31T10:25:17Z"}}
    ' > "$LEGION_REGISTRY_DIR/$run_id.json"
    git -C "$repo" branch "legion/opencode-$run_id"

    LEGION_TRACE_ID=fanout-trace LEGION_PARENT_ID=fanout-root \
      run "$LEGION_OPENCODE" run --task "do the thing" --repo "$repo" \
        --run-id "$run_id" --quiet

    [ "$status" -eq 2 ]
    [[ "$output" == *"worktree add failed"* ]]
    jq -e '
      .run_id == "queued-opencode-worktree-fail"
      and .trace_id == "fanout-trace"
      and .parent_id == "fanout-root"
      and .state_version >= 2
      and .lifecycle.phase == "failed"
    ' "$LEGION_REGISTRY_DIR/$run_id.json"
}

@test "legion-opencode: parses the JSONL event stream (cost summed across message ids, nested tokens)" {
    local repo; repo="$(make_test_repo parse1)"
    run "$LEGION_OPENCODE" run --task "edit" --repo "$repo" --quiet
    [ "$status" -eq 0 ]
    # cost = 0.005 (final a1) + 0.002 (a2) = 0.007
    echo "$output" | jq -e '.cost_usd == 0.007'
    # tokens summed across a1(final)+a2 with nested cache mapped to canonical keys
    echo "$output" | jq -e '.usage.input_tokens == 210 and .usage.output_tokens == 55'
    echo "$output" | jq -e '.usage.reasoning_output_tokens == 5'
    echo "$output" | jq -e '.usage.cache_read_input_tokens == 20 and .usage.cache_creation_input_tokens == 30'
    # result is the final streamed text part
    echo "$output" | jq -e '.result == "OPENCODE_OK_OUTPUT"'

    # span carries the same cost + tokens
    run bash -c "cat '$LEGION_TELEMETRY_DIR'/*.jsonl | jq -e '.cost_usd == 0.007 and .tokens.output_tokens == 55'"
    [ "$status" -eq 0 ]
}

@test "legion-opencode: parses OpenCode 1.3 top-level text and step events" {
    local repo; repo="$(make_test_repo current-stream)"
    MOCK_OPENCODE_CURRENT_STREAM=1 run "$LEGION_OPENCODE" run --task "inspect" \
        --repo "$repo" --sandbox read-only --quiet

    [ "$status" -eq 0 ]
    echo "$output" | jq -e --arg model "$OPENCODE_DEFAULT" '
      .status == "ok"
      and .model == $model
      and .result == "OPENCODE_CURRENT_OUTPUT"
      and .cost_usd == 0.013
      and .usage.input_tokens == 300
      and .usage.output_tokens == 40
      and .usage.reasoning_output_tokens == 3
      and .usage.cache_read_input_tokens == 20
      and .usage.cache_creation_input_tokens == 10
    '
}

@test "legion-opencode: a JSONL error event fails even when OpenCode exits zero" {
    local repo; repo="$(make_test_repo error-event)"
    MOCK_OPENCODE_ERROR_EVENT=1 run "$LEGION_OPENCODE" run --task "inspect" \
        --repo "$repo" --sandbox read-only --quiet

    [ "$status" -eq 1 ]
    echo "$output" | jq -e '
      .status == "failed"
      and .opencode_exit == 0
      and .opencode_error == "The requested model is not supported."
      and (.result | contains("opencode error: The requested model is not supported."))
    '
    run bash -c "cat '$LEGION_TELEMETRY_DIR'/*.jsonl | jq -r .status"
    [ "$output" = "failed" ]
}

@test "legion-opencode: an empty event stream is never reported as success" {
    local repo; repo="$(make_test_repo empty-stream)"
    MOCK_OPENCODE_EMPTY_STREAM=1 run "$LEGION_OPENCODE" run --task "inspect" \
        --repo "$repo" --sandbox read-only --quiet

    [ "$status" -eq 1 ]
    echo "$output" | jq -e '
      .status == "error"
      and (.result | contains("no recognized JSONL events"))
    '
}

@test "legion-opencode: read-only sandbox uses the plan agent and produces no diff" {
    local repo; repo="$(make_test_repo ro1)"
    run "$LEGION_OPENCODE" run --task "inspect only" --repo "$repo" --sandbox read-only --quiet
    [ "$status" -eq 0 ]
    assert_mock_called opencode "--agent plan"
    [ ! -s "$(echo "$output" | jq -r .diff_path)" ]
}

@test "legion-opencode: read-only sandbox rejects unexpected writes" {
    local repo; repo="$(make_test_repo ro-write)"
    MOCK_OPENCODE_WRITE_IN_PLAN=1 run "$LEGION_OPENCODE" run --task "inspect only" \
        --repo "$repo" --sandbox read-only --apply --quiet
    [ "$status" -eq 1 ]
    echo "$output" | jq -e '.status == "error"'
    [ ! -f "$repo/MOCK_OPENCODE_CHANGE.txt" ]
}

@test "legion-opencode: read-only .opencode/plans write is not treated as an edit" {
    local repo; repo="$(make_test_repo plan1)"
    MOCK_OPENCODE_WRITE_PLAN_FILE=1 run "$LEGION_OPENCODE" run --task "plan it" \
        --repo "$repo" --sandbox read-only --quiet
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.status == "ok"'
}

@test "legion-opencode: a stray non-JSON stdout line does not zero the metering" {
    local repo; repo="$(make_test_repo stray1)"
    MOCK_OPENCODE_STRAY_STDOUT=1 run "$LEGION_OPENCODE" run --task "x" --repo "$repo" --quiet
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.cost_usd == 0.007 and .usage.output_tokens == 55'
    echo "$output" | jq -e '.result == "OPENCODE_OK_OUTPUT"'
}

@test "legion-opencode: --apply applies the captured diff to the repo" {
    local repo; repo="$(make_test_repo app1)"
    run "$LEGION_OPENCODE" run --task "edit" --repo "$repo" --apply --quiet
    [ "$status" -eq 0 ]
    [ -f "$repo/MOCK_OPENCODE_CHANGE.txt" ]
}

@test "legion-opencode: direct adapter refuses delegated executor context" {
    local repo; repo="$(make_test_repo nested)"
    LEGION_ACTIVE=1 run "$LEGION_OPENCODE" run --task "do the thing" --repo "$repo" --quiet
    [ "$status" -eq 2 ]
    [[ "$output" == *"nested Legion delegation is blocked"* ]]
    assert_mock_not_called opencode
}

@test "legion-opencode: missing CLI terminalizes a preallocated run id" {
    local repo; repo="$(make_test_repo missing-cli)"
    local run_id="queued-opencode-missing-cli"
    mkdir -p "$LEGION_REGISTRY_DIR"
    jq -cn --arg run "$run_id" --arg repo "$repo" '
      {schema:"legion.run-state.v1",run_id:$run,trace_id:"fanout-trace",
       parent_id:"fanout-root",kind:"run",state_version:1,repo_root:$repo,
       lifecycle:{phase:"queued",started_at:"",updated_at:"2026-07-31T10:25:17Z"}}
    ' > "$LEGION_REGISTRY_DIR/$run_id.json"

    OPENCODE_BIN="$TEST_TMPDIR/missing-opencode" run "$LEGION_OPENCODE" run \
      --task "x" --repo "$repo" --run-id "$run_id" --quiet

    [ "$status" -eq 2 ]
    [[ "$output" == *"opencode CLI not found"* ]]
    jq -e '
      .run_id == "queued-opencode-missing-cli"
      and .state_version >= 2
      and .lifecycle.phase == "failed"
    ' "$LEGION_REGISTRY_DIR/$run_id.json"
}

@test "legion-opencode: opencode failure yields status failed and non-zero exit" {
    local repo; repo="$(make_test_repo fail1)"
    MOCK_OPENCODE_FAIL=1 run "$LEGION_OPENCODE" run --task "boom" --repo "$repo" --quiet
    [ "$status" -eq 1 ]
    echo "$output" | jq -e '.status == "failed"'
    run bash -c "cat '$LEGION_TELEMETRY_DIR'/*.jsonl | jq -r .status"
    [ "$output" = "failed" ]
}

@test "legion-opencode: --model overrides the default" {
    local repo; repo="$(make_test_repo model1)"
    # opencode model ids are provider/model, and the adapter reassembles the id
    # from the stream's providerID + modelID — so the fixture must carry a provider.
    run "$LEGION_OPENCODE" run --task "x" --repo "$repo" --model test-provider/test-model-opencode --quiet
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.model == "test-provider/test-model-opencode"'
    assert_mock_called opencode "-m test-provider/test-model-opencode"
}
