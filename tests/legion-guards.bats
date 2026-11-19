#!/usr/bin/env bats
# Run guards (issue #218 steps 3 and 5): health-aware routing, default spending
# caps, the quiet share gate, and the OpenRouter key for the cheap executor.

load 'helpers/setup'

setup() {
    setup_test_env
    DELEGATE="$REPO_ROOT/legion-router/bin/legion-delegate"
    HEALTH="$REPO_ROOT/legion-router/bin/legion-health"
    BUDGET="$REPO_ROOT/legion-router/bin/legion-budget"
    SHARE="$REPO_ROOT/legion-observability/bin/legion-share"
    OPENCODE="$REPO_ROOT/legion-router/bin/legion-opencode"
    export LEGION_TELEMETRY_DIR="$TEST_TMPDIR/spans"
    export LEGION_STATE_ROOT="$TEST_TMPDIR/state"
    export LEGION_REGISTRY_DIR="$LEGION_STATE_ROOT/registry"
    export LEGION_REPOS_FILE="$LEGION_STATE_ROOT/repos.jsonl"
    # Dispatch prefers adapters on PATH; this install's must win over any other.
    export PATH="$REPO_ROOT/legion-router/bin:$PATH"
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

all_spans() {
    cat "$LEGION_TELEMETRY_DIR"/*.jsonl 2>/dev/null
}

# A codex stand-in whose `login status` answers like the real CLI.
fake_codex_login() {
    local answer="$1" rc="$2" bin="$TEST_TMPDIR/fake-codex-bin"
    mkdir -p "$bin"
    cat > "$bin/codex" <<SH
#!/usr/bin/env bash
if [[ "\$1 \$2" == "login status" ]]; then printf '%s\n' "$answer"; exit $rc; fi
exit 0
SH
    chmod +x "$bin/codex"
    printf '%s\n' "$bin/codex"
}

# ── legion-health ──────────────────────────────────────────────────────

@test "health: a recorded outage makes check fail; ok and no record are available" {
    run "$HEALTH" check codex
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.available == true and .source == "none"'

    "$HEALTH" record codex --status unavailable --reason logged_out --detail "test" >/dev/null
    run "$HEALTH" check codex
    [ "$status" -eq 1 ]
    echo "$output" | jq -e '.available == false and .reason == "logged_out" and .fresh == true'

    "$HEALTH" record codex --status ok >/dev/null
    run "$HEALTH" check codex
    [ "$status" -eq 0 ]
}

@test "health: a stale outage is re-probed, so a re-login is noticed without a reset" {
    CODEX_BIN="$(fake_codex_login 'Not logged in' 1)" \
        "$HEALTH" record codex --status unavailable --reason logged_out --ttl 0 >/dev/null

    CODEX_BIN="$(fake_codex_login 'Not logged in' 1)" run "$HEALTH" check codex
    [ "$status" -eq 1 ]
    echo "$output" | jq -e '.source == "probe" and .reason == "logged_out"'

    "$HEALTH" record codex --status unavailable --reason logged_out --ttl 0 >/dev/null
    CODEX_BIN="$(fake_codex_login 'Logged in using ChatGPT' 0)" run "$HEALTH" check codex
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.source == "probe" and .status == "ok"'
}

@test "health: an inconclusive probe never invents an outage" {
    "$HEALTH" record codex --status unavailable --reason logged_out --ttl 0 >/dev/null
    CODEX_BIN="$(fake_codex_login 'something else entirely' 3)" run "$HEALTH" check codex
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.status == "unknown" and .available == true'
}

@test "health: observe records quota and login failures but not ordinary task failures" {
    printf 'ERROR: You have hit your usage limit.\n' > "$TEST_TMPDIR/quota.err"
    "$HEALTH" observe codex-review --run-status failed --file "$TEST_TMPDIR/quota.err" >/dev/null
    run "$HEALTH" check codex --no-probe
    [ "$status" -eq 1 ]
    echo "$output" | jq -e '.reason == "no_quota" and .source == "run"'

    "$HEALTH" record claude --status ok >/dev/null
    printf 'TypeError: cannot read property of undefined\n' > "$TEST_TMPDIR/task.err"
    "$HEALTH" observe claude --run-status failed --file "$TEST_TMPDIR/task.err" >/dev/null
    run "$HEALTH" check claude --no-probe
    [ "$status" -eq 0 ]
}

# ── health-aware routing in legion-delegate ────────────────────────────

@test "routing: a routed run skips a logged-out executor and the span records the fallback" {
    local repo; repo="$(make_test_repo fallback)"
    "$HEALTH" record codex --status unavailable --reason logged_out --detail "test" >/dev/null

    run "$DELEGATE" run --archetype implement-feature --task "add a line" --repo "$repo" --quiet
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.status == "ok" and .executor == "claude"'
    assert_mock_not_called codex
    all_spans | jq -se '
      [.[] | select(.executor == "claude")][0].artifacts.health_fallback
        == {from:"codex", to:"claude", reason:"logged_out"}'
}

@test "routing: an explicit --executor that is logged out is refused, naming a healthy alternative" {
    local repo; repo="$(make_test_repo explicit)"
    "$HEALTH" record codex --status unavailable --reason logged_out --detail "test" >/dev/null

    run "$DELEGATE" run --executor codex --task "add a line" --repo "$repo" --quiet
    [ "$status" -eq 2 ]
    printf '%s\n' "$output" | grep '^{' | jq -e '
      .status == "blocked" and .reason == "executor_unavailable"
      and .alternatives == ["claude"] and .health.reason == "logged_out"'
    assert_mock_not_called codex
    all_spans | jq -se 'any(.[]; .executor == "legion-route" and .status == "blocked"
      and .artifacts.reason == "executor_unavailable")'
}

@test "routing: the fallback never picks an executor the active models file cannot run" {
    local repo; repo="$(make_test_repo claude-only)"
    local models="$TEST_TMPDIR/claude-only-models.toml"
    {
        printf '[models]\n'
        grep -E '^claude_' "$REPO_ROOT/legion-router/config/models.toml"
    } > "$models"
    "$HEALTH" record claude --status unavailable --reason no_quota --detail "test" >/dev/null

    LEGION_MODELS_FILE="$models" run "$DELEGATE" run --archetype frontend-polish \
        --task "polish the page" --repo "$repo" --quiet
    [ "$status" -eq 2 ]
    printf '%s\n' "$output" | grep '^{' | jq -e '.reason == "no_healthy_executor"'
    assert_mock_not_called codex
    assert_mock_not_called claude
}

@test "routing: a codex run that hits its usage limit is remembered for the next route" {
    local repo; repo="$(make_test_repo quota)"
    local workhorse; workhorse="$("$REPO_ROOT/legion-router/bin/legion-route" --model-ref codex_workhorse)"
    MOCK_CODEX_QUOTA_FAIL="$workhorse" run "$DELEGATE" run --model "$workhorse" \
        --task "add a line" --repo "$repo" --quiet
    [ "$status" -ne 0 ]
    run "$HEALTH" check codex --no-probe
    [ "$status" -eq 1 ]
    echo "$output" | jq -e '.reason == "no_quota"'
}

@test "routing: LEGION_HEALTH=off restores the old behaviour" {
    local repo; repo="$(make_test_repo health-off)"
    "$HEALTH" record codex --status unavailable --reason logged_out >/dev/null
    LEGION_HEALTH=off run "$DELEGATE" run --executor codex --task "add a line" --repo "$repo" --quiet
    [ "$status" -eq 0 ]
    assert_mock_called codex "exec"
}

@test "review: a reviewer recorded unavailable is skipped before an attempt is spent" {
    local repo; repo="$(make_test_repo review-skip)"
    printf 'more\n' >> "$repo/foo.ts"
    git -C "$repo" -c user.email=t@t.c -c user.name=t commit -qam change
    "$HEALTH" record codex --status unavailable --reason no_quota >/dev/null

    run "$DELEGATE" review --base HEAD~1 --head HEAD --repo "$repo"
    [[ "$output" == *"reviewer 'codex' is unavailable (legion-health)"* ]]
    # Invocations only: other reviewers' prompts quote "codex exec review".
    if grep -E '^codex ' "$MOCK_CALL_LOG" | grep -q "review"; then
        echo "codex was asked to review although it is recorded unavailable" >&2
        return 1
    fi
}

# ── spending caps ──────────────────────────────────────────────────────

@test "budget: caps resolve env over routing.toml over defaults, and 0 turns a cap off" {
    run "$BUDGET" caps --json
    echo "$output" | jq -e '.sources.run_usd == "routing.toml" and .run_usd > 0 and .day_usd > 0'
    LEGION_RUN_BUDGET_USD=2.5 run "$BUDGET" caps --field run_usd
    [ "$output" = "2.5" ]
    LEGION_RUN_BUDGET_USD=0 run "$BUDGET" run-status --status ok --cost 999
    [ "$output" = "ok" ]
    LEGION_RUN_BUDGET_USD=1 run "$BUDGET" run-status --status ok --cost 1.5
    [ "$output" = "over_budget" ]
}

@test "budget: once today's delegated spend reaches the day cap, new runs are refused" {
    local repo; repo="$(make_test_repo day-cap)"
    local day; day="$(date -u +%F)"
    mkdir -p "$LEGION_HOME/projects/other/spans"
    # Delegated spend counts; an orchestrator roll-up of the same spend does not.
    printf '%s\n' \
      '{"schema":"legion.span.v1","executor":"claude","status":"ok","cost_usd":3}' \
      '{"schema":"legion.span.v1","executor":"orchestrator","status":"ok","cost_usd":3}' \
      > "$LEGION_HOME/projects/other/spans/$day.jsonl"

    LEGION_DAY_BUDGET_USD=5 run "$BUDGET" check
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.spent_usd == 3'

    LEGION_DAY_BUDGET_USD=3 run "$DELEGATE" run --executor codex --task "add a line" --repo "$repo" --quiet
    [ "$status" -eq 2 ]
    printf '%s\n' "$output" | grep '^{' | jq -e '.reason == "daily_budget_exhausted" and .budget.spent_usd == 3'
    assert_mock_not_called codex
}

@test "budget: a codex run above the per-run cap is over_budget and its diff is not applied" {
    local repo; repo="$(make_test_repo run-cap)"
    LEGION_RUN_BUDGET_USD=0.000001 run "$DELEGATE" run --executor codex --task "add a line" \
        --repo "$repo" --apply --quiet
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.status == "over_budget"'
    git -C "$repo" diff --quiet
    all_spans | jq -se '[.[] | select(.executor == "codex")][0]
      | .status == "over_budget" and .artifacts.budget.exceeded == true'
}

@test "budget: legion-claude passes the per-run cap to Claude Code as a hard stop" {
    local repo; repo="$(make_test_repo claude-cap)"
    LEGION_RUN_BUDGET_USD=4 run "$REPO_ROOT/legion-router/bin/legion-claude" run \
        --task "x" --repo "$repo" --quiet
    [ "$status" -eq 0 ]
    assert_mock_called claude "--max-budget-usd 4"
}

@test "budget: a Claude run stopped by its cap is over_budget and never handed to Codex" {
    local repo; repo="$(make_test_repo claude-stop)"
    MOCK_CLAUDE_BUDGET_STOP=1 LEGION_RUN_BUDGET_USD=0.4 run \
        "$REPO_ROOT/legion-router/bin/legion-claude" run --task "x" --repo "$repo" --quiet
    [ "$status" -ne 0 ]
    printf '%s\n' "$output" | grep '^{' | tail -1 | jq -e '.status == "over_budget" and .reason == "budget_exceeded"'
    assert_mock_not_called codex
    assert_mock_not_called legion-delegate
}

# ── legion-share stays quiet when codex is down ────────────────────────

@test "share: the gate nags while codex is up and is silent once codex is recorded down" {
    local spans="$TEST_TMPDIR/share-spans"
    mkdir -p "$spans"
    printf '%s\n' '{"schema":"legion.span.v1","ts":"2026-11-20T00:00:00Z","executor":"opus","model":"m","status":"ok","tokens":{"output_tokens":100}}' \
      > "$spans/2026-11-20.jsonl"

    run "$SHARE" gate --dir "$spans" --target 0.5
    [ "$status" -eq 1 ]
    [[ "$output" == *"codex share 0% < 50% target"* ]]

    "$HEALTH" record codex --status unavailable --reason logged_out >/dev/null
    run "$SHARE" gate --dir "$spans" --target 0.5
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run "$SHARE" next --dir "$spans" --target 0.5
    [ "$output" = "opus" ]
    run "$SHARE" --dir "$spans" --target 0.5
    echo "$output" | jq -e '.codex_available == false and .codex_unavailable_reason == "logged_out"'
}

# ── the cheap executor's OpenRouter key ────────────────────────────────

@test "opencode: an OpenRouter model loads its key from the key file and passes it only to opencode" {
    local repo; repo="$(make_test_repo or-key)"
    MOCK_ENV_LOG="$TEST_TMPDIR/env.log" run "$OPENCODE" run --task "x" --repo "$repo" --quiet
    [ "$status" -eq 0 ]
    grep -qx 'opencode openrouter_key=set' "$TEST_TMPDIR/env.log"
    ! grep -q 'test-placeholder-not-a-key' "$LEGION_TELEMETRY_DIR"/*.jsonl
}

@test "opencode: without a key file the run is refused with the exact remedy and health records it" {
    local repo; repo="$(make_test_repo or-nokey)"
    LEGION_OPENROUTER_KEY_FILE="$TEST_TMPDIR/absent.key" run "$OPENCODE" run --task "x" --repo "$repo" --quiet
    [ "$status" -eq 2 ]
    [[ "$output" == *"OPENROUTER_API_KEY is missing"* ]]
    [[ "$output" == *"$TEST_TMPDIR/absent.key"* ]]
    [[ "$output" == *"chmod 600"* ]]
    assert_mock_not_called opencode
    run "$HEALTH" check opencode --no-probe
    [ "$status" -eq 1 ]
    echo "$output" | jq -e '.reason == "missing_key"'
}

# ── review round: regressions ──────────────────────────────────────────

@test "routing: a health fallback inside a delegated worker is still subject to the nesting policy" {
    local repo; repo="$(make_test_repo nested)"
    "$HEALTH" record codex --status unavailable --reason logged_out >/dev/null
    LEGION_ACTIVE=1 LEGION_EXECUTOR=1 LEGION_DEPTH=1 LEGION_EXECUTOR_NAME=codex \
      LEGION_RUN_ID=parent-codex run "$DELEGATE" run --archetype implement-feature \
        --task "add a line" --repo "$repo" --quiet
    [ "$status" -eq 2 ]
    [[ "$output" == *"nested-delegation-requires-explicit-executor"* ]]
    assert_mock_not_called claude
    assert_mock_not_called codex
}

@test "budget: an adapter run above the per-run cap keeps its diff and is not applied" {
    local repo; repo="$(make_test_repo opencode-cap)"
    LEGION_RUN_BUDGET_USD=0.000001 run "$OPENCODE" run --task "x" --repo "$repo" --apply --quiet
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.status == "over_budget"'
    [ -s "$(echo "$output" | jq -r .diff_path)" ]
    git -C "$repo" diff --quiet
    [ -z "$(git -C "$repo" status --porcelain --untracked-files=all -- . ':!.legion')" ]
}

@test "health: a codex task ABOUT rate limiting does not mark codex out of quota" {
    local repo; repo="$(make_test_repo topic)"
    local bin="$TEST_TMPDIR/topic-codex"
    mkdir -p "$bin"
    cat > "$bin/codex" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"type":"thread.started","thread_id":"t"}'
printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"Added rate limit middleware; the rate-limit test still fails"}}'
printf 'stream disconnected before completion\n' >&2
exit 1
SH
    chmod +x "$bin/codex"
    CODEX_BIN="$bin/codex" run "$DELEGATE" run --executor codex --task "add rate limiting" --repo "$repo" --quiet
    [ "$status" -ne 0 ]
    run "$HEALTH" check codex --no-probe
    [ "$status" -eq 0 ]
}

@test "opencode: an OpenRouter key stored by 'opencode auth login' is accepted as it is" {
    local repo; repo="$(make_test_repo or-native)"
    mkdir -p "$HOME/.local/share/opencode"
    printf '%s\n' '{"openrouter":{"type":"api","key":"placeholder"}}' > "$HOME/.local/share/opencode/auth.json"
    LEGION_OPENROUTER_KEY_FILE="$TEST_TMPDIR/absent.key" MOCK_ENV_LOG="$TEST_TMPDIR/env.log" \
      run "$OPENCODE" run --task "x" --repo "$repo" --quiet
    [ "$status" -eq 0 ]
    # Legion does not read or export that key; opencode uses its own store.
    grep -qx 'opencode openrouter_key=' "$TEST_TMPDIR/env.log"
}
