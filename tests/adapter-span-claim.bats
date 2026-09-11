#!/usr/bin/env bats

load 'helpers/setup'

setup() {
  setup_test_env
  SPAN_CLAIM_PUBLISHER_PID=""
  export LEGION_TELEMETRY_DIR="$TEST_TMPDIR/spans"
  mkdir -p "$LEGION_TELEMETRY_DIR"
  export CONTRACT="$REPO_ROOT/legion-router/scripts/lib/adapter-contract.sh"
  export ATTEMPT="$TEST_TMPDIR/attempt-1.json"
  printf '{}\n' > "$ATTEMPT"
}

teardown() {
  if [[ -n "${SPAN_CLAIM_PUBLISHER_PID:-}" ]] && kill -0 "$SPAN_CLAIM_PUBLISHER_PID" 2>/dev/null; then
    kill -TERM "$SPAN_CLAIM_PUBLISHER_PID" 2>/dev/null || true
    wait "$SPAN_CLAIM_PUBLISHER_PID" 2>/dev/null || true
  fi
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
  SPAN_CLAIM_PUBLISHER_PID="$publisher"
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
  SPAN_CLAIM_PUBLISHER_PID=""
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

@test "valid JSON non-object claim owners are malformed and reclaimable" {
  run bash -c '
    set -euo pipefail
    source "$1"
    base="$2"
    index=0
    for payload in "[]" "null"; do
      index=$((index + 1))
      attempt="$base-$index.json"
      printf "{}\n" > "$attempt"
      mkdir -p "$attempt.provider-span-emitted"
      printf "%s\n" "$payload" > "$attempt.provider-span-emitted/owner.json"
      legion_adapter_claim_provider_span "$attempt"
      jq -e "type == \"object\"
        and .schema == \"legion.provider-span-claim.v1\"
        and (.publisher_pid | type) == \"number\"
        and (.publisher_incarnation | type) == \"string\"
        and (.token | test(\"^[0-9a-f]{48}$\"))" \
        "$attempt.provider-span-emitted/owner.json" >/dev/null
      legion_adapter_release_provider_span_claim "$attempt"
    done
  ' _ "$CONTRACT" "$TEST_TMPDIR/non-object-owner"

  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }
}

@test "claim owner reads reject links FIFOs and oversized files without blocking or touching targets" {
  run bash -c '
    set -euo pipefail
    source "$1"
    base="$2"
    for kind in symlink hardlink fifo oversized; do
      attempt="$base-$kind.json"
      claim="$attempt.provider-span-emitted"
      owner="$claim/owner.json"
      victim="$base-$kind.victim"
      printf "{}\n" > "$attempt"
      mkdir -p "$claim"
      printf "do-not-touch-%s\n" "$kind" > "$victim"
      case "$kind" in
        symlink) ln -s "$victim" "$owner" ;;
        hardlink) ln "$victim" "$owner" ;;
        fifo) mkfifo "$owner" ;;
        oversized) python3 -c '\''print("x" * 4097)'\'' > "$owner" ;;
      esac
      legion_adapter_claim_provider_span "$attempt"
      jq -e '\''
        .schema == "legion.provider-span-claim.v1"
        and (.publisher_pid | type) == "number"
        and (.publisher_incarnation | type) == "string"
        and (.token | test("^[0-9a-f]{48}$"))
      '\'' "$owner" >/dev/null
      [[ "$(cat "$victim")" == "do-not-touch-$kind" ]]
      legion_adapter_release_provider_span_claim "$attempt"
    done

    # Release must also refuse a replaced owner path rather than following or
    # unlinking a target selected after acquisition.
    attempt="$base-release.json"
    victim="$base-release.victim"
    printf "{}\n" > "$attempt"
    printf "release-target\n" > "$victim"
    legion_adapter_claim_provider_span "$attempt"
    owner="$attempt.provider-span-emitted/owner.json"
    rm -f "$owner"; ln -s "$victim" "$owner"
    legion_adapter_release_provider_span_claim "$attempt"
    [[ -L "$owner" ]]
    [[ "$(cat "$victim")" == release-target ]]
  ' _ "$CONTRACT" "$TEST_TMPDIR/unsafe-owner"

  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }
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

@test "malformed trailing telemetry cannot hide an already durable provider span" {
  local calls="$TEST_TMPDIR/malformed-tail-calls"
  jq -cn --arg attempt "$ATTEMPT" \
    '{schema:"legion.span.v1",artifacts:{provider_attempt:true,attempt_receipt:$attempt}}' \
    > "$LEGION_TELEMETRY_DIR/spans.jsonl"
  printf '%s\n' '{malformed trailing record' >> "$LEGION_TELEMETRY_DIR/spans.jsonl"
  printf '%s\n' '"structurally malformed record"' >> "$LEGION_TELEMETRY_DIR/spans.jsonl"

  run bash -c '
    set -euo pipefail
    source "$1"
    LEGION_TELEMETRY_DIR="$2"
    calls="$4"
    emit_span() { printf "duplicate\n" >> "$calls"; }
    legion_adapter_emit_normal_provider_span "$3"
  ' _ "$CONTRACT" "$LEGION_TELEMETRY_DIR" "$ATTEMPT" "$calls"

  [ "$status" -eq 0 ]
  [ ! -e "$calls" ]
  [ "$(wc -l < "$LEGION_TELEMETRY_DIR/spans.jsonl" | tr -d ' ')" -eq 3 ]
}

