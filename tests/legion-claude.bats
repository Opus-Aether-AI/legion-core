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

install_launch_failed_python() {
    local shim_dir="$TEST_TMPDIR/launch-failed-python" real_python
    real_python="$(command -v python3)"
    mkdir -p "$shim_dir"
    cat > "$shim_dir/python3" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == */legion-process-supervisor.py ]]; then
  should_fail=1
  if [[ -n "${LEGION_TEST_LAUNCH_FAIL_MODEL:-}" ]]; then
    should_fail=0
    for arg in "$@"; do
      [[ "$arg" != "$LEGION_TEST_LAUNCH_FAIL_MODEL" ]] || should_fail=1
    done
  fi
  if [[ "$should_fail" -ne 1 ]]; then
    exec "$LEGION_TEST_REAL_PYTHON" "$@"
  fi
  status_file=""
  max_runtime=""
  for ((i=1; i <= $#; i++)); do
    if [[ "${!i}" == --status-file ]]; then
      j=$((i + 1)); status_file="${!j}"
    elif [[ "${!i}" == --max-runtime-seconds ]]; then
      j=$((i + 1)); max_runtime="${!j}"
    fi
  done
  jq -cn --arg reason 'child launch failed: command not found: admitted-claude' \
    --argjson runtime "$max_runtime" \
    '{schema:"legion.child-execution-lease.v1",status:"launch_failed",
      reason:$reason,max_runtime_seconds:$runtime}' > "$status_file"
  exit 127
fi
exec "$LEGION_TEST_REAL_PYTHON" "$@"
SH
    chmod +x "$shim_dir/python3"
    export LEGION_TEST_REAL_PYTHON="$real_python"
    export PATH="$shim_dir:$PATH"
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
    local attempt span
    attempt="$(echo "$output" | jq -r .attempt_receipt)"
    jq -e '
      .schema == "legion.attempt.v1" and .terminal_status == "succeeded"
      and .usage_status == "known" and .cost_status == "known"' \
      "$attempt"
    lease="$(echo "$output" | jq -r .lease_receipt)"
    [ -n "$lease" ]
    jq -e '.schema == "legion.child-execution-lease.v1" and .status == "completed"' "$lease"

    run bash -c "cat '$LEGION_TELEMETRY_DIR'/*.jsonl | jq -r '[.executor, .archetype] | @tsv'"
    [ "$status" -eq 0 ]
    [ "$output" = $'claude\tfinal-review' ]
    span="$(cat "$LEGION_TELEMETRY_DIR"/*.jsonl | jq -c 'select(.executor == "claude")')"
    jq -e --argjson attempt "$(cat "$attempt")" --arg attempt_path "$attempt" '
      .tokens == $attempt.usage and .usage_status == $attempt.usage_status
      and .cost_usd == $attempt.cost_usd and .cost_status == $attempt.cost_status
      and .artifacts.provider_attempt == true
      and .artifacts.attempt_receipt == $attempt_path
    ' <<<"$span"
    grep -Eq '^claude active=1 executor=1 depth=[1-9][0-9]* run=.+$' "$context"
}

