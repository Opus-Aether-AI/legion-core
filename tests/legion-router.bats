#!/usr/bin/env bats
# Tests for the legion-router delegation spine: codex-json + cost libs + legion-delegate.
# Uses the shared isolation helpers (redirected HOME/PATH, mock `codex` on PATH).

load 'helpers/setup'

setup() {
    setup_test_env
    LIB="$REPO_ROOT/legion-router/scripts/lib"
    DELEGATE="$REPO_ROOT/legion-router/scripts/delegate.sh"
    TASK_SCAN_FIXTURE="$BATS_TEST_DIRNAME/fixtures/dangerous-task-cases.json"
    SHARE="$REPO_ROOT/legion-observability/bin/legion-share"
    FIXTURE="$BATS_TEST_DIRNAME/fixtures/codex-json/turn-with-diff.jsonl"
    export LEGION_TELEMETRY_DIR="$TEST_TMPDIR/spans"
    export LEGION_STATE_ROOT="$TEST_TMPDIR/state"
    export LEGION_REGISTRY_DIR="$LEGION_STATE_ROOT/registry"
    export LEGION_REPOS_FILE="$LEGION_STATE_ROOT/repos.jsonl"
    export LEGION_BENCH_DIR="$LEGION_STATE_ROOT/bench"
    export LEGION_REPORTS_DIR="$LEGION_STATE_ROOT/reports"
    export LEGION_COSTS_FILE="$REPO_ROOT/legion-router/config/costs.json"
    CODEX_WORKHORSE="$("$REPO_ROOT/legion-router/bin/legion-route" --model-ref codex_workhorse)"
    CODEX_REVIEW="$("$REPO_ROOT/legion-router/bin/legion-route" --model-ref codex_review)"
    CLAUDE_OPUS="$("$REPO_ROOT/legion-router/bin/legion-route" --model-ref claude_opus)"
    MINIMAX_MATCH="$(jq -r '.models[] | select(.match == "minimax") | .match' "$LEGION_COSTS_FILE")"
}

# Make a throwaway git repo with one source file; echoes its path.
make_test_repo() {
    local d="$TEST_TMPDIR/repo-${1:-a}"
    mkdir -p "$d"
    git -C "$d" init -q
    git -C "$d" config user.email t@t.c
    git -C "$d" config user.name t
    printf 'export function foo(x){ return x }\n' > "$d/foo.ts"
    git -C "$d" add -A
    git -C "$d" -c user.email=t@t.c -c user.name=t commit -qm init
    echo "$d"
}

registry_dir_for_repo() {
    python3 "$REPO_ROOT/legion-observability/scripts/legion_state.py" --repo "$1" --field registry_dir
}

repos_file_for_repo() {
    python3 "$REPO_ROOT/legion-observability/scripts/legion_state.py" --repo "$1" --field repos_file
}

# ── codex-json parser ────────────────────────────────────────────────
@test "codex-json: thread-id from fixture" {
    run "$LIB/codex-json.sh" thread-id "$FIXTURE"
    [ "$status" -eq 0 ]
    [ "$output" = "019ec766-f1bd-7161-8f9b-e64093bde8f7" ]
}

@test "codex-json: last agent_message (ignores reasoning items)" {
    run "$LIB/codex-json.sh" last-message "$FIXTURE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Added the missing return type"* ]]
}

@test "codex-json: usage sums turn.completed fields" {
    run bash -c "'$LIB/codex-json.sh' usage '$FIXTURE' | jq -c ."
    [ "$status" -eq 0 ]
    [ "$output" = '{"input_tokens":18369,"cached_input_tokens":4992,"output_tokens":120,"reasoning_output_tokens":40}' ]
}

@test "codex-json: usage tolerates empty input" {
    run bash -c "printf '' | '$LIB/codex-json.sh' usage - | jq -c ."
    [ "$status" -eq 0 ]
    [ "$output" = '{"input_tokens":0,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0}' ]
}

@test "codex-json: usage tolerates non-JSON lines" {
    run bash -c "printf 'garbage\n{\"type\":\"turn.completed\",\"usage\":{\"input_tokens\":7}}\n' | '$LIB/codex-json.sh' usage - | jq -r .input_tokens"
    [ "$status" -eq 0 ]
    [ "$output" = "7" ]
}

# ── cost lib ─────────────────────────────────────────────────────────
@test "cost: claude_opus pricing comes from costs.json" {
    run "$LIB/cost.sh" "$CLAUDE_OPUS" 1000000 500000 0 0
    [ "$status" -eq 0 ]
    [ "$output" = "17.5" ]
}

@test "cost: codex_review pricing comes from costs.json" {
    run "$LIB/cost.sh" "$CODEX_REVIEW" 100000 5000 0 0
    [ "$status" -eq 0 ]
    [ "$output" = "0.65" ]
}

@test "cost: codex_workhorse pricing comes from costs.json" {
    run "$LIB/cost.sh" "$CODEX_WORKHORSE" 100000 5000 0 0
    [ "$status" -eq 0 ]
    [ "$output" = "0.325" ]
}

@test "cost: the configured minimax matcher uses costs.json pricing" {
    run "$LIB/cost.sh" "$MINIMAX_MATCH" 1000000 1000000
    [ "$status" -eq 0 ]
    [ "$output" = "1.5" ]
}

@test "cost: unknown model falls back to default 0" {
    run "$LIB/cost.sh" llama-3 1000000 1000000
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

# ── legion-delegate run ──────────────────────────────────────────────
@test "delegate run: happy path returns ok + captures diff + emits span" {
    local repo; repo="$(make_test_repo run1)"
    local context="$TEST_TMPDIR/context.log"
    MOCK_CONTEXT_LOG="$context" run "$DELEGATE" run --model test-model-beta --task "add a guard to foo()" --repo "$repo" --quiet
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.status == "ok"'
    echo "$output" | jq -e '.model == "test-model-beta"'
    local diff; diff="$(echo "$output" | jq -r .diff_path)"
    [ -s "$diff" ]
    grep -q "MOCK_CODEX_CHANGE" "$diff"
    local run_id; run_id="$(echo "$output" | jq -r .run_id)"
    local raw="$repo/.legion/runs/$run_id/codex.err"
    local filtered="$repo/.legion/runs/$run_id/codex.filtered.err"
    [ -f "$raw" ]
    [ ! -s "$filtered" ]
    [ "$(echo "$output" | jq -r .error_log)" = "no run-level errors were recorded (raw stderr: $raw)" ]
    # span written
    run bash -c "cat '$LEGION_TELEMETRY_DIR'/*.jsonl | jq -r 'select(.executor==\"codex\") | .executor'"
    [ "$output" = "codex" ]
    grep -Eq '^codex active=1 executor=1 depth=[1-9][0-9]* run=.+$' "$context"
}

@test "delegate run: forwards a preallocated run id to every non-Codex adapter" {
    local executor repo run_id
    for executor in claude cursor opencode; do
      repo="$(make_test_repo "adopt-$executor")"
      run_id="queued-slice-$executor"

      PATH="$REPO_ROOT/legion-router/bin:$PATH" \
        run "$DELEGATE" run --executor "$executor" --run-id "$run_id" \
          --task "do the thing" --repo "$repo" --quiet

      [ "$status" -eq 0 ]
      echo "$output" | jq -e --arg run "$run_id" '.run_id == $run'
      jq -e --arg run "$run_id" \
        '.run_id == $run and .state_version >= 2 and .lifecycle.phase == "ok"' \
        "$LEGION_REGISTRY_DIR/$run_id.json"
    done
}

@test "delegate run: fails closed when an adapter cannot honor run identity" {
    local repo; repo="$(make_test_repo legacy-adapter)"
    local adapter_bin="$TEST_TMPDIR/legacy-adapter-bin"
    mkdir -p "$adapter_bin"
    cat > "$adapter_bin/legion-cursor" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'legacy-cursor %s\n' "$*" >> "$MOCK_CALL_LOG"
case " $* " in
  *" --run-id "*) printf 'legacy adapter does not support --run-id\n' >&2; exit 64 ;;
esac
printf '{"status":"ok","run_id":"fresh-id"}\n'
SH
    chmod +x "$adapter_bin/legion-cursor"

    PATH="$adapter_bin:$PATH" run "$DELEGATE" run --executor cursor \
      --run-id queued-slice-cursor --task "do the thing" --repo "$repo" --quiet

    [ "$status" -eq 64 ]
    [[ "$output" == *"does not support --run-id"* ]]
    [ "$(grep -c '^legacy-cursor ' "$MOCK_CALL_LOG")" -eq 1 ]
    grep -Fq -- "--run-id queued-slice-cursor" "$MOCK_CALL_LOG"
}

