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
    CODEX_FRONTIER="$("$REPO_ROOT/legion-router/bin/legion-route" --model-ref codex_frontier)"
    CLAUDE_DEFAULT="$("$REPO_ROOT/legion-router/bin/legion-route" --model-ref claude_default)"
    CLAUDE_FRONTIER="$("$REPO_ROOT/legion-router/bin/legion-route" --model-ref claude_frontier)"
    CURSOR_DEFAULT="$("$REPO_ROOT/legion-router/bin/legion-route" --model-ref cursor_default)"
    MINIMAX_MATCH="$(jq -r '.models[] | select(.match == "minimax") | .match' "$LEGION_COSTS_FILE")"
}

@test "run ids stay unique across simultaneous fresh harness shells" {
    ids="$TEST_TMPDIR/run-ids"
    for _index in $(seq 1 32); do
        bash -c 'source "$1"; RANDOM=1234; printf "%s\n" "$(legion_new_run_id)"' _ \
            "$LIB/run-id.sh" >> "$ids" &
    done
    wait

    [ "$(wc -l < "$ids" | tr -d ' ')" -eq 32 ]
    [ "$(sort -u "$ids" | wc -l | tr -d ' ')" -eq 32 ]
    while IFS= read -r run_id; do
        [[ "$run_id" =~ ^[0-9]{8}-[0-9]{6}-[0-9a-f]{24}$ ]]
    done < "$ids"
}

@test "run ids work when PATH omits date and utility commands" {
    run env PATH="$TEST_TMPDIR/empty-path" /bin/bash -c \
        'source "$1"; legion_new_run_id' _ "$LIB/run-id.sh"

    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]{8}-[0-9]{6}-[0-9a-f]{24}$ ]]
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

# Replace only supervisor invocations with deterministic cleanup_failed evidence;
# every other Python call still reaches the real interpreter.
install_cleanup_failed_supervisor_shim() {
    local shim_dir="$TEST_TMPDIR/cleanup-failed-python" real_python
    real_python="$(command -v python3)"
    mkdir -p "$shim_dir"
    cat > "$shim_dir/python3" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == */legion-process-supervisor.py ]]; then
  status_file=""
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == --status-file ]]; then status_file="$2"; break; fi
    shift
  done
  printf '%s\n' '{"schema":"legion.child-execution-lease.v1","status":"cleanup_failed","reason":"forced cleanup evidence","max_runtime_seconds":30}' > "$status_file"
  exit 70
fi
exec "$LEGION_TEST_REAL_PYTHON" "$@"
SH
    chmod +x "$shim_dir/python3"
    export LEGION_TEST_REAL_PYTHON="$real_python"
    export PATH="$shim_dir:$PATH"
}

install_prelaunch_cleanup_failed_supervisor_shim() {
    local shim_dir="$TEST_TMPDIR/prelaunch-cleanup-failed-python" real_python
    real_python="$(command -v python3)"
    mkdir -p "$shim_dir"
    cat > "$shim_dir/python3" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == */legion-process-supervisor.py ]]; then
  status_file=""
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == --status-file ]]; then status_file="$2"; break; fi
    shift
  done
  printf '%s\n' '{"schema":"legion.child-execution-lease.v1","status":"cleanup_failed","reason":"forced prelaunch containment evidence","max_runtime_seconds":30,"child_started":false}' > "$status_file"
  exit 70
fi
exec "$LEGION_TEST_REAL_PYTHON" "$@"
SH
    chmod +x "$shim_dir/python3"
    export LEGION_TEST_REAL_PYTHON="$real_python"
    export PATH="$shim_dir:$PATH"
}

install_launch_failed_supervisor_shim() {
    local shim_dir="$TEST_TMPDIR/launch-failed-python" real_python
    real_python="$(command -v python3)"
    mkdir -p "$shim_dir"
    cat > "$shim_dir/python3" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == */legion-process-supervisor.py ]]; then
  status_file="" max_runtime="" child="" model="" after_separator=0 should_fail=1
  for ((i=1; i <= $#; i++)); do
    if [[ "${!i}" == --status-file ]]; then
      j=$((i + 1)); status_file="${!j}"
    elif [[ "${!i}" == --max-runtime-seconds ]]; then
      j=$((i + 1)); max_runtime="${!j}"
    elif [[ "${!i}" == -- ]]; then
      after_separator=1
    elif [[ "$after_separator" -eq 1 && -z "$child" ]]; then
      child="${!i}"
    elif [[ "${!i}" == -m || "${!i}" == --model ]]; then
      j=$((i + 1)); model="${!j}"
    fi
  done
  if [[ -n "${LEGION_TEST_LAUNCH_FAIL_EXECUTABLE:-}" \
        && "${child##*/}" != "$LEGION_TEST_LAUNCH_FAIL_EXECUTABLE" ]]; then
    should_fail=0
  fi
  if [[ -n "${LEGION_TEST_LAUNCH_FAIL_MODEL:-}" \
        && "$model" != "$LEGION_TEST_LAUNCH_FAIL_MODEL" ]]; then
    should_fail=0
  fi
  [[ "$should_fail" -eq 1 ]] || exec "$LEGION_TEST_REAL_PYTHON" "$@"
  jq -cn --arg reason 'child launch failed: command not found: admitted-provider' \
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

install_exhausted_remaining_seconds_python_shim() {
    local shim_dir="$TEST_TMPDIR/exhausted-remaining-python" real_python
    real_python="$(command -v python3)"
    mkdir -p "$shim_dir"
  cat > "$shim_dir/python3" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == - ]]; then
  source_file="$(mktemp)"
  trap 'rm -f "$source_file"' EXIT
  cat > "$source_file"
  if grep -q 'remaining = int(sys.argv\[1\]) - time.monotonic_ns()' "$source_file"; then
    count=0
    [[ ! -f "$LEGION_TEST_REMAINING_COUNT_FILE" ]] || count="$(cat "$LEGION_TEST_REMAINING_COUNT_FILE")"
    printf '%s\n' "$((count + 1))" > "$LEGION_TEST_REMAINING_COUNT_FILE"
    value="$(printf '%s\n' "${LEGION_TEST_REMAINING_VALUES:-0}" | cut -d, -f"$((count + 1))")"
    [[ -n "$value" ]] || value=0
    printf '%s\n' "$value"
    exit 0
  fi
  exec "$LEGION_TEST_REAL_PYTHON" "$@" < "$source_file"
fi
exec "$LEGION_TEST_REAL_PYTHON" "$@"
SH
    chmod +x "$shim_dir/python3"
    export LEGION_TEST_REAL_PYTHON="$real_python"
    export LEGION_TEST_REMAINING_COUNT_FILE="$TEST_TMPDIR/remaining-seconds-count"
    : > "$LEGION_TEST_REMAINING_COUNT_FILE"
    export PATH="$shim_dir:$PATH"
}

# Simulate a supervisor that returned after the provider ran but lost its
# durable lease sidecar. The prompt reviewer must not treat the provider's
# otherwise valid answer/attempt as safe enough to continue or approve.
install_missing_lease_supervisor_shim() {
    local shim_dir="$TEST_TMPDIR/missing-lease-python" real_python
    real_python="$(command -v python3)"
    mkdir -p "$shim_dir"
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'if [[ "${1:-}" == */legion-process-supervisor.py ]]; then' \
      '  status_file=""' \
      '  for ((i=1; i <= $#; i++)); do' \
      '    if [[ "${!i}" == --status-file ]]; then j=$((i + 1)); status_file="${!j}"; break; fi' \
      '  done' \
      '  "$LEGION_TEST_REAL_PYTHON" "$@"; rc=$?' \
      '  [[ -z "$status_file" ]] || rm -f "$status_file"' \
      '  exit "$rc"' \
      'fi' \
      'exec "$LEGION_TEST_REAL_PYTHON" "$@"' > "$shim_dir/python3"
    chmod +x "$shim_dir/python3"
    export LEGION_TEST_REAL_PYTHON="$real_python"
    export PATH="$shim_dir:$PATH"
}

install_refused_fallback_preflight_shim() {
    local shim_dir="$TEST_TMPDIR/refused-fallback-python" real_python
    real_python="$(command -v python3)"
    mkdir -p "$shim_dir"
    cat > "$shim_dir/python3" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == */legion_preflight.py ]]; then
  for ((i=1; i <= $#; i++)); do
    if [[ "${!i}" == --model ]]; then
      j=$((i + 1))
      if [[ "${!j}" == refused-fallback ]]; then
        printf '%s\n' '{"schema":"legion.preflight.v1","executor":"codex","status":"incompatible","reason":"forced fallback refusal","identity":null,"cache":{"hit":false,"key":null},"compatibility":{}}'
        exit 1
      fi
    fi
  done
fi
exec "$LEGION_TEST_REAL_PYTHON" "$@"
SH
    chmod +x "$shim_dir/python3"
    export LEGION_TEST_REAL_PYTHON="$real_python"
    export PATH="$shim_dir:$PATH"
}

install_authenticated_incompatible_preflight_shim() {
    local shim_dir="$TEST_TMPDIR/authenticated-incompatible-python" real_python
    local refused_executor="$1" refused_model="$2"
    real_python="$(command -v python3)"
    mkdir -p "$shim_dir"
    cat > "$shim_dir/python3" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == */legion_preflight.py ]]; then
  executor="" model="" sandbox=""
  for ((i=1; i <= $#; i++)); do
    case "${!i}" in
      --executor) j=$((i + 1)); executor="${!j}" ;;
      --model) j=$((i + 1)); model="${!j}" ;;
      --sandbox) j=$((i + 1)); sandbox="${!j}" ;;
    esac
  done
  if [[ "$executor" == "$LEGION_TEST_REFUSED_EXECUTOR" \
        && "$model" == "$LEGION_TEST_REFUSED_MODEL" ]]; then
    jq -cn --arg executor "$executor" --arg model "$model" --arg sandbox "$sandbox" '
      {schema:"legion.preflight.v1",executor:$executor,status:"incompatible",
       reason:"authenticated model incompatibility",
       identity:null,cache:{hit:false,key:null},
       compatibility:{model:{requested:$model,status:"incompatible"},
                      sandbox:{requested:$sandbox,status:"supported"}}}'
    exit 1
  fi
fi
exec "$LEGION_TEST_REAL_PYTHON" "$@"
SH
    chmod +x "$shim_dir/python3"
    export LEGION_TEST_REAL_PYTHON="$real_python"
    export LEGION_TEST_REFUSED_EXECUTOR="$refused_executor"
    export LEGION_TEST_REFUSED_MODEL="$refused_model"
    export PATH="$shim_dir:$PATH"
}

install_authenticated_untested_preflight_shim() {
    local shim_dir="$TEST_TMPDIR/authenticated-untested-python" real_python
    local refused_executor="$1" refused_model="$2"
    real_python="$(command -v python3)"
    mkdir -p "$shim_dir"
    cat > "$shim_dir/python3" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == */legion_preflight.py ]]; then
  executor="" model="" sandbox=""
  for ((i=1; i <= $#; i++)); do
    case "${!i}" in
      --executor) j=$((i + 1)); executor="${!j}" ;;
      --model) j=$((i + 1)); model="${!j}" ;;
      --sandbox) j=$((i + 1)); sandbox="${!j}" ;;
    esac
  done
  if [[ "$executor" == "$LEGION_TEST_REFUSED_EXECUTOR" \
        && "$model" == "$LEGION_TEST_REFUSED_MODEL" ]]; then
    jq -cn --arg executor "$executor" --arg model "$model" --arg sandbox "$sandbox" '
      {schema:"legion.preflight.v1",executor:$executor,status:"untested",
       reason:"authenticated executable version is untested",
       identity:{executable_path:"/trusted/agent",version:"future",config_sha256:"fixture"},
       cache:{hit:false,key:null},
       compatibility:{model:{requested:$model,status:"supported"},
                      sandbox:{requested:$sandbox,status:"supported"},
                      version:{status:"untested"}}}'
    exit 1
  fi
fi
exec "$LEGION_TEST_REAL_PYTHON" "$@"
SH
    chmod +x "$shim_dir/python3"
    export LEGION_TEST_REAL_PYTHON="$real_python"
    export LEGION_TEST_REFUSED_EXECUTOR="$refused_executor"
    export LEGION_TEST_REFUSED_MODEL="$refused_model"
    export PATH="$shim_dir:$PATH"
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
@test "cost: claude_default pricing comes from costs.json" {
    run "$LIB/cost.sh" "$CLAUDE_DEFAULT" 1000000 500000 0 0
    [ "$status" -eq 0 ]
    # 1M in @ $5.00/M + 500k out @ $25.00/M
    [ "$output" = "17.5" ]
}

@test "cost: the frontier Claude role is priced above the default one" {
    # The tier split is a COST decision, so the price gap is the thing to pin:
    # if these ever match, either the catalog collapsed back to one tier or a
    # costs.json row is missing and the frontier model is being under-billed.
    run "$LIB/cost.sh" "$CLAUDE_FRONTIER" 1000000 500000 0 0
    [ "$status" -eq 0 ]
    # 1M in @ $10.00/M + 500k out @ $50.00/M
    [ "$output" = "35" ]
}

@test "cost: codex_review pricing comes from costs.json" {
    run "$LIB/cost.sh" "$CODEX_REVIEW" 100000 5000 0 0
    [ "$status" -eq 0 ]
    # 100k in @ $4.00/M + 5k out @ $20.00/M
    [ "$output" = "0.5" ]
}