@test "legion-claude: authenticated supervisor launch failure is no-spend terminal evidence" {
    local repo run_id art lease
    repo="$(make_test_repo launch-failed)"
    run_id="launch-failed-claude"
    install_launch_failed_python

    run "$LEGION_CLAUDE" run --task "do the thing" --repo "$repo" \
      --run-id "$run_id" --quiet --no-fallback

    [ "$status" -eq 1 ]
    echo "$output" | jq -e '
      .status == "failed"
      and .attempt_receipt == null and .failure_receipt == null
      and .usage == null and .usage_status == "not_applicable"
      and .cost_usd == null and .cost_status == "not_applicable"
      and (.reason | contains("child launch failed"))
      and (.lease_receipt | type == "string" and length > 0)
    '
    lease="$(echo "$output" | jq -r .lease_receipt)"
    jq -e '
      .schema == "legion.child-execution-lease.v1"
      and .status == "launch_failed"
      and (has("child_exit_code") | not)
    ' "$lease"
    art="$repo/.legion/runs/$run_id"
    [ "$(find "$art" -maxdepth 1 -name 'attempt-*.json' | wc -l | tr -d ' ')" -eq 0 ]
    [ "$(find "$art" -maxdepth 1 -name 'failure-*.json' | wc -l | tr -d ' ')" -eq 0 ]
    ! grep -q '^claude -p ' "$MOCK_CALL_LOG"
    if compgen -G "$LEGION_TELEMETRY_DIR/*.jsonl" >/dev/null; then
      run jq -s -e '[.[] | select(.artifacts.provider_attempt == true)] | length > 0' \
        "$LEGION_TELEMETRY_DIR"/*.jsonl
      [ "$status" -ne 0 ]
    fi
}

@test "legion-claude: later launch failure retains only earlier paid spend" {
    local repo run_id art lease prior_attempt provider_spans provider_receipt first_model second_model
    repo="$(make_test_repo later-launch-failed)"
    run_id="later-launch-failed-claude"
    install_launch_failed_python
    first_model="$(python3 "$REPO_ROOT/legion-router/scripts/legion-route.py" \
      frontend-polish | jq -r .model)"
    second_model="$CLAUDE_DEFAULT"

    LEGION_TEST_LAUNCH_FAIL_MODEL="$second_model" \
      MOCK_CLAUDE_DECLINE_MODELS="$first_model" \
      run "$LEGION_CLAUDE" run --task "do the thing" --repo "$repo" \
        --run-id "$run_id" --model "$first_model" \
        --fallback-models "$second_model" --allow-premium-credit --quiet --no-fallback

    [ "$status" -eq 1 ]
    echo "$output" | jq -e --arg second "$second_model" '
      .status == "failed" and .model == $second
      and .attempt_receipt == null and .failure_receipt == null
      and .usage.input_tokens == 100000 and .usage_status == "known"
      and (.cost_usd | type == "number" and . > 0)
      and .cost_status == "known"
      and (.reason | contains("child launch failed"))
    '
    lease="$(echo "$output" | jq -r .lease_receipt)"
    jq -e '.status == "launch_failed" and (has("child_exit_code") | not)' "$lease"
    art="$repo/.legion/runs/$run_id"
    prior_attempt="$art/attempt-1.json"
    jq -e '.executor == "claude" and .terminal_status == "failed" and .cost_status == "known"' \
      "$prior_attempt"
    jq -en --argjson reported "$(echo "$output" | jq -c .cost_usd)" \
      --argjson prior "$(jq -c .cost_usd "$prior_attempt")" '$reported == $prior'
    [ "$(find "$art" -maxdepth 1 -name 'attempt-*.json' | wc -l | tr -d ' ')" -eq 1 ]
    provider_spans="$(cat "$LEGION_TELEMETRY_DIR"/*.jsonl | jq -c \
      'select(.executor == "claude" and .artifacts.provider_attempt == true)')"
    [ "$(wc -l <<<"$provider_spans" | tr -d ' ')" -eq 1 ]
    provider_receipt="$(jq -r '.artifacts.attempt_receipt' <<<"$provider_spans")"
    [ "${provider_receipt##*/}" = "attempt-1.json" ]
    cmp "$prior_attempt" "$provider_receipt"
    ! grep -q -- "--model $second_model" "$MOCK_CALL_LOG"
}

