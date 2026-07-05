#!/usr/bin/env bats
# legion-telemetry (legion-trace) — emit + validate legion.span.v1 spans.

setup() {
  TEL="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/legion-observability/bin/legion-trace"
  export LEGION_TELEMETRY_DIR="$BATS_TEST_TMPDIR/spans"
}

@test "telemetry: emit writes a valid span + appends to the daily log" {
  run "$TEL" emit --executor codex --model fixture-codex --status ok --cost 0.05 \
    --duration-ms 1200 --tokens '{"input_tokens":10}'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.schema=="legion.span.v1" and .executor=="codex" and .cost_usd==0.05 and .tokens.input_tokens==10'
  [ -n "$(find "$LEGION_TELEMETRY_DIR" -name '*.jsonl')" ]
}

@test "telemetry: emit defaults run_id, mirrors trace_id, nulls parent" {
  run "$TEL" emit --executor claude --model fixture-claude --status ok
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.run_id != "" and .trace_id == .run_id and .parent_id == null'
}

@test "telemetry: emit carries task / trace-id / parent-id / artifacts" {
  run "$TEL" emit --executor codex --model fixture-codex --status ok \
    --task "do x" --trace-id T1 --parent-id P1 --artifacts '{"diff":"d"}'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.task=="do x" and .trace_id=="T1" and .parent_id=="P1" and .artifacts.diff=="d"'
}

@test "telemetry: emit carries harness target metadata" {
  run "$TEL" emit --executor codex --model fixture-codex --status blocked \
    --target-type command --target-name feature
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status=="blocked" and .target_type=="command" and .target_name=="feature"'
}

@test "telemetry: emit requires executor/model/status" {
  run "$TEL" emit --executor codex --model fixture-codex
  [ "$status" -eq 2 ]
}

@test "telemetry: emit rejects an unknown arg" {
  run "$TEL" emit --executor x --model y --status ok --bogus z
  [ "$status" -eq 2 ]
}

@test "telemetry: validate passes for emitted spans" {
  "$TEL" emit --executor codex --model fixture-codex --status ok >/dev/null
  "$TEL" emit --executor codex --model fixture-other --status failed >/dev/null
  run "$TEL" validate "$LEGION_TELEMETRY_DIR"/*.jsonl
  [ "$status" -eq 0 ]
  [[ "$output" == *"valid"* ]]
}

@test "telemetry: validate fails (exit 1) on a bad span via stdin" {
  run bash -c "printf '%s\n' '{\"not\":\"a span\"}' | '$TEL' validate -"
  [ "$status" -eq 1 ]
}

@test "telemetry: validate passes a good span via stdin" {
  span="$("$TEL" emit --executor codex --model fixture-codex --status ok)"
  run bash -c "printf '%s\n' '$span' | '$TEL' validate -"
  [ "$status" -eq 0 ]
}

@test "telemetry: validate catches a bad final line with no trailing newline" {
  printf '%s\n%s' \
    '{"schema":"legion.span.v1","ts":"t","run_id":"r","executor":"e","model":"m","status":"ok"}' \
    '{"bad":1}' > "$BATS_TEST_TMPDIR/nonl.jsonl"
  run "$TEL" validate "$BATS_TEST_TMPDIR/nonl.jsonl"
  [ "$status" -eq 1 ]
}

@test "telemetry: validate rejects unknown status" {
  run bash -c "printf '%s\n' '{\"schema\":\"legion.span.v1\",\"ts\":\"t\",\"run_id\":\"r\",\"executor\":\"e\",\"model\":\"m\",\"status\":\"definitely_not_valid\"}' | '$TEL' validate -"
  [ "$status" -eq 1 ]
}

@test "telemetry: validate rejects negative cost or duration" {
  run bash -c "printf '%s\n' '{\"schema\":\"legion.span.v1\",\"ts\":\"t\",\"run_id\":\"r\",\"executor\":\"e\",\"model\":\"m\",\"status\":\"ok\",\"duration_ms\":-1,\"cost_usd\":0}' | '$TEL' validate -"
  [ "$status" -eq 1 ]
  run bash -c "printf '%s\n' '{\"schema\":\"legion.span.v1\",\"ts\":\"t\",\"run_id\":\"r\",\"executor\":\"e\",\"model\":\"m\",\"status\":\"ok\",\"duration_ms\":1,\"cost_usd\":-0.1}' | '$TEL' validate -"
  [ "$status" -eq 1 ]
}

@test "telemetry: unknown subcommand exits 2" {
  run "$TEL" frobnicate
  [ "$status" -eq 2 ]
}
