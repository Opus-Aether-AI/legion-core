#!/usr/bin/env bats

load 'helpers/setup'

setup() {
  setup_test_env
  export LEGION_TELEMETRY_DIR="$TEST_TMPDIR/spans"
  mkdir -p "$LEGION_TELEMETRY_DIR"
  export CONTRACT="$REPO_ROOT/legion-router/scripts/lib/adapter-contract.sh"
  export ATTEMPT="$TEST_TMPDIR/attempt-1.json"
  printf '{}\n' > "$ATTEMPT"
}

@test "a failed contender never emits while a live publisher owns the claim" {
  local entered="$TEST_TMPDIR/publisher-entered" release="$TEST_TMPDIR/release"
  local calls="$TEST_TMPDIR/calls" publisher

  bash -c '
    set -euo pipefail
    source "$1"
    LEGION_TELEMETRY_DIR="$2"
    attempt="$3" calls="$4" entered="$5" release="$6"
    emit_span() {
      printf "publisher\n" >> "$calls"
      : > "$entered"
      while [[ ! -f "$release" ]]; do sleep 0.02; done
      jq -cn --arg attempt "$attempt" \
        '\''{schema:"legion.span.v1",artifacts:{provider_attempt:true,attempt_receipt:$attempt}}'\'' \
        >> "$LEGION_TELEMETRY_DIR/spans.jsonl"
    }
    legion_adapter_emit_normal_provider_span "$attempt"
  ' _ "$CONTRACT" "$LEGION_TELEMETRY_DIR" "$ATTEMPT" "$calls" "$entered" "$release" &
  publisher=$!
  for _ in $(seq 1 100); do
    [[ -f "$entered" ]] && break
    sleep 0.02
  done
  [ -f "$entered" ]

  run env LEGION_ADAPTER_PROVIDER_SPAN_CLAIM_WAIT_MILLISECONDS=150 \
    bash -c '
      set -euo pipefail
      source "$1"
      LEGION_TELEMETRY_DIR="$2"
      attempt="$3" calls="$4"
      emit_span() { printf "contender\n" >> "$calls"; }
      ! legion_adapter_emit_normal_provider_span "$attempt"
    ' _ "$CONTRACT" "$LEGION_TELEMETRY_DIR" "$ATTEMPT" "$calls"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^contender$' "$calls" || true)" -eq 0 ]

  : > "$release"
  wait "$publisher"
  [ "$(grep -c '^publisher$' "$calls")" -eq 1 ]
  [ "$(wc -l < "$LEGION_TELEMETRY_DIR/spans.jsonl" | tr -d ' ')" -eq 1 ]
}

@test "a dead publisher claim is reclaimed before publication" {
  run bash -c '
    set -euo pipefail
    source "$1"
    legion_adapter_claim_provider_span "$2"
  ' _ "$CONTRACT" "$ATTEMPT"
  [ "$status" -eq 0 ]

  run bash -c '
    set -euo pipefail
    source "$1"
    LEGION_TELEMETRY_DIR="$2"
    attempt="$3"
    emit_span() {
      jq -cn --arg attempt "$attempt" \
        '\''{schema:"legion.span.v1",artifacts:{provider_attempt:true,attempt_receipt:$attempt}}'\'' \
        >> "$LEGION_TELEMETRY_DIR/spans.jsonl"
    }
    legion_adapter_emit_normal_provider_span "$attempt"
  ' _ "$CONTRACT" "$LEGION_TELEMETRY_DIR" "$ATTEMPT"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$LEGION_TELEMETRY_DIR/spans.jsonl" | tr -d ' ')" -eq 1 ]
}

@test "concurrent publishers reconcile to exactly one durable provider span" {
  local calls="$TEST_TMPDIR/concurrent-calls" pid rc=0
  local -a pids=()
  for _ in $(seq 1 8); do
    bash -c '
      set -euo pipefail
      source "$1"
      LEGION_TELEMETRY_DIR="$2"
      attempt="$3" calls="$4"
      emit_span() {
        printf "emit\n" >> "$calls"
        sleep 0.1
        jq -cn --arg attempt "$attempt" \
          '\''{schema:"legion.span.v1",artifacts:{provider_attempt:true,attempt_receipt:$attempt}}'\'' \
          >> "$LEGION_TELEMETRY_DIR/spans.jsonl"
      }
      legion_adapter_emit_normal_provider_span "$attempt"
    ' _ "$CONTRACT" "$LEGION_TELEMETRY_DIR" "$ATTEMPT" "$calls" &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do
    wait "$pid" || rc=$?
  done
  [ "$rc" -eq 0 ]
  [ "$(wc -l < "$calls" | tr -d ' ')" -eq 1 ]
  [ "$(wc -l < "$LEGION_TELEMETRY_DIR/spans.jsonl" | tr -d ' ')" -eq 1 ]
}