@test "process incarnation reclaims a same-PID collision while legacy live owners remain conservative" {
  run bash -c '
    set -euo pipefail
    source "$1"
    attempt="$2"
    claim="$attempt.provider-span-emitted"
    mkdir -p "$claim"

    legion_adapter_claim_provider_span "$attempt"
    incarnation="$(jq -r .publisher_incarnation "$claim/owner.json")"
    legion_adapter_release_provider_span_claim "$attempt"
    case "$incarnation" in
      linux:*) collision="${incarnation%:*}:$(( ${incarnation##*:} + 1 ))" ;;
      darwin:*) collision="${incarnation%:*}:$(( ${incarnation##*:} + 1 ))" ;;
      *) exit 1 ;;
    esac
    jq -cn --argjson pid "$$" --arg incarnation "$collision" \
      '\''{schema:"legion.provider-span-claim.v1",publisher_pid:$pid,
          publisher_incarnation:$incarnation,
          token:"111111111111111111111111111111111111111111111111"}'\'' > "$claim/owner.json"
    legion_adapter_claim_provider_span "$attempt"
    jq -e --arg incarnation "$incarnation" \
      '\''.publisher_incarnation == $incarnation'\'' "$claim/owner.json"
    legion_adapter_release_provider_span_claim "$attempt"

    jq -cn --argjson pid "$$" \
      '\''{schema:"legion.provider-span-claim.v1",publisher_pid:$pid,token:"legacy"}'\'' \
      > "$claim/owner.json"
    ! legion_adapter_claim_provider_span "$attempt"
  ' _ "$CONTRACT" "$ATTEMPT"

  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }
}

@test "a supervisor token supplies publisher incarnation inside restricted process sandboxes" {
  [[ "$(uname -s)" == Darwin && -x /usr/bin/sandbox-exec ]] || skip "requires Darwin sandbox-exec"
  run /usr/bin/sandbox-exec -p '(version 1) (allow default) (deny process-info*)' bash -c '
    set -euo pipefail
    source "$1"
    attempt="$2"
    export LEGION_SUPERVISOR_TOKEN=0123456789abcdef0123456789abcdef0123456789abcdef
    legion_adapter_claim_provider_span "$attempt"
    jq -e --argjson pid "$$" --arg token "$LEGION_SUPERVISOR_TOKEN" \
      '\''.publisher_pid == $pid
          and .publisher_incarnation == ("supervisor:" + $token + ":pid:" + ($pid | tostring))'\'' \
      "$attempt.provider-span-emitted/owner.json"
    legion_adapter_release_provider_span_claim "$attempt"
  ' _ "$CONTRACT" "$ATTEMPT"

  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }
}

@test "an already-owned claim is reusable by a signal path in the same shell" {
  run bash -c '
    set -euo pipefail
    source "$1"
    legion_adapter_claim_provider_span "$2"
    first_token="$LEGION_ADAPTER_PROVIDER_SPAN_CLAIM_TOKEN"
    first_owner="$(cat "$2.provider-span-emitted/owner.json")"
    legion_adapter_claim_provider_span "$2"
    [[ "$LEGION_ADAPTER_PROVIDER_SPAN_CLAIM_TOKEN" == "$first_token" ]]
    [[ "$(cat "$2.provider-span-emitted/owner.json")" == "$first_owner" ]]
    legion_adapter_release_provider_span_claim "$2"
  ' _ "$CONTRACT" "$ATTEMPT"

  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }
}

@test "a different restricted supervisor cannot reclaim a live supervised owner" {
  [[ "$(uname -s)" == Darwin && -x /usr/bin/sandbox-exec ]] || skip "requires Darwin sandbox-exec"
  local entered="$TEST_TMPDIR/restricted-entered" release="$TEST_TMPDIR/restricted-release" publisher
  env LEGION_SUPERVISOR_TOKEN=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    /usr/bin/sandbox-exec -p '(version 1) (allow default) (deny process-info*)' bash -c '
      set -euo pipefail
      source "$1"
      legion_adapter_claim_provider_span "$2"
      : > "$3"
      while [[ ! -e "$4" ]]; do sleep 0.02; done
      legion_adapter_release_provider_span_claim "$2"
    ' _ "$CONTRACT" "$ATTEMPT" "$entered" "$release" &
  publisher=$!
  SPAN_CLAIM_PUBLISHER_PID="$publisher"
  for _ in $(seq 1 100); do
    [[ -e "$entered" ]] && break
    sleep 0.02
  done
  [ -e "$entered" ]

  run env LEGION_SUPERVISOR_TOKEN=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    /usr/bin/sandbox-exec -p '(version 1) (allow default) (deny process-info*)' bash -c '
      set -euo pipefail
      source "$1"
      ! legion_adapter_claim_provider_span "$2"
    ' _ "$CONTRACT" "$ATTEMPT"
  [ "$status" -eq 0 ]

  : > "$release"
  wait "$publisher"
  SPAN_CLAIM_PUBLISHER_PID=""
}
