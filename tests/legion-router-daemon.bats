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
  UPSTREAM_PORT=8190
  # Fixture prices, not the shipped table: the cost assertions below are exact,
  # and pinning them to real list prices makes an unrelated price edit fail here.
  export LEGION_COSTS_FILE="$REPO_ROOT/tests/fixtures/costs.json"
  ROUTER_STREAM_UPSTREAM_PORT="$UPSTREAM_PORT" bun run "$REPO_ROOT/tests/fixtures/router-stream-upstream.ts" \
    >"$BATS_TEST_TMPDIR/upstream.log" 2>&1 &
  UPSTREAM_PID=$!
  if ! curl -sf --retry 40 --retry-connrefused --retry-delay 1 -m 2 \
        "http://127.0.0.1:$UPSTREAM_PORT/health" >/dev/null 2>&1; then
    cat "$BATS_TEST_TMPDIR/upstream.log" >&2
    return 1
  fi
  ROUTER_PORT="$PORT" OLLAMA_MODELS="local-stream" OLLAMA_BASE_URL="http://127.0.0.1:$UPSTREAM_PORT" \
    UPSTREAM_TIMEOUT_MS=200 \
    STREAM_UPSTREAM_TIMEOUT_MS=0 bun run "$REPO_ROOT/legion-router/scripts/router.ts" \
    >"$BATS_TEST_TMPDIR/router.log" 2>&1 &
  ROUTER_PID=$!
  if ! curl -sf --retry 40 --retry-connrefused --retry-delay 1 -m 2 \
        "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    cat "$BATS_TEST_TMPDIR/router.log" >&2
    return 1
  fi
}

teardown() {
  if [[ -n "${ROUTER_PID:-}" ]]; then
    kill "$ROUTER_PID" 2>/dev/null || true
    wait "$ROUTER_PID" 2>/dev/null || true
  fi
  if [[ -n "${UPSTREAM_PID:-}" ]]; then
    kill "$UPSTREAM_PID" 2>/dev/null || true
    wait "$UPSTREAM_PID" 2>/dev/null || true
  fi
}

@test "router: starts with no keys (degraded, not crashed)" {
  run curl -s "http://127.0.0.1:$PORT/health"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "degraded"'
  echo "$output" | jq -e '.anthropicKeySet == false'
  echo "$output" | jq -e '.minimaxTokenSet == false'
}

@test "router: rejects an upstream URL that targets itself" {
  local self_port=8211
  run env ROUTER_PORT="$self_port" \
    LEGION_ANTHROPIC_UPSTREAM_URL="http://127.0.0.1:$self_port" \
    bun run "$REPO_ROOT/legion-router/scripts/router.ts"
  [ "$status" -ne 0 ]
  [[ "$output" == *"upstream URL must not target the Legion router itself"* ]]
}

@test "router: /ingest folds a codex test-model-alpha run into stats with cost" {
  run curl -s -X POST "http://127.0.0.1:$PORT/ingest" \
    -d '{"model":"test-model-alpha","upstream":"codex","usage":{"input_tokens":89124,"cached_input_tokens":71552,"output_tokens":806,"reasoning_output_tokens":214}}'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ok == true'
  echo "$output" | jq -e '.costUsd == 0.077118'

  run curl -s "http://127.0.0.1:$PORT/stats"
  echo "$output" | jq -e '.totalCostUsd == 0.077118'
  echo "$output" | jq -e '.byUpstream.codex.costUsd == 0.077118'
  echo "$output" | jq -e '.byModel["test-model-alpha"].inputTokens == 17572'   # billed = 89124 - 71552 cached
  echo "$output" | jq -e '.byModel["test-model-alpha"].outputTokens == 1020'   # 806 + 214 reasoning
}

@test "router: explicit cost_usd in the record is used verbatim" {
  run curl -s -X POST "http://127.0.0.1:$PORT/ingest" \
    -d '{"model":"test-model-beta","upstream":"codex","cost_usd":1.2345,"usage":{"input_tokens":10,"output_tokens":5}}'
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
    -d '{"model":"test-model-alpha","usage":{"input_tokens":"oops","output_tokens":{}}}' >/dev/null
  curl -s -X POST "http://127.0.0.1:$PORT/ingest" \
    -d '{"model":"test-model-alpha","usage":{"input_tokens":100,"output_tokens":10}}' >/dev/null
  run curl -s "http://127.0.0.1:$PORT/stats"
  echo "$output" | jq -e '.totalInputTokens == 100'             # garbage coerced to 0
  echo "$output" | jq -e '(.totalCostUsd | type) == "number"'   # never NaN/null
  echo "$output" | jq -e '.totalCostUsd != null'
}

