#!/usr/bin/env bats

load 'helpers/setup'

setup() {
    setup_test_env
    export LEGION_TELEMETRY_DIR="$TEST_TMPDIR/spans"
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
    run "$LEGION_OPENCODE" run --task "do the thing" --repo "$repo" --quiet
    [ "$status" -eq 0 ]
    echo "$output" | jq -e --arg m "$OPENCODE_DEFAULT" '.status == "ok" and .executor == "opencode" and .model == $m'
    local diff; diff="$(echo "$output" | jq -r .diff_path)"
    [ -s "$diff" ]
    grep -q "mock-opencode-change" "$diff"
    assert_mock_called opencode "run --format json -m $OPENCODE_DEFAULT"

    run bash -c "cat '$LEGION_TELEMETRY_DIR'/*.jsonl | jq -r .executor"
    [ "$output" = "opencode" ]
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
    run "$LEGION_OPENCODE" run --task "x" --repo "$repo" --model test-model-opencode --quiet
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.model == "test-model-opencode"'
    assert_mock_called opencode "-m test-model-opencode"
}