@test "delegate run: executor context does not leak into sandbox setup" {
    local repo; repo="$(make_test_repo executor-context)"
    mkdir -p "$repo/.legion"
    printf '%s\n' '{"install":"printf '\''%s\\n'\'' \"${LEGION_ACTIVE:-unset}\" > SANDBOX_LEGION_ACTIVE.txt"}' > "$repo/.legion/sandbox.json"
    git -C "$repo" add .legion/sandbox.json
    git -C "$repo" -c user.email=t@t.c -c user.name=t commit -qm sandbox
    local context="$TEST_TMPDIR/context.log"

    MOCK_CONTEXT_LOG="$context" run "$DELEGATE" run --model test-model-beta \
        --task "add a guard" --repo "$repo" --quiet
    [ "$status" -eq 0 ]
    local diff; diff="$(echo "$output" | jq -r .diff_path)"
    grep -Fq '+unset' "$diff"
    grep -Eq '^codex active=1 executor=1 depth=[1-9][0-9]* run=.+$' "$context"
}

@test "delegate run: preserves raw stderr and separates benign MCP OAuth noise" {
    local repo; repo="$(make_test_repo stderr1)"
    local mcp_noise='ERROR codex_rmcp_client::oauth::refresh_transaction: error=failed to refresh OAuth tokens for server higgsfield: OAuth token refresh failed'
    local run_error='mock run-level error'

    MOCK_CODEX_STDERR="$mcp_noise
$run_error" run "$DELEGATE" run --model test-model-alpha --task "x" --repo "$repo" --quiet
    [ "$status" -eq 0 ]
    local run_id; run_id="$(echo "$output" | jq -r .run_id)"
    local raw="$repo/.legion/runs/$run_id/codex.err"
    local filtered="$repo/.legion/runs/$run_id/codex.filtered.err"

    [ "$(cat "$raw")" = "$mcp_noise
$run_error" ]
    [ "$(cat "$filtered")" = "$run_error" ]
    [ "$(echo "$output" | jq -r .error_log)" = "run-level errors: $filtered (raw stderr: $raw)" ]
}

@test "delegate run: filters generated Python bytecode from captured diffs" {
    local repo; repo="$(make_test_repo pycache1)"
    MOCK_CODEX_PYCACHE=1 run "$DELEGATE" run --model test-model-beta --task "run Python tests and edit code" --repo "$repo" --quiet
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.status == "ok"'
    local diff; diff="$(echo "$output" | jq -r .diff_path)"
    [ -s "$diff" ]
    ! grep -q "__pycache__" "$diff"
    ! grep -q "\\.pyc" "$diff"
}

@test "delegate run: warns about tracked and untracked source work hidden by the base" {
    local repo; repo="$(make_test_repo dirtywarn1)"
    printf '// dirty\n' >> "$repo/foo.ts"
    printf 'draft contract\n' > "$repo/CONTRACT.md"
    run "$DELEGATE" run --model test-model-alpha --task x --repo "$repo"
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARNING: the delegated agent will NOT see these files"* ]]
    [[ "$output" == *"modified tracked files (1):"* ]]
    [[ "$output" == *"foo.ts"* ]]
    [[ "$output" == *"untracked files (1):"* ]]
    [[ "$output" == *"CONTRACT.md"* ]]
    [[ "$output" == *"pass an explicit --base"* ]]
    [[ "$output" != *".legion/.gitignore"* ]]
}

@test "delegate run: --no-dirty-warn suppresses the source visibility warning" {
    local repo; repo="$(make_test_repo dirtywarn2)"
    printf 'draft contract\n' > "$repo/CONTRACT.md"
    run "$DELEGATE" run --model test-model-alpha --task x --repo "$repo" --no-dirty-warn
    [ "$status" -eq 0 ]
    [[ "$output" != *"WARNING: the delegated agent will NOT see these files"* ]]
}

@test "delegate run: --scope restricts the diff and reports excluded paths" {
    local repo; repo="$(make_test_repo scope1)"
    run "$DELEGATE" run --model test-model-alpha --task x --repo "$repo" --scope foo.ts
    [ "$status" -eq 0 ]
    local diff; diff="$(echo "$output" | tail -n 1 | jq -r .diff_path)"
    [ ! -s "$diff" ]
    [[ "$output" == *"changed paths:"* ]]
    [[ "$output" == *"MOCK_CODEX_CHANGE.txt"* ]]
    [[ "$output" == *"changes excluded by --scope:"* ]]
}

@test "delegate run: auto-emits an Opus baseline span for share measurement" {
    local repo; repo="$(make_test_repo share0)"
    run "$DELEGATE" run --model test-model-alpha --task "x" --repo "$repo" --quiet
    [ "$status" -eq 0 ]

    run bash -c "cat '$LEGION_TELEMETRY_DIR'/*.jsonl | jq -src '[.[].executor] | sort'"
    [ "$output" = '["codex","opus-baseline"]' ]

    run "$SHARE" --dir "$LEGION_TELEMETRY_DIR"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.status == "met" and .codex_runs == 1 and .opus_runs == 1'
}

@test "delegate run: synthetic Opus baseline is ignored when real Opus work exists" {
    local repo; repo="$(make_test_repo share1)"
    run "$DELEGATE" run --model test-model-alpha --task "x" --repo "$repo" --quiet
    [ "$status" -eq 0 ]
    "$REPO_ROOT/legion-observability/bin/legion-trace" emit \
      --executor opus --model opus --status ok >/dev/null

    run "$SHARE" --dir "$LEGION_TELEMETRY_DIR"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.status == "met" and .total_runs == 2 and .codex_runs == 1 and .opus_runs == 1'
}

@test "delegate run: synthetic Opus baseline is ignored when any real non-Codex work exists" {
    local repo; repo="$(make_test_repo share2)"
    run "$DELEGATE" run --model test-model-alpha --task "x" --repo "$repo" --quiet
    [ "$status" -eq 0 ]
    "$REPO_ROOT/legion-observability/bin/legion-trace" emit \
      --executor claude --model opus --status ok >/dev/null

    run "$SHARE" --dir "$LEGION_TELEMETRY_DIR"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.status == "met" and .total_runs == 2 and .codex_runs == 1 and .opus_runs == 1'
}

@test "delegate run: writes a legion.run-state.v1 registry record (running→terminal)" {
    local repo; repo="$(make_test_repo rs1)"
    out="$("$DELEGATE" run --model test-model-alpha --task "x" --repo "$repo" --quiet)"
    rid="$(echo "$out" | jq -r .run_id)"
    local rec="$(registry_dir_for_repo "$repo")/$rid.json"
    [ -f "$rec" ]
    [ "$(jq -r .schema "$rec")" = "legion.run-state.v1" ]
    [ "$(jq -r .run_id "$rec")" = "$rid" ]
    [ "$(jq -r .lifecycle.phase "$rec")" = "ok" ]
    [ "$(jq -r '.state_version >= 2' "$rec")" = "true" ]
}

@test "delegate run: run-state captures pid + pgid + started_at + worktree" {
    local repo; repo="$(make_test_repo rs2)"
    out="$("$DELEGATE" run --model test-model-alpha --task "x" --repo "$repo" --quiet)"
    rid="$(echo "$out" | jq -r .run_id)"
    local rec="$(registry_dir_for_repo "$repo")/$rid.json"
    [ "$(jq -r '.process.pid > 0' "$rec")" = "true" ]
    [ "$(jq -r '.process.pgid >= 0' "$rec")" = "true" ]
    [ "$(jq -r '.process.started_at | length > 0' "$rec")" = "true" ]
    [ "$(jq -r '.worktree_dir | contains(".legion/worktrees")' "$rec")" = "true" ]
}

@test "delegate run: registers the repo in repos.jsonl for cross-repo discovery" {
    local repo; repo="$(make_test_repo rs3)"
    "$DELEGATE" run --model test-model-alpha --task "x" --repo "$repo" --quiet >/dev/null
    local repos="$(repos_file_for_repo "$repo")"
    [ -f "$repos" ]
    grep -qF "$repo" "$repos"
}

@test "delegate run: registry record persists even when the run failed" {
    local repo; repo="$(make_test_repo rs4)"
    out="$(MOCK_CODEX_FAIL=1 "$DELEGATE" run --model test-model-alpha --task "x" --repo "$repo" --quiet || true)"
    rid="$(echo "$out" | jq -r .run_id)"
    local rec="$(registry_dir_for_repo "$repo")/$rid.json"
    [ -f "$rec" ]
    [ "$(jq -r .lifecycle.phase "$rec")" = "failed" ]
}

@test "delegate run: --run-id adopts a preallocated id (fanout queued records)" {
    local repo; repo="$(make_test_repo rid1)"
    out="$("$DELEGATE" run --model test-model-alpha --run-id "preset-xyz-123" --task "x" --repo "$repo" --quiet)"
    [ "$(echo "$out" | jq -r .run_id)" = "preset-xyz-123" ]
    [ -f "$(registry_dir_for_repo "$repo")/preset-xyz-123.json" ]
}

@test "delegate run: standalone span is its own trace root (trace_id=run_id, parent null)" {
    local repo; repo="$(make_test_repo trace0)"
    "$DELEGATE" run --model test-model-alpha --task "x" --repo "$repo" --quiet >/dev/null
    run bash -c "cat '$LEGION_TELEMETRY_DIR'/*.jsonl | jq -ec 'select(.executor==\"codex\") | {same:(.trace_id==.run_id), parent:.parent_id}'"
    [ "$output" = '{"same":true,"parent":null}' ]
}

@test "delegate run: inherits LEGION_TRACE_ID + LEGION_PARENT_ID into the span" {
    local repo; repo="$(make_test_repo trace1)"
    LEGION_TRACE_ID="trace-abc" LEGION_PARENT_ID="parent-xyz" \
        "$DELEGATE" run --model test-model-alpha --task "x" --repo "$repo" --quiet >/dev/null
    run bash -c "cat '$LEGION_TELEMETRY_DIR'/*.jsonl | jq -ec 'select(.executor==\"codex\") | {t:.trace_id, p:.parent_id}'"
    [ "$output" = '{"t":"trace-abc","p":"parent-xyz"}' ]
}

@test "delegate run: invokes codex with model, sandbox, worktree, stdin prompt" {
    local repo; repo="$(make_test_repo run2)"
    run "$DELEGATE" run --model test-model-alpha --task "x" --repo "$repo" --quiet
    [ "$status" -eq 0 ]
    assert_mock_called codex "exec --json -m test-model-alpha -s workspace-write"
    assert_mock_called codex "skip-git-repo-check"
}

@test "delegate run: span records copied secret names without values" {
    local repo; repo="$(make_test_repo secret-audit)"
    mkdir -p "$repo/.legion"
    printf 'TOKEN=super-secret\n' > "$repo/.env.local"
    printf '{"copy":[".env.local"]}\n' > "$repo/.legion/sandbox.json"

    run "$DELEGATE" run --model test-model-beta --task "touch foo" --repo "$repo" --quiet

    [ "$status" -eq 0 ]
    run bash -c "cat '$LEGION_TELEMETRY_DIR'/*.jsonl | jq -ec 'select(.executor==\"codex\") | .artifacts.copied_secret_names'"
    [ "$output" = '[".env.local"]' ]
    run bash -c "cat '$LEGION_TELEMETRY_DIR'/*.jsonl | jq -e 'select(.executor==\"codex\") | tostring | contains(\"super-secret\") | not'"
    [ "$status" -eq 0 ]
}

@test "delegate run: explicit container sandbox accepts flag and fails with Sandcastle install hint when absent" {
    if node -e 'import("@ai-hero/sandcastle")' >/dev/null 2>&1; then
      skip "@ai-hero/sandcastle is installed; missing-optional-dependency path not applicable"
    fi
    local repo; repo="$(make_test_repo run2docker)"
    run "$DELEGATE" run --model test-model-alpha --sandbox docker --task "x" --repo "$repo" --quiet
    [ "$status" -ne 0 ]
    [[ "$output" == *"@ai-hero/sandcastle not installed. Run: npm i -D @ai-hero/sandcastle"* ]]
    [[ "$output" != *"invalid --sandbox"* ]]
    assert_mock_not_called codex
}

@test "delegate run: podman and vercel sandbox values parse as Sandcastle modes" {
    if node -e 'import("@ai-hero/sandcastle")' >/dev/null 2>&1; then
      skip "@ai-hero/sandcastle is installed; missing-optional-dependency path not applicable"
    fi
    local repo; repo="$(make_test_repo run2podman)"
    run "$DELEGATE" run --model test-model-alpha --sandbox podman --task "x" --repo "$repo" --quiet
    [ "$status" -ne 0 ]
    [[ "$output" == *"@ai-hero/sandcastle not installed. Run: npm i -D @ai-hero/sandcastle"* ]]
    [[ "$output" != *"invalid --sandbox"* ]]

    repo="$(make_test_repo run2vercel)"
    run "$DELEGATE" run --model test-model-alpha --sandbox vercel --task "x" --repo "$repo" --quiet
    [ "$status" -ne 0 ]
    [[ "$output" == *"@ai-hero/sandcastle not installed. Run: npm i -D @ai-hero/sandcastle"* ]]
    [[ "$output" != *"invalid --sandbox"* ]]
}

@test "sandcastle-run: missing optional package exits 3 with install hint" {
    if node -e 'import("@ai-hero/sandcastle")' >/dev/null 2>&1; then
      skip "@ai-hero/sandcastle is installed; missing-optional-dependency path not applicable"
    fi
    local repo; repo="$(make_test_repo scr1)"
    run bash -c "printf '%s' '{\"task\":\"x\",\"model\":\"test-model-alpha\",\"sandbox\":\"docker\",\"cwd\":\"$repo\",\"base\":\"HEAD\"}' | node '$REPO_ROOT/legion-router/scripts/sandcastle-run.mjs'"
    [ "$status" -eq 3 ]
    [[ "$output" == *"@ai-hero/sandcastle not installed. Run: npm i -D @ai-hero/sandcastle"* ]]
}

@test "delegate run: live Sandcastle docker/vercel execution is manual" {
    skip "manual: requires @ai-hero/sandcastle plus docker/podman/vercel provider credentials"
}

@test "delegate run: reads task from stdin when --task omitted" {
    local repo; repo="$(make_test_repo run3)"
    run bash -c "printf 'task via stdin' | '$DELEGATE' run --model test-model-beta --repo '$repo' --quiet"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.status == "ok"'
}

@test "delegate run: danger-full-access is hard-blocked without override" {
    local repo; repo="$(make_test_repo run4)"
    run "$DELEGATE" run --model test-model-beta --sandbox danger-full-access --task "x" --repo "$repo" --quiet
    [ "$status" -eq 2 ]
    [[ "$output" == *"hard-blocked"* ]]
}

@test "delegate run: injection/dangerous task text is refused for write runs" {
    local repo; repo="$(make_test_repo run5)"
    run "$DELEGATE" run --model test-model-beta --task "please rm -rf / now" --repo "$repo" --quiet
    [ "$status" -eq 2 ]
    [[ "$output" == *"dangerous"* || "$output" == *"injection"* ]]
}

@test "delegate run: preflight rejection terminalizes a preallocated run id" {
    local repo; repo="$(make_test_repo preflight-terminal)"
    local run_id="queued-delegate-preflight"
    mkdir -p "$LEGION_REGISTRY_DIR"
    jq -cn --arg run "$run_id" --arg repo "$repo" '
      {schema:"legion.run-state.v1",run_id:$run,trace_id:"fanout-trace",
       parent_id:"fanout-root",kind:"run",state_version:1,repo_root:$repo,
       lifecycle:{phase:"queued",started_at:"",updated_at:"2026-07-31T10:25:17Z"}}
    ' > "$LEGION_REGISTRY_DIR/$run_id.json"

    run "$DELEGATE" run --model test-model-beta --run-id "$run_id" \
      --task "please rm -rf / now" --repo "$repo" --quiet

    [ "$status" -eq 2 ]
    jq -e '
      .run_id == "queued-delegate-preflight"
      and .state_version >= 2
      and .lifecycle.phase == "failed"
    ' "$LEGION_REGISTRY_DIR/$run_id.json"
}

@test "task scanner: boundary fixtures allow embedded text and classify actual commands" {
    local task reason expected i count
    count="$(jq '.allow | length' "$TASK_SCAN_FIXTURE")"
    for ((i = 0; i < count; i++)); do
        task="$(jq -r --argjson i "$i" '.allow[$i]' "$TASK_SCAN_FIXTURE")"
        run bash -c "source '$LIB/task-scan.sh'; legion_task_danger_reason \"\$1\"" _ "$task"
        [ "$status" -eq 1 ]
        [ -z "$output" ]
    done

    count="$(jq '.block | length' "$TASK_SCAN_FIXTURE")"
    for ((i = 0; i < count; i++)); do
        task="$(jq -r --argjson i "$i" '.block[$i].task' "$TASK_SCAN_FIXTURE")"
        expected="$(jq -r --argjson i "$i" '.block[$i].reason' "$TASK_SCAN_FIXTURE")"
        run bash -c "source '$LIB/task-scan.sh'; legion_task_danger_reason \"\$1\"" _ "$task"
        [ "$status" -eq 0 ]
        [ "$output" = "$expected" ]
    done
}

@test "delegate run: benign words containing command substrings reach the executor" {
    local repo; repo="$(make_test_repo scanner-boundary)"
    run "$DELEGATE" run --model test-model-beta \
      --task "Fix the truncated sync response with pseudocode and a backdrop table." \
      --repo "$repo" --quiet
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.status == "ok"'
    assert_mock_called codex "exec --json"
}

@test "delegate run: codex failure -> status failed, exit 1" {
    local repo; repo="$(make_test_repo run6)"
    MOCK_CODEX_FAIL=1 run "$DELEGATE" run --model test-model-beta --task "x" --repo "$repo" --quiet
    [ "$status" -eq 1 ]
    echo "$output" | jq -e '.status == "failed"'
    run bash -c "jq -s '[.[] | select(.artifacts.synthetic_opus_baseline == true)] | length' '$LEGION_TELEMETRY_DIR'/*.jsonl"
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

@test "delegate run: --budget-tokens marks over_budget when exceeded" {
    local repo; repo="$(make_test_repo run7)"
    # mock reports 1000+200+50+10 ~ 1060 total; budget 100 -> over
    run "$DELEGATE" run --model test-model-beta --task "x" --repo "$repo" --budget-tokens 100 --quiet
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.status == "over_budget"'
    run bash -c "jq -s '[.[] | select(.artifacts.synthetic_primary_baseline == true)] | length' '$LEGION_TELEMETRY_DIR'/*.jsonl"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
}

# ── review / cleanup ─────────────────────────────────────────────────
@test "delegate review: returns a verdict + emits span" {
    local repo; repo="$(make_test_repo rev1)"
    local base_sha; base_sha="$(git -C "$repo" rev-parse HEAD)"
    run "$DELEGATE" review --model test-model-beta --base HEAD --repo "$repo" \
      --task "Verify the learned idempotency guardrail." --quiet
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.status == "ok"'
    echo "$output" | jq -e --arg sha "$base_sha" '
      .reviewed_base_sha == $sha and .reviewed_head_sha == $sha
      and .attempts == 1 and .max_attempts == 2
    '
    assert_mock_called codex "exec -s read-only review --base $base_sha"
    assert_mock_called codex "-c developer_instructions=\"Review only the immutable diff $base_sha...$base_sha. Verify the learned idempotency guardrail.\""
    assert_mock_called codex "Review only the immutable diff $base_sha...$base_sha."
    assert_mock_called codex "Verify the learned idempotency guardrail."
}

@test "delegate review: freezes base/head SHAs and writes a durable terminal receipt" {
    local repo; repo="$(make_test_repo review-snapshot)"
    local base_sha head_sha
    base_sha="$(git -C "$repo" rev-parse HEAD)"
    printf 'export const added = true\n' >> "$repo/foo.ts"
    git -C "$repo" add foo.ts
    git -C "$repo" commit -qm "add review target"
    head_sha="$(git -C "$repo" rev-parse HEAD)"

    local review_context="$TEST_TMPDIR/review-context.log"
    MOCK_CODEX_REVIEW_CONTEXT_LOG="$review_context" run "$DELEGATE" review --model test-model-beta --base "$base_sha" --head HEAD \
      --repo "$repo" --quiet

    [ "$status" -eq 0 ]
    local receipt patch run_id
    receipt="$(echo "$output" | jq -r .terminal_receipt)"
    patch="$(echo "$output" | jq -r .review_patch)"
    run_id="$(echo "$output" | jq -r .run_id)"
    echo "$output" | jq -e --arg base "$base_sha" --arg head "$head_sha" '
      .status == "ok" and .reason == "completed"
      and .reviewed_base_sha == $base and .reviewed_head_sha == $head
      and .attempts == 1 and .verdict.verdict == "approve"
    '
    jq -e --arg base "$base_sha" --arg head "$head_sha" --arg patch "$patch" '
      .schema == "legion.review-terminal.v1"
      and .status == "ok" and .reason == "completed"
      and .reviewed_base_sha == $base and .reviewed_head_sha == $head
      and .review_patch == $patch and .attempts == 1
      and (.completed_at | length > 0)
    ' "$receipt"
    grep -q "export const added = true" "$patch"
    [ ! -d "$repo/.legion/worktrees/$run_id" ]
    grep -Eq "pwd=$repo/.legion/worktrees/.+ head=$head_sha" "$review_context"
    assert_mock_called codex "exec -s read-only review --base $base_sha"
}

@test "delegate review: retries one transient failure with the same immutable SHAs" {
    local repo; repo="$(make_test_repo review-retry)"
    local base_sha; base_sha="$(git -C "$repo" rev-parse HEAD)"
    export MOCK_CODEX_REVIEW_TRANSIENT_FAILS=1
    export MOCK_CODEX_REVIEW_ATTEMPT_FILE="$TEST_TMPDIR/review-attempts"

    run "$DELEGATE" review --model test-model-beta --base HEAD --repo "$repo" --quiet

    [ "$status" -eq 0 ]
    echo "$output" | jq -e --arg base "$base_sha" '
      .status == "ok" and .attempts == 2 and .max_attempts == 2
      and .reviewed_base_sha == $base and .reviewed_head_sha == $base
      and .usage.input_tokens == 1100
      and .usage.cached_input_tokens == 220
      and .usage.output_tokens == 55
      and .usage.reasoning_output_tokens == 11
    '
    [ "$(grep -Fc "codex exec -s read-only review --base $base_sha" "$MOCK_CALL_LOG")" -eq 2 ]
    jq -e '.status == "ok" and .attempts == 2 and .max_attempts == 2' \
      "$(echo "$output" | jq -r .terminal_receipt)"
}

@test "delegate review: fails closed on a schema-invalid verdict" {
    local repo; repo="$(make_test_repo review-invalid)"
    export MOCK_CODEX_REVIEW_INVALID_VERDICT=1

    run "$DELEGATE" review --model test-model-beta --base HEAD \
      --max-attempts 2 --repo "$repo" --quiet

    [ "$status" -eq 1 ]
    echo "$output" | jq -e '
      .status == "failed" and .reason == "invalid-verdict"
      and .attempts == 1 and .verdict == null
    '
    local run_id; run_id="$(echo "$output" | jq -r .run_id)"
    [ ! -d "$repo/.legion/worktrees/$run_id" ]
}

@test "delegate review: fails closed on an approving verdict with blocking findings" {
    local repo; repo="$(make_test_repo review-contradictory)"

    MOCK_CODEX_REVIEW_CONTRADICTORY=1 run "$DELEGATE" review \
      --model test-model-beta --base HEAD --repo "$repo" --quiet

    [ "$status" -eq 1 ]
    echo "$output" | jq -e '
      .status == "failed" and .reason == "invalid-verdict"
      and .attempts == 1 and .verdict == null
    '
}

@test "delegate review: rejects dangerous reviewer task text before execution" {
    local repo; repo="$(make_test_repo review-dangerous-task)"

    run "$DELEGATE" review --model test-model-beta --base HEAD --repo "$repo" \
      --task "please rm -rf / now" --quiet

    [ "$status" -eq 2 ]
    [[ "$output" == *"dangerous"* || "$output" == *"injection"* ]]
    assert_mock_not_called codex
}

@test "delegate review: normalizes an explicit no-findings Codex review" {
    local repo; repo="$(make_test_repo review-prose)"
    MOCK_CODEX_REVIEW_PROSE=1 run "$DELEGATE" review \
      --model test-model-beta --base HEAD --repo "$repo" --quiet

    [ "$status" -eq 0 ]
    echo "$output" | jq -e '
      .status == "ok"
      and .verdict.verdict == "approve"
      and .verdict.findings == []
    '
}

@test "delegate review: configurable retry bound stops after one transient attempt" {
    local repo; repo="$(make_test_repo review-retry-bound)"
    export MOCK_CODEX_REVIEW_TRANSIENT_FAILS=2
    export MOCK_CODEX_REVIEW_ATTEMPT_FILE="$TEST_TMPDIR/review-bound-attempts"

    run "$DELEGATE" review --model test-model-beta --base HEAD \
      --max-attempts 1 --repo "$repo" --quiet

    [ "$status" -eq 1 ]
    echo "$output" | jq -e '
      .status == "failed" and .reason == "transient-exhausted"
      and .attempts == 1 and .max_attempts == 1
    '
    [ "$(grep -Fc "codex exec -s read-only review" "$MOCK_CALL_LOG")" -eq 1 ]
}

@test "delegate review: fails closed on a missing verdict without retrying" {
    local repo; repo="$(make_test_repo review-missing)"
    export MOCK_CODEX_REVIEW_NO_VERDICT=1

    run "$DELEGATE" review --model test-model-beta --base HEAD \
      --max-attempts 2 --repo "$repo" --quiet

    [ "$status" -eq 1 ]
    echo "$output" | jq -e '
      .status == "failed" and .reason == "missing-verdict"
      and .attempts == 1 and .verdict == null
    '
    [ "$(grep -Fc "codex exec -s read-only review" "$MOCK_CALL_LOG")" -eq 1 ]
    jq -e '
      .status == "failed" and .reason == "missing-verdict"
      and .attempts == 1 and .verdict_path == null
    ' "$(echo "$output" | jq -r .terminal_receipt)"
}

@test "delegate review: does not retry a non-transient executor failure" {
    local repo; repo="$(make_test_repo review-failure)"
    export MOCK_CODEX_FAIL=1

    run "$DELEGATE" review --model test-model-beta --base HEAD \
      --max-attempts 2 --repo "$repo" --quiet

    [ "$status" -eq 1 ]
    echo "$output" | jq -e '
      .status == "failed" and .reason == "review-failed" and .attempts == 1
    '
    [ "$(grep -Fc "codex exec -s read-only review" "$MOCK_CALL_LOG")" -eq 1 ]
}

@test "delegate review: rejects an invalid retry bound before launching" {
    local repo; repo="$(make_test_repo review-bound)"

    run "$DELEGATE" review --model test-model-beta --base HEAD \
      --max-attempts 0 --repo "$repo" --quiet

    [ "$status" -eq 2 ]
    [[ "$output" == *"--max-attempts must be a positive integer"* ]]
    assert_mock_not_called codex
}

@test "delegate review: interruption writes a terminal receipt and cleans its snapshot" {
    local repo; repo="$(make_test_repo review-interrupt)"
    export MOCK_CODEX_REVIEW_DELAY=30
    export MOCK_CODEX_REVIEW_CHILD_PID_FILE="$TEST_TMPDIR/review-child.pid"
    local stdout="$TEST_TMPDIR/review-interrupt.out"
    local stderr="$TEST_TMPDIR/review-interrupt.err"

    "$DELEGATE" review --model test-model-beta --base HEAD \
      --repo "$repo" --quiet >"$stdout" 2>"$stderr" &
    local review_pid=$!
    local launched=0
    for _ in {1..100}; do
      if grep -qF "codex exec -s read-only review" "$MOCK_CALL_LOG"; then
        launched=1
        break
      fi
      sleep 0.02
    done
    [ "$launched" -eq 1 ]

    kill -TERM "$review_pid"
    local review_rc=0
    wait "$review_pid" || review_rc=$?

    [ "$review_rc" -eq 143 ]
    local child_pid; child_pid="$(cat "$MOCK_CODEX_REVIEW_CHILD_PID_FILE")"
    ! kill -0 "$child_pid" 2>/dev/null
    local receipt run_id registry
    receipt="$(find "$repo/.legion/runs" -name terminal.json -print -quit)"
    run_id="$(jq -r .run_id "$receipt")"
    registry="$LEGION_REGISTRY_DIR/$run_id.json"
    [ -n "$receipt" ]
    jq -e '
      .schema == "legion.review-terminal.v1"
      and .status == "failed" and .reason == "interrupted"
      and .codex_exit == 143 and .attempts == 1
      and (.reviewed_base_sha | length == 40)
      and (.reviewed_head_sha | length == 40)
      and (.completed_at | length > 0)
    ' "$receipt"
    jq -e '.kind == "review" and .lifecycle.phase == "failed"' "$registry"
    jq -e '.status == "failed" and .result_status == "failed"' \
      "$(dirname "$receipt")/status.json"
    run bash -c "cat '$LEGION_TELEMETRY_DIR'/*.jsonl | jq -e \
      'select(.run_id == \"$run_id\" and .executor == \"codex-review\" and .status == \"failed\")'"
    [ "$status" -eq 0 ]
    [ "$(find "$repo/.legion/worktrees" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')" = "0" ]
}

@test "delegate run: auto-cleans the worktree but preserves the diff (no --keep)" {
    local repo; repo="$(make_test_repo cln0)"
    out="$("$DELEGATE" run --model test-model-beta --task "x" --repo "$repo" --quiet)"
    rid="$(echo "$out" | jq -r .run_id)"
    [ ! -d "$repo/.legion/worktrees/$rid" ]         # worktree removed by default
    [ -s "$repo/.legion/runs/$rid/diff.patch" ]     # diff preserved under runs/
    [ -z "$(git -C "$repo" branch --list "legion/delegate-$rid")" ]  # branch deleted
}

@test "delegate run: --keep retains the worktree, then cleanup removes it" {
    local repo; repo="$(make_test_repo cln1)"
    out="$("$DELEGATE" run --model test-model-beta --task "x" --repo "$repo" --keep --quiet)"
    rid="$(echo "$out" | jq -r .run_id)"
    [ -d "$repo/.legion/worktrees/$rid" ]
    run "$DELEGATE" cleanup --run "$rid" --repo "$repo" --quiet
    [ "$status" -eq 0 ]
    [ ! -d "$repo/.legion/worktrees/$rid" ]
}

@test "delegate run: --detach preserves the worktree for its worker and status tracks completion" {
    local repo; repo="$(make_test_repo detach1)"
    local bin="$TEST_TMPDIR/detached-bin"
    mkdir -p "$bin"
    printf '#!/usr/bin/env bash\nsleep 2\nexec "%s" "$@"\n' "$BATS_TEST_DIRNAME/mocks/bin/codex" > "$bin/codex"
    chmod +x "$bin/codex"

    run env PATH="$bin:$PATH" "$DELEGATE" run --model test-model-alpha --task x --repo "$repo" --detach --quiet
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.status == "detached"'
    local rid; rid="$(echo "$output" | jq -r .run_id)"
    [ -d "$repo/.legion/worktrees/$rid" ]

    run "$DELEGATE" status --run "$rid" --repo "$repo" --quiet
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.status == "executing"'

    local i=0
    while [ "$i" -lt 50 ]; do
      run "$DELEGATE" status --run "$rid" --repo "$repo" --quiet
      [ "$status" -eq 0 ]
      [ "$(echo "$output" | jq -r .status)" = "completed" ] && break
      sleep 0.2
      i=$((i + 1))
    done
    [ "$(echo "$output" | jq -r .status)" = "completed" ]
    [ ! -d "$repo/.legion/worktrees/$rid" ]
}

@test "delegate run: writes .legion/.gitignore so runtime state never pollutes the repo" {
    local repo; repo="$(make_test_repo gi1)"
    "$DELEGATE" run --model test-model-beta --task "x" --repo "$repo" --quiet >/dev/null
    [ -f "$repo/.legion/.gitignore" ]
    grep -q '[*]' "$repo/.legion/.gitignore"
    # parent repo must show a clean tree (nothing from .legion leaks into status)
    [ -z "$(git -C "$repo" status --porcelain | grep -F '.legion')" ]
}

@test "delegate run: --archetype resolves model/sandbox/effort from routing.toml" {
  local repo; repo="$(make_test_repo arch1)"
  run "$DELEGATE" run --archetype bulk-mechanical-edit --task "x" --repo "$repo" --quiet
  [ "$status" -eq 0 ]
  echo "$output" | jq -e --arg model "$CODEX_WORKHORSE" '.model == $model'
  assert_mock_called codex "exec --json -m $CODEX_WORKHORSE -s workspace-write"
  assert_mock_called codex "model_reasoning_effort=medium"
}

@test "delegate run: explicit --model overrides --archetype" {
  local repo; repo="$(make_test_repo arch2)"
  run "$DELEGATE" run --archetype bulk-mechanical-edit --model test-model-beta --task x --repo "$repo" --quiet
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.model == "test-model-beta"'
}

@test "delegate run: a pre-resolved route preserves its fallback without resolving again" {
  local repo; repo="$(make_test_repo pre-resolved-route)"
  local route_env="$TEST_TMPDIR/pre-resolved-worker-env.log"
  LEGION_ROUTE_PRE_RESOLVED=1 \
    LEGION_RESOLVED_EXECUTOR=codex \
    LEGION_RESOLVED_FALLBACK=test-model-beta \
    MOCK_ROUTE_ENV_LOG="$route_env" \
    MOCK_CODEX_QUOTA_FAIL="$CODEX_WORKHORSE" \
    run "$DELEGATE" run --archetype route-does-not-exist \
      --executor codex --model "$CODEX_WORKHORSE" --sandbox workspace-write \
      --reasoning-effort high --task x --repo "$repo" --quiet

  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "ok" and .model == "test-model-beta"'
  [ -s "$route_env" ]
  ! grep -Eq 'pre=1|executor=codex|fallback=test-model-beta' "$route_env"
}

@test "delegate run: --archetype routing to executor=self is refused" {
  local repo; repo="$(make_test_repo arch3)"
  run "$DELEGATE" run --archetype deep-reasoning --task x --repo "$repo" --quiet
  [ "$status" -eq 2 ]
  echo "$output" | jq -e '.schema == "legion.route-preflight.v1"
    and .status == "blocked"
    and .reason == "inline-self-route"
    and .executor == "self"'
  assert_mock_not_called codex
}

@test "delegate run: top-level same-family Codex subagent is allowed" {
  local repo; repo="$(make_test_repo caller-codex)"
  LEGION_PRIMARY=codex run "$DELEGATE" run --model test-model-beta \
    --task x --repo "$repo" --quiet
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "ok" and .model == "test-model-beta"'
  assert_mock_called codex "exec --json -m test-model-beta"
}

@test "delegate run: delegated executor context blocks implicit nested Legion with telemetry" {
  local repo; repo="$(make_test_repo nested-codex)"
  LEGION_PRIMARY=codex LEGION_ACTIVE=1 LEGION_EXECUTOR=1 LEGION_DEPTH=1 \
    LEGION_EXECUTOR_NAME=codex LEGION_RUN_ID=parent-codex \
    run "$DELEGATE" run --model test-model-beta --task x --repo "$repo" --quiet
  [ "$status" -eq 2 ]
  echo "$output" | jq -e '.schema == "legion.route-preflight.v1"
    and .status == "blocked"
    and .reason == "nested-delegation-requires-explicit-executor"
    and .primary == "codex"
    and .executor == "codex"
    and (.receipt | endswith("/route-preflight.json"))'
  local receipt; receipt="$(echo "$output" | jq -r .receipt)"
  jq -e '.reason == "nested-delegation-requires-explicit-executor" and .primary == "codex"' "$receipt"
  run bash -c "cat '$LEGION_TELEMETRY_DIR'/*.jsonl | jq -ec \
    'select(.executor==\"legion-route\" and .status==\"blocked\")
     | .artifacts.reason == \"nested-delegation-requires-explicit-executor\"
       and .artifacts.primary == \"codex\"
       and .artifacts.target_executor == \"codex\"'"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
  assert_mock_not_called codex
}

@test "delegate run: each delegated-context sentinel independently blocks nesting" {
  local repo; repo="$(make_test_repo nested-sentinels)"
  LEGION_EXECUTOR=1 run "$DELEGATE" run --model test-model-beta \
    --task x --repo "$repo" --quiet
  [ "$status" -eq 2 ]
  echo "$output" | jq -e '.reason == "nested-delegation-requires-explicit-executor"'

  unset LEGION_EXECUTOR
  LEGION_DEPTH=1 run "$DELEGATE" run --model test-model-beta \
    --task x --repo "$repo" --quiet
  [ "$status" -eq 2 ]
  echo "$output" | jq -e '.reason == "nested-delegation-requires-explicit-executor"'
  assert_mock_not_called codex
}

@test "delegate run: physical Legion worktree cwd blocks nesting without env sentinels" {
  local repo; repo="$(make_test_repo nested-worktree-cwd)"
  local physical_cwd="$TEST_TMPDIR/outer/.legion/worktrees/slice"
  local logical_cwd="$TEST_TMPDIR/logical-cwd"
  mkdir -p "$physical_cwd"
  ln -s "$physical_cwd" "$logical_cwd"

  run env -u LEGION_ACTIVE -u LEGION_EXECUTOR -u LEGION_DEPTH \
    bash -c 'cd "$1" && "$2" run --model test-model-beta --task x --repo "$3" --quiet' \
    _ "$logical_cwd" "$DELEGATE" "$repo"

  [ "$status" -eq 2 ]
  echo "$output" | jq -e '.reason == "nested-delegation-requires-explicit-executor"'
  assert_mock_not_called codex
}

@test "delegate run: similar cwd names do not trigger worktree recursion guard" {
  local repo; repo="$(make_test_repo non-worktree-cwd)"
  local cwd="$TEST_TMPDIR/outer/.legion/worktrees-old/slice"
  mkdir -p "$cwd"

  run env -u LEGION_ACTIVE -u LEGION_EXECUTOR -u LEGION_DEPTH \
    bash -c 'cd "$1" && "$2" run --model test-model-beta --task x --repo "$3" --quiet' \
    _ "$cwd" "$DELEGATE" "$repo"

  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "ok" and .model == "test-model-beta"'
  assert_mock_called codex "exec --json -m test-model-beta"
}

@test "delegate run: blocked route does not follow repo runtime symlinks or persist task text" {
  local repo; repo="$(make_test_repo blocked-symlink)"
  local external="$TEST_TMPDIR/external-runtime"
  mkdir -p "$external"
  rm -rf "$repo/.legion"
  ln -s "$external" "$repo/.legion"
  local secret_task="nested task with private-marker-123"

  LEGION_ACTIVE=1 run "$DELEGATE" run --model test-model-beta \
    --task "$secret_task" --repo "$repo" --quiet

  [ "$status" -eq 2 ]
  echo "$output" | jq -e '.reason == "nested-delegation-requires-explicit-executor"'
  [ -z "$(find "$external" -mindepth 1 -print -quit)" ]
  ! grep -R -Fq "$secret_task" "$LEGION_STATE_ROOT"
  ! grep -R -Fq "$secret_task" "$LEGION_TELEMETRY_DIR"
}

@test "delegate run: delegated executor cannot use an implicit cross-harness archetype" {
  local repo; repo="$(make_test_repo caller-claude)"
  LEGION_PRIMARY=codex LEGION_ACTIVE=1 LEGION_EXECUTOR=1 LEGION_DEPTH=2 \
    LEGION_EXECUTOR_NAME=codex LEGION_RUN_ID=parent-codex \
    run "$DELEGATE" run --archetype frontend-polish --task x --repo "$repo" --quiet
  [ "$status" -eq 2 ]
  echo "$output" | jq -e '.reason == "nested-delegation-requires-explicit-executor"
    and .primary == "codex"
    and .executor == "claude"
    and .archetype == "frontend-polish"'
  assert_mock_not_called claude
}

@test "delegate run: a Codex worker explicitly hands off to Cursor with child depth, trace, and isolation" {
  local repo; repo="$(make_test_repo codex-to-cursor)"
  local context="$TEST_TMPDIR/cross-harness-context.log"
  LEGION_ACTIVE=1 LEGION_EXECUTOR=1 LEGION_DEPTH=1 \
    LEGION_EXECUTOR_NAME=codex LEGION_RUN_ID=parent-codex \
    LEGION_TRACE_ID=trace-codex MOCK_CONTEXT_DETAIL_LOG="$context" \
    run "$DELEGATE" run --executor cursor --task "do the thing" --repo "$repo" --quiet

  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "ok" and .executor == "cursor" and .run_id != "parent-codex"'
  [ ! -f "$repo/MOCK_CURSOR_CHANGE.txt" ]
  grep -Eq '^agent active=1 executor=1 depth=2 run=.+ name=cursor$' "$context"
  run bash -c "cat '$LEGION_TELEMETRY_DIR'/*.jsonl | jq -ec \
    'select(.executor == \"cursor\")
     | .trace_id == \"trace-codex\" and .parent_id == \"parent-codex\"'"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "delegate run: every supported worker can explicitly hand off to each other coding harness" {
  local source target repo
  for source in claude codex cursor opencode hermes; do
    for target in claude codex cursor opencode; do
      [[ "$source" == "$target" ]] && continue
      repo="$(make_test_repo "handoff-${source}-${target}")"
      LEGION_ACTIVE=1 LEGION_EXECUTOR=1 LEGION_DEPTH=1 \
        LEGION_EXECUTOR_NAME="$source" LEGION_RUN_ID="parent-${source}-${target}" \
        run "$DELEGATE" run --executor "$target" --task "do the thing" --repo "$repo" --quiet
      [ "$status" -eq 0 ]
      echo "$output" | jq -e --arg target "$target" '.status == "ok" and .executor == $target'
      local run_id; run_id="$(echo "$output" | jq -r .run_id)"
      run bash -c "cat '$LEGION_TELEMETRY_DIR'/*.jsonl | jq -ec --arg run '$run_id' --arg parent 'parent-${source}-${target}' \
        'select(.run_id == \$run) | .parent_id == \$parent'"
      [ "$status" -eq 0 ]
      [ "$output" = "true" ]
    done
  done
}

@test "delegate run: cross-harness handoff rejects same executor and depth-limit bypasses" {
  local repo; repo="$(make_test_repo handoff-guards)"
  LEGION_ACTIVE=1 LEGION_EXECUTOR=1 LEGION_DEPTH=1 \
    LEGION_EXECUTOR_NAME=codex LEGION_RUN_ID=parent-codex \
    run "$DELEGATE" run --executor codex --task x --repo "$repo" --quiet
  [ "$status" -eq 2 ]
  echo "$output" | jq -e '.reason == "nested-delegation-same-executor"'

  LEGION_ACTIVE=1 LEGION_EXECUTOR=1 LEGION_DEPTH=2 LEGION_MAX_DEPTH=2 \
    LEGION_EXECUTOR_NAME=codex LEGION_RUN_ID=parent-codex \
    run "$DELEGATE" run --executor cursor --task x --repo "$repo" --quiet
  [ "$status" -eq 2 ]
  echo "$output" | jq -e '.reason == "nested-delegation-depth-limit" and .depth == 2 and .max_depth == 2'
  assert_mock_not_called codex
  assert_mock_not_called agent
}

@test "delegate review: --archetype gives configured reviewer + structured verdict via --output-schema" {
  # `delegate review` is the codex structured-verdict flow -> use a codex review
  # archetype (security-review). Final-review routes to Fable through legion-run.
  # Cross-lineage archetypes (second-opinion/tiebreak)
  # route to Cursor and run via `--executor cursor`, not this codex path.
  local repo; repo="$(make_test_repo arch4)"
  local base_sha; base_sha="$(git -C "$repo" rev-parse HEAD)"
  run "$DELEGATE" review --archetype security-review --base HEAD --repo "$repo" --quiet
  [ "$status" -eq 0 ]
  echo "$output" | jq -e --arg model "$CODEX_REVIEW" '.model == $model and .verdict.verdict == "approve" and (.verdict.summary | type == "string")'
  assert_mock_called codex "exec -s read-only review --base $base_sha -m $CODEX_REVIEW"
  assert_mock_called codex "output-schema"
}

@test "delegate resume: continues a --keep'd run + emits codex-resume span" {
  local repo; repo="$(make_test_repo res1)"
  out="$("$DELEGATE" run --model test-model-alpha --task initial --repo "$repo" --keep --quiet)"
  rid="$(echo "$out" | jq -r .run_id)"
  run "$DELEGATE" resume --run "$rid" --task "follow up" --repo "$repo" --quiet
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "ok" and .thread_id == "mock-thread-0001"'
  assert_mock_called codex "exec resume mock-thread-0001"
}

@test "delegate resume: restores the original routing archetype in telemetry" {
  local repo; repo="$(make_test_repo res-archetype)"
  out="$("$DELEGATE" run --archetype bulk-mechanical-edit --task initial \
    --repo "$repo" --keep --quiet)"
  rid="$(echo "$out" | jq -r .run_id)"

  run "$DELEGATE" resume --run "$rid" --task "follow up" --repo "$repo" --quiet

  [ "$status" -eq 0 ]
  run bash -c "cat '$LEGION_TELEMETRY_DIR'/*.jsonl | jq -e --arg run '$rid' \
    'select(.executor == \"codex-resume\" and .run_id == \$run) \
     | .archetype == \"bulk-mechanical-edit\"'"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "delegate resume: recovers and backfills a legacy archetype after registry pruning" {
  local repo; repo="$(make_test_repo res-legacy-archetype)"
  out="$("$DELEGATE" run --archetype bulk-mechanical-edit --task initial \
    --repo "$repo" --keep --quiet)"
  rid="$(echo "$out" | jq -r .run_id)"
  rm -f "$repo/.legion/runs/$rid/archetype.txt"
  rm -f "$(registry_dir_for_repo "$repo")/$rid.json"

  run "$DELEGATE" resume --run "$rid" --task "follow up" --repo "$repo" --quiet

  [ "$status" -eq 0 ]
  [ "$(cat "$repo/.legion/runs/$rid/archetype.txt")" = "bulk-mechanical-edit" ]
  run bash -c "cat '$LEGION_TELEMETRY_DIR'/*.jsonl | jq -e --arg run '$rid' \
    'select(.executor == \"codex-resume\" and .run_id == \$run) \
     | .archetype == \"bulk-mechanical-edit\"'"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "delegate resume: fails clearly when the worktree was not kept" {
  local repo; repo="$(make_test_repo res2)"
  out="$("$DELEGATE" run --model test-model-alpha --task x --repo "$repo" --quiet)"
  rid="$(echo "$out" | jq -r .run_id)"
  run "$DELEGATE" resume --run "$rid" --task y --repo "$repo" --quiet
  [ "$status" -eq 2 ]
  [[ "$output" == *"--keep"* ]]
}

@test "delegate run: archetype quota failure does not downgrade off configured workhorse" {
  local repo; repo="$(make_test_repo fb1)"
  MOCK_CODEX_QUOTA_FAIL="$CODEX_WORKHORSE" run "$DELEGATE" run --archetype bulk-mechanical-edit --task x --repo "$repo" --quiet
  [ "$status" -eq 1 ]
  echo "$output" | jq -e --arg model "$CODEX_WORKHORSE" '.status == "failed" and .model == $model'
}

@test "delegate run: a non-quota failure does NOT burn the fallback chain" {
  local repo; repo="$(make_test_repo fb2)"
  MOCK_CODEX_FAIL=1 run "$DELEGATE" run --archetype bulk-mechanical-edit --task x --repo "$repo" --quiet
  [ "$status" -eq 1 ]
  echo "$output" | jq -e --arg model "$CODEX_WORKHORSE" '.status == "failed" and .model == $model'
}

@test "delegate run: LEGION_LOW_CREDIT=codex refuses to delegate to a depleted provider" {
  local repo; repo="$(make_test_repo lc1)"
  LEGION_LOW_CREDIT=codex run "$DELEGATE" run --archetype bulk-mechanical-edit --task x --repo "$repo" --quiet
  [ "$status" -eq 2 ]
  [[ "$output" == *"credits low"* ]]
}

@test "delegate run: LEGION_FORCE_DELEGATE=1 overrides LEGION_LOW_CREDIT=codex refusal" {
  local repo; repo="$(make_test_repo lc3)"
  LEGION_LOW_CREDIT=codex LEGION_FORCE_DELEGATE=1 run "$DELEGATE" run --archetype bulk-mechanical-edit --task x --repo "$repo" --quiet
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "ok"'
}

@test "delegate run: LEGION_LOW_CREDIT=claude delegates a normally-self task to Codex" {
  local repo; repo="$(make_test_repo lc2)"
  LEGION_LOW_CREDIT=claude run "$DELEGATE" run --archetype deep-reasoning --task x --repo "$repo" --quiet
  [ "$status" -eq 0 ]
  # the substitution warning goes to stderr (merged into $output by bats run); the
  # JSON result is the last line of stdout.
  echo "$output" | tail -n1 | jq -e --arg model "$CODEX_WORKHORSE" '.status == "ok" and .model == $model'
}

@test "delegate run: over_budget exits 0 — usable diff, graceful degradation (M1)" {
  local repo; repo="$(make_test_repo m1)"
  run "$DELEGATE" run --model test-model-alpha --task x --repo "$repo" --budget-tokens 1 --quiet
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "over_budget"'
}

@test "delegate resume: inherits the original run's model, not the default (M2)" {
  local repo; repo="$(make_test_repo m2)"
  out="$("$DELEGATE" run --model test-model-beta --task init --repo "$repo" --keep --quiet)"
  rid="$(echo "$out" | jq -r .run_id)"
  run "$DELEGATE" resume --run "$rid" --task followup --repo "$repo" --quiet
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.model == "test-model-beta"'
}

@test "delegate cleanup --all --purge removes worktrees + branches + run artifacts" {
  local repo; repo="$(make_test_repo cl1)"
  "$DELEGATE" run --model test-model-alpha --task a --repo "$repo" --keep --quiet >/dev/null
  "$DELEGATE" run --model test-model-alpha --task b --repo "$repo" --keep --quiet >/dev/null
  [ "$(find "$repo/.legion/worktrees" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" = "2" ]
  run "$DELEGATE" cleanup --all --purge --repo "$repo" --quiet
  [ "$status" -eq 0 ]
  [ "$(find "$repo/.legion/worktrees" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')" = "0" ]
  [ ! -d "$repo/.legion/runs" ]
  [ -z "$(git -C "$repo" branch --list 'legion/delegate-*')" ]
}

@test "delegate run: auto-deletes its worktree on completion (default, no --keep)" {
  local repo; repo="$(make_test_repo auto1)"
  "$DELEGATE" run --model test-model-alpha --task x --repo "$repo" --quiet >/dev/null
  [ "$(find "$repo/.legion/worktrees" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')" = "0" ]
}

@test "delegate review: passes a clean reasoning effort (no 5-field pipe leak)" {
    local repo; repo="$(make_test_repo rev5)"
    run "$DELEGATE" review --archetype security-review --base HEAD --repo "$repo" --quiet
    [ "$status" -eq 0 ]
    assert_mock_called codex "model_reasoning_effort=max"
    ! grep -qE 'model_reasoning_effort=[a-z]+\|' "$MOCK_CALL_LOG"
}

@test "cost: negative token counts clamp to 0 (lib safe for any caller)" {
    run "$LIB/cost.sh" "$CODEX_WORKHORSE" -100 100
    [ "$status" -eq 0 ]
    [ "$output" = "0.0015" ]
}

@test "delegate: no command prints usage and exits 2" {
    run "$DELEGATE"
    [ "$status" -eq 2 ]
    [[ "$output" == *"legion-delegate"* ]]
}

# ── service-management portability preflight (M4) ────────────────────
@test "router on non-macOS: install stores creds (exit 0); service commands refuse" {
    local fakebin="$TEST_TMPDIR/fakebin"; mkdir -p "$fakebin"
    printf '#!/usr/bin/env bash\necho Linux\n' > "$fakebin/uname"
    chmod +x "$fakebin/uname"
    local router="$REPO_ROOT/legion-router/scripts/router.sh"

    # install is portable: it stores credentials everywhere, then skips the
    # launchd step on non-macOS (exit 0) and points at the foreground runner.
    PATH="$fakebin:$PATH" run bash "$router" install
    [ "$status" -eq 0 ]
    [[ "$output" == *"only stored credentials"* ]]
    [[ "$output" == *"legion-router dev"* ]]

    # status/start/stop genuinely need launchd → still refuse on non-macOS.
    PATH="$fakebin:$PATH" run bash "$router" status
    [ "$status" -eq 1 ]
    [[ "$output" == *"macOS-only"* ]]
}

@test "delegate review: honors a non-approving verdict from a reviewer that exited nonzero" {
    local repo; repo="$(make_test_repo review-recover-reject)"
    # Real Codex writes a complete review and still exits nonzero when its prose
    # does not satisfy --output-schema. Discarding that reports a finished review
    # as unavailable, which downstream retries instead of acting on the verdict.
    MOCK_CODEX_REVIEW_FINDINGS=1 MOCK_CODEX_REVIEW_EXIT=1 \
      run "$DELEGATE" review --model test-model-beta --base HEAD --repo "$repo" --quiet

    [ "$status" -eq 0 ]
    echo "$output" | jq -e '
      .status == "ok"
      and .verdict.verdict == "request_changes"
      and (.verdict.findings | length) == 1
    '
}

@test "delegate review: never honors an approval from a reviewer that exited nonzero" {
    local repo; repo="$(make_test_repo review-recover-approve)"
    # Approval is what authorizes publishing, so it must come from a reviewer
    # that exited cleanly. Recovery is one-directional by design.
    MOCK_CODEX_REVIEW_EXIT=1 \
      run "$DELEGATE" review --model test-model-beta --base HEAD --repo "$repo" --quiet

    [ "$status" -ne 0 ]
    echo "$output" | jq -e '.status == "failed" and .verdict == null'
}