@test "router: negative cost_usd is rejected and recomputed, not trusted" {
  run curl -s -X POST "http://127.0.0.1:$PORT/ingest" \
    -d '{"model":"test-model-alpha","cost_usd":-999,"usage":{"input_tokens":100,"output_tokens":10}}'
  echo "$output" | jq -e '.costUsd >= 0'
}

@test "router: /stats reset clears counters" {
  curl -s -X POST "http://127.0.0.1:$PORT/ingest" \
    -d '{"model":"test-model-alpha","upstream":"codex","usage":{"input_tokens":100,"output_tokens":10}}' >/dev/null
  run curl -s "http://127.0.0.1:$PORT/stats?reset=true"
  echo "$output" | jq -e '.totalRequests >= 1'
  run curl -s "http://127.0.0.1:$PORT/stats"
  echo "$output" | jq -e '.totalRequests == 0'
  echo "$output" | jq -e '.totalCostUsd == 0'
}

@test "router: concurrent streaming responses complete and are metered" {
  local pids=()
  local i
  for i in 1 2 3 4 5 6; do
    curl -sS -N -X POST "http://127.0.0.1:$PORT/v1/messages" \
      -H 'content-type: application/json' \
      -d '{"model":"local-stream","stream":true,"messages":[{"role":"user","content":"hi"}]}' \
      >"$BATS_TEST_TMPDIR/stream-$i.out" &
    pids+=("$!")
  done

  for pid in "${pids[@]}"; do
    wait "$pid"
  done

  for i in 1 2 3 4 5 6; do
    grep -q 'message_delta' "$BATS_TEST_TMPDIR/stream-$i.out"
    grep -q 'message_stop' "$BATS_TEST_TMPDIR/stream-$i.out"
    ! grep -q 'upstream_stream_error' "$BATS_TEST_TMPDIR/stream-$i.out"
  done

  run curl -s "http://127.0.0.1:$PORT/stats"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.totalRequests == 6'
  echo "$output" | jq -e '.totalInputTokens == 18'
  echo "$output" | jq -e '.totalOutputTokens == 42'
  echo "$output" | jq -e '.byUpstream.ollama.requests == 6'
}

@test "router: stream fetch setup still has a finite header timeout" {
  run bash -c "curl -s -o /dev/null -w '%{http_code}' -m 3 -N -X POST 'http://127.0.0.1:$PORT/v1/messages' \
    -H 'content-type: application/json' \
    -H 'x-test-hang-headers: 1' \
    -d '{\"model\":\"local-stream\",\"stream\":true,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}'"
  [ "$status" -eq 0 ]
  [ "$output" = "502" ]
}

@test "router: downstream cancellation cancels and meters the upstream stream" {
  run bun -e '
    const response = await fetch(process.argv[1], {
      method: "POST",
      headers: {"content-type":"application/json", "x-test-slow-stream":"1"},
      body: JSON.stringify({model:"local-stream",stream:true,messages:[{role:"user",content:"hi"}]})
    });
    const reader = response.body.getReader();
    await reader.read();
    await reader.cancel("test-client-cancel");
  ' "http://127.0.0.1:$PORT/v1/messages"
  [ "$status" -eq 0 ]

  for _ in {1..50}; do
    output="$(curl -s "http://127.0.0.1:$PORT/stats")"
    echo "$output" | jq -e '.totalRequests == 1' >/dev/null && break
    sleep 0.02
  done
  echo "$output" | jq -e '.totalRequests == 1 and .recentEntries[0].status == 499'
}

@test "router: truncated upstream streams terminate with an error SSE event" {
  run curl -sS -N -m 3 -X POST "http://127.0.0.1:$PORT/v1/messages" \
    -H 'content-type: application/json' \
    -H 'x-test-error-stream: 1' \
    -d '{"model":"local-stream","stream":true,"messages":[{"role":"user","content":"hi"}]}'
  [ "$status" -eq 0 ]
  [[ "$output" == *'upstream_stream_error'* ]]

  run curl -s "http://127.0.0.1:$PORT/stats"
  echo "$output" | jq -e '.totalRequests == 1 and .recentEntries[0].status == 599'
}

