#!/usr/bin/env bats

load 'helpers/setup'

setup() {
    setup_test_env
    export LEGION_STATE_ROOT="$TEST_TMPDIR/state"
    export LEGION_TELEMETRY_DIR="$TEST_TMPDIR/spans"
    export LEGION_REGISTRY_DIR="$LEGION_STATE_ROOT/registry"
    export LEGION_DEEPSEEK="$REPO_ROOT/legion-router/bin/legion-deepseek"
    DEEPSEEK_DEFAULT="$("$REPO_ROOT/legion-router/bin/legion-route" --model-ref deepseek_default)"
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

@test "legion-deepseek: happy path boots a profile, captures diff, emits span" {
    local repo; repo="$(make_test_repo ok1)"
    local context="$TEST_TMPDIR/context.log"
    MOCK_CONTEXT_LOG="$context" run "$LEGION_DEEPSEEK" run --task "do the thing" --repo "$repo" --quiet
    [ "$status" -eq 0 ]
    echo "$output" | jq -e --arg m "$DEEPSEEK_DEFAULT" \
        '.status == "ok" and .executor == "deepseek" and .model == $m'

    local diff; diff="$(echo "$output" | jq -r .diff_path)"
    [ -s "$diff" ]
    grep -q "mock-dsh-change" "$diff"

    # dsh has no `run` subcommand -- a headless turn is a profile boot with the
    # task as the app's positional. Pin that, because getting it wrong is the
    # difference between a working adapter and one that opens a web server.
    assert_mock_called dsh "--profile legion-headless"

    run bash -c "cat '$LEGION_TELEMETRY_DIR'/*.jsonl | jq -r .executor"
    [ "$output" = "deepseek" ]
    grep -Eq '^dsh active=1 executor=1 depth=[1-9][0-9]* run=.+$' "$context"
}

@test "legion-deepseek: reports zero usage rather than inventing it" {
    # dsh publishes no headless usage contract. A fabricated number would flow
    # into cost reports and routing decisions that are meant to be evidence-
    # based, so the adapter meters nothing and says so.
    local repo; repo="$(make_test_repo usage1)"
    run "$LEGION_DEEPSEEK" run --task "measure me" --repo "$repo" --quiet
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.cost_usd == 0 and (.usage | length) == 0'

    run bash -c "cat '$LEGION_TELEMETRY_DIR'/*.jsonl | jq -r '.cost_usd, (.tokens | length)'"
    [ "${lines[0]}" = "0" ]
    [ "${lines[1]}" = "0" ]
}

@test "legion-deepseek: an executor that commits its work is not lost" {
    local repo; repo="$(make_test_repo commits1)"
    MOCK_DSH_COMMITS=1 run "$LEGION_DEEPSEEK" run \
        --task "change it and commit" --repo "$repo" --quiet
    [ "$status" -eq 0 ]
    local diff; diff="$(echo "$output" | jq -r .diff_path)"
    [ -s "$diff" ] || {
        echo "diff is empty: the executor's committed work was lost" >&2
        return 1
    }
    grep -q "mock-dsh-change" "$diff"
}

@test "legion-deepseek: a nonzero dsh exit is a failed run" {
    local repo; repo="$(make_test_repo fail1)"
    MOCK_DSH_FAIL=1 run "$LEGION_DEEPSEEK" run --task "break" --repo "$repo" --quiet
    [ "$status" -ne 0 ]
    echo "$output" | jq -e '.status == "failed"'
}

@test "legion-deepseek: a missing profile fails loudly, not silently" {
    # dsh ships no headless preset, so "profile not found" is the single most
    # likely misconfiguration of this executor.
    local repo; repo="$(make_test_repo prof1)"
    MOCK_DSH_NO_PROFILE=1 run "$LEGION_DEEPSEEK" run --task "boot" --repo "$repo" --quiet
    [ "$status" -ne 0 ]
    echo "$output" | jq -e '.status == "failed"'
}

@test "legion-deepseek: silence with a zero exit is never reported as success" {
    local repo; repo="$(make_test_repo empty1)"
    MOCK_DSH_EMPTY=1 run "$LEGION_DEEPSEEK" run --task "say nothing" --repo "$repo" --quiet
    [ "$status" -ne 0 ]
    echo "$output" | jq -e '.status == "error"'
    grep -qi "refusing to report an empty success" "$(echo "$output" | jq -r .last_message)"
}

@test "legion-deepseek: a read-only run that writes is refused" {
    # dsh exposes no flag that withholds the write tools, so unlike the other
    # adapters this backstop is the ONLY thing enforcing read-only. It has to
    # actually fire.
    local repo; repo="$(make_test_repo ro1)"
    run "$LEGION_DEEPSEEK" run --task "just look" --repo "$repo" --sandbox read-only --quiet
    [ "$status" -ne 0 ]
    echo "$output" | jq -e '.status == "error"'
    grep -qi "read-only" "$(echo "$output" | jq -r .last_message)"
}

@test "legion-deepseek: honours LEGION_DSH_PROFILE" {
    local repo; repo="$(make_test_repo prof2)"
    LEGION_DSH_PROFILE=my-profile run "$LEGION_DEEPSEEK" run \
        --task "boot mine" --repo "$repo" --quiet
    [ "$status" -eq 0 ]
    assert_mock_called dsh "--profile my-profile"
}

@test "legion-deepseek: takes the task from a file, not argv" {
    # A task carrying a diff or a long spec exceeds ARG_MAX.
    local repo; repo="$(make_test_repo tf1)"
    local tf="$TEST_TMPDIR/task.txt"
    printf 'implement the thing described at length\n' > "$tf"
    run "$LEGION_DEEPSEEK" run --task-file "$tf" --repo "$repo" --quiet
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.status == "ok"'
}

@test "legion-deepseek: is registered as a diff executor that cannot review" {
    # review = "none" keeps it out of the review fallback order. A reviewer that
    # cannot emit a schema-valid verdict looks exactly like one that rejected the
    # change, which is how a fallback turns a missing review into a blocked merge.
    run "$REPO_ROOT/legion-router/bin/legion-route" --executor-info deepseek
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.contract == "diff"'
    echo "$output" | jq -e '.review == "none"'
    echo "$output" | jq -e '.adapter == "legion-deepseek"'
}