@test "cost: codex_workhorse pricing comes from costs.json" {
    run "$LIB/cost.sh" "$CODEX_WORKHORSE" 100000 5000 0 0
    [ "$status" -eq 0 ]
    # 100k in @ $2.00/M + 5k out @ $12.00/M
    [ "$output" = "0.26" ]
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

@test "cost: receipt provenance distinguishes an unpriced zero from known pricing" {
    run bash -c 'source "$1"; cost_model_has_pricing "$2"' _ \
      "$LIB/cost.sh" "$CODEX_WORKHORSE"
    [ "$status" -eq 0 ]

    run bash -c 'source "$1"; cost_model_has_pricing "$2"' _ \
      "$LIB/cost.sh" fixture-unpriced-model
    [ "$status" -eq 1 ]
}

# ── legion-delegate run ──────────────────────────────────────────────
@test "delegate run: happy path returns ok + captures diff + emits span" {
    local repo; repo="$(make_test_repo run1)"
    local context="$TEST_TMPDIR/context.log"
    MOCK_CONTEXT_LOG="$context" run "$DELEGATE" run --model test-model-beta --task "add a guard to foo()" --repo "$repo" --quiet
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.status == "ok"'
    echo "$output" | jq -e '.model == "test-model-beta"'
    jq -e '.schema == "legion.preflight.v1" and .status == "supported"' \
      "$(echo "$output" | jq -r .preflight_receipt)"
    jq -e '
      .schema == "legion.attempt.v1" and .terminal_status == "succeeded"
      and .usage_status == "known" and .cost_status == "unknown"
      and .cost_usd == null and .cost_source == null' \
      "$(echo "$output" | jq -r .attempt_receipt)"
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
    run bash -c "cat '$LEGION_TELEMETRY_DIR'/*.jsonl | jq -r 'select(.executor==\"codex\" and .artifacts.provider_attempt==true) | .executor'"
    [ "$output" = "codex" ]
    grep -Eq '^codex active=1 executor=1 depth=[1-9][0-9]* run=.+$' "$context"
}

@test "delegate run: unavailable Codex refuses in preflight before provider launch" {
    local repo; repo="$(make_test_repo codex-preflight-unavailable)"
    CODEX_BIN="$TEST_TMPDIR/missing-codex" run "$DELEGATE" run \
      --model test-model-beta --task "do the thing" --repo "$repo" --quiet

    [ "$status" -eq 1 ]
    echo "$output" | jq -e '
      .status == "refused" and (.reason | contains("binary not found"))
      and .attempt_receipt == null and .failure_receipt == null'
    ! grep -q '^codex exec ' "$MOCK_CALL_LOG"
    [ ! -d "$repo/.legion/worktrees" ]
}

@test "delegate run: forwards explicit premium consent to the Claude admission boundary" {
    local repo premium_model
    repo="$(make_test_repo delegated-fable-consent)"
    premium_model="$(python3 "$REPO_ROOT/legion-router/scripts/legion-route.py" frontend-polish | jq -r '.model')"
    PATH="$REPO_ROOT/legion-router/bin:$PATH" run "$DELEGATE" run \
      --executor claude --model "$premium_model" \
      --task "polish it" --repo "$repo" --quiet
    [ "$status" -eq 1 ]
    echo "$output" | jq -e '.status == "refused" and .reason == "admission_refused"'
    ! grep -q '^claude -p ' "$MOCK_CALL_LOG"

    PATH="$REPO_ROOT/legion-router/bin:$PATH" run "$DELEGATE" run \
      --executor claude --model "$premium_model" \
      --allow-premium-credit --task "polish it" --repo "$repo" --quiet
    [ "$status" -eq 0 ]
    assert_mock_called claude "-p --output-format json --model $premium_model"
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

@test "Pi adapter: uses official JSON mode, maps model thinking, and meters a terminal result" {
    local repo; repo="$(make_test_repo pi-contract)"
    PI_BIN=pi run bash -c 'cd "$1" && "$2" run --model openai/fixture-pi:high --task "make a scoped edit" --repo "$3" --keep --quiet' \
      _ "$TEST_TMPDIR" "$REPO_ROOT/legion-router/bin/legion-pi" "$repo"

    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.status == "ok" and .executor == "pi" and .model == "openai/fixture-pi" and .result == "PI_OK_OUTPUT"'
    jq -e '.terminal_status == "succeeded" and .usage_status == "known" and .cost_status == "known"' \
      "$(echo "$output" | jq -r .attempt_receipt)"
    echo "$output" | jq -e '.usage == {"input_tokens":220,"cached_input_tokens":30,"output_tokens":38,"reasoning_output_tokens":12,"cache_creation_input_tokens":5} and .cost_usd == 0.007'
    assert_mock_called pi '-p --mode json --no-session --no-approve --no-extensions --no-skills --no-prompt-templates --model openai/fixture-pi --thinking high'
    assert_mock_called sandbox-exec '-f '
    local diff; diff="$(echo "$output" | jq -r .diff_path)"
    [ -s "$diff" ]
    local run_id profile artifact_root
    run_id="$(echo "$output" | jq -r .run_id)"
    artifact_root="$(dirname "$(echo "$output" | jq -r .diff_path)")"
    profile="$artifact_root/filesystem.sb"
    [ -f "$profile" ]
    grep -Fq "(literal \"$artifact_root/pi.out.jsonl\")" "$profile"
    grep -Fq "(literal \"$artifact_root/pi.err\")" "$profile"
    grep -Fq "(literal \"$artifact_root/pi.usage.json\")" "$profile"
    ! grep -Fq "(subpath \"$artifact_root\")" "$profile"
    ! grep -Fq 'last-message.txt' "$profile"

    MOCK_PI_ERROR_EVENT=1 PI_BIN=pi run bash -c 'cd "$1" && "$2" run --model openai/fixture-pi --task "make a scoped edit" --repo "$3" --quiet' \
      _ "$TEST_TMPDIR" "$REPO_ROOT/legion-router/bin/legion-pi" "$repo"
    [ "$status" -ne 0 ]
    echo "$output" | jq -e '.status == "error" and .provider_exit == 0'

    MOCK_PI_MALFORMED=1 PI_BIN=pi run bash -c 'cd "$1" && "$2" run --model openai/fixture-pi --task "make a scoped edit" --repo "$3" --quiet' \
      _ "$TEST_TMPDIR" "$REPO_ROOT/legion-router/bin/legion-pi" "$repo"
    [ "$status" -ne 0 ]
    echo "$output" | jq -e '.status == "error" and .provider_exit == 0'
    jq -e '.terminal_status == "failed" and .failure.class == "malformed_event"' \
      "$(echo "$output" | jq -r .attempt_receipt)"

    MOCK_PI_MISSING_USAGE=1 PI_BIN=pi run bash -c 'cd "$1" && "$2" run --model openai/fixture-pi --task "make a scoped edit" --repo "$3" --quiet' \
      _ "$TEST_TMPDIR" "$REPO_ROOT/legion-router/bin/legion-pi" "$repo"
    [ "$status" -ne 0 ]
    echo "$output" | jq -e '.status == "error" and .provider_exit == 0'

    MOCK_PI_NO_AGENT_END=1 PI_BIN=pi run bash -c 'cd "$1" && "$2" run --model openai/fixture-pi --task "make a scoped edit" --repo "$3" --quiet' \
      _ "$TEST_TMPDIR" "$REPO_ROOT/legion-router/bin/legion-pi" "$repo"
    [ "$status" -ne 0 ]
    echo "$output" | jq -e '.status == "error" and .provider_exit == 0'
}

@test "Pi adapter: unavailable binary refuses in preflight before provider launch" {
    local repo; repo="$(make_test_repo pi-preflight-unavailable)"
    PI_BIN="$TEST_TMPDIR/missing-pi" run "$REPO_ROOT/legion-router/bin/legion-pi" run \
      --model openai/fixture-pi --task "make a scoped edit" --repo "$repo" --quiet

    [ "$status" -eq 1 ]
    echo "$output" | jq -e '
      .status == "refused" and (.reason | contains("binary not found"))
      and .attempt_receipt == null and .failure_receipt == null'
    assert_mock_not_called pi
    [ ! -d "$repo/.legion/worktrees" ]
}

@test "Pi adapter: meters retry and compaction calls exactly once" {
    local repo; repo="$(make_test_repo pi-retry-compaction)"
    MOCK_PI_RETRY_COMPACTION=1 PI_BIN=pi run "$REPO_ROOT/legion-router/bin/legion-pi" \
      run --model openai/fixture-pi --task "make a scoped edit" --repo "$repo" --quiet

    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.status == "ok" and .result == "PI_OK_OUTPUT"'
    echo "$output" | jq -e '.usage == {"input_tokens":280,"cached_input_tokens":35,"output_tokens":49,"reasoning_output_tokens":15,"cache_creation_input_tokens":6}'
    echo "$output" | jq -e '.cost_usd == 0.01'
}

@test "Pi and Hermes adapters broker one real cross-harness handoff outside the provider sandbox" {
    local source repo context run_id
    context="$TEST_TMPDIR/handoff-context.log"
    for source in pi hermes; do
      repo="$(make_test_repo "broker-$source")"
      : > "$context"
      MOCK_CONTEXT_DETAIL_LOG="$context" MOCK_PROVIDER_HANDOFF_EXECUTOR=cursor \
        PI_BIN=pi HERMES_BIN=hermes run "$REPO_ROOT/legion-router/bin/legion-$source" \
          run --model openai/fixture-model --task "make a scoped edit" --repo "$repo" --quiet

      [ "$status" -eq 0 ]
      echo "$output" | jq -e --arg source "$source" '.status == "ok" and .executor == $source'
      run_id="$(echo "$output" | jq -r .run_id)"
      grep -Eq '^agent active=1 executor=1 depth=2 run=.+ name=cursor$' "$context"
      jq -e --arg parent "$run_id" 'select(.executor == "cursor") | .parent_id == $parent' "$LEGION_TELEMETRY_DIR"/*.jsonl
      ! git -C "$repo" worktree list --porcelain | grep -Fq '/broker/repo'
    done
}

@test "Pi and Hermes fail when an abandoned handoff supervisor reports incomplete cleanup" {
    local fixture_root executor repo
    fixture_root="$TEST_TMPDIR/exit70-fixture"
    mkdir "$fixture_root"
    cp -R "$REPO_ROOT/legion-router" "$fixture_root/legion-router"
    ln -s "$REPO_ROOT/legion-observability" "$fixture_root/legion-observability"
    cp "$BATS_TEST_DIRNAME/mocks/bin/supervisor-exit70" \
      "$fixture_root/legion-router/scripts/legion-process-supervisor.py"
    chmod 755 "$fixture_root/legion-router/scripts/legion-process-supervisor.py"

    for executor in pi hermes; do
      repo="$(make_test_repo "broker-exit70-$executor")"
      MOCK_REAL_SUPERVISOR="$REPO_ROOT/legion-router/scripts/legion-process-supervisor.py" \
        MOCK_PROVIDER_HANDOFF_EXECUTOR=cursor PI_BIN=pi HERMES_BIN=hermes \
        run "$fixture_root/legion-router/bin/legion-$executor" run --model openai/fixture-model \
          --task "make a scoped edit" --repo "$repo" --quiet

      [ "$status" -ne 0 ]
      echo "$output" | jq -e '.status == "containment_failed" and (.reason | contains("broker.err"))'
      local retained
      retained="$(echo "$output" | jq -r '.worktree')"
      [ -d "$retained" ]
    done
}

@test "Pi and Hermes handoff broker is single-use" {
    local repo; repo="$(make_test_repo broker-single-use)"
    MOCK_PROVIDER_HANDOFF_EXECUTOR=cursor MOCK_PROVIDER_HANDOFF_TWICE=1 PI_BIN=pi \
      run "$REPO_ROOT/legion-router/bin/legion-pi" run --model openai/fixture-pi \
        --task "make a scoped edit" --repo "$repo" --quiet

    [ "$status" -ne 0 ]
    echo "$output" | jq -e '.status == "failed" and .provider_exit != 0'
    [ "$(grep -c '^agent ' "$MOCK_CALL_LOG")" -eq 1 ]
}

@test "Pi handoff broker rejects arithmetic-injection and opaque arguments" {
    local repo escape payload
    repo="$(make_test_repo broker-typed-args)"
    escape="$repo/BROKER_ARGUMENT_ESCAPED.txt"
    payload="BASH_VERSINFO[\$(printf exploited > $escape; printf 0)]"

    MOCK_PROVIDER_HANDOFF_EXECUTOR=cursor MOCK_PROVIDER_HANDOFF_BUDGET="$payload" PI_BIN=pi \
      run "$REPO_ROOT/legion-router/bin/legion-pi" run --model openai/fixture-pi \
        --task "make a scoped edit" --repo "$repo" --quiet

    [ "$status" -ne 0 ]
    [ ! -e "$escape" ]
    echo "$output" | jq -e '.status == "failed" and .provider_exit != 0'
    assert_mock_not_called agent
}

@test "Pi and Hermes use scrubbed private credential homes" {
    local executor repo env_log private_path
    mkdir -p "$HOME/.pi/agent" "$HOME/.hermes"
    printf '{}\n' > "$HOME/.pi/agent/auth.json"
    printf '{}\n' > "$HOME/.hermes/auth.json"
    env_log="$TEST_TMPDIR/provider-env.log"
    for executor in pi hermes; do
      repo="$(make_test_repo "private-home-$executor")"
      : > "$env_log"
      MOCK_PROVIDER_ENV_LOG="$env_log" PI_BIN=pi HERMES_BIN=hermes \
        run "$REPO_ROOT/legion-router/bin/legion-$executor" run --model openai/fixture-model \
          --task "make a scoped edit" --repo "$repo" --quiet
      [ "$status" -eq 0 ]
      private_path="$(cut -d= -f2- "$env_log")"
      [ -n "$private_path" ]
      [[ "$private_path" != "$HOME"/* ]]
      [ ! -e "$private_path" ]
    done
}

@test "Pi adapter rejects child-replaced Git metadata without running its filter" {
    local repo escape
    repo="$(make_test_repo pi-git-metadata)"
    escape="$repo/FILTER_ESCAPED.txt"
    MOCK_PROVIDER_REPLACE_GIT=1 MOCK_FILTER_ESCAPE_PATH="$escape" PI_BIN=pi \
      run "$REPO_ROOT/legion-router/bin/legion-pi" run --model openai/fixture-pi \
        --task "make a scoped edit" --repo "$repo" --quiet

    [ "$status" -ne 0 ]
    [ ! -e "$escape" ]
    echo "$output" | jq -e '.status == "error" and (.result | contains("trusted worktree metadata"))'
}

@test "Pi adapter: read-only restricts tools and rejects a changed worktree" {
    local repo; repo="$(make_test_repo pi-read-only)"
    PI_BIN=pi run bash -c 'cd "$1" && "$2" run --model openai/fixture-pi --sandbox read-only --task "review this" --repo "$3" --quiet' \
      _ "$TEST_TMPDIR" "$REPO_ROOT/legion-router/bin/legion-pi" "$repo"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.status == "ok" and (.diff_path | type == "string")'
    assert_mock_called pi '--tools read,grep,find,ls'

    MOCK_PI_WRITE_IN_READONLY=1 PI_BIN=pi run bash -c 'cd "$1" && "$2" run --model openai/fixture-pi --sandbox read-only --task "review this" --repo "$3" --quiet' \
      _ "$TEST_TMPDIR" "$REPO_ROOT/legion-router/bin/legion-pi" "$repo"
    [ "$status" -ne 0 ]
    echo "$output" | jq -e '.status == "error" and (.result | contains("read-only"))'
}

@test "Hermes adapter: uses one-shot usage artifact and rejects unsupported read-only mode" {
    local repo; repo="$(make_test_repo hermes-contract)"
    HERMES_BIN=hermes run bash -c 'cd "$1" && "$2" run --model openai/fixture-hermes --task "make a scoped edit" --repo "$3" --quiet' \
      _ "$TEST_TMPDIR" "$REPO_ROOT/legion-router/bin/legion-hermes" "$repo"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.status == "ok" and .executor == "hermes" and .result == "HERMES_OK_OUTPUT" and .usage.input_tokens == 256 and .cost_usd == 0.002'
    jq -e '.terminal_status == "succeeded" and .usage_status == "known" and .cost_status == "known"' \
      "$(echo "$output" | jq -r .attempt_receipt)"
    echo "$output" | jq -e '.model == "openai/fixture-hermes" and .usage.cached_input_tokens == 24 and .usage.output_tokens == 36 and .usage.reasoning_output_tokens == 12'
    assert_mock_called hermes '--oneshot make a scoped edit --usage-file'
    assert_mock_called hermes '--ignore-user-config --toolsets terminal,file'
    assert_mock_called sandbox-exec '-f '

    MOCK_HERMES_JSON_STDOUT=1 HERMES_BIN=hermes run bash -c 'cd "$1" && "$2" run --model openai/fixture-hermes --task "make a scoped edit" --repo "$3" --quiet' \
      _ "$TEST_TMPDIR" "$REPO_ROOT/legion-router/bin/legion-hermes" "$repo"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.result == "{\"findings\":[]}"'

    MOCK_HERMES_COST=1e-8 HERMES_BIN=hermes run bash -c 'cd "$1" && "$2" run --model openai/fixture-hermes --task "make a scoped edit" --repo "$3" --quiet' \
      _ "$TEST_TMPDIR" "$REPO_ROOT/legion-router/bin/legion-hermes" "$repo"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.cost_usd == 1e-8'

    MOCK_HERMES_USAGE_FAILED=1 HERMES_BIN=hermes run bash -c 'cd "$1" && "$2" run --model openai/fixture-hermes --task "make a scoped edit" --repo "$3" --quiet' \
      _ "$TEST_TMPDIR" "$REPO_ROOT/legion-router/bin/legion-hermes" "$repo"
    [ "$status" -ne 0 ]
    echo "$output" | jq -e '.status == "error" and .provider_exit == 0'

    MOCK_HERMES_USAGE_MALFORMED=1 HERMES_BIN=hermes run bash -c 'cd "$1" && "$2" run --model openai/fixture-hermes --task "make a scoped edit" --repo "$3" --quiet' \
      _ "$TEST_TMPDIR" "$REPO_ROOT/legion-router/bin/legion-hermes" "$repo"
    [ "$status" -ne 0 ]
    echo "$output" | jq -e '.status == "error" and .provider_exit == 0'

    MOCK_HERMES_NO_USAGE=1 HERMES_BIN=hermes run bash -c 'cd "$1" && "$2" run --model openai/fixture-hermes --task "make a scoped edit" --repo "$3" --quiet' \
      _ "$TEST_TMPDIR" "$REPO_ROOT/legion-router/bin/legion-hermes" "$repo"
    [ "$status" -ne 0 ]
    echo "$output" | jq -e '.status == "error" and .provider_exit == 0'

}

@test "Hermes adapter: rejects read-only in preflight before provider resolution or launch" {
    local repo; repo="$(make_test_repo hermes-read-only-admission)"
    HERMES_BIN=hermes run "$REPO_ROOT/legion-router/bin/legion-hermes" run \
      --model openai/fixture-hermes --sandbox read-only --task "review this" \
      --repo "$repo" --quiet
    [ "$status" -eq 1 ]
    echo "$output" | jq -e '
      .status == "refused" and (.reason | contains("unsupported sandbox"))
      and .attempt_receipt == null and .failure_receipt == null'
    assert_mock_not_called hermes
    [ ! -d "$repo/.legion/worktrees" ]
}

@test "Pi and Hermes adapters: preserve dispatcher run identity and trace context" {
    local executor repo run_id
    for executor in pi hermes; do
      repo="$(make_test_repo "${executor}-adopted")"
      run_id="queued-${executor}-slice"
      LEGION_ACTIVE=1 LEGION_EXECUTOR=1 LEGION_DEPTH=1 LEGION_EXECUTOR_NAME=codex \
        LEGION_RUN_ID=parent-codex LEGION_TRACE_ID=trace-pi-hermes \
        LEGION_TARGET_TYPE=harness LEGION_TARGET_NAME="$executor" \
        PI_BIN=pi HERMES_BIN=hermes PATH="$REPO_ROOT/legion-router/bin:$PATH" \
        run bash -c 'cd "$1" && "$2" run --executor "$3" --model openai/fixture-model --run-id "$4" --task "make a scoped edit" --repo "$5" --quiet' \
          _ "$TEST_TMPDIR" "$DELEGATE" "$executor" "$run_id" "$repo"
      [ "$status" -eq 0 ]
      echo "$output" | jq -e --arg run "$run_id" --arg executor "$executor" '.status == "ok" and .run_id == $run and .executor == $executor'
      jq -e --arg run "$run_id" --arg executor "$executor" 'select(.run_id == $run) | .trace_id == "trace-pi-hermes" and .parent_id == "parent-codex" and .target_type == "harness" and .target_name == $executor' "$LEGION_TELEMETRY_DIR"/*.jsonl
      jq -e --arg run "$run_id" '.run_id == $run and .lifecycle.phase == "ok"' "$LEGION_REGISTRY_DIR/$run_id.json"
      local recorded_wt
      recorded_wt="$(jq -r '.worktree_dir' "$LEGION_REGISTRY_DIR/$run_id.json")"
      local repo_physical
      repo_physical="$(cd "$repo" && pwd -P)"
      [ "$recorded_wt" = "$repo_physical/.legion/worktrees/$run_id" ] || {
        echo "recorded worktree mismatch: got '$recorded_wt'" >&2
        return 1
      }
    done
}

@test "Pi and Hermes adapters fail closed without a filesystem write sandbox" {
    local executor repo
    for executor in pi hermes; do
      repo="$(make_test_repo "${executor}-no-fs-sandbox")"
      : > "$MOCK_CALL_LOG"
      LEGION_FS_SANDBOX_BIN="$TEST_TMPDIR/missing-sandbox" PI_BIN=pi HERMES_BIN=hermes \
        run "$REPO_ROOT/legion-router/bin/legion-$executor" run --model openai/fixture-model \
          --task "make a scoped edit" --repo "$repo" --quiet
      [ "$status" -eq 2 ]
      [[ "$output" == *"filesystem sandbox is unavailable"* ]]
      assert_mock_not_called "$executor"
      [ ! -d "$repo/.legion/worktrees" ]
    done
}

@test "Pi adapter supports the Linux Bubblewrap boundary" {
    local repo; repo="$(make_test_repo pi-bwrap)"
    LEGION_FS_SANDBOX_BIN=bwrap PI_BIN=pi run "$REPO_ROOT/legion-router/bin/legion-pi" \
      run --model openai/fixture-pi --task "make a scoped edit" --repo "$repo" --quiet
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.status == "ok"'
    assert_mock_called bwrap '--ro-bind / / --bind '
    assert_mock_called bwrap '--unshare-pid'
    assert_mock_called bwrap '--tmpfs /run'
    assert_mock_called bwrap '--proc /proc'
    assert_mock_called bwrap '--chdir '
}

@test "Pi sandbox exposes only the broker delegate and scrubs host control channels" {
    local repo fake_bin fake_delegate env_log profile artifact
    repo="$(make_test_repo pi-delegate-boundary)"
    fake_bin="$TEST_TMPDIR/installed-legion-bin"
    fake_delegate="$fake_bin/legion-delegate"
    env_log="$TEST_TMPDIR/provider-security-env.log"
    mkdir -p "$fake_bin"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$fake_delegate"
    chmod +x "$fake_delegate"

    PATH="$fake_bin:$PATH" DOCKER_HOST='unix:///var/run/docker.sock' \
      CONTAINER_HOST='unix:///run/podman/podman.sock' SSH_AUTH_SOCK='/tmp/agent.sock' \
      MOCK_PROVIDER_SECURITY_ENV_LOG="$env_log" PI_BIN=pi \
      run "$REPO_ROOT/legion-router/bin/legion-pi" run --model openai/fixture-pi \
        --task "make a scoped edit" --repo "$repo" --keep --quiet

    [ "$status" -eq 0 ]
    artifact="$(dirname "$(echo "$output" | jq -r .diff_path)")"
    profile="$artifact/filesystem.sb"
    grep -Fq '(deny network-outbound (remote unix-socket))' "$profile"
    grep -Fq "(deny process-exec (literal \"$fake_delegate\"))" "$profile"
    ! grep -Fq "$fake_bin" < <(sed -n 's/^path=//p' "$env_log")
    grep -qx 'docker_host=' "$env_log"
    grep -qx 'container_host=' "$env_log"
    grep -qx 'ssh_auth_sock=' "$env_log"
}

@test "Pi and Hermes never clean a colliding worktree or branch they did not create" {
    local executor repo run_id wt branch
    for executor in pi hermes; do
      repo="$(make_test_repo "owned-cleanup-$executor")"
      run_id="collision-$executor"
      wt="$repo/.legion/worktrees/$run_id"
      branch="legion/$executor-$run_id"
      mkdir -p "$repo/.legion/worktrees"
      git -C "$repo" worktree add -q -b "$branch" "$wt" HEAD
      printf 'operator-owned\n' > "$wt/OWNER.txt"

      PI_BIN=pi HERMES_BIN=hermes run "$REPO_ROOT/legion-router/bin/legion-$executor" \
        run --run-id "$run_id" --model openai/fixture-model \
        --task "make a scoped edit" --repo "$repo" --quiet

      [ "$status" -eq 2 ]
      [ -f "$wt/OWNER.txt" ]
      git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"
      git -C "$repo" worktree remove --force "$wt"
      git -C "$repo" branch -D "$branch" >/dev/null
    done
}

@test "Pi and Hermes fail closed for repositories with clean filters" {
    local executor repo
    for executor in pi hermes; do
      repo="$(make_test_repo "filter-semantics-$executor")"
      printf '*.ts filter=lfs\n' > "$repo/.gitattributes"
      git -C "$repo" add .gitattributes
      git -C "$repo" -c user.email=t@t.c -c user.name=t commit -qm attributes
      : > "$MOCK_CALL_LOG"

      PI_BIN=pi HERMES_BIN=hermes run "$REPO_ROOT/legion-router/bin/legion-$executor" \
        run --model openai/fixture-model --task "make a scoped edit" --repo "$repo" --quiet

      [ "$status" -eq 2 ]
      [[ "$output" == *"clean-filter attributes are unsupported"* ]]
      assert_mock_not_called "$executor"
    done
}

@test "Pi and Hermes fail closed for external Git attribute sources" {
    local executor repo git_dir
    for executor in pi hermes; do
      repo="$(make_test_repo "external-attributes-$executor")"
      git_dir="$(git -C "$repo" rev-parse --absolute-git-dir)"
      mkdir -p "$git_dir/info"
      printf '*.ts text eol=crlf\n' > "$git_dir/info/attributes"
      : > "$MOCK_CALL_LOG"

      PI_BIN=pi HERMES_BIN=hermes run "$REPO_ROOT/legion-router/bin/legion-$executor" \
        run --model openai/fixture-model --task "make a scoped edit" --repo "$repo" --quiet

      [ "$status" -eq 2 ]
      [[ "$output" == *"Git info/attributes is unsupported"* ]]
      assert_mock_not_called "$executor"
    done

    repo="$(make_test_repo core-attributes-file)"
    printf '*.ts text eol=crlf\n' > "$repo/local.attributes"
    git -C "$repo" config core.attributesFile "$repo/local.attributes"
    PI_BIN=pi run "$REPO_ROOT/legion-router/bin/legion-pi" run \
      --model openai/fixture-pi --task "make a scoped edit" --repo "$repo" --quiet
    [ "$status" -eq 2 ]
    [[ "$output" == *"core.attributesFile is unsupported"* ]]
}

@test "Pi isolated diff capture preserves safe Git normalization settings" {
    local repo artifact
    repo="$(make_test_repo safe-git-semantics)"
    git -C "$repo" config core.autocrlf input
    git -C "$repo" config core.safecrlf warn

    PI_BIN=pi run "$REPO_ROOT/legion-router/bin/legion-pi" run --model openai/fixture-pi \
      --task "make a scoped edit" --repo "$repo" --keep --quiet

    [ "$status" -eq 0 ]
    artifact="$(dirname "$(echo "$output" | jq -r .diff_path)")"
    [ "$(git config --file "$artifact/safe-git/config" core.autocrlf)" = input ]
    [ "$(git config --file "$artifact/safe-git/config" core.safecrlf)" = warn ]
}

@test "portable process supervisor terminates provider descendants" {
    local pid_file supervisor child i
    pid_file="$TEST_TMPDIR/provider-child.pid"
    python3 "$REPO_ROOT/legion-router/scripts/legion-process-supervisor.py" --cwd "$TEST_TMPDIR" -- \
      bash -c 'sleep 300 & printf "%s\n" "$!" > "$1"; wait' _ "$pid_file" &
    supervisor=$!
    i=0
    while [ ! -s "$pid_file" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
    [ -s "$pid_file" ]
    child="$(cat "$pid_file")"
    kill -TERM "$supervisor"
    wait "$supervisor" || true
    ! kill -0 "$child" 2>/dev/null
}

@test "delegate child lease emits one timed_out lineage and removes kept Git state" {
    local repo run_id pid_file child attempt failure
    repo="$(make_test_repo codex-lease-timeout)"
    run_id="codex-lease-timeout"
    pid_file="$TEST_TMPDIR/codex-lease-child.pid"

    MOCK_CODEX_DELAY=30 MOCK_CODEX_DETACH_DELAY=1 \
      MOCK_CODEX_DELAY_PID_FILE="$pid_file" \
      run "$DELEGATE" run --executor codex --model fixture-codex \
        --task "wait forever" --repo "$repo" --run-id "$run_id" \
        --max-runtime-seconds 1 --keep --quiet

    [ "$status" -eq 1 ]
    echo "$output" | jq -e '.status == "timed_out" and (.reason | contains("expired after 1 seconds"))'
    attempt="$(echo "$output" | jq -r .attempt_receipt)"
    failure="$(echo "$output" | jq -r .failure_receipt)"
    jq -e '.terminal_status == "timed_out" and .failure.class == "timed_out"' "$attempt"
    jq -e '.class == "timed_out" and .retryable == false' "$failure"
    [ ! -d "$repo/.legion/worktrees/$run_id" ]
    ! git -C "$repo" show-ref --verify --quiet "refs/heads/legion/delegate-$run_id"
    jq -e '.lifecycle.phase == "timed_out"' "$LEGION_REGISTRY_DIR/$run_id.json"
    child="$(cat "$pid_file")"
    ! kill -0 "$child" 2>/dev/null
}

@test "delegate child lease can only lower the registry default" {
    local repo
    repo="$(make_test_repo codex-lease-cap)"
    run "$DELEGATE" run --executor codex --model fixture-codex \
      --task "do the thing" --repo "$repo" --max-runtime-seconds 3601 --quiet
    [ "$status" -eq 2 ]
    [[ "$output" == *"may lower but not raise"* ]]
    ! grep -q '^codex exec ' "$MOCK_CALL_LOG"

    run "$DELEGATE" run --executor codex --model fixture-codex \
      --task "do the thing" --repo "$repo" \
      --max-runtime-seconds 999999999999999999999999999999999999 --quiet
    [ "$status" -eq 2 ]
    [[ "$output" == *"may lower but not raise"* ]]
    ! grep -q '^codex exec ' "$MOCK_CALL_LOG"
}

@test "portable process supervisor terminates a setsid descendant that ignores TERM" {
    local pid_file supervisor child i
    pid_file="$TEST_TMPDIR/provider-setsid-child.pid"
    python3 "$REPO_ROOT/legion-router/scripts/legion-process-supervisor.py" --cwd "$TEST_TMPDIR" -- \
      bash -c 'python3 - "$1" <<'"'PY'"' &
import os, signal, sys, time
os.setsid()
signal.signal(signal.SIGTERM, signal.SIG_IGN)
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    stream.write(str(os.getpid()))
while True:
    time.sleep(1)
PY
wait' _ "$pid_file" &
    supervisor=$!
    i=0
    while [ ! -s "$pid_file" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
    [ -s "$pid_file" ]
    child="$(cat "$pid_file")"
    kill -TERM "$supervisor"
    wait "$supervisor" || true
    ! kill -0 "$child" 2>/dev/null
}

@test "macOS supervisor fails closed when an outer sandbox hides its fingerprint" {
    [ -x /usr/bin/sandbox-exec ] || skip "macOS sandbox-exec is unavailable"
    local canary_dir deny_canary allow_canary profile pid_file
    canary_dir="$TEST_TMPDIR/mach-denied-canaries"
    mkdir "$canary_dir"
    canary_dir="$(cd "$canary_dir" && pwd -P)"
    deny_canary="$canary_dir/deny"
    allow_canary="$canary_dir/allow"
    profile="$TEST_TMPDIR/mach-denied.sb"
    : > "$deny_canary"
    : > "$allow_canary"
    chmod 400 "$deny_canary" "$allow_canary"
    printf '%s\n' '(version 1)' '(allow default)' '(deny mach-task-name)' \
      "(deny file-read* (literal \"$deny_canary\"))" > "$profile"
    pid_file="$TEST_TMPDIR/provider-mach-denied-child.pid"
    run /usr/bin/sandbox-exec -f "$profile" \
      python3 "$REPO_ROOT/legion-router/scripts/legion-process-supervisor.py" \
      --cwd "$TEST_TMPDIR" \
      --darwin-sandbox-deny-canary "$deny_canary" \
      --darwin-sandbox-allow-canary "$allow_canary" -- \
      bash -c 'printf "%s\n" launched > "$1"' _ "$pid_file"
    [ "$status" -eq 2 ]
    [[ "$output" == *"invalid Darwin sandbox canary"* ]]
    [ ! -e "$pid_file" ]
}

@test "macOS supervisor reaps a rapid double-fork after ancestry and environment are shed" {
    [ -x /usr/bin/sandbox-exec ] || skip "macOS sandbox-exec is unavailable"
    local canary_dir deny_canary allow_canary profile pid_file supervisor child unrelated i attempt
    canary_dir="$TEST_TMPDIR/supervisor-canaries"
    mkdir "$canary_dir"
    canary_dir="$(cd "$canary_dir" && pwd -P)"
    deny_canary="$canary_dir/deny"
    allow_canary="$canary_dir/allow"
    profile="$TEST_TMPDIR/supervisor-fingerprint.sb"
    : > "$deny_canary"
    : > "$allow_canary"
    chmod 400 "$deny_canary" "$allow_canary"
    printf '%s\n' '(version 1)' '(allow default)' \
      "(deny file-read* (literal \"$deny_canary\"))" > "$profile"

    /usr/bin/sandbox-exec -p "(version 1)(allow default)(deny file-read* (subpath \"$canary_dir\"))" \
      /bin/sleep 30 &
    unrelated=$!

    for attempt in 1 2 3 4 5; do
      pid_file="$TEST_TMPDIR/provider-double-fork-$attempt.pid"
      python3 "$REPO_ROOT/legion-router/scripts/legion-process-supervisor.py" \
        --cwd "$TEST_TMPDIR" \
        --darwin-sandbox-deny-canary "$deny_canary" \
        --darwin-sandbox-allow-canary "$allow_canary" -- \
        /usr/bin/sandbox-exec -f "$profile" python3 - "$pid_file" <<'PY' &
import os
import sys

if os.fork() != 0:
    os._exit(0)
os.setsid()
if os.fork() != 0:
    os._exit(0)
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    stream.write(str(os.getpid()))
null = os.open("/dev/null", os.O_RDWR)
for descriptor in (0, 1, 2):
    os.dup2(null, descriptor)
if null > 2:
    os.close(null)
os.execve("/bin/sleep", ["sleep", "60"], {})
PY
      supervisor=$!
      wait "$supervisor"
      i=0
      while [ ! -s "$pid_file" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
      [ -s "$pid_file" ]
      child="$(cat "$pid_file")"
      i=0
      while kill -0 "$child" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
      ! kill -0 "$child" 2>/dev/null
    done
    kill -0 "$unrelated"
    kill -TERM "$unrelated"
    wait "$unrelated" || true
}

@test "Pi real macOS sandbox reaps a rapid detached provider daemon" {
    [ -x /usr/bin/sandbox-exec ] || skip "macOS sandbox-exec is unavailable"
    local repo worktree pid_file child i
    repo="$(make_test_repo pi-fast-daemon)"
    MOCK_CALL_LOG= LEGION_FS_SANDBOX_BIN=/usr/bin/sandbox-exec \
      MOCK_PROVIDER_FAST_DAEMON_PID_FILE=FAST_DAEMON.pid PI_BIN=pi \
      run "$REPO_ROOT/legion-router/bin/legion-pi" run --model openai/fixture-pi \
        --task "make a scoped edit" --repo "$repo" --keep --quiet
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.status == "ok"'
    worktree="$(echo "$output" | jq -r .worktree)"
    pid_file="$worktree/FAST_DAEMON.pid"
    [ -s "$pid_file" ]
    child="$(cat "$pid_file")"
    i=0
    while kill -0 "$child" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
    ! kill -0 "$child" 2>/dev/null
}

@test "Pi real macOS broker reaps a rapid detached Cursor daemon" {
    [ -x /usr/bin/sandbox-exec ] || skip "macOS sandbox-exec is unavailable"
    local repo worktree handoff child unrelated temp_root i attempt
    temp_root="$(cd "${TMPDIR:-/tmp}" && pwd -P)"

    /usr/bin/sandbox-exec -p \
      "(version 1)(allow default)(deny file-read* (subpath \"$temp_root\"))" \
      /bin/sleep 120 &
    unrelated=$!

    for attempt in 1 2 3 4 5; do
      repo="$(make_test_repo "pi-fast-cursor-daemon-$attempt")"
      MOCK_CALL_LOG= LEGION_FS_SANDBOX_BIN=/usr/bin/sandbox-exec \
      MOCK_PROVIDER_HANDOFF_EXECUTOR=cursor MOCK_PROVIDER_CAPTURE_HANDOFF=HANDOFF.json \
        MOCK_CURSOR_FAST_DAEMON=1 PI_BIN=pi \
        run "$REPO_ROOT/legion-router/bin/legion-pi" run --model openai/fixture-pi \
          --task "make a scoped edit and ask Cursor to verify it" --repo "$repo" --keep --quiet
      [ "$status" -eq 0 ]
      echo "$output" | jq -e '.status == "ok"'
      worktree="$(echo "$output" | jq -r .worktree)"
      handoff="$worktree/HANDOFF.json"
      [ -s "$handoff" ]
      child="$(jq -r '.result | select(startswith("CURSOR_FAST_DAEMON_PID:")) | split(":")[1]' "$handoff")"
      [[ "$child" =~ ^[0-9]+$ ]]
      i=0
      while kill -0 "$child" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
      ! kill -0 "$child" 2>/dev/null
    done
    kill -0 "$unrelated"
    kill -TERM "$unrelated"
    wait "$unrelated" || true
}

@test "cancelling Pi reaps an active broker handoff and its descendants" {
    local repo adapter_pid child_pid pid_file stdout_file stderr_file i attempt
    for attempt in 1 2 3 4 5; do
      repo="$(make_test_repo "broker-cancel-$attempt")"
      pid_file="$TEST_TMPDIR/broker-child-$attempt.pid"
      stdout_file="$TEST_TMPDIR/broker-cancel-$attempt.out"
      stderr_file="$TEST_TMPDIR/broker-cancel-$attempt.err"

      MOCK_PROVIDER_HANDOFF_EXECUTOR=cursor MOCK_CURSOR_DELAY=300 \
        MOCK_CURSOR_DELAY_PID_FILE="$pid_file" PI_BIN=pi \
        "$REPO_ROOT/legion-router/bin/legion-pi" run --model openai/fixture-pi \
          --task "make a scoped edit" --repo "$repo" --quiet \
          >"$stdout_file" 2>"$stderr_file" &
      adapter_pid=$!
      i=0
      while [ ! -s "$pid_file" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
      [ -s "$pid_file" ]
      child_pid="$(cat "$pid_file")"

      kill -TERM "$adapter_pid"
      wait "$adapter_pid" || true

      ! kill -0 "$child_pid" 2>/dev/null
      [ "$(git -C "$repo" worktree list --porcelain | grep -c '^worktree ')" -eq 1 ]
    done
}

@test "cancelling Pi reaps a broker target that starts a new session and ignores TERM" {
    local repo adapter_pid child_pid pid_file i attempt
    for attempt in 1 2 3 4 5; do
      repo="$(make_test_repo "broker-detached-cancel-$attempt")"
      pid_file="$TEST_TMPDIR/broker-detached-child-$attempt.pid"
      MOCK_PROVIDER_HANDOFF_EXECUTOR=cursor MOCK_CURSOR_DELAY=300 MOCK_CURSOR_DETACH_DELAY=1 \
        MOCK_CURSOR_DELAY_PID_FILE="$pid_file" PI_BIN=pi \
        "$REPO_ROOT/legion-router/bin/legion-pi" run --model openai/fixture-pi \
          --task "make a scoped edit" --repo "$repo" --quiet \
          >"$TEST_TMPDIR/broker-detached-$attempt.out" 2>"$TEST_TMPDIR/broker-detached-$attempt.err" &
      adapter_pid=$!
      i=0
      while [ ! -s "$pid_file" ] && [ "$i" -lt 240 ]; do sleep 0.05; i=$((i + 1)); done
      [ -s "$pid_file" ]
      child_pid="$(cat "$pid_file")"
      kill -TERM "$adapter_pid"
      wait "$adapter_pid" || true
      ! kill -0 "$child_pid" 2>/dev/null
    done
}

@test "broker provisions scrubbed private Cursor credential and data stores" {
    local repo env_log config data
    repo="$(make_test_repo cursor-private-runtime)"
    env_log="$TEST_TMPDIR/cursor-private-env.log"
    mkdir -p "$HOME/.config/cursor" "$HOME/.cursor"
    printf '{"token":"config-secret"}\n' > "$HOME/.config/cursor/auth.json"
    printf '{"token":"data-secret"}\n' > "$HOME/.cursor/auth.json"

    MOCK_PROVIDER_HANDOFF_EXECUTOR=cursor MOCK_CURSOR_ENV_LOG="$env_log" PI_BIN=pi \
      run "$REPO_ROOT/legion-router/bin/legion-pi" run --model openai/fixture-pi \
        --task "make a scoped edit" --repo "$repo" --quiet

    [ "$status" -eq 0 ]
    config="$(sed -n 's/^config=//p' "$env_log")"
    data="$(sed -n 's/^data=//p' "$env_log")"
    [[ "$config" != "$HOME"/* && "$data" != "$HOME"/* ]]
    grep -qx 'config_auth=present' "$env_log"
    grep -qx 'data_auth=present' "$env_log"
    [ ! -e "$config" ]
    [ ! -e "$data" ]
}

@test "broker rejects incomplete oversized and symlink-redirected telemetry" {
    local mode repo escape
    for mode in missing-fields oversized symlink-ancestor; do
      repo="$(make_test_repo "broker-telemetry-$mode")"
      escape="$TEST_TMPDIR/telemetry-escape-$mode"
      MOCK_PROVIDER_HANDOFF_EXECUTOR=cursor MOCK_CHILD_TELEMETRY_MODE="$mode" \
        MOCK_CHILD_TELEMETRY_ESCAPE_DIR="$escape" PI_BIN=pi \
        run "$REPO_ROOT/legion-router/bin/legion-pi" run --model openai/fixture-pi \
          --task "make a scoped edit" --repo "$repo" --quiet

      [ "$status" -ne 0 ]
      echo "$output" | jq -e '.status == "failed" and .provider_exit != 0'
      ! grep -R -q '"executor":"cursor"' "$LEGION_TELEMETRY_DIR" 2>/dev/null
    done
}

@test "Pi and Hermes adapters reject symlinked runtime roots" {
    local executor repo outside
    for executor in pi hermes; do
      repo="$(make_test_repo "${executor}-runtime-symlink")"
      outside="$TEST_TMPDIR/${executor}-outside-runtime"
      mkdir -p "$outside"
      ln -s "$outside" "$repo/.legion"
      : > "$MOCK_CALL_LOG"

      PI_BIN=pi HERMES_BIN=hermes run "$REPO_ROOT/legion-router/bin/legion-$executor" \
        run --model openai/fixture-model --task "make a scoped edit" --repo "$repo" --quiet
      [ "$status" -eq 2 ]
      [[ "$output" == *"refusing symlinked Legion runtime path"* ]]
      assert_mock_not_called "$executor"
      [ -z "$(find "$outside" -mindepth 1 -print -quit)" ]
    done
}

@test "Pi and Hermes adapters reject pre-populated artifact directories" {
    local executor repo run_id artifact escape
    for executor in pi hermes; do
      repo="$(make_test_repo "${executor}-artifact-poison")"
      run_id="poisoned-${executor}-run"
      artifact="$repo/.legion/runs/$run_id"
      escape="$repo/${executor}-ESCAPED.txt"
      mkdir -p "$artifact"
      ln -s "$escape" "$artifact/last-message.txt"
      : > "$MOCK_CALL_LOG"

      PI_BIN=pi HERMES_BIN=hermes run "$REPO_ROOT/legion-router/bin/legion-$executor" \
        run --run-id "$run_id" --model openai/fixture-model \
        --task "make a scoped edit" --repo "$repo" --quiet
      [ "$status" -eq 2 ]
      [[ "$output" == *"refusing non-empty Legion artifact directory"* ]]
      [ ! -e "$escape" ]
      assert_mock_not_called "$executor"
    done
}

@test "Pi provider cannot write outside its worktree under the real macOS sandbox" {
    [ -x /usr/bin/sandbox-exec ] || skip "macOS sandbox-exec is unavailable"
    local repo escape
    repo="$(make_test_repo pi-real-sandbox)"
    escape="$repo/ESCAPED.txt"
    MOCK_CALL_LOG= LEGION_FS_SANDBOX_BIN=/usr/bin/sandbox-exec PI_BIN=pi \
      run "$REPO_ROOT/legion-router/bin/legion-pi" run --model openai/fixture-pi \
        --task "make a scoped edit" --repo "$repo" --quiet
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.status == "ok"'

    local control_socket="$TEST_TMPDIR/host-control.sock" socket_server i
    python3 - "$control_socket" <<'PY' &
import socket, sys, time
server = socket.socket(socket.AF_UNIX)
server.bind(sys.argv[1])
server.listen(1)
time.sleep(30)
PY
    socket_server=$!
    i=0
    while [ ! -S "$control_socket" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
    [ -S "$control_socket" ]
    MOCK_CALL_LOG= LEGION_FS_SANDBOX_BIN=/usr/bin/sandbox-exec \
      MOCK_PROVIDER_UNIX_SOCKET="$control_socket" \
      MOCK_REAL_DELEGATE_PATH="$REPO_ROOT/legion-router/bin/legion-delegate" PI_BIN=pi \
      run "$REPO_ROOT/legion-router/bin/legion-pi" run --model openai/fixture-pi \
        --task "make a scoped edit" --repo "$repo" --quiet
    kill -TERM "$socket_server" 2>/dev/null || true
    wait "$socket_server" 2>/dev/null || true
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.status == "ok"'

    MOCK_CALL_LOG= LEGION_FS_SANDBOX_BIN=/usr/bin/sandbox-exec MOCK_PROVIDER_ESCAPE_PATH="$escape" PI_BIN=pi \
      run "$REPO_ROOT/legion-router/bin/legion-pi" run --model openai/fixture-pi \
        --task "make a scoped edit" --repo "$repo" --quiet
    [ "$status" -ne 0 ]
    [ ! -e "$escape" ]
    echo "$output" | jq -e '.status == "failed" and .provider_exit != 0'

    escape="$repo/PARENT_ARTIFACT_ESCAPED.txt"
    MOCK_CALL_LOG= LEGION_FS_SANDBOX_BIN=/usr/bin/sandbox-exec \
      MOCK_PROVIDER_POISON_PARENT_ARTIFACT=1 MOCK_PARENT_ARTIFACT_ESCAPE_PATH="$escape" PI_BIN=pi \
      run "$REPO_ROOT/legion-router/bin/legion-pi" run --model openai/fixture-pi \
        --task "make a scoped edit" --repo "$repo" --quiet
    [ "$status" -ne 0 ]
    [ ! -e "$escape" ]
    echo "$output" | jq -e '.status == "failed" and .provider_exit != 0'

    escape="$repo/BROKER_CHILD_ESCAPED.txt"
    MOCK_CALL_LOG= LEGION_FS_SANDBOX_BIN=/usr/bin/sandbox-exec \
      MOCK_PROVIDER_HANDOFF_EXECUTOR=cursor MOCK_CHILD_ESCAPE_PATH="$escape" PI_BIN=pi \
      run "$REPO_ROOT/legion-router/bin/legion-pi" run --model openai/fixture-pi \
        --task "make a scoped edit" --repo "$repo" --quiet
    [ "$status" -ne 0 ]
    [ ! -e "$escape" ]
    echo "$output" | jq -e '.status == "failed" and .provider_exit != 0'

    sleep 30 &
    local victim=$!
    MOCK_CALL_LOG= LEGION_FS_SANDBOX_BIN=/usr/bin/sandbox-exec MOCK_PROVIDER_SIGNAL_PID="$victim" PI_BIN=pi \
      run "$REPO_ROOT/legion-router/bin/legion-pi" run --model openai/fixture-pi \
        --task "make a scoped edit" --repo "$repo" --quiet
    [ "$status" -ne 0 ]
    kill -0 "$victim"
    kill -TERM "$victim"
    wait "$victim" || true
}

@test "delegate run: prefers its trusted sibling over an unverified external adapter" {
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

    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.status == "ok" and .run_id == "queued-slice-cursor"'
    [ "$(grep -c '^legacy-cursor ' "$MOCK_CALL_LOG" || true)" -eq 0 ]
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
    # The summary must carry the REASON, not only paths. Pointing at a file that
    # turned out to hold nothing but MCP noise is how a real cause got lost.
    local summary; summary="$(echo "$output" | jq -r .error_log)"
    [[ "$summary" == "run-level errors: $filtered (raw stderr: $raw)"* ]]
    [[ "$summary" == *"first: $run_error"* ]]
    [[ "$summary" != *"OAuth"* ]]
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

    run bash -c "cat '$LEGION_TELEMETRY_DIR'/*.jsonl | jq -src '[.[] | select(.artifacts.rollup_only != true) | .executor] | sort'"
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
    run bash -c "cat '$LEGION_TELEMETRY_DIR'/*.jsonl | jq -sec '[.[] | select(.executor==\"codex\")] | if length > 0 and all(.[]; .trace_id==.run_id and .parent_id==null) then {same:true,parent:null} else error(\"invalid trace root\") end'"
    [ "$output" = '{"same":true,"parent":null}' ]
}

@test "delegate run: inherits LEGION_TRACE_ID + LEGION_PARENT_ID into the span" {
    local repo; repo="$(make_test_repo trace1)"
    LEGION_TRACE_ID="trace-abc" LEGION_PARENT_ID="parent-xyz" \
        "$DELEGATE" run --model test-model-alpha --task "x" --repo "$repo" --quiet >/dev/null
    run bash -c "cat '$LEGION_TELEMETRY_DIR'/*.jsonl | jq -sec '[.[] | select(.executor==\"codex\")] | if length > 0 and all(.[]; .trace_id==\"trace-abc\" and .parent_id==\"parent-xyz\") then {t:\"trace-abc\",p:\"parent-xyz\"} else error(\"invalid inherited trace\") end'"
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
    run bash -c "cat '$LEGION_TELEMETRY_DIR'/*.jsonl | jq -ec 'select(.executor==\"codex\" and .artifacts.copied_secret_names != null) | .artifacts.copied_secret_names'"
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
    echo "$output" | tail -n 1 | jq -e '.status == "refused"
      and .attempt_receipt == null and .failure_receipt == null and .lease_receipt == null'
    local art; art="$(find "$repo/.legion/runs" -mindepth 1 -maxdepth 1 -type d -print -quit)"
    [ ! -f "$art/attempt-1.json" ]
    [ "$(cat "$LEGION_TELEMETRY_DIR"/*.jsonl | jq -s '[.[] | select(.artifacts.provider_attempt == true)] | length')" -eq 0 ]
    assert_mock_called codex "--version"
    [ "$(grep -Ec '^codex exec ' "$MOCK_CALL_LOG" || true)" -eq 0 ]
}

@test "delegate run: arbitrary Sandcastle backend setup failure is a typed no-launch refusal" {
    local repo shim real_node art
    repo="$(make_test_repo run-sandcastle-setup-failure)"
    shim="$TEST_TMPDIR/sandcastle-setup-node"
    real_node="$(command -v node)"
    mkdir -p "$shim"
    cat > "$shim/node" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == */sandcastle-run.mjs ]]; then
  cat >/dev/null
  printf 'backend configuration exploded\n' >&2
  exit 42
fi
exec "$LEGION_TEST_REAL_NODE" "$@"
SH
    chmod +x "$shim/node"

    LEGION_TEST_REAL_NODE="$real_node" PATH="$shim:$PATH" run "$DELEGATE" run \
      --model test-model-alpha --sandbox docker --task x --repo "$repo" --quiet

    [ "$status" -ne 0 ]
    echo "$output" | tail -n 1 | jq -e '.status == "refused"
      and .attempt_receipt == null and .failure_receipt == null and .lease_receipt == null'
    art="$(find "$repo/.legion/runs" -mindepth 1 -maxdepth 1 -type d -print -quit)"
    [ ! -e "$art/sandcastle-provider-launched" ]
    [ ! -f "$art/attempt-1.json" ]
    [ "$(grep -Ec '^codex exec ' "$MOCK_CALL_LOG" || true)" -eq 0 ]
    [ "$(cat "$LEGION_TELEMETRY_DIR"/*.jsonl | jq -s '[.[] | select(.artifacts.provider_attempt == true)] | length')" -eq 0 ]
}