@test "router: Anthropic fallback uses the same non-streaming accounting path" {
  kill "$ROUTER_PID" 2>/dev/null || true
  wait "$ROUTER_PID" 2>/dev/null || true
  ROUTER_PID=""

  ROUTER_PORT="$PORT" \
    MINIMAX_MODELS="minimax-fallback" \
    LEGION_MINIMAX_UPSTREAM_URL="http://127.0.0.1:$UPSTREAM_PORT/minimax" \
    LEGION_ANTHROPIC_UPSTREAM_URL="http://127.0.0.1:$UPSTREAM_PORT/anthropic" \
    MINIMAX_AUTH_TOKEN="test-minimax" ANTHROPIC_API_KEY="test-anthropic" \
    UPSTREAM_TIMEOUT_MS=200 STREAM_UPSTREAM_TIMEOUT_MS=0 \
    bun run "$REPO_ROOT/legion-router/scripts/router.ts" \
    >"$BATS_TEST_TMPDIR/router-fallback.log" 2>&1 &
  ROUTER_PID=$!
  curl -sf --retry 40 --retry-connrefused --retry-delay 1 -m 2 \
    "http://127.0.0.1:$PORT/health" >/dev/null

  run curl -sS -X POST "http://127.0.0.1:$PORT/v1/messages" \
    -H 'content-type: application/json' \
    -d '{"model":"minimax-fallback","stream":false,"messages":[{"role":"user","content":"hi"}]}'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.usage.input_tokens == 11 and .usage.output_tokens == 5'

  run curl -s "http://127.0.0.1:$PORT/stats"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '
    .totalRequests == 2
    and .totalInputTokens == 11
    and .totalOutputTokens == 5
    and .byUpstream.minimax.requests == 1
    and .byUpstream.anthropic.requests == 1
    and [.recentEntries[].status] == [503, 200]
  '

  run curl -sS -N -X POST "http://127.0.0.1:$PORT/v1/messages" \
    -H 'content-type: application/json' \
    -d '{"model":"minimax-fallback","stream":true,"messages":[{"role":"user","content":"hi"}]}'
  [ "$status" -eq 0 ]
  [[ "$output" == *'message_stop'* ]]

  run curl -s "http://127.0.0.1:$PORT/stats"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '
    .totalRequests == 4
    and .totalInputTokens == 14
    and .totalOutputTokens == 12
    and .byUpstream.minimax.requests == 2
    and .byUpstream.anthropic.requests == 2
    and [.recentEntries[].status] == [503, 200, 503, 200]
  '
}

@test "router: a failed fallback is not retried and attributes the failed primary to its routed model" {
  kill "$ROUTER_PID" 2>/dev/null || true
  wait "$ROUTER_PID" 2>/dev/null || true
  ROUTER_PID=""

  ROUTER_PORT="$PORT" \
    MINIMAX_MODEL_MAP="alias-claude:minimax-fallback" \
    LEGION_MINIMAX_UPSTREAM_URL="http://127.0.0.1:$UPSTREAM_PORT/minimax" \
    LEGION_ANTHROPIC_UPSTREAM_URL="http://127.0.0.1:8212/anthropic" \
    MINIMAX_AUTH_TOKEN="test-minimax" ANTHROPIC_API_KEY="test-anthropic" \
    UPSTREAM_TIMEOUT_MS=100 STREAM_UPSTREAM_TIMEOUT_MS=0 \
    bun run "$REPO_ROOT/legion-router/scripts/router.ts" \
    >"$BATS_TEST_TMPDIR/router-double-failure.log" 2>&1 &
  ROUTER_PID=$!
  curl -sf --retry 40 --retry-connrefused --retry-delay 1 -m 2 \
    "http://127.0.0.1:$PORT/health" >/dev/null

  run curl -sS -o "$BATS_TEST_TMPDIR/double-failure.body" -w '%{http_code}' \
    -X POST "http://127.0.0.1:$PORT/v1/messages" \
    -H 'content-type: application/json' \
    -d '{"model":"alias-claude","stream":false,"messages":[{"role":"user","content":"hi"}]}'
  [ "$status" -eq 0 ]
  [ "$output" = "502" ]
  grep -q "Both upstreams failed" "$BATS_TEST_TMPDIR/double-failure.body"

  run curl -s "http://127.0.0.1:$PORT/stats"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '
    .totalRequests == 2
    and .byUpstream.minimax.requests == 1
    and .byUpstream.anthropic.requests == 1
    and .byModel["minimax-fallback"].requests == 1
    and .byModel["alias-claude"].requests == 1
    and [.recentEntries[].status] == [503, 599]
  '
}