@test "legion-claude: timeout never applies a partial diff" {
    local repo attempt failure
    repo="$(make_test_repo lease-partial)"

    MOCK_CLAUDE_WRITE=1 MOCK_CLAUDE_DELAY=30 \
      run "$LEGION_CLAUDE" run --task "make a change and wait" --repo "$repo" \
        --max-runtime-seconds 1 --apply --keep --quiet

    [ "$status" -eq 1 ]
    echo "$output" | jq -e '.status == "timed_out" and (.reason | contains("expired after 1 seconds"))'
    attempt="$(echo "$output" | jq -r .attempt_receipt)"
    failure="$(echo "$output" | jq -r .failure_receipt)"
    jq -e '.terminal_status == "timed_out" and .failure.class == "timed_out"' "$attempt"
    jq -e '.class == "timed_out" and .retryable == false' "$failure"
    [ ! -e "$repo/claude-unexpected.txt" ]
    [[ "$(echo "$output" | jq -r .worktree)" == *"removed"* ]]
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

@test "legion-claude: unattended mode refuses danger permissions before provider launch" {
    local repo; repo="$(make_test_repo passthru)"
    run "$LEGION_CLAUDE" run --task "do it" --repo "$repo" \
        --effort high --append-system-prompt "be safe" --dangerously-skip-permissions --quiet
    [ "$status" -eq 1 ]
    echo "$output" | jq -e '
      .status == "refused" and .reason == "permission_policy_refused"
      and .attempt_receipt == null and .failure_receipt == null
      and .usage == null and .usage_status == "not_applicable"
      and .cost_usd == null and .cost_status == "not_applicable"'
    ! grep -q '^claude -p ' "$MOCK_CALL_LOG"
    assert_mock_not_called legion-delegate
}

@test "legion-claude: unattended workspace writes deny prompts and keep ordinary flags" {
    local repo; repo="$(make_test_repo unattended-flags)"
    run "$LEGION_CLAUDE" run --task "do it" --repo "$repo" \
        --effort high --append-system-prompt "be safe" --quiet
    [ "$status" -eq 0 ]
    assert_mock_called claude "--permission-mode dontAsk"
    assert_mock_called claude "--effort high"
    assert_mock_called claude "--append-system-prompt be safe"
    ! grep -q -- '--dangerously-skip-permissions' "$MOCK_CALL_LOG"
}

@test "legion-claude: Fable requires explicit premium-credit consent before any provider call" {
    local repo premium_model
    repo="$(make_test_repo fable-consent)"
    premium_model="$(python3 "$REPO_ROOT/legion-router/scripts/legion-route.py" frontend-polish | jq -r '.model')"
    run "$LEGION_CLAUDE" run --task "polish it" --repo "$repo" \
      --model "$premium_model" --quiet
    [ "$status" -eq 1 ]
    echo "$output" | jq -e '
      .status == "refused" and .reason == "admission_refused"
      and .attempt_receipt == null and .failure_receipt == null
      and .usage == null and .usage_status == "not_applicable"
      and .cost_usd == null and .cost_status == "not_applicable"'
    assert_mock_not_called claude
    assert_mock_not_called legion-delegate

    run "$LEGION_CLAUDE" run --task "polish it" --repo "$repo" \
      --model "$premium_model" --allow-premium-credit --quiet
    [ "$status" -eq 0 ]
    assert_mock_called claude "-p --output-format json --model $premium_model"
}

@test "legion-claude: permission prompts fail closed without fallback or danger retry" {
    local repo; repo="$(make_test_repo permission-refusal)"
    MOCK_CLAUDE_PERMISSION_PROMPT=1 run "$LEGION_CLAUDE" run \
      --task "edit it" --repo "$repo" --quiet
    [ "$status" -eq 1 ]
    echo "$output" | jq -e '.reason == "permission_policy_refused" and .fell_back == false'
    [ "$(grep -c '^claude -p ' "$MOCK_CALL_LOG")" -eq 1 ]
    ! grep -q -- '--dangerously-skip-permissions' "$MOCK_CALL_LOG"
    assert_mock_not_called legion-delegate
}

@test "legion-claude: output_started suppresses all fallback" {
    local repo; repo="$(make_test_repo partial-output)"
    MOCK_CLAUDE_OUTPUT_THEN_FAIL=1 run "$LEGION_CLAUDE" run \
      --task "edit it" --repo "$repo" --fallback-models test-fallback-model --quiet
    [ "$status" -eq 1 ]
    echo "$output" | jq -e '.reason == "claude_error_after_output" and .fell_back == false'
    [ "$(grep -c '^claude -p ' "$MOCK_CALL_LOG")" -eq 1 ]
    assert_mock_not_called legion-delegate
    jq -e '.output_started == true and .failure.retryable == false' \
      "$(echo "$output" | jq -r .attempt_receipt)"
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
    jq -e '.terminal_status == "failed" and .failure.class == "policy_refused"' \
      "$(echo "$output" | jq -r .attempt_receipt)"
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

@test "legion-claude: fallback preserves Claude attempts and exposes Codex aliases" {
    local repo run_id art final_attempt
    repo="$(make_test_repo fallback-receipts)"
    run_id="fallback-receipts-claude"

    MOCK_CLAUDE_LIMIT=1 MOCK_DELEGATE_WRITE_RECEIPTS=1 \
      run "$LEGION_CLAUDE" run --task "do the thing" --repo "$repo" \
        --run-id "$run_id" --quiet

    [ "$status" -eq 0 ]
    art="$repo/.legion/runs/$run_id"
    final_attempt="$(echo "$output" | jq -r .attempt_receipt)"
    [ "$final_attempt" = "$art/attempt-1.json" ]
    jq -e '.executor == "codex" and .terminal_status == "succeeded"' "$final_attempt"
    jq -e '.executor == "codex"' "$art/attempt.json"
    jq -e '.executor == "claude" and .failure.class == "quota"' "$art/claude/attempt-1.json"
    jq -e '.class == "quota"' "$art/claude/failure-1.json"
    [ ! -e "$art/failure.json" ]
    echo "$output" | jq -e '
      .run_id == "fallback-receipts-claude"
      and .executor == "codex" and .result == "GPT_FALLBACK"
      and (.last_message_path | endswith("/last-message.txt"))
      and .fell_back == true and .fell_back_reason == "claude_limit"
      and .failure_receipt == null'
}

@test "legion-claude: real Codex fallback reconciles the shared run directory" {
    local repo run_id art final_attempt
    repo="$(make_test_repo real-fallback-receipts)"
    run_id="real-fallback-receipts-claude"

    PATH="$(path_without legion-delegate)" \
      CLAUDE_BIN="$BATS_TEST_DIRNAME/mocks/bin/claude" MOCK_CLAUDE_LIMIT=1 \
      run "$LEGION_CLAUDE" run --task "do the thing" --repo "$repo" \
        --run-id "$run_id" --quiet

    [ "$status" -eq 0 ]
    art="$repo/.legion/runs/$run_id"
    final_attempt="$(echo "$output" | jq -r .attempt_receipt)"
    [ "$final_attempt" = "$art/attempt-1.json" ]
    jq -e '.executor == "codex" and .terminal_status == "succeeded"' "$final_attempt"
    jq -e '.executor == "claude" and .failure.class == "quota"' "$art/claude/attempt-1.json"
    local claude_span
    claude_span="$(cat "$LEGION_TELEMETRY_DIR"/*.jsonl | jq -c \
      'select(.run_id == "real-fallback-receipts-claude" and .executor == "claude")')"
    for evidence in preflight_receipt attempt_receipt failure_receipt lease_receipt; do
      local evidence_path
      evidence_path="$(jq -r --arg key "$evidence" '.artifacts[$key]' <<<"$claude_span")"
      [[ "$evidence_path" == "$art/claude/"* ]]
      [ -f "$evidence_path" ]
    done
    echo "$output" | jq -e '
      .run_id == "real-fallback-receipts-claude"
      and .executor == "codex" and (.result | length > 0)
      and (.last_message_path | endswith("/last-message.txt"))
      and .fell_back == true and .fell_back_reason == "claude_limit"'
}

@test "legion-claude: Codex fallback receives only the remaining absolute lease" {
    local repo fallback_runtime
    repo="$(make_test_repo fallback-deadline)"

    MOCK_CLAUDE_LIMIT=1 MOCK_CLAUDE_DELAY=1 \
      run "$LEGION_CLAUDE" run --task "do the thing" --repo "$repo" \
        --max-runtime-seconds 4 --quiet

    [ "$status" -eq 0 ]
    fallback_runtime="$(sed -n 's/^legion-delegate .*--max-runtime-seconds \([0-9][0-9]*\).*/\1/p' "$MOCK_CALL_LOG")"
    [[ "$fallback_runtime" =~ ^[1-3]$ ]]
    echo "$output" | jq -e '.executor == "codex" and .fell_back == true'
}

@test "legion-claude: same-vendor retries share one absolute lease" {
    local repo
    repo="$(make_test_repo model-chain-deadline)"

    MOCK_CLAUDE_DECLINE_MODELS="model-a,model-b" MOCK_CLAUDE_DELAY=2 \
      run "$LEGION_CLAUDE" run --task x --model model-a \
        --fallback-models model-b --repo "$repo" --max-runtime-seconds 3 --quiet

    [ "$status" -eq 1 ]
    echo "$output" | jq -e '
      .executor == "claude" and .status == "timed_out"
      and (.reason | contains("expired after 3 seconds"))'
    [ "$(grep -c '^claude -p ' "$MOCK_CALL_LOG")" -eq 2 ]
    assert_mock_not_called legion-delegate
}

@test "legion-claude: inherited child lease only lowers the local deadline" {
    local repo inherited started elapsed
    repo="$(make_test_repo inherited-deadline)"
    inherited="$(python3 - <<'PY'
import time
print(time.monotonic_ns() + 1_000_000_000)
PY
)"
    started="$SECONDS"
    LEGION_CHILD_LEASE_DEADLINE_NS="$inherited" MOCK_CLAUDE_DELAY=30 \
      run "$LEGION_CLAUDE" run --task x --repo "$repo" \
        --max-runtime-seconds 10 --no-fallback --quiet
    elapsed=$((SECONDS-started))

    [ "$status" -eq 1 ]
    [ "$elapsed" -lt 5 ]
    echo "$output" | jq -e '.status == "timed_out" and (.lease_receipt | length > 0)'
}

@test "legion-claude: environment archetype survives Codex fallback" {
    local repo; repo="$(make_test_repo fb-env-archetype)"
    LEGION_ARCHETYPE=security-review MOCK_CLAUDE_LIMIT=1 \
      run "$LEGION_CLAUDE" run --task "review it" --repo "$repo" --quiet
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.executor == "codex" and .fell_back == true'
    assert_mock_called legion-delegate "--archetype security-review"
    run bash -c "cat '$LEGION_TELEMETRY_DIR'/*.jsonl | jq -e \
      'select(.executor == \"claude\" and .archetype == \"security-review\")'"
    [ "$status" -eq 0 ]
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
    ! grep -q '^claude -p ' "$MOCK_CALL_LOG"
}

@test "legion-claude: low-credit no-launch span is not a provider attempt" {
    local repo span; repo="$(make_test_repo low-credit-no-launch)"
    LEGION_LOW_CREDIT=claude run "$LEGION_CLAUDE" run --task "do the thing" \
      --repo "$repo" --quiet --no-fallback
    [ "$status" -eq 1 ]
    ! grep -q '^claude -p ' "$MOCK_CALL_LOG"
    span="$(cat "$LEGION_TELEMETRY_DIR"/*.jsonl | jq -c 'select(.executor == "claude")')"
    jq -e '
      .status == "failed" and .cost_status == "not_applicable"
      and .usage_status == "not_applicable"
      and .usage == null and .cost_usd == null
      and .artifacts.provider_attempt != true
    ' <<<"$span"
}

@test "legion-claude: worktree setup failure fails closed before invoking Claude" {
    local repo; repo="$(make_test_repo worktree-fail)"
    run "$LEGION_CLAUDE" run --task "do the thing" --repo "$repo" \
        --base "refs/does-not-exist" --quiet
    [ "$status" -eq 1 ]
    echo "$output" | jq -e \
        '.status == "failed" and .reason == "worktree_setup_failed" and .fell_back == false'
    ! grep -q '^claude -p ' "$MOCK_CALL_LOG"
    assert_mock_not_called legion-delegate
    run bash -c "cat '$LEGION_TELEMETRY_DIR'/*.jsonl | jq -e 'select(.executor == \"claude\" and .status == \"failed\")'"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.artifacts.provider_attempt != true'
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
    ! grep -q '^claude -p ' "$MOCK_CALL_LOG"
    run bash -c "cat '$LEGION_TELEMETRY_DIR'/*.jsonl | jq -e \
      'select(.executor == \"claude\" and .artifacts.provider_attempt != true)'"
    [ "$status" -eq 0 ]
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

# ── same-vendor model chain (--fallback-models) ──────────────────────────
# The chain exists because the Claude adapter's only escape used to be
# CROSS-EXECUTOR: a model that declined handed the work to a codex model, which
# for a frontend-craft archetype throws away the reason the archetype exists.

@test "legion-claude: a declined model advances to the next in the chain" {
    local repo; repo="$(make_test_repo chain-advance)"
    MOCK_CLAUDE_DECLINE_MODELS="model-declines" \
      run "$LEGION_CLAUDE" run --task x --model model-declines \
        --fallback-models "model-answers" --repo "$repo" --quiet
    [ "$status" -eq 0 ]
    # The run succeeds, and reports the model that actually answered.
    echo "$output" | jq -e '.status == "ok" and .model == "model-answers"'
    # It stayed with Claude rather than crossing to codex.
    echo "$output" | jq -e '.executor == "claude" and .fell_back == false'
}

@test "legion-claude: an exhausted chain reports failure, never ok" {
    local repo; repo="$(make_test_repo chain-exhausted)"
    # Every model declines. A decline is a well-formed answer, so without an
    # explicit guard this returns rc 0 with the decline text as the "result" of a
    # successful run -- the caller then acts on a refusal as if it were work.
    MOCK_CLAUDE_DECLINE_MODELS="model-a,model-b" \
      run "$LEGION_CLAUDE" run --task x --model model-a \
        --fallback-models "model-b" --repo "$repo" --no-fallback --quiet
    echo "$output" | jq -e '.status != "ok"'
    echo "$output" | jq -e '.reason == "claude_declined"'
}

@test "legion-claude: a single-model chain that declines is not reported ok" {
    local repo attempt_cost; repo="$(make_test_repo chain-single)"
    # No fallback_refs at all -- the common case for most archetypes.
    MOCK_CLAUDE_DECLINE_MODELS="$CLAUDE_DEFAULT" \
      run "$LEGION_CLAUDE" run --task x --model "$CLAUDE_DEFAULT" \
        --repo "$repo" --no-fallback --quiet
    echo "$output" | jq -e '.status != "ok"'
    echo "$output" | jq -e '.reason == "claude_declined"'
    attempt_cost="$(jq -r .cost_usd "$(echo "$output" | jq -r .attempt_receipt)")"
    [ "$(echo "$output" | jq -r .cost_usd)" = "$attempt_cost" ]
    [ "$attempt_cost" != 0 ]
}

@test "foreground adapters disarm signal accounting only after provider span emission" {
    local script receipt_line span_line disarm_line
    for script in legion-cursor.sh legion-opencode.sh legion-deepseek.sh legion-pi-hermes.sh; do
      receipt_line="$(grep -n 'legion_adapter_write_attempt ' "$REPO_ROOT/legion-router/scripts/$script" | tail -1 | cut -d: -f1)"
      span_line="$(grep -n '^[[:space:]]*legion_adapter_emit_normal_provider_span ' "$REPO_ROOT/legion-router/scripts/$script" | tail -1 | cut -d: -f1)"
      disarm_line="$(grep -n '^[[:space:]]*legion_adapter_disarm_signal_receipt$' "$REPO_ROOT/legion-router/scripts/$script" | tail -1 | cut -d: -f1)"
      [ "$receipt_line" -lt "$span_line" ]
      [ "$span_line" -lt "$disarm_line" ]
    done
    local claude_script="$REPO_ROOT/legion-router/scripts/legion-claude.sh"
    receipt_line="$(grep -n 'legion_adapter_write_attempt ' "$claude_script" | tail -1 | cut -d: -f1)"
    span_line="$(grep -n '^[[:space:]]*legion_adapter_emit_normal_provider_span ' "$claude_script" | tail -1 | cut -d: -f1)"
    disarm_line="$(grep -n '^[[:space:]]*finish_claude_signal_accounting$' "$claude_script" | tail -1 | cut -d: -f1)"
    [ "$receipt_line" -lt "$span_line" ]
    [ "$span_line" -lt "$disarm_line" ]
}

@test "legion-claude: an ordinary failure does NOT burn the model chain" {
    local repo; repo="$(make_test_repo chain-not-burned)"
    # MOCK_CLAUDE_FAIL is a real run failure, not a decline. Retrying another
    # model would hide the cause and pay twice for the same broken task.
    local calls="$TEST_TMPDIR/chain-calls.log"
    MOCK_CLAUDE_FAIL=1 MOCK_CALL_LOG="$calls" \
      run "$LEGION_CLAUDE" run --task x --model model-a \
        --fallback-models "model-b" --repo "$repo" --no-fallback --quiet
    echo "$output" | jq -e '.reason != "claude_declined"'
    ! grep -q -- '--model model-b' "$calls"
}

@test "legion-claude: a task ABOUT declined models does not reroute itself" {
    local repo; repo="$(make_test_repo chain-prose)"
    # The classifier reads .result, which is the model's own prose. A successful
    # run whose subject is model ids and refusals must stay a successful run.
    local calls="$TEST_TMPDIR/prose-calls.log"
    MOCK_CALL_LOG="$calls" \
      run "$LEGION_CLAUDE" run --task "explain model_not_found and refusal handling" \
        --model model-a --fallback-models "model-b" --repo "$repo" --quiet
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.status == "ok" and .model == "model-a"'
    ! grep -q -- '--model model-b' "$calls"
}

@test "legion-claude: a declined attempt's spend is not lost from the total" {
    local repo; repo="$(make_test_repo chain-metering)"
    # out_file is overwritten each time round the chain, so without explicit
    # banking the declined attempt's input tokens vanish from the record. They
    # were really spent: the prompt was sent and read before the model declined.
    # The declining model's id must match a costs.json row, or its spend prices
    # at $0 and the test would pass for the wrong reason.
    MOCK_CLAUDE_DECLINE_MODELS="$CLAUDE_DEFAULT" \
      run "$LEGION_CLAUDE" run --task x --model "$CLAUDE_DEFAULT" \
        --fallback-models "model-answers" --repo "$repo" --quiet
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.model == "model-answers"
      and .usage_status == "known" and .usage.input_tokens == 101000
      and .cost_status == "known"'
    # The answering model's own cost is the mock's 0.12; the declined attempt read
    # 100k input tokens at the default role's rate, so the reported total
    # must exceed a single call's.
    echo "$output" | jq -e '.cost_usd > 0.12'
    local art provider_spans
    art="$(dirname "$(echo "$output" | jq -r .attempt_receipt)")"
    provider_spans="$(cat "$LEGION_TELEMETRY_DIR"/*.jsonl | jq -c \
      'select(.executor == "claude")')"
    [ "$(wc -l <<<"$provider_spans" | tr -d ' ')" -eq 2 ]
    jq -e --argjson attempt "$(cat "$art/attempt-1.json")" '
      select(.artifacts.intermediate_attempt == true)
      | .tokens == $attempt.usage and .usage_status == $attempt.usage_status
        and .cost_usd == $attempt.cost_usd and .cost_status == $attempt.cost_status
    ' <<<"$provider_spans"
    [ "$(jq -s '[.[].cost_usd // 0] | add > 0.12' <<<"$provider_spans")" = true ]
    # The chain is legible in the record rather than only in the logs.
    run bash -c "cat '$LEGION_TELEMETRY_DIR'/*.jsonl | jq -r '.artifacts.declined_models // empty'"
    [ "$output" = "$CLAUDE_DEFAULT" ]
}

@test "legion-claude: final provider span uses its receipt model and duration" {
    local repo final_attempt final_span; repo="$(make_test_repo chain-final-span)"
    MOCK_CLAUDE_DECLINE_MODELS="$CLAUDE_DEFAULT" \
      MOCK_CLAUDE_DECLINE_DELAY=1 \
      MOCK_CLAUDE_EFFECTIVE_MODEL="anthropic/effective-answer" \
      run "$LEGION_CLAUDE" run --task x --model "$CLAUDE_DEFAULT" \
        --fallback-models "model-answers" --repo "$repo" --quiet

    [ "$status" -eq 0 ]
    final_attempt="$(echo "$output" | jq -r .attempt_receipt)"
    final_span="$(cat "$LEGION_TELEMETRY_DIR"/*.jsonl | jq -c \
      'select(.executor == "claude" and ((.artifacts.intermediate_attempt // false) | not))')"
    jq -e --arg model "$(jq -r '.effective_model // .requested_model' "$final_attempt")" \
      --argjson duration "$(jq -r .duration_ms "$final_attempt")" \
      '.model == $model and .duration_ms == $duration' <<<"$final_span"
    [ "$(jq -r .model <<<"$final_span")" = "anthropic/effective-answer" ]
}