@test "delegate run: Sandcastle failure after Codex launch remains a paid provider attempt" {
    local repo shim real_node art attempt
    repo="$(make_test_repo run-sandcastle-provider-failure)"
    shim="$TEST_TMPDIR/sandcastle-provider-node"
    real_node="$(command -v node)"
    mkdir -p "$shim"
    cat > "$shim/node" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == */sandcastle-run.mjs ]]; then
  cat >/dev/null
  codex exec --json -m test-model-alpha -s workspace-write --skip-git-repo-check - >/dev/null
  printf 'backend failed after provider launch\n' >&2
  exit 42
fi
exec "$LEGION_TEST_REAL_NODE" "$@"
SH
    chmod +x "$shim/node"

    LEGION_TEST_REAL_NODE="$real_node" PATH="$shim:$PATH" run "$DELEGATE" run \
      --model test-model-alpha --sandbox docker --task x --repo "$repo" --quiet

    [ "$status" -ne 0 ]
    echo "$output" | tail -n 1 | jq -e '.status == "failed"
      and .attempt_receipt != null and .failure_receipt != null and .lease_receipt != null'
    art="$(find "$repo/.legion/runs" -mindepth 1 -maxdepth 1 -type d -print -quit)"
    [ -f "$art/sandcastle-provider-launched" ]
    jq -e '.schema == "legion.sandcastle-provider-launch.v1" and .status == "started"
      and (.token | type == "string" and length == 48) and .provider_pid > 0' \
      "$art/sandcastle-provider-launched"
    attempt="$(find "$art" -maxdepth 1 -type f -name 'attempt-*.json' -print -quit)"
    jq -e '.terminal_status == "failed" and .failure.class == "provider"' "$attempt"
    [ "$(grep -Ec '^codex exec ' "$MOCK_CALL_LOG" || true)" -eq 1 ]
    [ "$(cat "$LEGION_TELEMETRY_DIR"/*.jsonl | jq -s '[.[] | select(.artifacts.provider_attempt == true)] | length')" -eq 1 ]
}

@test "delegate run: Sandcastle Codex disappearing after admission remains no-launch" {
    local repo shim real_node admitted art
    repo="$(make_test_repo run-sandcastle-disappearing-codex)"
    shim="$TEST_TMPDIR/sandcastle-disappearing-node"
    real_node="$(command -v node)"
    admitted="$TEST_TMPDIR/admitted-codex"
    printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$(command -v codex)" > "$admitted"
    chmod +x "$admitted"
    mkdir -p "$shim"
    cat > "$shim/node" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == */sandcastle-run.mjs ]]; then
  cat >/dev/null
  rm -f "$LEGION_TEST_ADMITTED_CODEX"
  codex exec --json -m test-model-alpha -s workspace-write --skip-git-repo-check - >/dev/null
  exit $?
fi
exec "$LEGION_TEST_REAL_NODE" "$@"
SH
    chmod +x "$shim/node"

    CODEX_BIN="$admitted" LEGION_TEST_REAL_NODE="$real_node" LEGION_TEST_ADMITTED_CODEX="$admitted" \
      PATH="$shim:$PATH" run "$DELEGATE" run --model test-model-alpha \
        --sandbox docker --task x --repo "$repo" --quiet

    [ "$status" -ne 0 ]
    echo "$output" | tail -n 1 | jq -e '.status == "refused"
      and .attempt_receipt == null and .failure_receipt == null'
    art="$(find "$repo/.legion/runs" -mindepth 1 -maxdepth 1 -type d -print -quit)"
    jq -e '.schema == "legion.sandcastle-provider-launch.v1" and .status == "not-started"
      and (.token | type == "string" and length == 48)' "$art/sandcastle-provider-launched"
    [ "$(find "$art" -maxdepth 1 -type f -name 'attempt-[0-9]*.json' | wc -l | tr -d ' ')" -eq 0 ]
    [ "$(cat "$LEGION_TELEMETRY_DIR"/*.jsonl | jq -s '[.[] | select(.artifacts.provider_attempt == true)] | length')" -eq 0 ]
}

