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
  echo "$output" | jq -e '
    .run_id != "" and .trace_id == .run_id and .parent_id == null
    and .cost_usd == null and .cost_status == "unknown"
    and .tokens == null and .usage_status == "unknown"'
}

@test "telemetry: emit carries task / trace-id / parent-id / artifacts" {
  run "$TEL" emit --executor codex --model fixture-codex --status ok \
    --task "do x" --trace-id T1 --parent-id P1 --artifacts '{"diff":"d"}'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.task=="do x" and .trace_id=="T1" and .parent_id=="P1" and .artifacts.diff=="d"'
}

@test "telemetry: emit carries an explicit routing archetype" {
  run "$TEL" emit --executor codex --model fixture-codex --status ok \
    --archetype implement-feature
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.archetype == "implement-feature"'
}

@test "telemetry: emit inherits LEGION_ARCHETYPE when no flag is supplied" {
  LEGION_ARCHETYPE=write-tests run "$TEL" emit \
    --executor opencode --model fixture-opencode --status ok
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.archetype == "write-tests"'
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

@test "telemetry: validate accepts a timed_out terminal span" {
  span="$("$TEL" emit --executor codex --model fixture-codex --status timed_out)"
  run bash -c "printf '%s\n' '$span' | '$TEL' validate -"
  [ "$status" -eq 0 ]
}

@test "telemetry: validate accepts a containment_failed terminal span" {
  span="$("$TEL" emit --executor pi --model fixture-pi --status containment_failed)"
  run bash -c "printf '%s\n' '$span' | '$TEL' validate -"
  [ "$status" -eq 0 ]
}

@test "telemetry: validate accepts a refused no-launch span" {
  span="$("$TEL" emit --executor codex --model fixture-codex --status refused)"
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

@test "telemetry: validate enforces cost and usage provenance conditionals" {
  local base='{"schema":"legion.span.v1","ts":"t","run_id":"r","executor":"e","model":"m","status":"ok"}'
  run bash -c "jq -c '. + {cost_usd:null,cost_status:\"unknown\",tokens:null,usage_status:\"unknown\"}' <<<'$base' | '$TEL' validate -"
  [ "$status" -eq 0 ]
  run bash -c "jq -c '. + {cost_usd:0,cost_status:\"unknown\",tokens:null,usage_status:\"unknown\"}' <<<'$base' | '$TEL' validate -"
  [ "$status" -eq 1 ]
  run bash -c "jq -c '. + {cost_usd:null,cost_status:\"partial\",known_cost_usd:0,known_cost_attempts:1,tokens:null,usage_status:\"partial\",known_usage:{input_tokens:0},known_usage_attempts:1}' <<<'$base' | '$TEL' validate -"
  [ "$status" -eq 0 ]
  run bash -c "jq -c '. + {cost_usd:null,cost_status:\"known\",tokens:null,usage_status:\"known\"}' <<<'$base' | '$TEL' validate -"
  [ "$status" -eq 1 ]
}

@test "telemetry: validate rejects malformed companion metering fields for every status" {
  local base='{"schema":"legion.span.v1","ts":"t","run_id":"r","executor":"e","model":"m","status":"ok","cost_usd":0,"cost_status":"known","tokens":{},"usage_status":"known"}'
  for invalid in \
    '{"known_cost_usd":-1}' \
    '{"known_cost_usd":"free"}' \
    '{"known_cost_attempts":-1}' \
    '{"known_cost_attempts":1.5}' \
    '{"known_usage":[]}' \
    '{"known_usage":{"input_tokens":-1}}' \
    '{"known_usage":{"input_tokens":1.5}}' \
    '{"known_usage":{"input_tokens":"many"}}' \
    '{"known_usage_attempts":-1}' \
    '{"known_usage_attempts":true}'; do
    run bash -c "jq -c --argjson invalid '$invalid' '. + \$invalid' <<<'$base' | '$TEL' validate -"
    [ "$status" -eq 1 ]
  done

  run bash -c "jq -c '. + {cost_usd:null,cost_status:\"unknown\",tokens:null,usage_status:\"unknown\",known_cost_attempts:-1,known_usage_attempts:1.5}' <<<'$base' | '$TEL' validate -"
  [ "$status" -eq 1 ]
}

@test "telemetry: validate enforces canonical attempt identity fields" {
  local base='{"schema":"legion.span.v1","ts":"t","run_id":"r","executor":"e","model":"m","status":"ok"}'
  run bash -c "jq -c '. + {attempt_id:\"attempt-1\",attempt_ordinal:1}' <<<'$base' | '$TEL' validate -"
  [ "$status" -eq 0 ]
  run bash -c "jq -c '. + {attempt_id:null,attempt_ordinal:null}' <<<'$base' | '$TEL' validate -"
  [ "$status" -eq 0 ]
  for invalid in \
    '{"attempt_id":""}' \
    '{"attempt_id":7}' \
    '{"attempt_ordinal":0}' \
    '{"attempt_ordinal":1.5}' \
    '{"attempt_ordinal":true}' \
    '{"attempt_ordinal":"1"}'; do
    run bash -c "jq -c --argjson invalid '$invalid' '. + \$invalid' <<<'$base' | '$TEL' validate -"
    [ "$status" -eq 1 ]
  done
}

@test "telemetry: emit derives nullable unknown and not-applicable values" {
  run "$TEL" emit --executor codex --model fixture-codex --status failed \
    --cost-status unknown --usage-status unknown
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '
    .cost_status == "unknown" and .cost_usd == null
    and .usage_status == "unknown" and .tokens == null'

  run "$TEL" emit --executor legion-run --model orchestrator --status ok \
    --cost-status not_applicable --usage-status not_applicable
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '
    .cost_status == "not_applicable" and .cost_usd == null
    and .usage_status == "not_applicable" and .tokens == null'
}

@test "telemetry: emit constructs and validates partial provenance" {
  run "$TEL" emit --executor codex --model fixture-codex --status failed \
    --cost-status partial --known-cost 0.25 --known-cost-attempts 1 \
    --usage-status partial --known-usage '{"input_tokens":7}' \
    --known-usage-attempts 1
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '
    .cost_usd == null and .cost_status == "partial"
    and .known_cost_usd == 0.25 and .known_cost_attempts == 1
    and .tokens == null and .usage_status == "partial"
    and .known_usage.input_tokens == 7 and .known_usage_attempts == 1'
}

@test "telemetry: emit rejects contradictory provenance before append" {
  run "$TEL" emit --executor codex --model fixture-codex --status failed \
    --cost-status unknown --cost 0 --usage-status unknown --tokens '{}'
  [ "$status" -eq 2 ]
  [ -z "$(find "$LEGION_TELEMETRY_DIR" -name '*.jsonl' 2>/dev/null)" ]

  run "$TEL" emit --executor codex --model fixture-codex --status failed \
    --cost-status partial --known-cost 0.25 --known-cost-attempts 0
  [ "$status" -eq 2 ]
  [ -z "$(find "$LEGION_TELEMETRY_DIR" -name '*.jsonl' 2>/dev/null)" ]
}

@test "telemetry: validate rejects a non-string archetype" {
  run bash -c "printf '%s\n' '{\"schema\":\"legion.span.v1\",\"ts\":\"t\",\"run_id\":\"r\",\"executor\":\"codex\",\"model\":\"m\",\"archetype\":7,\"status\":\"ok\"}' | '$TEL' validate -"
  [ "$status" -eq 1 ]
}

@test "telemetry: unknown subcommand exits 2" {
  run "$TEL" frobnicate
  [ "$status" -eq 2 ]
}
