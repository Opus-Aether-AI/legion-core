#!/usr/bin/env bats

load 'helpers/setup'

setup() {
    setup_test_env
    export LEGION_TELEMETRY_DIR="$TEST_TMPDIR/spans"
    export LEGION_CURSOR="$REPO_ROOT/legion-router/bin/legion-cursor"
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
    run "$LEGION_CURSOR" run --task "do the thing" --repo "$repo" --quiet
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.status == "ok" and .executor == "cursor" and .model == "cursor-auto"'
    local diff; diff="$(echo "$output" | jq -r .diff_path)"
    [ -s "$diff" ]
    grep -q "MOCK_CURSOR_CHANGE" "$diff"
    assert_mock_called agent "-p --output-format json --trust --force"

    run bash -c "cat '$LEGION_TELEMETRY_DIR'/*.jsonl | jq -r .executor"
    [ "$output" = "cursor" ]
}

@test "legion-cursor: read-only sandbox does not force writes" {
    local repo; repo="$(make_test_repo ro1)"
    run "$LEGION_CURSOR" run --task "inspect only" --repo "$repo" --sandbox read-only --quiet
    [ "$status" -eq 0 ]
    assert_mock_called agent "-p --output-format json --trust --mode plan inspect only"
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
    [[ "$output" == *"dangerous/injection pattern"* ]]
    assert_mock_not_called agent
}

@test "legion-cursor: missing Cursor Agent CLI fails clearly" {
    local repo; repo="$(make_test_repo miss1)"
    PATH="$(path_without agent)" run "$LEGION_CURSOR" run --task "x" --repo "$repo" --quiet
    [ "$status" -eq 2 ]
    [[ "$output" == *"Cursor Agent CLI not found"* ]]
}