@test "delegate run: native and Sandcastle supervisor launch failure retain only no-launch lease evidence" {
    local sandbox repo result lease art
    install_launch_failed_supervisor_shim
    for sandbox in workspace-write docker; do
      repo="$(make_test_repo "run-launch-failed-$sandbox")"

      run "$DELEGATE" run --model test-model-alpha --sandbox "$sandbox" \
        --task x --repo "$repo" --quiet

      [ "$status" -ne 0 ]
      result="$(printf '%s\n' "$output" | tail -n 1)"
      jq -e '.status == "failed"
        and .attempt_receipt == null and .failure_receipt == null
        and .usage == null and .cost_usd == null
        and (.reason | contains("no provider launched"))
        and (.lease_receipt | type == "string" and length > 0)' <<<"$result"
      lease="$(jq -r .lease_receipt <<<"$result")"
      jq -e '.schema == "legion.child-execution-lease.v1"
        and .status == "launch_failed" and (has("child_exit_code") | not)' "$lease"
      art="$(dirname "$lease")"
      [ "$(find "$art" -maxdepth 1 -type f -name 'attempt-*.json' | wc -l | tr -d ' ')" -eq 0 ]
      [ "$(find "$art" -maxdepth 1 -type f -name 'failure-*.json' | wc -l | tr -d ' ')" -eq 0 ]
    done
    [ "$(grep -Ec '^codex exec ' "$MOCK_CALL_LOG" || true)" -eq 0 ]
    [ "$(cat "$LEGION_TELEMETRY_DIR"/*.jsonl | jq -s '[.[] | select(.artifacts.provider_attempt == true)] | length')" -eq 0 ]
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

@test "delegate native run and review retain containment-failed worktrees with lease evidence" {
    local repo run_wt review_repo review_wt
    install_cleanup_failed_supervisor_shim

    repo="$(make_test_repo run-cleanup-failed)"
    run "$DELEGATE" run --model test-model-beta --task x --repo "$repo" \
      --max-runtime-seconds 30 --quiet
    [ "$status" -eq 1 ]
    echo "$output" | jq -e '.status == "containment_failed"
      and (.reason | contains("forced cleanup evidence"))
      and (.lease_receipt | type) == "string"'
    run_wt="$(echo "$output" | jq -r .worktree)"
    [ -d "$run_wt" ]
    jq -e '.terminal_status == "failed" and .failure.class == "internal"' \
      "$(echo "$output" | jq -r .attempt_receipt)"
    jq -e '.status == "cleanup_failed"' "$(echo "$output" | jq -r .lease_receipt)"

    review_repo="$(make_test_repo review-cleanup-failed)"
    run "$DELEGATE" review --model test-model-beta --base HEAD --repo "$review_repo" \
      --max-runtime-seconds 30 --quiet
    # Review containment failures retain the supervisor's reserved exit so a
    # caller cannot downgrade them to an ordinary reviewer rejection.
    [ "$status" -eq 70 ]
    echo "$output" | jq -e '.status == "containment_failed"
      and (.reason | contains("forced cleanup evidence"))
      and (.lease_receipt | type) == "string"'
    review_wt="$(echo "$output" | jq -r .worktree)"
    [ -d "$review_wt" ]
    jq -e '.terminal_status == "failed" and .failure.class == "internal"' \
      "$(echo "$output" | jq -r .attempt_receipt)"
    jq -e '.status == "cleanup_failed"' "$(echo "$output" | jq -r .lease_receipt)"
}

@test "delegate native run and review keep prelaunch cleanup failure as containment with no attempt" {
    local repo result wt review_repo
    install_prelaunch_cleanup_failed_supervisor_shim

    repo="$(make_test_repo run-prelaunch-cleanup-failed)"
    run "$DELEGATE" run --model test-model-beta --task x --repo "$repo" \
      --max-runtime-seconds 30 --quiet
    [ "$status" -eq 1 ]
    result="$(printf '%s\n' "$output" | tail -n 1)"
    echo "$result" | jq -e '.status == "containment_failed"
      and .attempt_receipt == null and .failure_receipt == null
      and (.reason | contains("forced prelaunch containment evidence"))'
    wt="$(echo "$result" | jq -r .worktree)"
    [ -d "$wt" ]
    jq -e '.status == "cleanup_failed" and .child_started == false' \
      "$(echo "$result" | jq -r .lease_receipt)"

    review_repo="$(make_test_repo review-prelaunch-cleanup-failed)"
    run "$DELEGATE" review --model test-model-beta --base HEAD --repo "$review_repo" \
      --max-runtime-seconds 30 --quiet
    [ "$status" -eq 70 ]
    result="$(printf '%s\n' "$output" | tail -n 1)"
    echo "$result" | jq -e '.status == "containment_failed"
      and .attempt_receipt == null and .failure_receipt == null
      and (.reason | contains("forced prelaunch containment evidence"))'
    [ -d "$(echo "$result" | jq -r .worktree)" ]
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
@test "delegate review: native child lease times out once without retrying" {
    local repo pid_file child receipt
    repo="$(make_test_repo review-lease-timeout)"
    pid_file="$TEST_TMPDIR/review-lease-child.pid"

    MOCK_CODEX_REVIEW_DELAY=30 MOCK_CODEX_REVIEW_CHILD_PID_FILE="$pid_file" \
      run "$DELEGATE" review --model test-model-beta --base HEAD --repo "$repo" \
        --max-runtime-seconds 1 --max-attempts 2 --quiet

    [ "$status" -eq 1 ]
    echo "$output" | jq -e '
      .status == "timed_out" and .attempts == 1
      and (.reason | contains("expired after 1 seconds"))
    '
    receipt="$(echo "$output" | jq -r .terminal_receipt)"
    jq -e '.schema == "legion.review-terminal.v1" and .status == "timed_out"' "$receipt"
    [ "$(grep -Fc "codex exec -s read-only review" "$MOCK_CALL_LOG")" -eq 1 ]
    child="$(cat "$pid_file")"
    ! kill -0 "$child" 2>/dev/null
}

@test "delegate review: native launch failure retains its lease and falls through to the next reviewer" {
    local repo result lease art
    repo="$(make_test_repo review-launch-failed)"
    export LEGION_TEST_LAUNCH_FAIL_EXECUTABLE=codex
    export MOCK_CURSOR_RESULT='{"verdict":"approve","summary":"No blocking findings.","findings":[]}'
    install_launch_failed_supervisor_shim

    run "$DELEGATE" review --model test-model-beta --base HEAD --repo "$repo" \
      --max-attempts 2 --quiet

    [ "$status" -eq 0 ]
    result="$(printf '%s\n' "$output" | tail -n 1)"
    jq -e '.status == "ok" and .attempts == 1
      and (.attempt_receipt | contains("/prompt-review-"))' <<<"$result"
    art="$(dirname "$(jq -r .terminal_receipt <<<"$result")")"
    lease="$art/attempt-1.lease.json"
    jq -e '.status == "launch_failed" and (has("child_exit_code") | not)' "$lease"
    [ ! -f "$art/attempt-1.json" ]
    jq -e '.executor == "cursor" and .terminal_status == "succeeded"' \
      "$(jq -r .attempt_receipt <<<"$result")"
    [ "$(grep -Fc 'codex exec -s read-only review' "$MOCK_CALL_LOG" || true)" -eq 0 ]
    [ "$(cat "$LEGION_TELEMETRY_DIR"/*.jsonl | jq -s '[.[] | select(.artifacts.provider_attempt == true)] | length')" -eq 1 ]
}

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
      and (.preflight_receipt | type) == "string"
      and (.attempt_receipt | type) == "string"
      and .failure_receipt == null
    '
    jq -e '.schema == "legion.preflight.v1" and .status == "supported"' \
      "$(echo "$output" | jq -r .preflight_receipt)"
    jq -e '.schema == "legion.attempt.v1" and .executor == "codex-review"
      and .terminal_status == "succeeded" and .usage_status == "known"' \
      "$(echo "$output" | jq -r .attempt_receipt)"
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
      and .failure_receipt == null
      and .usage.input_tokens == 1100
      and .usage.cached_input_tokens == 220
      and .usage.output_tokens == 55
      and .usage.reasoning_output_tokens == 11
    '
    [ "$(grep -Fc "codex exec -s read-only review --base $base_sha" "$MOCK_CALL_LOG")" -eq 2 ]
    jq -e '.status == "ok" and .attempts == 2 and .max_attempts == 2' \
      "$(echo "$output" | jq -r .terminal_receipt)"
    local art; art="$(dirname "$(echo "$output" | jq -r .terminal_receipt)")"
    [ -f "$art/failure-1.json" ]
    [ ! -e "$art/failure.json" ]
    jq -e '.terminal_status == "succeeded" and .failure == null' "$art/attempt.json"
}

@test "delegate review: retries share one absolute child lease" {
    local repo started elapsed
    repo="$(make_test_repo review-shared-retry-lease)"
    export MOCK_CODEX_REVIEW_INVALID_VERDICTS=1
    export MOCK_CODEX_REVIEW_INVALID_VERDICT_ATTEMPT_FILE="$TEST_TMPDIR/review-shared-lease-attempts"
    # Leave enough scheduling margin for a loaded hosted runner to begin the
    # second attempt, while keeping that attempt longer than the shared lease.
    export MOCK_CODEX_REVIEW_DELAY=4
    started="$SECONDS"

    run "$DELEGATE" review --model test-model-beta --base HEAD --repo "$repo" \
      --max-runtime-seconds 7 --max-attempts 2 --quiet
    elapsed=$((SECONDS - started))

    [ "$status" -eq 1 ]
    echo "$output" | jq -e '.status == "timed_out" and .attempts == 2'
    [ "$(grep -Fc "codex exec -s read-only review" "$MOCK_CALL_LOG")" -eq 2 ]
    local art; art="$(dirname "$(echo "$output" | jq -r .terminal_receipt)")"
    jq -e '.status == "timed_out" and .max_runtime_seconds < 7' \
      "$art/attempt-2.lease.json"
    [ "$elapsed" -lt 10 ]
}

@test "delegate review: expiry before first native launch writes strict no-launch evidence" {
    local repo result lease art
    repo="$(make_test_repo review-first-prelaunch-expiry)"
    install_exhausted_remaining_seconds_python_shim

    run "$DELEGATE" review --model test-model-beta --base HEAD --repo "$repo" \
      --max-runtime-seconds 30 --quiet

    [ "$status" -eq 1 ]
    result="$(printf '%s\n' "$output" | tail -n 1)"
    echo "$result" | jq -e '.status == "timed_out" and .attempts == 0
      and .attempt_receipt == null and .failure_receipt == null
      and .usage == null and .usage_status == "not_applicable"
      and .cost_usd == null and .cost_status == "not_applicable"'
    lease="$(echo "$result" | jq -r .lease_receipt)"
    art="$(dirname "$lease")"
    jq -e '.schema == "legion.child-execution-lease.v1"
      and .status == "launch_failed" and (has("child_exit_code") | not)' "$lease"
    [ ! -e "$art/attempt.json" ]
    [ ! -e "$art/failure.json" ]
    [ "$(grep -Ec '^codex exec ' "$MOCK_CALL_LOG" || true)" -eq 0 ]
}

@test "delegate review: retry expiry retains prior paid receipt only in reconciliation" {
    local repo result lease art
    repo="$(make_test_repo review-retry-prelaunch-expiry)"
    install_exhausted_remaining_seconds_python_shim
    export LEGION_TEST_REMAINING_VALUES=30,0
    export MOCK_CODEX_REVIEW_INVALID_VERDICTS=1
    export MOCK_CODEX_REVIEW_INVALID_VERDICT_ATTEMPT_FILE="$TEST_TMPDIR/review-expiry-attempts"

    run "$DELEGATE" review --model test-model-beta --base HEAD --repo "$repo" \
      --max-runtime-seconds 30 --max-attempts 2 --quiet

    [ "$status" -eq 1 ]
    result="$(printf '%s\n' "$output" | tail -n 1)"
    echo "$result" | jq -e '.status == "timed_out" and .attempts == 1
      and .attempt_receipt == null and .failure_receipt == null
      and (.usage | type) == "object" and .usage_status == "known"'
    lease="$(echo "$result" | jq -r .lease_receipt)"
    art="$(dirname "$lease")"
    jq -e '.status == "launch_failed" and (has("child_exit_code") | not)' "$lease"
    jq -e '.executor == "codex-review" and .failure.class == "malformed_event"' \
      "$art/attempt-1.json"
    [ ! -e "$art/attempt.json" ]
    [ ! -e "$art/failure.json" ]
    [ "$(grep -Ec '^codex exec ' "$MOCK_CALL_LOG" || true)" -eq 1 ]
}

@test "delegate review: invalid runtime bound creates no worktree or lifecycle" {
    local repo
    repo="$(make_test_repo review-invalid-runtime-bound)"

    run "$DELEGATE" review --base HEAD --repo "$repo" --max-runtime-seconds 0 --quiet

    [ "$status" -ne 0 ]
    [[ "$output" == *"--max-runtime-seconds must be a positive integer"* ]]
    [ ! -d "$repo/.legion/worktrees" ] \
      || [ -z "$(find "$repo/.legion/worktrees" -mindepth 1 -print -quit)" ]
    [ ! -d "$repo/.legion/runs" ] \
      || [ -z "$(find "$repo/.legion/runs" -mindepth 1 -print -quit)" ]
}

@test "delegate review: fallback candidates share one absolute child lease" {
    local repo started elapsed
    repo="$(make_test_repo review-shared-candidate-lease)"
    export MOCK_CODEX_REVIEW_DELAY=2
    export MOCK_CODEX_REVIEW_EXIT=1
    export MOCK_CODEX_STDERR='Authentication required. Please run login first.'
    export MOCK_CURSOR_DELAY=30
    export MOCK_CURSOR_RESULT='{"verdict":"approve","summary":"No findings.","findings":[]}'
    started="$SECONDS"

    run "$DELEGATE" review --base HEAD --repo "$repo" \
      --max-runtime-seconds 6 --max-attempts 1 --quiet
    elapsed=$((SECONDS - started))

    [ "$status" -eq 1 ]
    echo "$output" | jq -e '.status == "timed_out"'
    [ "$(grep -Fc "codex exec -s read-only review" "$MOCK_CALL_LOG")" -eq 1 ]
    assert_mock_called agent "-p --output-format json"
    jq -e '.status == "timed_out" and .max_runtime_seconds > 0 and .max_runtime_seconds < 6' \
      "$(echo "$output" | jq -r .lease_receipt)"
    [ "$elapsed" -lt 9 ]
}

@test "delegate review: fails closed on a schema-invalid verdict" {
    local repo; repo="$(make_test_repo review-invalid)"
    export MOCK_CODEX_REVIEW_INVALID_VERDICT=1

    run "$DELEGATE" review --model test-model-beta --base HEAD \
      --max-attempts 2 --repo "$repo" --quiet

    [ "$status" -eq 1 ]
    echo "$output" | jq -e '
      .status == "failed" and .reason == "invalid-verdict"
      and .attempts == 2 and .max_attempts == 2 and .verdict == null
    '
    local run_id; run_id="$(echo "$output" | jq -r .run_id)"
    [ -s "$repo/.legion/runs/$run_id/attempt-1.stream.jsonl" ]
    [ -f "$repo/.legion/runs/$run_id/attempt-1.codex.err" ]
    [ -s "$repo/.legion/runs/$run_id/attempt-1.verdict.json" ]
    [ -s "$repo/.legion/runs/$run_id/attempt-2.stream.jsonl" ]
    [ -f "$repo/.legion/runs/$run_id/attempt-2.codex.err" ]
    [ -s "$repo/.legion/runs/$run_id/attempt-2.verdict.json" ]
    [ "$(grep -Fc "codex exec -s read-only review" "$MOCK_CALL_LOG")" -eq 2 ]
    [ ! -d "$repo/.legion/worktrees/$run_id" ]
}

@test "delegate review: retries a clean schema-invalid verdict with immutable SHAs" {
    local repo; repo="$(make_test_repo review-invalid-retry)"
    local base_sha; base_sha="$(git -C "$repo" rev-parse HEAD)"
    local review_context="$TEST_TMPDIR/review-invalid-retry-context.log"
    export MOCK_CODEX_REVIEW_INVALID_VERDICTS=1
    export MOCK_CODEX_REVIEW_INVALID_VERDICT_ATTEMPT_FILE="$TEST_TMPDIR/review-invalid-retry-attempts"

    MOCK_CODEX_REVIEW_CONTEXT_LOG="$review_context" run "$DELEGATE" review \
      --model test-model-beta --base HEAD --repo "$repo" \
      --task "Check the retry contract." --quiet

    [ "$status" -eq 0 ]
    echo "$output" | jq -e --arg sha "$base_sha" '
      .status == "ok" and .reason == "completed"
      and .attempts == 2 and .max_attempts == 2
      and .reviewed_base_sha == $sha and .reviewed_head_sha == $sha
      and .verdict.verdict == "approve"
    '
    [ "$(grep -Fc "codex exec -s read-only review --base $base_sha" "$MOCK_CALL_LOG")" -eq 2 ]
    [ "$(grep -Ec "^pwd=.* head=$base_sha$" "$review_context")" -eq 2 ]
    grep -Fq "developer_instructions=\"Review only the immutable diff $base_sha...$base_sha. Check the retry contract.\"" "$MOCK_CALL_LOG"
    [ "$(grep -Fc "Return ONLY a JSON object conforming exactly to the supplied output schema; do not include prose, Markdown, or code fences." "$MOCK_CALL_LOG")" -eq 1 ]
}

@test "delegate review: fails closed on an approving verdict with blocking findings" {
    local repo; repo="$(make_test_repo review-contradictory)"

    MOCK_CODEX_REVIEW_CONTRADICTORY=1 run "$DELEGATE" review \
      --model test-model-beta --base HEAD --repo "$repo" --quiet

    [ "$status" -eq 1 ]
    echo "$output" | jq -e '
      .status == "failed" and .reason == "invalid-verdict"
      and .attempts == 1 and .max_attempts == 2 and .verdict == null
    '
    [ "$(grep -Fc "codex exec -s read-only review" "$MOCK_CALL_LOG")" -eq 1 ]
}

@test "delegate review: retries unparseable output but not a contradictory structured verdict" {
    local repo; repo="$(make_test_repo review-unparseable)"

    MOCK_CODEX_REVIEW_UNPARSEABLE=1 run "$DELEGATE" review \
      --model test-model-beta --base HEAD --repo "$repo" --quiet

    [ "$status" -eq 1 ]
    echo "$output" | jq -e '
      .status == "failed" and .reason == "invalid-verdict"
      and .attempts == 2 and .max_attempts == 2 and .verdict == null
    '
    [ "$(grep -Fc "codex exec -s read-only review" "$MOCK_CALL_LOG")" -eq 2 ]
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
    jq -e '.terminal_status == "failed" and .failure.class == "malformed_event"' \
      "$(echo "$output" | jq -r .attempt_receipt)"
    jq -e '.schema == "legion.failure.v1" and .class == "malformed_event"' \
      "$(echo "$output" | jq -r .failure_receipt)"
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
    local interrupted_attempt
    interrupted_attempt="$(dirname "$receipt")/attempt-1.json"
    jq -e '.schema == "legion.attempt.v1" and .terminal_status == "cancelled"
      and .failure.class == "cancelled"' "$interrupted_attempt"
    [ "$(find "$(dirname "$receipt")" -maxdepth 1 -type f \
      -name 'attempt-[0-9]*.json' ! -name '*.lease.json' | wc -l | tr -d ' ')" -eq 1 ]
    [ "$(find "$(dirname "$receipt")" -maxdepth 1 -type f -name 'failure-[0-9]*.json' | wc -l | tr -d ' ')" -eq 1 ]
    jq -e '.kind == "review" and .lifecycle.phase == "failed"' "$registry"
    jq -e '.status == "failed" and .result_status == "failed"' \
      "$(dirname "$receipt")/status.json"
    run bash -c "cat '$LEGION_TELEMETRY_DIR'/*.jsonl | jq -e \
      'select(.run_id == \"$run_id\" and .executor == \"codex-review\" and .status == \"failed\")'"
    [ "$status" -eq 0 ]
    [ "$(find "$repo/.legion/worktrees" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')" = "0" ]
}

@test "delegate review: a delayed signal preserves an authoritative completed receipt" {
    local helper art receipt overwritten rollup artifact_status
    helper="$TEST_TMPDIR/review-delayed-signal.sh"
    art="$TEST_TMPDIR/review-delayed-signal-art"
    receipt="$art/terminal.json"
    overwritten="$art/overwritten"
    rollup="$art/rollup"
    artifact_status="$art/artifact-status"
    mkdir -p "$art"
    printf '%s\n' '{"schema":"legion.review-terminal.v1","status":"ok","reason":"completed","codex_exit":0}' > "$receipt"
    {
      sed -n '/^on_terminating_signal()/,/^}/p' "$DELEGATE"
      cat <<'SH'
REVIEW_RECEIPT_PATH="$1/terminal.json"
REVIEW_RECEIPT_RUN_ID=review-complete
REVIEW_RECEIPT_MODEL=fixture-model
REVIEW_RECEIPT_ARCHETYPE=security-review
REVIEW_RECEIPT_BASE_SHA=base
REVIEW_RECEIPT_HEAD_SHA=head
REVIEW_RECEIPT_PATCH=patch
REVIEW_RECEIPT_ATTEMPT=1
REVIEW_RECEIPT_MAX_ATTEMPTS=1
REVIEW_ART_PATH="$1"
REVIEW_WT_PATH=worktree
REVIEW_START_MS="$(date +%s000)"
REVIEW_EXECUTOR_LABEL=codex
RUN_ID=review-complete
CODEX_CHILD_RC=0
CODEX_CHILD_PID=""
CODEX_SIGNAL_CHILD_PID=""
PROMPT_CHILD_PID=""
PROMPT_LEASE_STATUS=""
PROMPT_ATTEMPT_ART=""
NATIVE_ATTEMPT_ART=""
NATIVE_ATTEMPT_EXECUTOR=""
NATIVE_ATTEMPT_MODEL=""
NATIVE_ATTEMPT_ORDINAL=0
NATIVE_LEASE_STATUS=""
NATIVE_RESUME_ART=""
LEGION_WT_KEEP=0
TERMINATING_SIGNAL_ACTIVE=0
OVERWRITTEN="$2"
ROLLUP="$3"
ARTIFACT_STATUS="$4"
kill_codex_child() { :; }
kill_prompt_child() { :; }
legion_adapter_supervisor_cleanup_failed() { return 1; }
write_interrupted_native_attempt() { :; }
preserve_interrupted_prompt_receipts() { :; }
terminalize_interrupted_native_run() { :; }
terminalize_interrupted_native_resume() { :; }
write_interrupted_review_receipt() { : > "$OVERWRITTEN"; }
review_canonical_metering() { printf '%s\n' '{"reconciliation":{"usage":null,"cost_usd":null},"last":{}}'; }
emit_review_rollup_span() { printf '%s\n' "$3" >> "$ROLLUP"; }
write_run_state() { :; }
write_run_artifact_status() { printf '%s\n' "$3:$6" > "$ARTIFACT_STATUS"; }
_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
on_terminating_signal TERM
SH
    } > "$helper"

    run bash "$helper" "$art" "$overwritten" "$rollup" "$artifact_status"

    [ "$status" -eq 0 ]
    [ ! -e "$overwritten" ]
    jq -e '.status == "ok" and .reason == "completed"' "$receipt"
    [ "$(cat "$rollup")" = "ok" ]
    [ "$(cat "$artifact_status")" = "completed:ok" ]
}

@test "delegate run: interruption writes one cancelled attempt and terminalizes state" {
    local repo pid_file stdout stderr run_pid run_rc run_dir run_id registry
    repo="$(make_test_repo run-interrupt)"
    pid_file="$TEST_TMPDIR/run-interrupt-child.pid"
    stdout="$TEST_TMPDIR/run-interrupt.out"
    stderr="$TEST_TMPDIR/run-interrupt.err"

    MOCK_CODEX_DELAY=30 MOCK_CODEX_DELAY_PID_FILE="$pid_file" \
      "$DELEGATE" run --model test-model-beta --task x --repo "$repo" --quiet \
      >"$stdout" 2>"$stderr" &
    run_pid=$!
    for _ in {1..100}; do
      [[ -s "$pid_file" ]] && break
      sleep 0.02
    done
    [ -s "$pid_file" ]

    kill -TERM "$run_pid"
    run_rc=0
    wait "$run_pid" || run_rc=$?
    [ "$run_rc" -eq 143 ]

    run_dir="$(find "$repo/.legion/runs" -mindepth 1 -maxdepth 1 -type d -print -quit)"
    run_id="$(basename "$run_dir")"
    registry="$LEGION_REGISTRY_DIR/$run_id.json"
    jq -e '.terminal_status == "cancelled" and .failure.class == "cancelled"' \
      "$run_dir/attempt-1.json"
    [ "$(find "$run_dir" -maxdepth 1 -type f -name 'attempt-[0-9]*.json' | wc -l | tr -d ' ')" -eq 1 ]
    [ "$(find "$run_dir" -maxdepth 1 -type f -name 'failure-[0-9]*.json' | wc -l | tr -d ' ')" -eq 1 ]
    jq -e '.kind == "run" and .lifecycle.phase == "failed"' "$registry"
    jq -e '.status == "failed" and .result_status == "failed"' "$run_dir/status.json"
    ! kill -0 "$(cat "$pid_file")" 2>/dev/null
}

@test "delegate native signal writer never overwrites an already completed attempt" {
    local helper art
    helper="$TEST_TMPDIR/native-signal-guard.sh"
    art="$TEST_TMPDIR/native-signal-art"
    mkdir -p "$art"
    printf '%s\n' '{"schema":"legion.attempt.v1","terminal_status":"succeeded"}' > "$art/attempt-1.json"
    {
      sed -n '/^write_interrupted_native_attempt()/,/^}/p' "$DELEGATE"
      printf '%s\n' \
        'NATIVE_ATTEMPT_ART="$1"' \
        'NATIVE_ATTEMPT_ORDINAL=1' \
        'write_interrupted_native_attempt'
    } > "$helper"

    run bash "$helper" "$art"

    [ "$status" -eq 0 ]
    jq -e '.terminal_status == "succeeded"' "$art/attempt-1.json"
    [ ! -e "$art/failure-1.json" ]
}

@test "delegate native signal writer does not invent an attempt before launch commits" {
    local helper="$TEST_TMPDIR/native-signal-before-launch.sh"
    local art="$TEST_TMPDIR/native-signal-before-launch-art"
    mkdir -p "$art"
    {
      sed -n '/^write_interrupted_native_attempt()/,/^}/p' "$DELEGATE"
      cat <<'SH'
NATIVE_ATTEMPT_ART="$1"
NATIVE_ATTEMPT_ORDINAL=1
NATIVE_ATTEMPT_LAUNCHED=0
write_interrupted_native_attempt
SH
    } > "$helper"

    run bash "$helper" "$art"

    [ "$status" -eq 0 ]
    [ ! -e "$art/attempt-1.json" ]
    [ ! -e "$art/failure-1.json" ]
}

@test "delegate native signal writer preserves launch-failed lease without provider evidence" {
    local helper="$TEST_TMPDIR/native-signal-launch-failed.sh"
    local art="$TEST_TMPDIR/native-signal-launch-failed-art"
    mkdir -p "$art"
    printf '%s\n' '{"schema":"legion.child-execution-lease.v1","status":"launch_failed","reason":"child launch failed","max_runtime_seconds":30}' > "$art/lease-1.json"
    {
      sed -n '/^write_interrupted_native_attempt()/,/^}/p' "$DELEGATE"
      cat <<'SH'
legion_adapter_supervisor_launch_failed() {
  jq -e '.schema == "legion.child-execution-lease.v1"
    and .status == "launch_failed" and (has("child_exit_code") | not)' "$1" >/dev/null
}
NATIVE_ATTEMPT_ART="$1"
NATIVE_ATTEMPT_ORDINAL=1
NATIVE_ATTEMPT_LAUNCHED=1
NATIVE_LEASE_STATUS="$1/lease-1.json"
write_interrupted_native_attempt
[[ -z "$NATIVE_ATTEMPT_ART" && "$NATIVE_ATTEMPT_LAUNCHED" -eq 0 ]]
SH
    } > "$helper"

    run bash "$helper" "$art"

    [ "$status" -eq 0 ]
    [ -f "$art/lease-1.json" ]
    [ ! -e "$art/attempt-1.json" ]
    [ ! -e "$art/failure-1.json" ]
}

@test "delegate native signal writer honors completed lease and retained child result" {
    local helper art lease
    helper="$TEST_TMPDIR/native-signal-completed.sh"
    art="$TEST_TMPDIR/native-signal-completed-art"
    lease="$art/lease-1.json"
    mkdir -p "$art"
    printf '%s\n' '{"schema":"legion.child-execution-lease.v1","status":"completed","reason":"child completed","max_runtime_seconds":30,"child_exit_code":0}' > "$lease"
    {
      sed -n '/^write_interrupted_native_attempt()/,/^}/p' "$DELEGATE"
      cat <<'SH'
source "$1"
RUN_ID=native-completed-race
_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
codex_usage() { printf '{}'; }
cost_from_usage() { printf 0; }
cost_model_has_pricing() { return 1; }
NATIVE_ATTEMPT_ART="$2"
NATIVE_ATTEMPT_EXECUTOR=codex
NATIVE_ATTEMPT_ORDINAL=1
NATIVE_ATTEMPT_MODEL=fixture-model
NATIVE_ATTEMPT_EFFORT=high
NATIVE_ATTEMPT_SANDBOX=workspace-write
NATIVE_ATTEMPT_STREAM="$2/stream.jsonl"
NATIVE_ATTEMPT_LAST_MESSAGE="$2/last-message.txt"
NATIVE_ATTEMPT_STARTED_AT=2026-01-01T00:00:00Z
NATIVE_ATTEMPT_START_MS="$(date +%s000)"
NATIVE_ATTEMPT_LAUNCHED=1
NATIVE_LEASE_STATUS="$3"
CODEX_CHILD_RC=127
: > "$NATIVE_ATTEMPT_STREAM"
write_interrupted_native_attempt
SH
    } > "$helper"

    run bash "$helper" "$LIB/adapter-contract.sh" "$art" "$lease"

    [ "$status" -eq 0 ]
    jq -e '.terminal_status == "succeeded" and .failure == null' "$art/attempt-1.json"
    [ ! -e "$art/failure-1.json" ]
}

@test "delegate delayed signal after committed run rollup preserves success" {
    local helper="$TEST_TMPDIR/native-run-delayed-signal.sh"
    local art="$TEST_TMPDIR/native-run-delayed-signal-art"
    mkdir -p "$art"
    {
      sed -n '/^on_terminating_signal()/,/^}/p' "$DELEGATE"
      cat <<'SH'
NATIVE_RUN_ROLLUP_COMMITTED=1
NATIVE_RUN_TERMINAL_STATUS=ok
NATIVE_RUN_TERMINAL_EXIT=0
NATIVE_RUN_ART="$1"
NATIVE_ATTEMPT_ART=""
NATIVE_ATTEMPT_EXECUTOR=""
NATIVE_ATTEMPT_MODEL=""
NATIVE_ATTEMPT_ORDINAL=0
NATIVE_ATTEMPT_LAUNCHED=0
CODEX_CHILD_RC=0
CODEX_CHILD_PID=""
CODEX_SIGNAL_CHILD_PID=""
RUN_ID=completed-run
LEGION_WT_PATH=retained-until-exit
write_run_state() { :; }
write_run_artifact_status() { printf '%s:%s\n' "$3" "$6" > "$1/status.seen"; }
legion_disarm_adopted_run_guard() { :; }
on_terminating_signal TERM
SH
    } > "$helper"

    run bash "$helper" "$art"

    [ "$status" -eq 0 ]
    [ "$(cat "$art/status.seen")" = "completed:ok" ]
}

@test "native provider span publication defers a signal until its claim is durable" {
    local helper art signal_seen telemetry
    helper="$TEST_TMPDIR/native-span-signal.sh"
    art="$TEST_TMPDIR/native-span-signal-art"
    signal_seen="$TEST_TMPDIR/native-span-signal.seen"
    telemetry="$TEST_TMPDIR/native-span-signal.jsonl"
    mkdir -p "$art"
    printf '%s\n' '{"executor":"codex","provider":"openai","requested_model":"fixture-model","effective_model":"fixture-model","terminal_status":"succeeded","duration_ms":1,"usage":null,"usage_status":"unknown","cost_usd":null,"cost_status":"unknown","failure":null}' > "$art/attempt-1.json"
    {
      sed -n '/^native_span_publication_begin()/,/^}/p' "$DELEGATE"
      sed -n '/^native_span_publication_end()/,/^}/p' "$DELEGATE"
      sed -n '/^native_provider_span_is_recorded()/,/^}/p' "$DELEGATE"
      sed -n '/^native_provider_span_claim()/,/^}/p' "$DELEGATE"
      sed -n '/^native_provider_span_release_lock()/,/^}/p' "$DELEGATE"
      sed -n '/^native_provider_span_release()/,/^}/p' "$DELEGATE"
      sed -n '/^native_provider_span_commit()/,/^}/p' "$DELEGATE"
      sed -n '/^emit_provider_attempt_span()/,/^}/p' "$DELEGATE"
      cat <<'SH'
TERMINATING_SIGNAL_ACTIVE=0
NATIVE_SPAN_PUBLICATION_PENDING_SIGNAL=""
SIGNAL_SEEN="$2"
TELEMETRY="$3"
LEGION_TELEMETRY_DIR="$(dirname "$TELEMETRY")"
on_terminating_signal() { printf 'term\n' > "$SIGNAL_SEEN"; exit 143; }
ingest_usage() { :; }
ATTEMPT_ROOT="$1"
emit_span() {
  jq -cn --arg attempt "$ATTEMPT_ROOT/attempt-1.json" \
    '{schema:"legion.span.v1",artifacts:{provider_attempt:true,attempt_receipt:$attempt}}' \
    >> "$TELEMETRY"
  kill -TERM "$$"
}
emit_provider_attempt_span "$ATTEMPT_ROOT/attempt-1.json" fixture ""
SH
    } > "$helper"

    run bash "$helper" "$art" "$signal_seen" "$telemetry"

    [ "$status" -eq 143 ]
    [ "$(wc -l < "$telemetry" | tr -d ' ')" -eq 1 ]
    [ -f "$art/attempt-1.json.span-emitted/committed" ]
    [ -f "$signal_seen" ]
}

@test "native provider span publication atomically arbitrates concurrent stale-lock reclaimers" {
    local helper art telemetry
    helper="$TEST_TMPDIR/native-span-reclaim.sh"
    art="$TEST_TMPDIR/native-span-reclaim-art"
    telemetry="$TEST_TMPDIR/native-span-reclaim.jsonl"
    mkdir -p "$art/attempt-1.json.span-emitted"
    printf '%s\n' '{"executor":"codex","provider":"openai","requested_model":"fixture-model","effective_model":"fixture-model","terminal_status":"succeeded","duration_ms":1,"usage":null,"usage_status":"unknown","cost_usd":null,"cost_status":"unknown","failure":null}' > "$art/attempt-1.json"
    printf '%s\n' 99999999 > "$art/attempt-1.json.span-emitted/owner"
    : > "$art/attempt-1.json.span-emitted/committed"
    printf '%s\n' 99999999 > "$art/attempt-1.json.span-publishing"
    {
      sed -n '/^native_span_publication_begin()/,/^}/p' "$DELEGATE"
      sed -n '/^native_span_publication_end()/,/^}/p' "$DELEGATE"
      sed -n '/^native_provider_span_is_recorded()/,/^}/p' "$DELEGATE"
      sed -n '/^native_provider_span_claim()/,/^}/p' "$DELEGATE"
      sed -n '/^native_provider_span_release_lock()/,/^}/p' "$DELEGATE"
      sed -n '/^native_provider_span_release()/,/^}/p' "$DELEGATE"
      sed -n '/^native_provider_span_commit()/,/^}/p' "$DELEGATE"
      sed -n '/^emit_provider_attempt_span()/,/^}/p' "$DELEGATE"
      cat <<'SH'
TERMINATING_SIGNAL_ACTIVE=0
NATIVE_SPAN_PUBLICATION_PENDING_SIGNAL=""
ATTEMPT_ROOT="$1"
TELEMETRY="$2"
LEGION_TELEMETRY_DIR="$(dirname "$TELEMETRY")"
on_terminating_signal() { exit 143; }
emit_span() {
  sleep 0.1
  jq -cn --arg attempt "$ATTEMPT_ROOT/attempt-1.json" \
    '{schema:"legion.span.v1",artifacts:{provider_attempt:true,attempt_receipt:$attempt}}' \
    >> "$TELEMETRY"
}
ingest_usage() { :; }
for _retry in $(seq 1 100); do
  emit_provider_attempt_span "$ATTEMPT_ROOT/attempt-1.json" fixture "" && exit 0
  sleep 0.01
done
exit 1
SH
    } > "$helper"

    run bash -c 'bash "$1" "$2" "$3" & one=$!; bash "$1" "$2" "$3" & two=$!; wait "$one"; wait "$two"' \
      _ "$helper" "$art" "$telemetry"

    [ "$status" -eq 0 ] || { printf 'concurrent publishers: %s\n' "$output" >&2; false; }
    [ "$(wc -l < "$telemetry" | tr -d ' ')" -eq 1 ]
    [ -f "$art/attempt-1.json.span-emitted/committed" ]
    [ ! -e "$art/attempt-1.json.span-emitted/owner" ]
    [ -f "$art/attempt-1.json.span-publishing" ]
    [ ! -s "$art/attempt-1.json.span-publishing" ]
}

@test "native durability ignores a malformed telemetry tail" {
    local helper art telemetry
    helper="$TEST_TMPDIR/native-span-malformed-tail.sh"
    art="$TEST_TMPDIR/native-span-malformed-tail-art"
    telemetry="$TEST_TMPDIR/native-span-malformed-tail.jsonl"
    mkdir -p "$art"
    printf '%s\n' '{"executor":"codex","provider":"openai","requested_model":"fixture-model","effective_model":"fixture-model","terminal_status":"succeeded","duration_ms":1,"usage":null,"usage_status":"unknown","cost_usd":null,"cost_status":"unknown","failure":null}' > "$art/attempt-1.json"
    jq -cn --arg attempt "$art/attempt-1.json" \
      '{schema:"legion.span.v1",artifacts:{provider_attempt:true,attempt_receipt:$attempt}}' \
      > "$telemetry"
    printf '%s\n' '{malformed trailing record' >> "$telemetry"
    printf '%s\n' '"structurally malformed record"' >> "$telemetry"
    {
      sed -n '/^native_span_publication_begin()/,/^}/p' "$DELEGATE"
      sed -n '/^native_span_publication_end()/,/^}/p' "$DELEGATE"
      sed -n '/^native_provider_span_is_recorded()/,/^}/p' "$DELEGATE"
      sed -n '/^native_provider_span_claim()/,/^}/p' "$DELEGATE"
      sed -n '/^native_provider_span_release_lock()/,/^}/p' "$DELEGATE"
      sed -n '/^native_provider_span_release()/,/^}/p' "$DELEGATE"
      sed -n '/^native_provider_span_commit()/,/^}/p' "$DELEGATE"
      sed -n '/^emit_provider_attempt_span()/,/^}/p' "$DELEGATE"
      cat <<'SH'
LEGION_TELEMETRY_DIR="$(dirname "$2")"
DUPLICATE="$1/duplicate"
TERMINATING_SIGNAL_ACTIVE=0
NATIVE_SPAN_PUBLICATION_PENDING_SIGNAL=""
on_terminating_signal() { exit 143; }
emit_span() { : > "$DUPLICATE"; }
ingest_usage() { :; }
emit_provider_attempt_span "$1/attempt-1.json" fixture ""
[[ ! -e "$DUPLICATE" ]]
SH
    } > "$helper"

    run bash "$helper" "$art" "$telemetry"

    [ "$status" -eq 0 ]
}

@test "native claim keeps one stable inode and rejects a live same-shell contender" {
    local helper art
    helper="$TEST_TMPDIR/native-span-live-owner.sh"
    art="$TEST_TMPDIR/native-span-live-owner-art"
    mkdir -p "$art/telemetry"
    printf '{}\n' > "$art/attempt-1.json"
    {
      sed -n '/^native_provider_span_is_recorded()/,/^}/p' "$DELEGATE"
      sed -n '/^native_provider_span_claim()/,/^}/p' "$DELEGATE"
      sed -n '/^native_provider_span_release_lock()/,/^}/p' "$DELEGATE"
      sed -n '/^native_provider_span_release()/,/^}/p' "$DELEGATE"
      cat <<'SH'
set -euo pipefail
LEGION_TELEMETRY_DIR="$1/telemetry"
attempt="$1/attempt-1.json"
entered="$1/entered"
release="$1/release"
(
  native_provider_span_claim "$attempt"
  : > "$entered"
  while [[ ! -e "$release" ]]; do sleep 0.01; done
  native_provider_span_release "$attempt"
) &
publisher=$!
for _retry in $(seq 1 100); do
  [[ -e "$entered" ]] && break
  sleep 0.01
done
[[ -e "$entered" ]]
! native_provider_span_claim "$attempt"
: > "$release"
wait "$publisher"
[[ -f "$attempt.span-publishing" && ! -s "$attempt.span-publishing" ]]
SH
    } > "$helper"

    run bash "$helper" "$art"

    [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }
}

@test "native claim reclaims malformed owners and refuses linked lock inodes" {
    local helper art
    helper="$TEST_TMPDIR/native-span-owner-validation.sh"
    art="$TEST_TMPDIR/native-span-owner-validation-art"
    mkdir -p "$art/telemetry"
    printf '{}\n' > "$art/attempt-1.json"
    printf '%s\n' 'not-a-pid' > "$art/attempt-1.json.span-publishing"
    printf '%s\n' 'do-not-overwrite' > "$art/victim"
    ln "$art/victim" "$art/attempt-2.json.span-publishing"
    printf '{}\n' > "$art/attempt-2.json"
    {
      sed -n '/^native_provider_span_is_recorded()/,/^}/p' "$DELEGATE"
      sed -n '/^native_provider_span_claim()/,/^}/p' "$DELEGATE"
      sed -n '/^native_provider_span_release_lock()/,/^}/p' "$DELEGATE"
      sed -n '/^native_provider_span_release()/,/^}/p' "$DELEGATE"
      cat <<'SH'
set -euo pipefail
LEGION_TELEMETRY_DIR="$1/telemetry"
native_provider_span_claim "$1/attempt-1.json"
native_provider_span_release "$1/attempt-1.json"
! native_provider_span_claim "$1/attempt-2.json"
[[ "$(cat "$1/victim")" == do-not-overwrite ]]
SH
    } > "$helper"

    run bash "$helper" "$art"

    [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }
}

@test "native claim distinguishes PID reuse and conservatively migrates live legacy owners" {
    local helper art
    helper="$TEST_TMPDIR/native-span-incarnation.sh"
    art="$TEST_TMPDIR/native-span-incarnation-art"
    mkdir -p "$art/telemetry"
    printf '{}\n' > "$art/attempt-1.json"
    {
      sed -n '/^native_provider_span_is_recorded()/,/^}/p' "$DELEGATE"
      sed -n '/^native_provider_span_claim()/,/^}/p' "$DELEGATE"
      sed -n '/^native_provider_span_release_lock()/,/^}/p' "$DELEGATE"
      sed -n '/^native_provider_span_release()/,/^}/p' "$DELEGATE"
      cat <<'SH'
set -euo pipefail
LEGION_TELEMETRY_DIR="$1/telemetry"
attempt="$1/attempt-1.json"
lock="$attempt.span-publishing"

native_provider_span_claim "$attempt"
incarnation="$(jq -r .publisher_incarnation "$lock")"
native_provider_span_release "$attempt"
case "$incarnation" in
  linux:*) collision="${incarnation%:*}:$(( ${incarnation##*:} + 1 ))" ;;
  darwin:*) collision="${incarnation%:*}:$(( ${incarnation##*:} + 1 ))" ;;
  *) exit 1 ;;
