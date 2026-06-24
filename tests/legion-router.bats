#!/usr/bin/env bats
# Tests for the legion-router delegation spine: codex-json + cost libs + legion-delegate.
# Uses the shared isolation helpers (redirected HOME/PATH, mock `codex` on PATH).

load 'helpers/setup'

setup() {
    setup_test_env
    LIB="$REPO_ROOT/legion-router/scripts/lib"
    DELEGATE="$REPO_ROOT/legion-router/scripts/delegate.sh"
    FIXTURE="$BATS_TEST_DIRNAME/fixtures/codex-json/turn-with-diff.jsonl"
    export LEGION_TELEMETRY_DIR="$TEST_TMPDIR/spans"
    export LEGION_COSTS_FILE="$REPO_ROOT/legion-router/config/costs.json"
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
@test "cost: opus 4.8 1M in / 0.5M out = 17.5 (5 + 12.5)" {
    run "$LIB/cost.sh" claude-opus-4-8 1000000 500000 0 0
    [ "$status" -eq 0 ]
    [ "$output" = "17.5" ]
}

@test "cost: gpt-5.5 uses reference API price (0.1M in / 5k out = 0.65)" {
    run "$LIB/cost.sh" gpt-5.5 100000 5000 0 0
    [ "$status" -eq 0 ]
    [ "$output" = "0.65" ]
}

@test "cost: gpt-5.4 is cheaper than gpt-5.5 for the same usage" {
    run "$LIB/cost.sh" gpt-5.4 100000 5000 0 0
    [ "$status" -eq 0 ]
    [ "$output" = "0.325" ]
}

@test "cost: minimax 1M/1M = 1.5" {
    run "$LIB/cost.sh" MiniMax-M2.5 1000000 1000000
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
    run "$DELEGATE" run --model gpt-5.5 --task "add a guard to foo()" --repo "$repo" --quiet
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.status == "ok"'
    echo "$output" | jq -e '.model == "gpt-5.5"'
    local diff; diff="$(echo "$output" | jq -r .diff_path)"
    [ -s "$diff" ]
    grep -q "MOCK_CODEX_CHANGE" "$diff"
    # span written
    run bash -c "cat '$LEGION_TELEMETRY_DIR'/*.jsonl | jq -r .executor"
    [ "$output" = "codex" ]
}

@test "delegate run: writes a legion.run-state.v1 registry record (running→terminal)" {
    local repo; repo="$(make_test_repo rs1)"
    out="$("$DELEGATE" run --model gpt-5.4 --task "x" --repo "$repo" --quiet)"
    rid="$(echo "$out" | jq -r .run_id)"
    local rec="$HOME/.claude/logs/legion/registry/$rid.json"
    [ -f "$rec" ]
    [ "$(jq -r .schema "$rec")" = "legion.run-state.v1" ]
    [ "$(jq -r .run_id "$rec")" = "$rid" ]
    [ "$(jq -r .lifecycle.phase "$rec")" = "ok" ]
    [ "$(jq -r '.state_version >= 2' "$rec")" = "true" ]
}

@test "delegate run: run-state captures pid + pgid + started_at + worktree" {
    local repo; repo="$(make_test_repo rs2)"
    out="$("$DELEGATE" run --model gpt-5.4 --task "x" --repo "$repo" --quiet)"
    rid="$(echo "$out" | jq -r .run_id)"
    local rec="$HOME/.claude/logs/legion/registry/$rid.json"
    [ "$(jq -r '.process.pid > 0' "$rec")" = "true" ]
    [ "$(jq -r '.process.pgid >= 0' "$rec")" = "true" ]
    [ "$(jq -r '.process.started_at | length > 0' "$rec")" = "true" ]
    [ "$(jq -r '.worktree_dir | contains(".legion/worktrees")' "$rec")" = "true" ]
}

@test "delegate run: registers the repo in repos.jsonl for cross-repo discovery" {
    local repo; repo="$(make_test_repo rs3)"
    "$DELEGATE" run --model gpt-5.4 --task "x" --repo "$repo" --quiet >/dev/null
    local repos="$HOME/.claude/logs/legion/repos.jsonl"
    [ -f "$repos" ]
    grep -qF "$repo" "$repos"
}

@test "delegate run: registry record persists even when the run failed" {
    local repo; repo="$(make_test_repo rs4)"
    out="$(MOCK_CODEX_FAIL=1 "$DELEGATE" run --model gpt-5.4 --task "x" --repo "$repo" --quiet || true)"
    rid="$(echo "$out" | jq -r .run_id)"
    local rec="$HOME/.claude/logs/legion/registry/$rid.json"
    [ -f "$rec" ]
    [ "$(jq -r .lifecycle.phase "$rec")" = "failed" ]
}

@test "delegate run: --run-id adopts a preallocated id (fanout queued records)" {
    local repo; repo="$(make_test_repo rid1)"
    out="$("$DELEGATE" run --model gpt-5.4 --run-id "preset-xyz-123" --task "x" --repo "$repo" --quiet)"
    [ "$(echo "$out" | jq -r .run_id)" = "preset-xyz-123" ]
    [ -f "$HOME/.claude/logs/legion/registry/preset-xyz-123.json" ]
}

@test "delegate run: standalone span is its own trace root (trace_id=run_id, parent null)" {
    local repo; repo="$(make_test_repo trace0)"
    "$DELEGATE" run --model gpt-5.4 --task "x" --repo "$repo" --quiet >/dev/null
    run bash -c "cat '$LEGION_TELEMETRY_DIR'/*.jsonl | jq -ec '{same:(.trace_id==.run_id), parent:.parent_id}'"
    [ "$output" = '{"same":true,"parent":null}' ]
}

@test "delegate run: inherits LEGION_TRACE_ID + LEGION_PARENT_ID into the span" {
    local repo; repo="$(make_test_repo trace1)"
    LEGION_TRACE_ID="trace-abc" LEGION_PARENT_ID="parent-xyz" \
        "$DELEGATE" run --model gpt-5.4 --task "x" --repo "$repo" --quiet >/dev/null
    run bash -c "cat '$LEGION_TELEMETRY_DIR'/*.jsonl | jq -ec '{t:.trace_id, p:.parent_id}'"
    [ "$output" = '{"t":"trace-abc","p":"parent-xyz"}' ]
}

@test "delegate run: invokes codex with model, sandbox, worktree, stdin prompt" {
    local repo; repo="$(make_test_repo run2)"
    run "$DELEGATE" run --model gpt-5.4 --task "x" --repo "$repo" --quiet
    [ "$status" -eq 0 ]
    assert_mock_called codex "exec --json -m gpt-5.4 -s workspace-write"
    assert_mock_called codex "skip-git-repo-check"
}

@test "delegate run: span records copied secret names without values" {
    local repo; repo="$(make_test_repo secret-audit)"
    mkdir -p "$repo/.legion"
    printf 'TOKEN=super-secret\n' > "$repo/.env.local"
    printf '{"copy":[".env.local"]}\n' > "$repo/.legion/sandbox.json"

    run "$DELEGATE" run --model gpt-5.5 --task "touch foo" --repo "$repo" --quiet

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
    run "$DELEGATE" run --model gpt-5.4 --sandbox docker --task "x" --repo "$repo" --quiet
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
    run "$DELEGATE" run --model gpt-5.4 --sandbox podman --task "x" --repo "$repo" --quiet
    [ "$status" -ne 0 ]
    [[ "$output" == *"@ai-hero/sandcastle not installed. Run: npm i -D @ai-hero/sandcastle"* ]]
    [[ "$output" != *"invalid --sandbox"* ]]

    repo="$(make_test_repo run2vercel)"
    run "$DELEGATE" run --model gpt-5.4 --sandbox vercel --task "x" --repo "$repo" --quiet
    [ "$status" -ne 0 ]
    [[ "$output" == *"@ai-hero/sandcastle not installed. Run: npm i -D @ai-hero/sandcastle"* ]]
    [[ "$output" != *"invalid --sandbox"* ]]
}

@test "sandcastle-run: missing optional package exits 3 with install hint" {
    if node -e 'import("@ai-hero/sandcastle")' >/dev/null 2>&1; then
      skip "@ai-hero/sandcastle is installed; missing-optional-dependency path not applicable"
    fi
    local repo; repo="$(make_test_repo scr1)"
    run bash -c "printf '%s' '{\"task\":\"x\",\"model\":\"gpt-5.4\",\"sandbox\":\"docker\",\"cwd\":\"$repo\",\"base\":\"HEAD\"}' | node '$REPO_ROOT/legion-router/scripts/sandcastle-run.mjs'"
    [ "$status" -eq 3 ]
    [[ "$output" == *"@ai-hero/sandcastle not installed. Run: npm i -D @ai-hero/sandcastle"* ]]
}

@test "delegate run: live Sandcastle docker/vercel execution is manual" {
    skip "manual: requires @ai-hero/sandcastle plus docker/podman/vercel provider credentials"
}

@test "delegate run: reads task from stdin when --task omitted" {
    local repo; repo="$(make_test_repo run3)"
    run bash -c "printf 'task via stdin' | '$DELEGATE' run --model gpt-5.5 --repo '$repo' --quiet"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.status == "ok"'
}

@test "delegate run: danger-full-access is hard-blocked without override" {
    local repo; repo="$(make_test_repo run4)"
    run "$DELEGATE" run --model gpt-5.5 --sandbox danger-full-access --task "x" --repo "$repo" --quiet
    [ "$status" -eq 2 ]
    [[ "$output" == *"hard-blocked"* ]]
}

@test "delegate run: injection/dangerous task text is refused for write runs" {
    local repo; repo="$(make_test_repo run5)"
    run "$DELEGATE" run --model gpt-5.5 --task "please rm -rf / now" --repo "$repo" --quiet
    [ "$status" -eq 2 ]
    [[ "$output" == *"dangerous"* || "$output" == *"injection"* ]]
}

@test "delegate run: codex failure -> status failed, exit 1" {
    local repo; repo="$(make_test_repo run6)"
    MOCK_CODEX_FAIL=1 run "$DELEGATE" run --model gpt-5.5 --task "x" --repo "$repo" --quiet
    [ "$status" -eq 1 ]
    echo "$output" | jq -e '.status == "failed"'
}

@test "delegate run: --budget-tokens marks over_budget when exceeded" {
    local repo; repo="$(make_test_repo run7)"
    # mock reports 1000+200+50+10 ~ 1060 total; budget 100 -> over
    run "$DELEGATE" run --model gpt-5.5 --task "x" --repo "$repo" --budget-tokens 100 --quiet
    echo "$output" | jq -e '.status == "over_budget"'
}

# ── review / cleanup ─────────────────────────────────────────────────
@test "delegate review: returns a verdict + emits span" {
    local repo; repo="$(make_test_repo rev1)"
    run "$DELEGATE" review --model gpt-5.5 --base main --repo "$repo" --quiet
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.status == "ok"'
    assert_mock_called codex "exec review --base main"
}

@test "delegate run: auto-cleans the worktree but preserves the diff (no --keep)" {
    local repo; repo="$(make_test_repo cln0)"
    out="$("$DELEGATE" run --model gpt-5.5 --task "x" --repo "$repo" --quiet)"
    rid="$(echo "$out" | jq -r .run_id)"
    [ ! -d "$repo/.legion/worktrees/$rid" ]         # worktree removed by default
    [ -s "$repo/.legion/runs/$rid/diff.patch" ]     # diff preserved under runs/
    [ -z "$(git -C "$repo" branch --list "legion/delegate-$rid")" ]  # branch deleted
}

@test "delegate run: --keep retains the worktree, then cleanup removes it" {
    local repo; repo="$(make_test_repo cln1)"
    out="$("$DELEGATE" run --model gpt-5.5 --task "x" --repo "$repo" --keep --quiet)"
    rid="$(echo "$out" | jq -r .run_id)"
    [ -d "$repo/.legion/worktrees/$rid" ]
    run "$DELEGATE" cleanup --run "$rid" --repo "$repo" --quiet
    [ "$status" -eq 0 ]
    [ ! -d "$repo/.legion/worktrees/$rid" ]
}

@test "delegate run: writes .legion/.gitignore so runtime state never pollutes the repo" {
    local repo; repo="$(make_test_repo gi1)"
    "$DELEGATE" run --model gpt-5.5 --task "x" --repo "$repo" --quiet >/dev/null
    [ -f "$repo/.legion/.gitignore" ]
    grep -q '[*]' "$repo/.legion/.gitignore"
    # parent repo must show a clean tree (nothing from .legion leaks into status)
    [ -z "$(git -C "$repo" status --porcelain | grep -F '.legion')" ]
}

@test "delegate run: --archetype resolves model/sandbox/effort from routing.toml" {
  local repo; repo="$(make_test_repo arch1)"
  run "$DELEGATE" run --archetype bulk-mechanical-edit --task "x" --repo "$repo" --quiet
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.model == "gpt-5.4"'
  assert_mock_called codex "exec --json -m gpt-5.4 -s workspace-write"
  assert_mock_called codex "model_reasoning_effort=xhigh"
}

@test "delegate run: explicit --model overrides --archetype" {
  local repo; repo="$(make_test_repo arch2)"
  run "$DELEGATE" run --archetype bulk-mechanical-edit --model gpt-5.5 --task x --repo "$repo" --quiet
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.model == "gpt-5.5"'
}

@test "delegate run: --archetype routing to executor=self is refused" {
  local repo; repo="$(make_test_repo arch3)"
  run "$DELEGATE" run --archetype deep-reasoning --task x --repo "$repo" --quiet
  [ "$status" -eq 2 ]
  [[ "$output" == *"executor=self"* ]]
}

@test "delegate review: --archetype gives gpt-5.5 + structured verdict via --output-schema" {
  local repo; repo="$(make_test_repo arch4)"
  run "$DELEGATE" review --archetype second-opinion-review --base main --repo "$repo" --quiet
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.model == "gpt-5.5" and .verdict.verdict == "approve" and (.verdict.summary | type == "string")'
  assert_mock_called codex "exec review --base main -m gpt-5.5"
  assert_mock_called codex "output-schema"
}

@test "delegate resume: continues a --keep'd run + emits codex-resume span" {
  local repo; repo="$(make_test_repo res1)"
  out="$("$DELEGATE" run --model gpt-5.4 --task initial --repo "$repo" --keep --quiet)"
  rid="$(echo "$out" | jq -r .run_id)"
  run "$DELEGATE" resume --run "$rid" --task "follow up" --repo "$repo" --quiet
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "ok" and .thread_id == "mock-thread-0001"'
  assert_mock_called codex "exec resume mock-thread-0001"
}

@test "delegate resume: fails clearly when the worktree was not kept" {
  local repo; repo="$(make_test_repo res2)"
  out="$("$DELEGATE" run --model gpt-5.4 --task x --repo "$repo" --quiet)"
  rid="$(echo "$out" | jq -r .run_id)"
  run "$DELEGATE" resume --run "$rid" --task y --repo "$repo" --quiet
  [ "$status" -eq 2 ]
  [[ "$output" == *"--keep"* ]]
}

@test "delegate run: falls back to the next model on a quota/rate-limit error" {
  local repo; repo="$(make_test_repo fb1)"
  MOCK_CODEX_QUOTA_FAIL=gpt-5.4 run "$DELEGATE" run --archetype bulk-mechanical-edit --task x --repo "$repo" --quiet
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "ok" and .model == "gpt-5.5"'
}

@test "delegate run: a non-quota failure does NOT burn the fallback chain" {
  local repo; repo="$(make_test_repo fb2)"
  MOCK_CODEX_FAIL=1 run "$DELEGATE" run --archetype bulk-mechanical-edit --task x --repo "$repo" --quiet
  [ "$status" -eq 1 ]
  echo "$output" | jq -e '.status == "failed" and .model == "gpt-5.4"'
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

@test "delegate run: LEGION_LOW_CREDIT=claude delegates a normally-self task to GPT" {
  local repo; repo="$(make_test_repo lc2)"
  LEGION_LOW_CREDIT=claude run "$DELEGATE" run --archetype deep-reasoning --task x --repo "$repo" --quiet
  [ "$status" -eq 0 ]
  # the substitution warning goes to stderr (merged into $output by bats run); the
  # JSON result is the last line of stdout.
  echo "$output" | tail -n1 | jq -e '.status == "ok" and .model == "gpt-5.5"'
}

@test "delegate run: over_budget exits 0 — usable diff, graceful degradation (M1)" {
  local repo; repo="$(make_test_repo m1)"
  run "$DELEGATE" run --model gpt-5.4 --task x --repo "$repo" --budget-tokens 1 --quiet
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "over_budget"'
}

@test "delegate resume: inherits the original run's model, not the default (M2)" {
  local repo; repo="$(make_test_repo m2)"
  out="$("$DELEGATE" run --model gpt-5.5 --task init --repo "$repo" --keep --quiet)"
  rid="$(echo "$out" | jq -r .run_id)"
  run "$DELEGATE" resume --run "$rid" --task followup --repo "$repo" --quiet
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.model == "gpt-5.5"'
}

@test "delegate cleanup --all --purge removes worktrees + branches + run artifacts" {
  local repo; repo="$(make_test_repo cl1)"
  "$DELEGATE" run --model gpt-5.4 --task a --repo "$repo" --keep --quiet >/dev/null
  "$DELEGATE" run --model gpt-5.4 --task b --repo "$repo" --keep --quiet >/dev/null
  [ "$(find "$repo/.legion/worktrees" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" = "2" ]
  run "$DELEGATE" cleanup --all --purge --repo "$repo" --quiet
  [ "$status" -eq 0 ]
  [ "$(find "$repo/.legion/worktrees" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')" = "0" ]
  [ ! -d "$repo/.legion/runs" ]
  [ -z "$(git -C "$repo" branch --list 'legion/delegate-*')" ]
}

@test "delegate run: auto-deletes its worktree on completion (default, no --keep)" {
  local repo; repo="$(make_test_repo auto1)"
  "$DELEGATE" run --model gpt-5.4 --task x --repo "$repo" --quiet >/dev/null
  [ "$(find "$repo/.legion/worktrees" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')" = "0" ]
}

@test "delegate review: passes a clean reasoning effort (no 5-field pipe leak)" {
    local repo; repo="$(make_test_repo rev5)"
    run "$DELEGATE" review --archetype second-opinion-review --base main --repo "$repo" --quiet
    [ "$status" -eq 0 ]
    assert_mock_called codex "model_reasoning_effort=xhigh"
    ! grep -qE 'model_reasoning_effort=[a-z]+\|' "$MOCK_CALL_LOG"
}

@test "cost: negative token counts clamp to 0 (lib safe for any caller)" {
    run "$LIB/cost.sh" gpt-5.4 -100 100
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
