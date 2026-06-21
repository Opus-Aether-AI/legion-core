#!/usr/bin/env bats
# Router daemon e2e — starts router.ts directly via bun on an ephemeral port and
# exercises /health, /ingest, /stats. Skips where bun is unavailable (the default
# GitHub runner), so it never blocks CI. Invokes only bun + curl (no scripts/*.sh),
# so it does NOT affect the installer kcov coverage gate.

setup() {
  command -v bun >/dev/null 2>&1 || skip "bun not installed"
  command -v jq  >/dev/null 2>&1 || skip "jq not installed"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  PORT=8189
  export LEGION_COSTS_FILE="$REPO_ROOT/legion-router/config/costs.json"
  ROUTER_PORT="$PORT" bun run "$REPO_ROOT/legion-router/scripts/router.ts" \
    >"$BATS_TEST_TMPDIR/router.log" 2>&1 &
  ROUTER_PID=$!
  if ! curl -sf --retry 40 --retry-connrefused --retry-delay 1 -m 2 \
        "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    cat "$BATS_TEST_TMPDIR/router.log" >&2
    return 1
  fi
}

teardown() {
  [[ -n "${ROUTER_PID:-}" ]] && kill "$ROUTER_PID" 2>/dev/null || true
}

@test "router: starts with no keys (degraded, not crashed)" {
  run curl -s "http://127.0.0.1:$PORT/health"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "degraded"'
  echo "$output" | jq -e '.anthropicKeySet == false'
  echo "$output" | jq -e '.minimaxTokenSet == false'
}

@test "router: /ingest folds a codex gpt-5.4 run into stats with cost" {
  run curl -s -X POST "http://127.0.0.1:$PORT/ingest" \
    -d '{"model":"gpt-5.4","upstream":"codex","usage":{"input_tokens":89124,"cached_input_tokens":71552,"output_tokens":806,"reasoning_output_tokens":214}}'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ok == true'
  echo "$output" | jq -e '.costUsd == 0.077118'

  run curl -s "http://127.0.0.1:$PORT/stats"
  echo "$output" | jq -e '.totalCostUsd == 0.077118'
  echo "$output" | jq -e '.byUpstream.codex.costUsd == 0.077118'
  echo "$output" | jq -e '.byModel["gpt-5.4"].inputTokens == 17572'   # billed = 89124 - 71552 cached
  echo "$output" | jq -e '.byModel["gpt-5.4"].outputTokens == 1020'   # 806 + 214 reasoning
}

@test "router: explicit cost_usd in the record is used verbatim" {
  run curl -s -X POST "http://127.0.0.1:$PORT/ingest" \
    -d '{"model":"gpt-5.5","upstream":"codex","cost_usd":1.2345,"usage":{"input_tokens":10,"output_tokens":5}}'
  echo "$output" | jq -e '.costUsd == 1.2345'
}

@test "router: /ingest rejects non-POST and bad payloads" {
  run bash -c "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$PORT/ingest"
  [ "$output" = "405" ]
  run bash -c "curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:$PORT/ingest -d 'not json'"
  [ "$output" = "400" ]
}

@test "router: malformed /ingest numbers do not poison stats (NaN guard)" {
  curl -s -X POST "http://127.0.0.1:$PORT/ingest" \
    -d '{"model":"gpt-5.4","usage":{"input_tokens":"oops","output_tokens":{}}}' >/dev/null
  curl -s -X POST "http://127.0.0.1:$PORT/ingest" \
    -d '{"model":"gpt-5.4","usage":{"input_tokens":100,"output_tokens":10}}' >/dev/null
  run curl -s "http://127.0.0.1:$PORT/stats"
  echo "$output" | jq -e '.totalInputTokens == 100'             # garbage coerced to 0
  echo "$output" | jq -e '(.totalCostUsd | type) == "number"'   # never NaN/null
  echo "$output" | jq -e '.totalCostUsd != null'
}

@test "router: negative cost_usd is rejected and recomputed, not trusted" {
  run curl -s -X POST "http://127.0.0.1:$PORT/ingest" \
    -d '{"model":"gpt-5.4","cost_usd":-999,"usage":{"input_tokens":100,"output_tokens":10}}'
  echo "$output" | jq -e '.costUsd >= 0'
}

@test "router: /stats reset clears counters" {
  curl -s -X POST "http://127.0.0.1:$PORT/ingest" \
    -d '{"model":"gpt-5.4","upstream":"codex","usage":{"input_tokens":100,"output_tokens":10}}' >/dev/null
  run curl -s "http://127.0.0.1:$PORT/stats?reset=true"
  echo "$output" | jq -e '.totalRequests >= 1'
  run curl -s "http://127.0.0.1:$PORT/stats"
  echo "$output" | jq -e '.totalRequests == 0'
  echo "$output" | jq -e '.totalCostUsd == 0'
}