esac
jq -cn --argjson pid "$$" --arg incarnation "$collision" \
  '{schema:"legion.native-provider-span-claim.v1",publisher_pid:$pid,
    publisher_incarnation:$incarnation,
    token:"111111111111111111111111111111111111111111111111"}' > "$lock"
native_provider_span_claim "$attempt"
jq -e --arg incarnation "$incarnation" '.publisher_incarnation == $incarnation' "$lock"
native_provider_span_release "$attempt"

printf '%s\n' "$$" > "$lock"
! native_provider_span_claim "$attempt"
SH
    } > "$helper"

    run bash "$helper" "$art"

    [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }
}

@test "native claim supports authenticated self re-entry and restricted supervisor fallback" {
    [[ "$(uname -s)" == Darwin && -x /usr/bin/sandbox-exec ]] || skip "requires Darwin sandbox-exec"
    local helper art
    helper="$TEST_TMPDIR/native-span-self-reentry.sh"
    art="$TEST_TMPDIR/native-span-self-reentry-art"
    mkdir -p "$art/telemetry"
    printf '{}\n' > "$art/attempt-1.json"
    {
      sed -n '/^native_provider_span_is_recorded()/,/^}/p' "$DELEGATE"
      sed -n '/^native_provider_span_claim()/,/^}/p' "$DELEGATE"
      sed -n '/^native_provider_span_release_lock()/,/^}/p' "$DELEGATE"
      sed -n '/^native_provider_span_release()/,/^}/p' "$DELEGATE"
      cat <<'SH'
set -euo pipefail
LEGION_TELEMETRY_DIR="$1/telemetry"
attempt="$1/attempt-1.json"
native_provider_span_claim "$attempt"
first_token="$NATIVE_PROVIDER_SPAN_CLAIM_TOKEN"
first_owner="$(cat "$attempt.span-publishing")"
native_provider_span_claim "$attempt"
[[ "$NATIVE_PROVIDER_SPAN_CLAIM_TOKEN" == "$first_token" ]]
[[ "$(cat "$attempt.span-publishing")" == "$first_owner" ]]
jq -e --argjson pid "$$" --arg supervisor "$LEGION_SUPERVISOR_TOKEN" \
  '.publisher_pid == $pid
   and .publisher_incarnation == ("supervisor:" + $supervisor + ":pid:" + ($pid | tostring))' \
  "$attempt.span-publishing"
native_provider_span_release "$attempt"
SH
    } > "$helper"

    run env LEGION_SUPERVISOR_TOKEN=cccccccccccccccccccccccccccccccccccccccccccccccc \
      /usr/bin/sandbox-exec -p '(version 1) (allow default) (deny process-info*)' \
      bash "$helper" "$art"

    [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }
}

@test "native review ingestion preserves the failed provider status" {
    local helper art ingest
    helper="$TEST_TMPDIR/native-review-ingest.sh"
    art="$TEST_TMPDIR/native-review-ingest-art"
    ingest="$TEST_TMPDIR/native-review-ingest.args"
    mkdir -p "$art"
    printf '%s\n' '{"executor":"codex-review","provider":"openai","requested_model":"fixture-model","effective_model":"fixture-model","terminal_status":"failed","duration_ms":1,"usage":{"input_tokens":1},"usage_status":"known","cost_usd":0.01,"cost_status":"known","failure":{"provider_code":17}}' > "$art/attempt-1.json"
    {
      sed -n '/^native_span_publication_begin()/,/^}/p' "$DELEGATE"
      sed -n '/^native_span_publication_end()/,/^}/p' "$DELEGATE"
      sed -n '/^native_provider_span_is_recorded()/,/^}/p' "$DELEGATE"
      sed -n '/^native_provider_span_claim()/,/^}/p' "$DELEGATE"
      sed -n '/^native_provider_span_release_lock()/,/^}/p' "$DELEGATE"
      sed -n '/^native_provider_span_release()/,/^}/p' "$DELEGATE"
      sed -n '/^native_provider_span_commit()/,/^}/p' "$DELEGATE"
      sed -n '/^emit_native_review_provider_span()/,/^}/p' "$DELEGATE"
      cat <<'SH'
TERMINATING_SIGNAL_ACTIVE=0
NATIVE_SPAN_PUBLICATION_PENDING_SIGNAL=""
INGEST="$2"
LEGION_TELEMETRY_DIR="$1/telemetry"
mkdir -p "$LEGION_TELEMETRY_DIR"
on_terminating_signal() { exit 143; }
ATTEMPT_ROOT="$1"
emit_span() {
  jq -cn --arg attempt "$ATTEMPT_ROOT/attempt-1.json" \
    '{schema:"legion.span.v1",artifacts:{provider_attempt:true,attempt_receipt:$attempt}}' \
    >> "$LEGION_TELEMETRY_DIR/spans.jsonl"
}
ingest_usage() { printf '%s\n' "$3" > "$INGEST"; }
emit_native_review_provider_span "$1/attempt-1.json" fixture ""
SH
    } > "$helper"

    run bash "$helper" "$art" "$ingest"

    [ "$status" -eq 0 ]
    [ "$(cat "$ingest")" -eq 17 ]
    [ -f "$art/attempt-1.json.span-emitted/committed" ]
}

@test "adapter receipts clear the mutable failure alias after a successful retry" {
    local art="$TEST_TMPDIR/receipt-retry"
    mkdir -p "$art"

    run bash -c '
      source "$1"
      RUN_ID=retry-run
      legion_adapter_write_attempt "$2" codex openai 1 first "" "" "" workspace-write \
        failed 2026-01-01T00:00:00Z 2026-01-01T00:00:01Z 1000 \
        "{}" unknown "" 0 unknown "" provider true false 1 failed
      legion_adapter_write_attempt "$2" codex openai 2 second "" "" "" workspace-write \
        succeeded 2026-01-01T00:00:01Z 2026-01-01T00:00:02Z 1000 \
        "{}" unknown "" 0 unknown "" "" false true "" ""
      [[ -z "$LEGION_ADAPTER_FAILURE_PATH" ]]
    ' _ "$LIB/adapter-contract.sh" "$art"

    [ "$status" -eq 0 ]
    [ -f "$art/failure-1.json" ]
    [ ! -e "$art/failure.json" ]
    jq -e '.terminal_status == "succeeded" and .failure == null' "$art/attempt.json"
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

@test "delegate cleanup removes retained Pi and Hermes worktrees from ownership receipts" {
    local executor repo result run_id branch
    for executor in pi hermes; do
      repo="$(make_test_repo "cleanup-retained-$executor")"
      result="$(PI_BIN=pi HERMES_BIN=hermes "$REPO_ROOT/legion-router/bin/legion-$executor" \
        run --model openai/fixture-model --task "make a scoped edit" --repo "$repo" --keep --quiet)"
      run_id="$(echo "$result" | jq -r .run_id)"
      branch="legion/$executor-$run_id"
      [ -d "$repo/.legion/worktrees/$run_id" ]
      jq -e --arg run "$run_id" --arg branch "$branch" \
        '.schema == "legion.worktree-owner.v1" and .run_id == $run and .branch == $branch' \
        "$repo/.legion/runs/$run_id/worktree-owner.json"

      run "$DELEGATE" cleanup --run "$run_id" --repo "$repo" --quiet
      [ "$status" -eq 0 ]
      [ ! -d "$repo/.legion/worktrees/$run_id" ]
      [ -z "$(git -C "$repo" branch --list "$branch")" ]
    done
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

@test "delegate run: model-less DeepSeek dispatch leaves profile model selection opaque" {
  local repo preflight
  repo="$(make_test_repo deepseek-model-less)"

  run "$DELEGATE" run --executor deepseek --task x --repo "$repo" --quiet

  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "ok" and .executor == "deepseek"'
  preflight="$(echo "$output" | jq -r .preflight_receipt)"
  jq -e '.executor == "deepseek"
    and .compatibility.model.requested == null
    and .compatibility.model.status == "not_requested"' "$preflight"
  assert_mock_called dsh "--profile"
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
  echo "$output" | jq -e '.status == "ok" and .model == "test-model-beta"
    and .failure_receipt == null
    and .usage == null and .usage_status == "partial"
    and (.known_usage.input_tokens | type) == "number"
    and .known_usage_attempts == 1
    and .cost_usd == null and .cost_status == "unknown"
    and (has("known_cost_usd") | not)
    and (has("known_cost_attempts") | not)
    and .metering_reconciliation.attempt_count == 2'
  local art; art="$(dirname "$(echo "$output" | jq -r .attempt_receipt)")"
  [ -f "$art/failure-1.json" ]
  [ ! -e "$art/failure.json" ]
  [ -s "$route_env" ]
  ! grep -Eq 'pre=1|executor=codex|fallback=test-model-beta' "$route_env"

  local spans provider_spans rollup
  spans="$(cat "$LEGION_TELEMETRY_DIR"/*.jsonl)"
  provider_spans="$(jq -cs '[.[] | select(.executor == "codex" and .artifacts.provider_attempt == true)]' \
    <<<"$spans")"
  [ "$(jq length <<<"$provider_spans")" -eq 2 ]
  while IFS= read -r provider_span; do
    local receipt
    receipt="$(jq -r .artifacts.attempt_receipt <<<"$provider_span")"
    jq -e --arg model "$(jq -r '.effective_model // .requested_model' "$receipt")" \
      --argjson duration "$(jq -r .duration_ms "$receipt")" \
      '.model == $model and .duration_ms == $duration' <<<"$provider_span"
  done < <(jq -c '.[]' <<<"$provider_spans")
  rollup="$(jq -c 'select(.executor == "codex" and .artifacts.rollup_only == true)' <<<"$spans")"
  jq -e '.cost_usd == null and .cost_status == "not_applicable"
    and .tokens == null and .usage_status == "not_applicable"' <<<"$rollup"
}

@test "delegate run: fallback launch_failed clears current aliases without losing prior paid spend" {
  local repo result art lease
  repo="$(make_test_repo fallback-launch-failed-aliases)"
  export LEGION_TEST_LAUNCH_FAIL_MODEL=test-model-beta
  install_launch_failed_supervisor_shim

  LEGION_ROUTE_PRE_RESOLVED=1 LEGION_RESOLVED_EXECUTOR=codex \
    LEGION_RESOLVED_FALLBACK=test-model-beta MOCK_CODEX_QUOTA_FAIL="$CODEX_WORKHORSE" \
    run "$DELEGATE" run --archetype route-does-not-exist --executor codex \
      --model "$CODEX_WORKHORSE" --sandbox workspace-write --reasoning-effort high \
      --task x --repo "$repo" --quiet

  [ "$status" -ne 0 ]
  result="$(printf '%s\n' "$output" | tail -n 1)"
  jq -e '.status == "failed" and .model == "test-model-beta"
    and .attempt_receipt == null and .failure_receipt == null
    and .usage == null and .cost_usd == null
    and (.reason | contains("no provider launched"))' <<<"$result"
  lease="$(jq -r .lease_receipt <<<"$result")"
  art="$(dirname "$lease")"
  jq -e '.status == "launch_failed"' "$lease"
  jq -e --arg model "$CODEX_WORKHORSE" '.requested_model == $model
    and .terminal_status == "failed" and .failure.class == "quota"' "$art/attempt-1.json"
  [ -f "$art/failure-1.json" ]
  [ ! -e "$art/attempt.json" ]
  [ ! -e "$art/failure.json" ]
  jq -e '.compatibility.model.requested == "test-model-beta"' "$art/preflight.json"
  [ "$(cat "$LEGION_TELEMETRY_DIR"/*.jsonl | jq -s \
    '[.[] | select(.artifacts.provider_attempt == true)] | length')" -eq 1 ]
  [ "$(cat "$LEGION_TELEMETRY_DIR"/*.jsonl | jq -s \
    '[.[] | select(.artifacts.provider_attempt == true)
      | .artifacts.attempt_receipt | select(endswith("/attempt-1.json"))] | length')" -eq 1 ]
}

@test "delegate run: a refused fallback never replaces the paid model identity" {
  local repo art
  repo="$(make_test_repo refused-fallback-identity)"
  install_refused_fallback_preflight_shim

  LEGION_ROUTE_PRE_RESOLVED=1 \
    LEGION_RESOLVED_EXECUTOR=codex \
    LEGION_RESOLVED_FALLBACK=refused-fallback \
    MOCK_CODEX_QUOTA_FAIL="$CODEX_WORKHORSE" \
    run "$DELEGATE" run --archetype route-does-not-exist \
      --executor codex --model "$CODEX_WORKHORSE" \
      --sandbox workspace-write --reasoning-effort high --task x --repo "$repo" --quiet

  [ "$status" -eq 1 ]
  echo "$output" | jq -e --arg paid "$CODEX_WORKHORSE" '
    .status == "failed" and .model == $paid
    and .attempt_receipt == null and .failure_receipt == null
    and .usage == null and .usage_status == "unknown"
    and .cost_usd == null and .cost_status == "unknown"
    and .metering_reconciliation.attempt_count == 1'
  art="$(find "$repo/.legion/runs" -mindepth 1 -maxdepth 1 -type d -print -quit)"
  jq -e --arg paid "$CODEX_WORKHORSE" \
    '.requested_model == $paid and .failure.class == "quota"' "$art/attempt-1.json"
  jq -e '.status == "incompatible" and .reason == "forced fallback refusal"' \
    "$art/codex-preflight-2.json"
  [ ! -e "$art/attempt.json" ]
  [ ! -e "$art/failure.json" ]
  [ "$(grep -c '^codex exec ' "$MOCK_CALL_LOG")" -eq 1 ]
}

@test "delegate run: every paid Codex fallback is re-admitted under one absolute lease" {
  local repo precision workhorse art
  repo="$(make_test_repo codex-fallback-admission-lease)"
  precision="$("$REPO_ROOT/legion-router/bin/legion-route" --model-ref codex_precision)"
  workhorse="$("$REPO_ROOT/legion-router/bin/legion-route" --model-ref codex_workhorse)"

  MOCK_CODEX_QUOTA_FAIL="$precision" MOCK_CODEX_DELAY=2 \
    run "$DELEGATE" run --archetype migration --task x --repo "$repo" \
      --max-runtime-seconds 3 --quiet

  [ "$status" -eq 1 ]
  echo "$output" | jq -e '.status == "timed_out"'
  art="$(dirname "$(echo "$output" | jq -r .attempt_receipt)")"
  jq -e --arg model "$precision" \
    '.schema == "legion.preflight.v1" and .compatibility.model.requested == $model' \
    "$art/codex-preflight-1.json"
  jq -e --arg model "$workhorse" \
    '.schema == "legion.preflight.v1" and .compatibility.model.requested == $model' \
    "$art/codex-preflight-2.json"
  jq -e '.terminal_status == "failed" and .failure.class == "quota"' "$art/attempt-1.json"
  jq -e '.terminal_status == "timed_out" and .failure.class == "timed_out"' "$art/attempt-2.json"
  [ "$(grep -c '^codex exec ' "$MOCK_CALL_LOG")" -eq 2 ]
}

@test "Claude does not re-emit a declined attempt for a later no-launch model" {
  local repo art run_id
  repo="$(make_test_repo claude-decline-no-launch)"
  install_authenticated_incompatible_preflight_shim claude model-b

  MOCK_CLAUDE_DECLINE_MODELS=model-declines \
    LEGION_CLAUDE_FALLBACK_MODELS=model-b \
    run "$REPO_ROOT/legion-router/bin/legion-claude" run \
      --model model-declines --no-fallback --task x --repo "$repo" --quiet

  [ "$status" -eq 1 ]
  echo "$output" | jq -e '.status == "failed" and .reason == "admission_refused"
    and .model == "model-b"
    and .attempt_receipt == null and .failure_receipt == null
    and .usage_status == "known" and .usage.input_tokens == 100000
    and .cost_status == "unknown" and .cost_usd == null'
  run_id="$(echo "$output" | jq -r .run_id)"
  art="$repo/.legion/runs/$run_id"
  [ -f "$art/attempt-1.json" ]
  [ ! -e "$art/attempt-2.json" ]
  [ "$(grep -Ec '^claude -p ' "$MOCK_CALL_LOG")" -eq 1 ]
  jq -s -e --arg run "$run_id" '
    [.[] | select(.run_id == $run and .executor == "claude")] as $spans
    | ($spans | length) == 1
      and $spans[0].model == "model-declines"
      and $spans[0].artifacts.provider_attempt == true
  ' "$LEGION_TELEMETRY_DIR"/*.jsonl
}

@test "Claude-to-Codex fallback keeps every emitted Claude receipt path stable" {
  local repo run_id art spans
  repo="$(make_test_repo claude-fallback-stable-receipts)"

  MOCK_CLAUDE_DECLINE_MODELS=model-declines,model-b \
    LEGION_CLAUDE_FALLBACK_MODELS=model-b \
    run "$REPO_ROOT/legion-router/bin/legion-claude" run \
      --model model-declines --task x --repo "$repo" --quiet

  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.executor == "codex" and .fell_back == true'
  run_id="$(echo "$output" | jq -r .run_id)"
  art="$repo/.legion/runs/$run_id"
  spans="$(cat "$LEGION_TELEMETRY_DIR"/*.jsonl)"
  [ "$(jq -s --arg run "$run_id" '[.[] | select(.run_id == $run and .executor == "claude")] | length' <<<"$spans")" -eq 2 ]
  while IFS= read -r receipt; do
    [[ "$receipt" == "$art/claude/"* ]]
    jq -e '.executor == "claude"' "$receipt"
  done < <(jq -r --arg run "$run_id" \
    'select(.run_id == $run and .executor == "claude") | .artifacts.attempt_receipt' <<<"$spans")
}

@test "delegate run: inherited Codex deadline can lower but never be raised" {
  local repo inherited started elapsed
  repo="$(make_test_repo codex-inherited-lease)"
  inherited="$(python3 - <<'PY'
import time
print(time.monotonic_ns() + 1_000_000_000)
PY
)"
  started="$SECONDS"

  LEGION_CHILD_LEASE_DEADLINE_NS="$inherited" MOCK_CODEX_DELAY=30 \
    run "$DELEGATE" run --model test-model-beta --task x --repo "$repo" \
      --max-runtime-seconds 30 --quiet
  elapsed=$((SECONDS - started))

  [ "$status" -eq 1 ]
  echo "$output" | jq -e '.status == "timed_out"'
  [ "$elapsed" -lt 5 ]
}

@test "delegate run: an exhausted lease before first launch has canonical no-launch identity" {
  local repo result lease run_id
  repo="$(make_test_repo codex-prelaunch-exhausted-lease)"
  install_exhausted_remaining_seconds_python_shim

  run "$DELEGATE" run --model test-model-beta --task x --repo "$repo" \
    --max-runtime-seconds 30 --quiet

  [ "$status" -eq 1 ]
  result="$(printf '%s\n' "$output" | tail -n 1)"
  echo "$result" | jq -e '.status == "timed_out"
    and .model == "test-model-beta" and .codex_exit == 124
    and .attempt_receipt == null and .failure_receipt == null
    and (.lease_receipt | type == "string" and length > 0)
    and (.reason | contains("child execution lease expired"))'
  lease="$(echo "$result" | jq -r .lease_receipt)"
  jq -e '.schema == "legion.child-execution-lease.v1"
    and .status == "launch_failed"
    and (.reason | contains("expired before provider launch"))
    and .max_runtime_seconds == 30
    and (has("child_exit_code") | not)
    and ((keys_unsorted - ["schema","status","reason","max_runtime_seconds"]) | length == 0)' \
    "$lease"
  run_id="$(echo "$result" | jq -r .run_id)"
  [ ! -e "$repo/.legion/runs/$run_id/attempt.json" ]
  [ ! -e "$repo/.legion/runs/$run_id/failure.json" ]
  [ "$(grep -Ec '^codex exec ' "$MOCK_CALL_LOG" || true)" -eq 0 ]
}

@test "delegate run: fallback candidate lease exhaustion retains prior spend and current no-launch identity" {
  local repo result art lease
  repo="$(make_test_repo codex-fallback-prelaunch-exhausted)"
  install_exhausted_remaining_seconds_python_shim
  export LEGION_TEST_REMAINING_VALUES=30,0

  LEGION_ROUTE_PRE_RESOLVED=1 LEGION_RESOLVED_EXECUTOR=codex \
    LEGION_RESOLVED_FALLBACK=test-model-beta MOCK_CODEX_QUOTA_FAIL="$CODEX_WORKHORSE" \
    run "$DELEGATE" run --archetype route-does-not-exist --executor codex \
      --model "$CODEX_WORKHORSE" --sandbox workspace-write --reasoning-effort high \
      --task x --repo "$repo" --max-runtime-seconds 30 --quiet

  [ "$status" -eq 1 ]
  result="$(printf '%s\n' "$output" | tail -n 1)"
  echo "$result" | jq -e '.status == "timed_out"
    and .model == "test-model-beta" and .codex_exit == 124
    and .attempt_receipt == null and .failure_receipt == null
    and .metering_reconciliation.attempt_count == 1'
  lease="$(echo "$result" | jq -r .lease_receipt)"
  art="$(dirname "$lease")"
  jq -e '.status == "launch_failed" and (has("child_exit_code") | not)' "$lease"
  jq -e --arg paid "$CODEX_WORKHORSE" '
    .requested_model == $paid and .failure.class == "quota"' "$art/attempt-1.json"
  [ ! -e "$art/attempt.json" ]
  [ ! -e "$art/failure.json" ]
  [ "$(grep -Ec '^codex exec ' "$MOCK_CALL_LOG" || true)" -eq 1 ]
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
      run bash -c "cat '$LEGION_TELEMETRY_DIR'/*.jsonl | jq -sec --arg run '$run_id' --arg parent 'parent-${source}-${target}' \
        '[.[] | select(.run_id == \$run)] | length > 0 and all(.[]; .parent_id == \$parent)'"
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
  # `delegate review` walks [review].order, and codex is first -> use a codex review
  # archetype (security-review). Final-review routes to Claude through legion-run.
  # Cross-lineage archetypes (second-opinion/tiebreak)
  # route to Cursor and run via `--executor cursor`, not this codex path.
  local repo; repo="$(make_test_repo arch4)"
  local base_sha; base_sha="$(git -C "$repo" rev-parse HEAD)"
  run "$DELEGATE" review --archetype security-review --base HEAD --repo "$repo" --quiet
  [ "$status" -eq 0 ]
  # security-review routes to the FRONTIER codex role, not the routine review one.
  echo "$output" | jq -e --arg model "$CODEX_FRONTIER" '.model == $model and .verdict.verdict == "approve" and (.verdict.summary | type == "string")'
  assert_mock_called codex "exec -s read-only review --base $base_sha -m $CODEX_FRONTIER"
  assert_mock_called codex "output-schema"
}

@test "delegate resume: continues a --keep'd run + emits codex-resume span" {
  local repo; repo="$(make_test_repo res1)"
  out="$("$DELEGATE" run --model test-model-alpha --task initial --repo "$repo" --keep --quiet)"
  rid="$(echo "$out" | jq -r .run_id)"
  run "$DELEGATE" resume --run "$rid" --task "follow up" --repo "$repo" --quiet
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "ok" and .thread_id == "mock-thread-0001"
    and (.preflight_receipt | type) == "string"
    and (.attempt_receipt | type) == "string" and .failure_receipt == null'
  jq -e '.schema == "legion.preflight.v1" and .status == "supported"' \
    "$(echo "$output" | jq -r .preflight_receipt)"
  jq -e '.schema == "legion.attempt.v1" and .executor == "codex-resume"
    and .terminal_status == "succeeded"
    and (.cache_lineage.previous_attempt_id | type) == "string"' \
    "$(echo "$output" | jq -r .attempt_receipt)"
  assert_mock_called codex "exec resume mock-thread-0001"
}

@test "delegate resume: terminal metering follows canonical normalization" {
  local repo out rid attempt result
  repo="$(make_test_repo resume-negative-metering)"
  out="$("$DELEGATE" run --model test-model-alpha --task initial --repo "$repo" --keep --quiet)"
  rid="$(echo "$out" | jq -r .run_id)"

  MOCK_CODEX_RESUME_NEGATIVE_METERING=1 run "$DELEGATE" resume \
    --run "$rid" --task "follow up" --repo "$repo" --quiet

  [ "$status" -eq 0 ]
  result="$(printf '%s\n' "$output" | tail -n 1)"
  echo "$result" | jq -e '.usage == null and .usage_status == "unknown"'
  attempt="$(echo "$result" | jq -r .attempt_receipt)"
  jq -e --argjson terminal "$result" '
    .usage == $terminal.usage and .usage_status == $terminal.usage_status
    and .cost_usd == $terminal.cost_usd and .cost_status == $terminal.cost_status
  ' "$attempt"
}

@test "delegate resume: supervisor launch failure writes no provider receipt or span" {
  local repo rid result lease provider_spans_before provider_spans_after
  repo="$(make_test_repo resume-launch-failed)"
  out="$("$DELEGATE" run --model test-model-alpha --task initial --repo "$repo" --keep --quiet)"
  rid="$(echo "$out" | jq -r .run_id)"
  provider_spans_before="$(cat "$LEGION_TELEMETRY_DIR"/*.jsonl | jq -s \
    '[.[] | select(.artifacts.provider_attempt == true)] | length')"
  install_launch_failed_supervisor_shim

  run "$DELEGATE" resume --run "$rid" --task "follow up" --repo "$repo" --quiet

  [ "$status" -ne 0 ]
  result="$(printf '%s\n' "$output" | tail -n 1)"
  jq -e '.status == "failed"
    and .attempt_receipt == null and .failure_receipt == null
    and .usage == null and .cost_usd == null
    and (.reason | contains("no provider launched"))
    and (.lease_receipt | type == "string" and length > 0)' <<<"$result" || {
      printf 'resume result: %s\n' "$result" >&2
      false
    }
  lease="$(jq -r .lease_receipt <<<"$result")"
  jq -e '.status == "launch_failed" and (has("child_exit_code") | not)' "$lease"
  [ "$(find "$(dirname "$lease")" -maxdepth 1 -type f -name 'attempt-*.json' | wc -l | tr -d ' ')" -eq 0 ]
  provider_spans_after="$(cat "$LEGION_TELEMETRY_DIR"/*.jsonl | jq -s \
    '[.[] | select(.artifacts.provider_attempt == true)] | length')"
  [ "$provider_spans_after" -eq "$provider_spans_before" ]
  [ "$(grep -Fc 'codex exec resume' "$MOCK_CALL_LOG" || true)" -eq 0 ]
}

@test "delegate resume: each resume retains its ordinal-specific lease receipt" {
  local repo rid first second first_lease second_lease
  repo="$(make_test_repo resume-ordinal-leases)"
  out="$("$DELEGATE" run --model test-model-alpha --task initial --repo "$repo" --keep --quiet)"
  rid="$(echo "$out" | jq -r .run_id)"

  first="$("$DELEGATE" resume --run "$rid" --task first --repo "$repo" --quiet)"
  second="$("$DELEGATE" resume --run "$rid" --task second --repo "$repo" --quiet)"
  first_lease="$(echo "$first" | jq -r .lease_receipt)"
  second_lease="$(echo "$second" | jq -r .lease_receipt)"

  [ "$first_lease" != "$second_lease" ]
  [[ "$first_lease" == */resume-1/lease-1.json ]]
  [[ "$second_lease" == */resume-2/lease-2.json ]]
  jq -e '.status == "completed"' "$first_lease"
  jq -e '.status == "completed"' "$second_lease"
}

@test "delegate resume: interruption publishes one provider span and terminalizes the run" {
  local repo rid pid_file stdout stderr resume_pid resume_rc run_dir
  repo="$(make_test_repo resume-interrupt)"
  out="$("$DELEGATE" run --model test-model-alpha --task initial --repo "$repo" --keep --quiet)"
  rid="$(echo "$out" | jq -r .run_id)"
  pid_file="$TEST_TMPDIR/resume-interrupt-child.pid"
  stdout="$TEST_TMPDIR/resume-interrupt.out"
  stderr="$TEST_TMPDIR/resume-interrupt.err"

  MOCK_CODEX_DELAY=30 MOCK_CODEX_DELAY_PID_FILE="$pid_file" \
    "$DELEGATE" resume --run "$rid" --task interrupted --repo "$repo" --quiet \
      >"$stdout" 2>"$stderr" &
  resume_pid=$!
  for _ in {1..100}; do
    [[ -s "$pid_file" ]] && break
    sleep 0.02
  done
  [ -s "$pid_file" ]

  kill -TERM "$resume_pid"
  resume_rc=0
  wait "$resume_pid" || resume_rc=$?

  if [[ "$resume_rc" -ne 143 ]]; then
    printf 'resume exited %s\n' "$resume_rc" >&2
    cat "$stderr" >&2
    false
  fi
  run_dir="$repo/.legion/runs/$rid"
  jq -e '.executor == "codex-resume" and .terminal_status == "cancelled"
    and .failure.class == "cancelled"' "$run_dir/resume-1/attempt-1.json"
  jq -e '.status == "failed" and .result_status == "failed"' "$run_dir/status.json"
  [ "$(cat "$LEGION_TELEMETRY_DIR"/*.jsonl | jq -s --arg run "$rid" '
    [.[] | select(.run_id == $run and .executor == "codex-resume"
      and .artifacts.provider_attempt == true)] | length')" -eq 1 ]
  ! kill -0 "$(cat "$pid_file")" 2>/dev/null
}

@test "delegate resume: unavailable admission refuses before another provider launch" {
  local repo rid
  repo="$(make_test_repo resume-admission-unavailable)"
  out="$("$DELEGATE" run --model test-model-alpha --task initial --repo "$repo" --keep --quiet)"
  rid="$(echo "$out" | jq -r .run_id)"

  CODEX_BIN=missing-codex-for-resume run "$DELEGATE" resume --run "$rid" \
    --task "follow up" --repo "$repo" --quiet

  [ "$status" -eq 1 ]
  echo "$output" | jq -e '.status == "refused"
    and (.reason | contains("binary not found"))
    and .attempt_receipt == null and .failure_receipt == null'
  jq -e '.schema == "legion.preflight.v1" and .status == "unavailable"' \
    "$(echo "$output" | jq -r .preflight_receipt)"
  [ "$(grep -Fc "codex exec resume" "$MOCK_CALL_LOG" || true)" -eq 0 ]
}

@test "delegate resume: provider failure writes attempt and failure receipts" {
  local repo rid
  repo="$(make_test_repo resume-provider-failure)"
  out="$("$DELEGATE" run --model test-model-alpha --task initial --repo "$repo" --keep --quiet)"
  rid="$(echo "$out" | jq -r .run_id)"

  MOCK_CODEX_FAIL=1 run "$DELEGATE" resume --run "$rid" --task "follow up" \
    --repo "$repo" --quiet

  [ "$status" -eq 1 ]
  echo "$output" | jq -e '.status == "failed"
    and .usage == null and .usage_status == "unknown"
    and .cost_usd == null and .cost_status == "unknown"'
  jq -e '.schema == "legion.attempt.v1" and .terminal_status == "failed"
    and .failure.class == "provider"' "$(echo "$output" | jq -r .attempt_receipt)"
  jq -e '.schema == "legion.failure.v1" and .class == "provider"' \
    "$(echo "$output" | jq -r .failure_receipt)"
}

@test "delegate resume: admission preserves the kept run's read-only sandbox" {
  local repo rid
  repo="$(make_test_repo resume-read-only-admission)"
  out="$("$DELEGATE" run --model test-model-alpha --sandbox read-only \
    --task initial --repo "$repo" --keep --quiet)"
  rid="$(echo "$out" | jq -r .run_id)"

  run "$DELEGATE" resume --run "$rid" --task "follow up" --repo "$repo" --quiet

  [ "$status" -eq 0 ]
  jq -e '.compatibility.sandbox.requested == "read-only"' \
    "$(echo "$output" | jq -r .preflight_receipt)"
  jq -e '.sandbox == "read-only"' "$(echo "$output" | jq -r .attempt_receipt)"
}

@test "delegate resume: child lease timeout removes the kept worktree and branch" {
  local repo rid pid_file child
  repo="$(make_test_repo resume-lease-timeout)"
  out="$("$DELEGATE" run --model test-model-alpha --task initial --repo "$repo" --keep --quiet)"
  rid="$(echo "$out" | jq -r .run_id)"
  pid_file="$TEST_TMPDIR/resume-lease-child.pid"

  MOCK_CODEX_DELAY=30 MOCK_CODEX_DETACH_DELAY=1 \
    MOCK_CODEX_DELAY_PID_FILE="$pid_file" \
    run "$DELEGATE" resume --run "$rid" --task "wait forever" --repo "$repo" \
      --max-runtime-seconds 1 --quiet

  [ "$status" -eq 1 ]
  echo "$output" | jq -e '
    .status == "timed_out"
    and (.reason | contains("expired after 1 seconds"))
    and (.worktree | contains("removed after child execution lease timeout"))
  '
  [ ! -d "$repo/.legion/worktrees/$rid" ]
  ! git -C "$repo" show-ref --verify --quiet "refs/heads/legion/delegate-$rid"
  child="$(cat "$pid_file")"
  ! kill -0 "$child" 2>/dev/null
}

@test "delegate resume: cleanup failure is internal and retains the kept worktree" {
  local repo rid wt
  repo="$(make_test_repo resume-cleanup-failed)"
  out="$("$DELEGATE" run --model test-model-alpha --task initial --repo "$repo" --keep --quiet)"
  rid="$(echo "$out" | jq -r .run_id)"
  install_cleanup_failed_supervisor_shim

  run "$DELEGATE" resume --run "$rid" --task follow-up --repo "$repo" \
    --max-runtime-seconds 30 --quiet

  [ "$status" -eq 1 ]
  echo "$output" | jq -e '.status == "containment_failed"
    and (.reason | contains("forced cleanup evidence"))
    and (.lease_receipt | type) == "string"'
  wt="$(echo "$output" | jq -r .worktree)"
  [ -d "$wt" ]
  jq -e '.terminal_status == "failed" and .failure.class == "internal"' \
    "$(echo "$output" | jq -r .attempt_receipt)"
  jq -e '.status == "cleanup_failed"' "$(echo "$output" | jq -r .lease_receipt)"
}

@test "delegate resume: prelaunch cleanup failure is containment with no attempt" {
  local repo rid result wt
  repo="$(make_test_repo resume-prelaunch-cleanup-failed)"
  out="$("$DELEGATE" run --model test-model-alpha --task initial --repo "$repo" --keep --quiet)"
  rid="$(echo "$out" | jq -r .run_id)"
  install_prelaunch_cleanup_failed_supervisor_shim

  run "$DELEGATE" resume --run "$rid" --task follow-up --repo "$repo" \
    --max-runtime-seconds 30 --quiet

  [ "$status" -eq 1 ]
  result="$(printf '%s\n' "$output" | tail -n 1)"
  echo "$result" | jq -e '.status == "containment_failed"
    and .attempt_receipt == null and .failure_receipt == null
    and .usage == null and .cost_usd == null
    and (.reason | contains("forced prelaunch containment evidence"))'
  wt="$(echo "$result" | jq -r .worktree)"
  [ -d "$wt" ]
  jq -e '.status == "cleanup_failed" and .child_started == false' \
    "$(echo "$result" | jq -r .lease_receipt)"
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

@test "delegate resume: tolerates malformed telemetry when a legacy archetype is unavailable" {
  local repo; repo="$(make_test_repo res-legacy-corrupt-telemetry)"
  out="$("$DELEGATE" run --archetype bulk-mechanical-edit --task initial \
    --repo "$repo" --keep --quiet)"
  rid="$(echo "$out" | jq -r .run_id)"
  rm -f "$repo/.legion/runs/$rid/archetype.txt"
  rm -f "$(registry_dir_for_repo "$repo")/$rid.json"
  rm -f "$LEGION_TELEMETRY_DIR"/*.jsonl
  printf 'not-json\n' > "$LEGION_TELEMETRY_DIR/corrupt.jsonl"

  run "$DELEGATE" resume --run "$rid" --task "follow up" --repo "$repo" --quiet

  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "ok" and .archetype == null'
  [ ! -e "$repo/.legion/runs/$rid/archetype.txt" ]
}

@test "delegate resume: skips an unreadable telemetry file before valid legacy history" {
  local repo; repo="$(make_test_repo res-legacy-unreadable-telemetry)"
  out="$("$DELEGATE" run --archetype bulk-mechanical-edit --task initial \
    --repo "$repo" --keep --quiet)"
  rid="$(echo "$out" | jq -r .run_id)"
  rm -f "$repo/.legion/runs/$rid/archetype.txt"
  rm -f "$(registry_dir_for_repo "$repo")/$rid.json"
  rm -f "$LEGION_TELEMETRY_DIR"/*.jsonl
  ln -s "$TEST_TMPDIR/missing-telemetry-target" \
    "$LEGION_TELEMETRY_DIR/000-unreadable.jsonl"
  jq -cn --arg run "$rid" \
    '{schema:"legion.span.v1", run_id:$run, archetype:"bulk-mechanical-edit"}' \
    > "$LEGION_TELEMETRY_DIR/999-valid.jsonl"

  run "$DELEGATE" resume --run "$rid" --task "follow up" --repo "$repo" --quiet

  [ "$status" -eq 0 ]
  [ "$(cat "$repo/.legion/runs/$rid/archetype.txt")" = "bulk-mechanical-edit" ]
  echo "$output" | jq -e '.status == "ok" and .archetype == "bulk-mechanical-edit"'
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

@test "delegate run: output_started suppresses the Codex fallback chain" {
  local repo; repo="$(make_test_repo codex-partial-fallback)"
  local precision; precision="$("$REPO_ROOT/legion-router/bin/legion-route" --model-ref codex_precision)"
  MOCK_CODEX_QUOTA_FAIL="$precision" MOCK_CODEX_OUTPUT_BEFORE_QUOTA=1 \
    run "$DELEGATE" run --archetype migration --task x --repo "$repo" --quiet
  [ "$status" -eq 1 ]
  echo "$output" | jq -e --arg model "$precision" '.status == "failed" and .model == $model'
  [ "$(grep -c '^codex exec ' "$MOCK_CALL_LOG")" -eq 1 ]
  jq -e '.output_started == true and .failure.retryable == false and .failure.class == "quota"' \
      "$(echo "$output" | jq -r .attempt_receipt)"
}

@test "delegate run: a zero-exit malformed Codex stream is a typed failed attempt" {
  local repo; repo="$(make_test_repo codex-malformed-stream)"
  MOCK_CODEX_MALFORMED=1 run "$DELEGATE" run \
    --model test-model-beta --task x --repo "$repo" --quiet
  [ "$status" -eq 1 ]
  echo "$output" | jq -e '.status == "error" and .codex_exit == 0'
  [ "$(grep -c '^codex exec ' "$MOCK_CALL_LOG")" -eq 1 ]
  jq -e '
    .terminal_status == "failed" and .failure.class == "malformed_event"
    and .failure.retryable == false and .output_started == false' \
    "$(echo "$output" | jq -r .attempt_receipt)"
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
    # input clamps to 0; 100 out @ $12.00/M
    [ "$output" = "0.0012" ]
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
    echo "$output" | jq -e '
      .status == "failed" and .reason == "review-failed"
      and .attempts == 1 and .verdict == null
    '
}

@test "delegate review: a malformed REJECTION fails closed and is never retried" {
    # Regression for the one-directional rule failing in the overlooked direction.
    # A request_changes carrying a CRITICAL finding, schema-invalid only because the
    # finding omits `title`, must not be retried -- retrying would let a clean
    # `approve` on attempt 2 erase the reviewer's rejection.
    local repo; repo="$(make_test_repo review-malformed-reject)"
    export MOCK_CODEX_REVIEW_MALFORMED_REJECT=1

    run "$DELEGATE" review --model test-model-beta --base HEAD --repo "$repo" --quiet

    [ "$status" -eq 1 ]
    echo "$output" | jq -e '
      .status == "failed" and .reason == "invalid-verdict"
      and .attempts == 1 and .max_attempts == 2 and .verdict == null
    '
    # exactly one codex invocation -- no second chance was taken
    [ "$(grep -Fc "codex exec -s read-only review" "$MOCK_CALL_LOG")" -eq 1 ]
}

@test "delegate review: recognized [P*] prose normalizes to a rejection, not a retry" {
    # The normalizer converts codex's recognized priority format into a proper
    # request_changes. The rejection is preserved on attempt 1 -- it is neither
    # retried nor allowed to become an approval.
    local repo; repo="$(make_test_repo review-priority-prose)"
    export MOCK_CODEX_REVIEW_PRIORITY_PROSE=1

    run "$DELEGATE" review --model test-model-beta --base HEAD --repo "$repo" --quiet

    [ "$status" -eq 0 ]
    echo "$output" | jq -e '
      .status == "ok" and .attempts == 1
      and .verdict.verdict == "request_changes"
      and (.verdict.findings | length) == 1
      and .verdict.findings[0].severity == "high"
    '
    [ "$(grep -Fc "codex exec -s read-only review" "$MOCK_CALL_LOG")" -eq 1 ]
}

@test "route --review-order: lists only executors that can review, in config order" {
    run python3 legion-router/scripts/legion-route.py --review-order
    [ "$status" -eq 0 ]
    # codex leads (native verb); hermes/pi declare review="none" and are excluded
    echo "$output" | jq -e '.[0].executor == "codex" and .[0].kind == "native"'
    echo "$output" | jq -e 'all(.[]; .kind != "none")'
    echo "$output" | jq -e 'any(.[]; .executor == "hermes") | not'
    echo "$output" | jq -e 'any(.[]; .executor == "pi") | not'
}

@test "delegate review: an archetype routing to a non-reviewer no longer aborts" {
    # Regression: this used to `die` with "invoke its executor-specific review
    # adapter", which made a whole class of archetypes unreviewable.
    local repo; repo="$(make_test_repo review-archetype-nonreviewer)"

    run "$DELEGATE" review --archetype implement-feature --base HEAD --repo "$repo" --quiet

    # It must not fail with the old routing abort.
    [[ "$output" != *"invoke its executor-specific review adapter"* ]]
}

@test "delegate review: a reviewer with no quota falls through to the next candidate" {
    local repo; repo="$(make_test_repo review-quota-fallback)"
    export MOCK_CODEX_REVIEW_QUOTA=1
    export MOCK_CURSOR_RESULT='{"verdict":"approve","summary":"No blocking findings.","findings":[]}'

    run "$DELEGATE" review --base HEAD --repo "$repo" --quiet

    # codex was tried and was unreachable, so the walk continued past it
    [ "$(grep -Fc "codex exec -s read-only review" "$MOCK_CALL_LOG")" -ge 1 ]
    [[ "$output" != *'"reason":"review-failed"'* ]] || \
      { echo "review failed outright instead of falling through"; false; }
    echo "$output" | jq -e '.status == "ok"
      and .usage == null and .usage_status == "partial"
      and (.known_usage | type) == "object" and .known_usage_attempts == 1
      and .cost_usd == null and .cost_status == "partial"
      and .known_cost_usd == 0.03 and .known_cost_attempts == 1
      and (.preflight_receipt | contains("/prompt-review-"))
      and (.attempt_receipt | contains("/prompt-review-"))'
    jq -e '.schema == "legion.preflight.v1" and .executor == "cursor"' \
      "$(echo "$output" | jq -r .preflight_receipt)"
    jq -e '.compatibility.sandbox.requested == "read-only"
      and .compatibility.sandbox.provider_sandbox == "read-only"' \
      "$(echo "$output" | jq -r .preflight_receipt)"
    jq -e '.schema == "legion.attempt.v1" and .executor == "cursor"
      and .terminal_status == "succeeded"' "$(echo "$output" | jq -r .attempt_receipt)"
    local art; art="$(dirname "$(echo "$output" | jq -r .terminal_receipt)")"
    jq -e '.executor == "cursor"' "$art/attempt.json"
    [ ! -e "$art/failure.json" ]
    jq -e '.executor == "codex-review" and .terminal_status == "failed"
      and .failure.class == "unavailable"' "$art/attempt-1.json"
    jq -e '.schema == "legion.failure.v1" and .class == "unavailable"' \
      "$art/failure-1.json"
    local review_span provider_span
    provider_span="$(cat "$LEGION_TELEMETRY_DIR"/*.jsonl | jq -c \
      'select(.artifacts.provider_attempt == true and .executor == "codex-review")')"
    jq -e --argjson attempt "$(cat "$art/attempt-1.json")" '
      .tokens == $attempt.usage and .usage_status == $attempt.usage_status
      and .cost_usd == $attempt.cost_usd and .cost_status == $attempt.cost_status
      and (.artifacts.attempt_receipt | endswith("/attempt-1.json"))
    ' <<<"$provider_span"
    [ "$(cat "$LEGION_TELEMETRY_DIR"/*.jsonl | jq -s \
      '[.[] | select(.artifacts.provider_attempt == true and .executor == "codex-review")] | length')" -eq 1 ]
    review_span="$(cat "$LEGION_TELEMETRY_DIR"/*.jsonl | jq -c 'select(.executor == "cursor-review")')"
    jq -e --arg model "$CURSOR_DEFAULT" '
      .model == $model
      and .cost_usd == null and .cost_status == "not_applicable"
      and .tokens == null and .usage_status == "not_applicable"
      and .artifacts.rollup_only == true
      and .artifacts.metering_reconciliation.attempt_count == 2
      and .artifacts.metering_reconciliation.cost_status == "partial"
      and .artifacts.metering_reconciliation.known_cost_usd == 0.03
    ' <<<"$review_span"
    [ "$(cat "$LEGION_TELEMETRY_DIR"/*.jsonl | jq -s '[.[] | .cost_usd // 0] | add')" = "0.03" ]
}

@test "delegate review: Claude prompt reviewer is read-only and cannot own fallback" {
    local repo; repo="$(make_test_repo review-claude-no-fallback)"
    export MOCK_CLAUDE_LIMIT=1
    export LEGION_CLAUDE_FALLBACK_MODELS=model-b

    CODEX_BIN=missing-codex-for-review CURSOR_AGENT_BIN=missing-cursor-for-review \
      OPENCODE_BIN=missing-opencode-for-review \
      run "$DELEGATE" review --base HEAD --repo "$repo" --quiet

    [ "$status" -ne 0 ]
    assert_mock_called claude "--permission-mode plan"
    [ "$(grep -Ec '^claude -p ' "$MOCK_CALL_LOG")" -eq 1 ]
    ! grep -q -- '--model model-b' "$MOCK_CALL_LOG"
    assert_mock_not_called legion-delegate
    local art claude_preflight
    art="$(dirname "$(echo "$output" | jq -r .terminal_receipt)")"
    claude_preflight="$(find "$art" -path '*/prompt-review-*/preflight.json' -type f \
      -exec sh -c 'jq -e '\''.executor == "claude"'\'' "$1" >/dev/null' _ {} \; -print -quit)"
    jq -e '.executor == "claude"
      and .compatibility.sandbox.requested == "read-only"' "$claude_preflight"
}

@test "delegate review: malformed prompt retry reconciles every paid attempt without collisions" {
    local repo; repo="$(make_test_repo review-prompt-malformed-retry)"
    export MOCK_CURSOR_RESULT_SEQUENCE_FILE="$TEST_TMPDIR/cursor-review-results"
    printf '%s\n%s\n' \
      'this is malformed but carries no rejection' \
      '{"verdict":"approve","summary":"No blocking findings.","findings":[]}' \
      > "$MOCK_CURSOR_RESULT_SEQUENCE_FILE"

    CODEX_BIN=missing-codex-for-review run "$DELEGATE" review \
      --archetype security-review --base HEAD --repo "$repo" --quiet

    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.status == "ok"'
    local art; art="$(dirname "$(echo "$output" | jq -r .terminal_receipt)")"
    jq -e '.executor == "cursor" and .terminal_status == "succeeded"' \
      "$art/prompt-review-2-1/attempt.json"
    jq -e '.executor == "cursor" and .terminal_status == "succeeded"' \
      "$art/prompt-review-2-2/attempt.json"
    [ "$(jq -sr 'map(.attempt_id) | unique | length' \
      "$art/prompt-review-2-1/attempt.json" "$art/prompt-review-2-2/attempt.json")" -eq 2 ]
    local review_span
    review_span="$(cat "$LEGION_TELEMETRY_DIR"/*.jsonl | jq -c 'select(.executor == "cursor-review")')"
    jq -e '
      .cost_usd == null and .cost_status == "not_applicable"
      and .artifacts.rollup_only == true
      and .artifacts.metering_reconciliation.attempt_count == 2
      and .artifacts.metering_reconciliation.cost_status == "known"
      and .artifacts.metering_reconciliation.cost_usd == 0.06
      and .artifacts.metering_reconciliation.known_cost_attempts == 2
    ' <<<"$review_span"
    [ "$(cat "$LEGION_TELEMETRY_DIR"/*.jsonl | jq -s \
      '[.[] | select(.executor == "cursor" and .cost_status == "known"
        and .archetype == "security-review"
        and (.artifacts.attempt_receipt | contains("/prompt-review-"))
        and (.artifacts.attempt_receipt | endswith("/attempt.json"))
        and (.artifacts.preflight_receipt | endswith("/preflight.json"))
        and (.artifacts.lease_receipt | endswith("/lease.json")))] | length')" -eq 2 ]
    while IFS= read -r evidence; do
      [ -f "$evidence" ]
      [[ "$evidence" != *'/.legion/worktrees/'* ]]
    done < <(cat "$LEGION_TELEMETRY_DIR"/*.jsonl | jq -r '
      select(.executor == "cursor" and .artifacts.provider_attempt == true)
      | [.artifacts.attempt_receipt, .artifacts.preflight_receipt,
         .artifacts.lease_receipt, .artifacts.failure_receipt]
      | .[] | select(. != null)')
    [ "$(cat "$LEGION_TELEMETRY_DIR"/*.jsonl | jq -s '[.[] | .cost_usd // 0] | add')" = "0.06" ]
}

@test "delegate review: unavailable native admission falls through before provider launch" {
    local repo; repo="$(make_test_repo review-admission-unavailable)"
    export MOCK_CURSOR_RESULT='{"verdict":"approve","summary":"No blocking findings.","findings":[]}'

    CODEX_BIN=missing-codex-for-review run "$DELEGATE" review --base HEAD \
      --repo "$repo" --quiet

    [ -n "$output" ]
    echo "$output" | jq -e '.status == "ok"
      and (.preflight_receipt | contains("/prompt-review-"))
      and (.attempt_receipt | contains("/prompt-review-"))'
    jq -e '.schema == "legion.preflight.v1" and .executor == "cursor"' \
      "$(echo "$output" | jq -r .preflight_receipt)"
    local art; art="$(dirname "$(echo "$output" | jq -r .terminal_receipt)")"
    jq -e '.schema == "legion.preflight.v1" and .status == "unavailable"' \
      "$art/codex-preflight.json"
    [ "$(grep -Ec '^codex exec ' "$MOCK_CALL_LOG" || true)" -eq 0 ]
    assert_mock_called agent "-p --output-format json"
}

@test "delegate review: a launched prompt reviewer without a durable lease fails closed" {
    local repo art
    repo="$(make_test_repo review-missing-prompt-lease)"
    export MOCK_CURSOR_RESULT='{"verdict":"approve","summary":"No blocking findings.","findings":[]}'
    install_missing_lease_supervisor_shim

    CODEX_BIN=missing-codex-for-review run "$DELEGATE" review --base HEAD \
      --repo "$repo" --quiet

    [ "$status" -eq 70 ]
    echo "$output" | jq -e '.status == "containment_failed"
      and (.reason | contains("without a valid durable attempt/lease receipt"))'
    art="$(dirname "$(echo "$output" | jq -r .terminal_receipt)")"
    [ -f "$art/prompt-review-2-1/attempt.json" ]
    [ ! -f "$art/prompt-review-2-1/lease.json" ]
    [ -d "$(echo "$output" | jq -r .worktree)" ]
}

@test "delegate review: prompt launch_failed bundle is authenticated no-spend rather than containment failure" {
    local repo art lease
    repo="$(make_test_repo review-prompt-launch-failed)"
    export LEGION_TEST_LAUNCH_FAIL_EXECUTABLE=agent
    install_launch_failed_supervisor_shim

    MOCK_CODEX_REVIEW_QUOTA=1 OPENCODE_BIN=missing-opencode-for-review \
      CLAUDE_BIN=missing-claude-for-review run "$DELEGATE" review --base HEAD \
        --repo "$repo" --quiet

    [ "$status" -ne 70 ]
    echo "$output" | tail -n 1 | jq -e '.status != "containment_failed"'
    art="$(dirname "$(echo "$output" | tail -n 1 | jq -r .terminal_receipt)")"
    lease="$(find "$art" -path '*/prompt-review-*/lease.json' -type f \
      -exec sh -c 'jq -e '\''.status == "launch_failed"'\'' "$1" >/dev/null' _ {} \; -print -quit)"
    [ -n "$lease" ]
    jq -e '.schema == "legion.child-execution-lease.v1" and .status == "launch_failed"' "$lease"
    [ ! -f "$(dirname "$lease")/attempt.json" ]
    [ ! -f "$(dirname "$lease")/failure.json" ]
    [ ! -e "$art/attempt.json" ]
    [ ! -e "$art/failure.json" ]
    jq -e '.executor == "codex-review" and .failure.class == "unavailable"' \
      "$art/attempt-1.json"
    [ "$(cat "$LEGION_TELEMETRY_DIR"/*.jsonl | jq -s \
      '[.[] | select(.artifacts.provider_attempt == true and .executor == "cursor")] | length')" -eq 0 ]
    # A launch failure is candidate-local: the outer walk must advance rather
    # than terminalizing immediately as if the admitted adapter had run.
    [ "$(find "$art" -maxdepth 1 -type d -name 'prompt-review-*' | wc -l | tr -d ' ')" -ge 2 ]
}

@test "delegate review: prompt prelaunch cleanup failure remains containment failure" {
    local repo result
    repo="$(make_test_repo review-prompt-prelaunch-cleanup)"
    install_prelaunch_cleanup_failed_supervisor_shim

    CODEX_BIN=missing-codex-for-review run "$DELEGATE" review --base HEAD \
      --repo "$repo" --quiet

    [ "$status" -eq 70 ]
    result="$(printf '%s\n' "$output" | tail -n 1)"
    echo "$result" | jq -e '.status == "containment_failed"
      and (.reason | contains("without a valid durable attempt/lease receipt"))'
    [ -d "$(echo "$result" | jq -r .worktree)" ]
}

@test "delegate review: interrupted prompt evidence missing an attempt is containment-invalid" {
    local helper="$TEST_TMPDIR/interrupted-prompt-bundle.sh"
    local source="$TEST_TMPDIR/interrupted-prompt-source"
    local receipt="$TEST_TMPDIR/interrupted-prompt-receipt"
    local shared="$TEST_TMPDIR/interrupted-prompt-shared"
    mkdir -p "$source" "$receipt" "$shared"
    printf '%s\n' '{"schema":"legion.preflight.v1","executor":"cursor","status":"supported"}' > "$source/preflight.json"
    printf '%s\n' '{"schema":"legion.child-execution-lease.v1","status":"cancelled"}' > "$source/lease.json"
    {
      sed -n '/^prompt_review_preflight_no_spend_status()/,/^}/p' "$DELEGATE"
      sed -n '/^preserve_interrupted_prompt_receipts()/,/^}/p' "$DELEGATE"
      cat <<'SH'
preserve_prompt_review_receipt() {
  [[ -f "$1" ]] || return 1
  cp "$1" "$3"
  printf '%s\n' "$3"
}
review_track_attempt_receipt() { :; }
PROMPT_ATTEMPT_ART="$1"
PROMPT_ATTEMPT_ORDINAL=1
PROMPT_RECEIPT_DIR="$2"
PROMPT_SHARED_ART="$3"
PROMPT_LEASE_STATUS="$1/lease.json"
PROMPT_EXPECTED_EXECUTOR=cursor
PROMPT_EXPECTED_PROVIDER=cursor
PROMPT_EXPECTED_MODEL=fixture-model
PROMPT_EXPECTED_SANDBOX=read-only
PROMPT_RUN_ID=prompt-run
REVIEW_WT_PATH=worktree
rc=0
preserve_interrupted_prompt_receipts || rc=$?
exit "$rc"
SH
    } > "$helper"

    run bash "$helper" "$source" "$receipt" "$shared"

    [ "$status" -eq 1 ]
    [ ! -e "$shared/attempt.json" ]
}

@test "delegate review: interrupted prompt prelaunch cleanup cannot be downgraded to launch failure" {
    local helper="$TEST_TMPDIR/interrupted-prompt-cleanup-bundle.sh"
    local source="$TEST_TMPDIR/interrupted-prompt-cleanup-source"
    local receipt="$TEST_TMPDIR/interrupted-prompt-cleanup-receipt"
    local shared="$TEST_TMPDIR/interrupted-prompt-cleanup-shared"
    mkdir -p "$source" "$receipt" "$shared"
    printf '%s\n' '{"schema":"legion.preflight.v1","executor":"cursor","status":"supported"}' > "$source/preflight.json"
    printf '%s\n' '{"schema":"legion.child-execution-lease.v1","status":"cleanup_failed","reason":"prelaunch containment","max_runtime_seconds":30,"child_started":false}' > "$source/lease.json"
    {
      printf 'source %q\n' "$LIB/adapter-contract.sh"
      sed -n '/^prompt_review_launch_failed_no_spend()/,/^}/p' "$DELEGATE"
      sed -n '/^preserve_interrupted_prompt_receipts()/,/^}/p' "$DELEGATE"
      cat <<'SH'
preserve_prompt_review_receipt() {
  [[ -f "$1" ]] || return 1
  cp "$1" "$3"
  printf '%s\n' "$3"
}
review_track_attempt_receipt() { :; }
PROMPT_ATTEMPT_ART="$1"
PROMPT_ATTEMPT_ORDINAL=1
PROMPT_RECEIPT_DIR="$2"
PROMPT_SHARED_ART="$3"
PROMPT_LEASE_STATUS="$1/lease.json"
PROMPT_EXPECTED_EXECUTOR=cursor
PROMPT_EXPECTED_PROVIDER=cursor
PROMPT_EXPECTED_MODEL=fixture-model
PROMPT_EXPECTED_SANDBOX=read-only
PROMPT_RUN_ID=prompt-run
REVIEW_WT_PATH=worktree
rc=0
preserve_interrupted_prompt_receipts || rc=$?
exit "$rc"
SH
    } > "$helper"

    run bash "$helper" "$source" "$receipt" "$shared"

    [ "$status" -eq 1 ]
    jq -e '.status == "cleanup_failed" and .child_started == false' "$receipt/lease.json"
    [ ! -e "$shared/attempt.json" ]
}

@test "delegate review: incompatible native admission stops reviewer selection" {
    local repo; repo="$(make_test_repo review-admission-incompatible)"

    run "$DELEGATE" review --model test-model-beta --reasoning-effort ultra \
      --base HEAD --repo "$repo" --quiet

    [ "$status" -eq 1 ]
    echo "$output" | jq -e '.status == "refused" and .attempts == 0
      and (.reason | contains("unsupported effort"))
      and .attempt_receipt == null and .failure_receipt == null
      and .usage == null and .usage_status == "unknown"
      and .cost_usd == null and .cost_status == "unknown"
      and (has("known_usage") | not) and (has("known_usage_attempts") | not)
      and (has("known_cost_usd") | not) and (has("known_cost_attempts") | not)'
    jq -e '.schema == "legion.preflight.v1" and .status == "incompatible"' \
      "$(echo "$output" | jq -r .preflight_receipt)"
    assert_mock_not_called codex
    assert_mock_not_called agent
}

@test "delegate review: authenticated prompt incompatibility is a zero-attempt refusal" {
    local repo preflight
    repo="$(make_test_repo review-prompt-admission-incompatible)"
    install_authenticated_incompatible_preflight_shim cursor "$CURSOR_DEFAULT"

    CODEX_BIN=missing-codex-for-review run "$DELEGATE" review --base HEAD \
      --repo "$repo" --quiet

    [ "$status" -eq 1 ]
    echo "$output" | jq -e '.status == "refused" and .attempts == 0
      and .reason == "authenticated model incompatibility"
      and .attempt_receipt == null and .failure_receipt == null
      and (.preflight_receipt | contains("/prompt-review-"))'
    preflight="$(echo "$output" | jq -r .preflight_receipt)"
    jq -e '.schema == "legion.preflight.v1" and .executor == "cursor"
      and .status == "incompatible" and .identity == null
      and .compatibility.model.status == "incompatible"' "$preflight"
    assert_mock_not_called agent
    assert_mock_not_called opencode
    assert_mock_not_called claude
}

@test "delegate review: authenticated untested prompt preflight is a zero-attempt refusal" {
    local repo preflight art
    repo="$(make_test_repo review-prompt-admission-untested)"
    install_authenticated_untested_preflight_shim cursor "$CURSOR_DEFAULT"

    MOCK_CODEX_REVIEW_QUOTA=1 run "$DELEGATE" review --base HEAD \
      --repo "$repo" --quiet

    [ "$status" -eq 1 ]
    echo "$output" | jq -e '.status == "refused" and .attempts == 0
      and .reason == "authenticated executable version is untested"
      and .attempt_receipt == null and .failure_receipt == null'
    preflight="$(echo "$output" | jq -r .preflight_receipt)"
    jq -e '.schema == "legion.preflight.v1" and .executor == "cursor"
      and .status == "untested" and (.identity | type) == "object"
      and .compatibility.version.status == "untested"' "$preflight"
    art="$(dirname "$(echo "$output" | jq -r .terminal_receipt)")"
    [ ! -e "$art/attempt.json" ]
    [ ! -e "$art/failure.json" ]
    jq -e '.executor == "codex-review" and .failure.class == "unavailable"' \
      "$art/attempt-1.json"
    local run_id
    run_id="$(echo "$output" | jq -r .run_id)"
    jq -s -e --arg run "$run_id" '
      any(.[]; .run_id == $run and .artifacts.rollup_only == true
        and .artifacts.metering_reconciliation.attempt_count == 1)
    ' "$LEGION_TELEMETRY_DIR"/*.jsonl
    assert_mock_not_called agent
    assert_mock_not_called opencode
    assert_mock_not_called claude
}

@test "delegate review: substantive route refusal stops reviewer selection" {
    local repo; repo="$(make_test_repo review-route-refusal)"

    LEGION_ACTIVE=1 LEGION_EXECUTOR=1 LEGION_DEPTH=1 \
      LEGION_EXECUTOR_NAME=claude LEGION_RUN_ID=parent-review \
      run "$DELEGATE" review --base HEAD --repo "$repo" --quiet

    [ "$status" -eq 1 ]
    echo "$output" | jq -e '.status == "refused"
      and .reason == "nested-delegation-requires-explicit-executor"
      and .attempts == 0'
    [ "$(grep -Ec '^(codex exec|agent -p) ' "$MOCK_CALL_LOG" || true)" -eq 0 ]
}

@test "delegate review: a real rejection is never retried on another executor" {
    # The safety invariant behind the fallback: only an UNREACHABLE reviewer
    # yields to the next candidate. A reviewer that ran and rejected ends the
    # walk, or a later approval could erase its findings.
    local repo; repo="$(make_test_repo review-reject-no-fallthrough)"
    export MOCK_CODEX_REVIEW_FINDINGS=1

    run "$DELEGATE" review --base HEAD --repo "$repo" --quiet

    echo "$output" | jq -e '.status == "ok"'
    echo "$output" | jq -e '.verdict.verdict == "request_changes"'
    # exactly one reviewer ran
    [ "$(grep -Fc "codex exec -s read-only review" "$MOCK_CALL_LOG")" -eq 1 ]
}

@test "delegate: seeds gitignored dependency dirs into the delegated worktree" {
    local repo; repo="$(make_test_repo seed-deps)"
    mkdir -p "$repo/node_modules/left-pad"
    echo "module.exports=1" > "$repo/node_modules/left-pad/index.js"
    printf 'node_modules/\n' > "$repo/.gitignore"
    git -C "$repo" add .gitignore && git -C "$repo" commit -qm "ignore node_modules"

    run "$DELEGATE" run --model test-model-beta --task "touch seeded.txt" --repo "$repo" --keep --quiet
    [ "$status" -eq 0 ]

    local wt; wt="$(echo "$output" | jq -r '.worktree')"
    [ -f "$wt/node_modules/left-pad/index.js" ]
}

@test "delegate: never seeds a git-tracked directory" {
    # A tracked dir already came with the worktree at the base commit; copying
    # the main repo's version over it would silently diverge the delegate's tree.
    local repo; repo="$(make_test_repo seed-tracked)"
    mkdir -p "$repo/node_modules/pkg"
    echo "committed" > "$repo/node_modules/pkg/marker.txt"
    git -C "$repo" add node_modules && git -C "$repo" commit -qm "track node_modules"
    echo "local-only-change" > "$repo/node_modules/pkg/marker.txt"

    run "$DELEGATE" run --model test-model-beta --task "noop" --repo "$repo" --keep --quiet
    [ "$status" -eq 0 ]

    local wt; wt="$(echo "$output" | jq -r '.worktree')"
    [ "$(cat "$wt/node_modules/pkg/marker.txt")" = "committed" ]
}

@test "delegate: LEGION_SEED_DEPS=0 disables seeding" {
    local repo; repo="$(make_test_repo seed-off)"
    mkdir -p "$repo/node_modules/pkg"
    echo x > "$repo/node_modules/pkg/i.js"
    printf 'node_modules/\n' > "$repo/.gitignore"
    git -C "$repo" add .gitignore && git -C "$repo" commit -qm "ignore"

    LEGION_SEED_DEPS=0 run "$DELEGATE" run --model test-model-beta --task "noop" --repo "$repo" --keep --quiet
    [ "$status" -eq 0 ]

    local wt; wt="$(echo "$output" | jq -r '.worktree')"
    [ ! -e "$wt/node_modules" ]
}

@test "delegate: never seeds a virtualenv by default (they are not relocatable)" {
    # A venv bakes its own absolute path into console-script shebangs and
    # bin/activate, so a clone at a different path points back at the original
    # -- the delegate would run against the operator's environment.
    local repo; repo="$(make_test_repo seed-no-venv)"
    mkdir -p "$repo/.venv/bin"
    printf '#!/%s/.venv/bin/python\n' "$repo" > "$repo/.venv/bin/pytest"
    printf '.venv/\nnode_modules/\n' > "$repo/.gitignore"
    git -C "$repo" add .gitignore && git -C "$repo" commit -qm ignore

    run "$DELEGATE" run --model test-model-beta --task "noop" --repo "$repo" --keep --quiet
    [ "$status" -eq 0 ]

    local wt; wt="$(echo "$output" | jq -r '.worktree')"
    [ ! -e "$wt/.venv" ]
}

@test "delegate: a task larger than ARG_MAX reaches the adapter" {
    # Regression for E2BIG at the adapter boundary: delegate.sh accepted a big
    # task on stdin, then re-serialised it onto argv when dispatching, so the
    # limit was reimposed at the boundary rather than at the door.
    local repo; repo="$(make_test_repo big-task)"
    local big; big="$BATS_TEST_TMPDIR/big.txt"
    python3 -c "print('x'*400000)" > "$big"

    run "$DELEGATE" run --executor opencode --model test-model-beta \
        --task-file "$big" --repo "$repo" --quiet

    # The failure this pins is "Argument list too long" — any other outcome
    # means the payload made it across the boundary.
    [[ "$output" != *"Argument list too long"* ]]
    [[ "$output" != *"E2BIG"* ]]
}

@test "delegate: --task-file overrides an earlier --task (last flag wins)" {
    local repo; repo="$(make_test_repo task-file-precedence)"
    local f; f="$BATS_TEST_TMPDIR/t.txt"; printf 'from-file' > "$f"

    run "$DELEGATE" run --executor opencode --model test-model-beta \
        --task "from-argv" --task-file "$f" --repo "$repo" --keep --quiet
    [ "$status" -eq 0 ]

    # The staged payload is the run's own evidence of what the adapter was asked.
    local run_id staged
    run_id="$(echo "$output" | jq -r '.run_id')"
    staged="$repo/.legion/tasks/$run_id.txt"
    [ -f "$staged" ]
    [ "$(cat "$staged")" = "from-file" ]
}

@test "delegate: --task-file rejects an unreadable path" {
    local repo; repo="$(make_test_repo task-file-missing)"
    run "$DELEGATE" run --model test-model-beta --task-file /nonexistent/nope.txt --repo "$repo" --quiet
    [ "$status" -ne 0 ]
    [[ "$output" == *"--task-file not readable"* ]]
}

@test "delegate: a native codex run records what it was asked" {
    # The native path pipes the task to codex on stdin and used to keep no copy,
    # so the span recorded an outcome whose instruction could not be retrieved.
    local repo; repo="$(make_test_repo task-evidence)"

    run "$DELEGATE" run --model test-model-beta --task "make the thing" --repo "$repo" --quiet
    [ "$status" -eq 0 ]

    local run_id; run_id="$(echo "$output" | jq -r '.run_id')"
    [ -f "$repo/.legion/tasks/$run_id.txt" ]
    [ "$(cat "$repo/.legion/tasks/$run_id.txt")" = "make the thing" ]
}

@test "delegate: the recorded digest matches the recorded bytes" {
    # The hash is what makes the evidence verifiable rather than merely present.
    local repo; repo="$(make_test_repo task-digest)"

    run "$DELEGATE" run --model test-model-beta --task "hash me" --repo "$repo" --quiet
    [ "$status" -eq 0 ]

    local run_id staged expected actual
    run_id="$(echo "$output" | jq -r '.run_id')"
    staged="$repo/.legion/tasks/$run_id.txt"
    expected="$(shasum -a 256 "$staged" | cut -d' ' -f1)"
    actual="$(jq -r '.artifacts.task_sha256 // empty' "$LEGION_TELEMETRY_DIR"/*.jsonl 2>/dev/null | tail -1)"
    [ -n "$actual" ]
    [ "$actual" = "$expected" ]
}

@test "delegate: evidence recording never fails the run" {
    # Evidence is best-effort by contract: an unwritable tasks dir must not turn
    # a successful delegation into a failure.
    local repo; repo="$(make_test_repo evidence-readonly)"
    mkdir -p "$repo/.legion"
    : > "$repo/.legion/tasks"   # a FILE where the directory should be

    run "$DELEGATE" run --model test-model-beta --task "still works" --repo "$repo" --quiet
    [ "$status" -eq 0 ]
}

@test "delegate review: a failing prompt reviewer does not kill the walk" {
    # Regression: review_invoke_prompt called a bare `set -e` and then returned
    # the reviewer's exit code. Shell options are GLOBAL, so it undid the
    # caller's `set +e` and a reviewer that merely failed took the whole script
    # down mid-walk — exit 1, no next candidate, no terminal receipt, empty
    # stdout. The walk must terminalize whatever the outcome.
    local repo; repo="$(make_test_repo review-walk-survives)"
    export MOCK_CODEX_REVIEW_QUOTA=1

    run "$DELEGATE" review --base HEAD --repo "$repo" --quiet

    [ -n "$output" ]
    echo "$output" | jq -e '.run_id and .status' >/dev/null
}

@test "delegate review: an adapter reporting auth_error counts as unavailable" {
    # Detection used to match prose only. When legion-cursor was given a
    # friendlier message the pattern stopped matching, so the fallback died at
    # exactly the executor it most needed to skip. Structured detection reads
    # the adapter's own auth_error field instead of guessing at wording.
    local helper err out
    helper="$BATS_TEST_TMPDIR/probe.sh"
    err="$BATS_TEST_TMPDIR/e.err"
    out="$BATS_TEST_TMPDIR/o.json"

    : > "$err"
    printf '{"status":"failed","auth_error":"CURSOR_API_KEY is unset"}\n' > "$out"

    {
      sed -n '/^review_executor_unavailable()/,/^}/p' \
        "$REPO_ROOT/legion-router/scripts/delegate.sh"
      printf 'review_executor_unavailable 1 "$1" "$2"\n'
    } > "$helper"

    run bash "$helper" "$err" "$out"
    [ "$status" -eq 0 ]
}

@test "delegate review: shared admission receipt distinguishes unavailable from incompatible" {
    local helper err out unavailable_receipt incompatible_receipt
    helper="$BATS_TEST_TMPDIR/probe-admission.sh"
    err="$BATS_TEST_TMPDIR/admission.err"
    out="$BATS_TEST_TMPDIR/admission.json"
    unavailable_receipt="$BATS_TEST_TMPDIR/unavailable-preflight.json"
    incompatible_receipt="$BATS_TEST_TMPDIR/incompatible-preflight.json"
    : > "$err"
    printf '{"schema":"legion.preflight.v1","status":"unavailable"}\n' > "$unavailable_receipt"
    printf '{"schema":"legion.preflight.v1","status":"incompatible"}\n' > "$incompatible_receipt"
    {
      sed -n '/^review_executor_unavailable()/,/^}/p' \
        "$REPO_ROOT/legion-router/scripts/delegate.sh"
      printf 'review_executor_unavailable 1 "$1" "$2"\n'
    } > "$helper"

    jq -cn --arg receipt "$unavailable_receipt" \
      '{status:"refused",reason:"binary missing",preflight_receipt:$receipt}' > "$out"
    run bash "$helper" "$err" "$out"
    [ "$status" -eq 0 ]

    jq -cn --arg receipt "$incompatible_receipt" \
      '{status:"refused",reason:"policy refused",preflight_receipt:$receipt}' > "$out"
    run bash "$helper" "$err" "$out"
    [ "$status" -ne 0 ]
}

@test "delegate review: a clean adapter result is not treated as unavailable" {
    local helper err out
    helper="$BATS_TEST_TMPDIR/probe-clean.sh"
    err="$BATS_TEST_TMPDIR/clean.err"
    out="$BATS_TEST_TMPDIR/clean.json"

    : > "$err"
    printf '{"status":"ok","result":"looks fine"}\n' > "$out"

    {
      sed -n '/^review_executor_unavailable()/,/^}/p' \
        "$REPO_ROOT/legion-router/scripts/delegate.sh"
      printf 'review_executor_unavailable 1 "$1" "$2"\n'
    } > "$helper"

    run bash "$helper" "$err" "$out"
    [ "$status" -ne 0 ]
}

@test "delegate review: a finding that mentions an API key is not read as unavailable" {
    # A reviewer writing "API key is required in config.py" as a genuine finding
    # must not be classified as unavailable — the walk would move on and a later
    # candidate's approval could erase that rejection.
    local helper err out
    helper="$BATS_TEST_TMPDIR/probe-finding.sh"
    err="$BATS_TEST_TMPDIR/finding.err"
    out="$BATS_TEST_TMPDIR/finding.json"

    : > "$err"
    printf '{"status":"failed","result":"[P1] API key is required in config.py but never set"}\n' > "$out"

    {
      sed -n '/^review_executor_unavailable()/,/^}/p' \
        "$REPO_ROOT/legion-router/scripts/delegate.sh"
      printf 'review_executor_unavailable 1 "$1" "$2"\n'
    } > "$helper"

    run bash "$helper" "$err" "$out"
    [ "$status" -ne 0 ]
}

@test "delegate review: a provider auth failure on stderr still counts as unavailable" {
    local helper err out
    helper="$BATS_TEST_TMPDIR/probe-stderr.sh"
    err="$BATS_TEST_TMPDIR/provider.err"
    out="$BATS_TEST_TMPDIR/provider.json"

    printf 'Error: Authentication required. Please run login first.\n' > "$err"
    printf '{"status":"failed"}\n' > "$out"

    {
      sed -n '/^review_executor_unavailable()/,/^}/p' \
        "$REPO_ROOT/legion-router/scripts/delegate.sh"
      printf 'review_executor_unavailable 1 "$1" "$2"\n'
    } > "$helper"

    run bash "$helper" "$err" "$out"
    [ "$status" -eq 0 ]
}

@test "delegate review: a native codex quota error on stdout still triggers fallback" {
    # The bug that started this: codex reports a spent quota inside its stdout
    # JSON event stream, not on stderr and not as auth_error. Confining prose
    # matching to stderr regressed exactly this case.
    local helper err out
    helper="$BATS_TEST_TMPDIR/probe-quota.sh"
    err="$BATS_TEST_TMPDIR/quota.err"
    out="$BATS_TEST_TMPDIR/quota.jsonl"

    : > "$err"
    {
      printf '{"type":"item.completed","item":{"id":"item_1"}}\n'
      printf '{"type":"error","message":"You'"'"'ve hit your usage limit. Try again later."}\n'
    } > "$out"

    {
      sed -n '/^review_executor_unavailable()/,/^}/p' \
        "$REPO_ROOT/legion-router/scripts/delegate.sh"
      printf 'review_executor_unavailable 1 "$1" "$2"\n'
    } > "$helper"

    run bash "$helper" "$err" "$out"
    [ "$status" -eq 0 ]
}

@test "delegate review: a prompt adapter's own failure field triggers fallback" {
    # Each adapter reports provider unavailability differently — opencode sets
    # opencode_error, claude sets reason=claude_limit — and their provider
    # stderr never reaches attempt_err, so the envelope is the only signal.
    local helper
    helper="$BATS_TEST_TMPDIR/probe-envelope.sh"
    {
      sed -n '/^review_executor_unavailable()/,/^}/p' \
        "$REPO_ROOT/legion-router/scripts/delegate.sh"
      printf 'review_executor_unavailable 1 /dev/null "$1"\n'
    } > "$helper"

    printf '{"status":"failed","opencode_error":"provider rate limited"}\n' \
      > "$BATS_TEST_TMPDIR/oc.json"
    run bash "$helper" "$BATS_TEST_TMPDIR/oc.json"
    [ "$status" -eq 0 ]

    printf '{"status":"blocked","reason":"claude_limit"}\n' > "$BATS_TEST_TMPDIR/cl.json"
    run bash "$helper" "$BATS_TEST_TMPDIR/cl.json"
    [ "$status" -eq 0 ]

    # and still not a finding that merely mentions limits
    printf '{"status":"failed","result":"[P2] the rate limit handling is wrong"}\n' \
      > "$BATS_TEST_TMPDIR/fd.json"
    run bash "$helper" "$BATS_TEST_TMPDIR/fd.json"
    [ "$status" -ne 0 ]
}

@test "delegate review: a substantive opencode failure is not an outage" {
    # opencode_error carries ANY error, including one raised after a good
    # request_changes — and the adapter appends it to .result, which stops the
    # normalizer parsing that rejection. Treating presence as an outage would
    # skip to a candidate whose approval erases the finding.
    local helper
    helper="$BATS_TEST_TMPDIR/probe-oc.sh"
    {
      sed -n '/^review_executor_unavailable()/,/^}/p' \
        "$REPO_ROOT/legion-router/scripts/delegate.sh"
      printf 'review_executor_unavailable 1 /dev/null "$1"\n'
    } > "$helper"

    printf '{"status":"failed","opencode_error":"tool crashed while writing","result":"[P1] real finding"}\n' \
      > "$BATS_TEST_TMPDIR/subst.json"
    run bash "$helper" "$BATS_TEST_TMPDIR/subst.json"
    [ "$status" -ne 0 ]

    printf '{"status":"failed","opencode_error":"provider rate limited"}\n' \
      > "$BATS_TEST_TMPDIR/avail.json"
    run bash "$helper" "$BATS_TEST_TMPDIR/avail.json"
    [ "$status" -eq 0 ]
}

@test "delegate review: one vocabulary covers every unavailability detector" {
    # The term list lived in three copies that drifted apart three times, each
    # drift silently disabling the fallback for one executor: cursor's
    # friendlier auth message, codex's stdout quota event, then codex's stdout
    # AUTH event, which the quota-only copy did not match. All four detectors
    # now read one list.
    local helper
    helper="$BATS_TEST_TMPDIR/probe-vocab.sh"
    {
      sed -n '/^review_executor_unavailable()/,/^}/p' \
        "$REPO_ROOT/legion-router/scripts/delegate.sh"
      printf 'review_executor_unavailable 1 "$1" "$2"\n'
    } > "$helper"
    : > "$BATS_TEST_TMPDIR/empty.err"

    # native codex auth failure: stdout event, stderr silent
    printf '{"type":"error","message":"Authentication required. Please run codex login."}\n' \
      > "$BATS_TEST_TMPDIR/auth.json"
    run bash "$helper" "$BATS_TEST_TMPDIR/empty.err" "$BATS_TEST_TMPDIR/auth.json"
    [ "$status" -eq 0 ]

    # a reviewer FINDING that says the same words is not an outage: .result is
    # never scanned, so a rejection cannot be rewritten into an approval.
    printf '{"status":"ok","result":"config.py fails because the api_key is required"}\n' \
      > "$BATS_TEST_TMPDIR/finding.json"
    run bash "$helper" "$BATS_TEST_TMPDIR/empty.err" "$BATS_TEST_TMPDIR/finding.json"
    [ "$status" -ne 0 ]
}

@test "delegate run: an executor that commits its work is not lost" {
    # The end-to-end version of the case below, through the real code path.
    #
    # The first attempt at this fix compared against "$base", and the unit test
    # passed because it used a concrete sha. The real path never does: --base
    # defaults to the NAME "HEAD", so an executor that commits moves HEAD and
    # the comparison measured the work against itself. The run reported ok with
    # an empty patch. Only a test that goes through `delegate run` catches that,
    # which is why this one exists alongside the narrower one.
    local repo; repo="$(make_test_repo commits-repo)"
    MOCK_CODEX_COMMITS=1 run "$DELEGATE" run --model test-model-beta \
        --task "make a change and commit it" --repo "$repo" --quiet
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.status == "ok"'

    local diff; diff="$(echo "$output" | jq -r .diff_path)"
    [ -s "$diff" ] || {
        echo "diff is empty: the executor's committed work was lost" >&2
        return 1
    }
    grep -q "MOCK_CODEX_CHANGE" "$diff"
}

@test "delegate run: an executor that COMMITS its work still yields a diff" {
    # `git diff --cached` alone compares the index to HEAD, so an executor that
    # commits produces an EMPTY patch: HEAD already holds the work, nothing is
    # left staged, and the run reports ok having silently lost everything it
    # did. Agents commit on their own, and a task that says "work on a branch
    # and commit when you are done" -- which benchmark harnesses state
    # explicitly -- hits this every single time.
    local wt base
    wt="$BATS_TEST_TMPDIR/commit-wt"
    mkdir -p "$wt"
    cd "$wt"
    git init -q .
    git config user.email t@example.com
    git config user.name tester
    echo original > file.txt
    git add -A
    git commit -q -m base
    base="$(git rev-parse HEAD)"

    # the executor works on a branch and commits, exactly as instructed
    git checkout -q -b work
    echo changed > file.txt
    git add -A
    git commit -q -m "executor commit"

    git add -A
    run git diff --cached
    [ -z "$output" ]                      # what the old code saw: nothing

    run git diff --cached "$base"
    [ -n "$output" ]                      # what the fix sees: the work
    echo "$output" | grep -q changed
}
