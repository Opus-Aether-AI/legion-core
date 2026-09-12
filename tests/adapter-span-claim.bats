#!/usr/bin/env bats

load 'helpers/setup'

setup() {
  setup_test_env
  SPAN_CLAIM_PUBLISHER_PID=""
  export LEGION_TELEMETRY_DIR="$TEST_TMPDIR/spans"
  mkdir -p "$LEGION_TELEMETRY_DIR"
  export CONTRACT="$REPO_ROOT/legion-router/scripts/lib/adapter-contract.sh"
  export ATTEMPT="$TEST_TMPDIR/attempt-1.json"
  export ATTEMPT_DATE="$(date -u +%F)"
  export SPAN_FILE="$LEGION_TELEMETRY_DIR/$ATTEMPT_DATE.jsonl"
  # Produce the same canonical provider receipt as the real adapters so the
  # durability check can bind telemetry identity and metering, not just a path.
  source "$CONTRACT"
  export RUN_ID=fixture-run
  legion_adapter_write_attempt "$TEST_TMPDIR" cursor cursor 1 fixture-model fixture-model \
    "" "" read-only succeeded "$ATTEMPT_DATE"T00:00:00Z \
    "$ATTEMPT_DATE"T00:00:01Z 1 '{}' unknown '' 0 unknown '' '' false false '' ''
  SPAN_PAYLOAD="$(jq -cn --arg attempt "$ATTEMPT" --arg date "$ATTEMPT_DATE" \
    '{schema:"legion.span.v1",ts:($date+"T00:00:01Z"),run_id:"fixture-run",
      executor:"cursor",model:"fixture-model",status:"ok",duration_ms:1,
      cost_usd:null,cost_status:"unknown",tokens:null,usage_status:"unknown",
      artifacts:{provider_attempt:true,attempt_receipt:$attempt}}')"
  export SPAN_PAYLOAD
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
      printf "%s\n" "$SPAN_PAYLOAD" >> "$LEGION_TELEMETRY_DIR/${LEGION_ADAPTER_SPAN_DATE:-2026-09-12}.jsonl"
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
  [ "$(wc -l < "$SPAN_FILE" | tr -d ' ')" -eq 1 ]
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
      printf "%s\n" "$SPAN_PAYLOAD" >> "$LEGION_TELEMETRY_DIR/${LEGION_ADAPTER_SPAN_DATE:-2026-09-12}.jsonl"
    }
    legion_adapter_emit_normal_provider_span "$attempt"
  ' _ "$CONTRACT" "$LEGION_TELEMETRY_DIR" "$ATTEMPT"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$SPAN_FILE" | tr -d ' ')" -eq 1 ]
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
        printf "%s\n" "$SPAN_PAYLOAD" >> "$LEGION_TELEMETRY_DIR/${LEGION_ADAPTER_SPAN_DATE:-2026-09-12}.jsonl"
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
  [ "$(wc -l < "$SPAN_FILE" | tr -d ' ')" -eq 1 ]
}

@test "malformed trailing telemetry cannot hide an already durable provider span" {
  local calls="$TEST_TMPDIR/malformed-tail-calls"
  # Historical telemetry is not part of this attempt's lookup. A global rescan
  # would block on this FIFO; the attempt-bound recovery reads only its date.
  mkfifo "$LEGION_TELEMETRY_DIR/1900-01-01.jsonl"
  printf '%s\n' "$SPAN_PAYLOAD" > "$SPAN_FILE"
  printf '%s\n' '{malformed trailing record' >> "$SPAN_FILE"
  printf '%s\n' '"structurally malformed record"' >> "$SPAN_FILE"

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
  [ "$(wc -l < "$SPAN_FILE" | tr -d ' ')" -eq 3 ]
  jq -e --arg attempt "$ATTEMPT" --arg telemetry "$(realpath "$SPAN_FILE")" '
    .schema == "legion.provider-span-ack.v1"
    and .attempt_receipt == $attempt and .telemetry_path == $telemetry
    and (.offset | type) == "number" and (.length | type) == "number"
    and (.span_sha256 | test("^[a-f0-9]{64}$"))
  ' "$ATTEMPT.provider-span-ack"
}

@test "a schema-invalid matching impostor cannot suppress the real provider span" {
  jq -cn --arg attempt "$ATTEMPT" \
    '{schema:"legion.span.v1",artifacts:{provider_attempt:true,attempt_receipt:$attempt}}' \
    > "$SPAN_FILE"
  printf '%s\n' "$SPAN_PAYLOAD" >> "$SPAN_FILE"

  run bash -c '
    source "$1"
    legion_adapter_provider_span_is_durable "$2"
  ' _ "$CONTRACT" "$ATTEMPT"
  [ "$status" -eq 0 ]
  jq -e '.offset > 0' "$ATTEMPT.provider-span-ack"
}

@test "a canonical but foreign run span cannot acknowledge this provider attempt" {
  jq -c '.run_id="another-paid-run"' <<<"$SPAN_PAYLOAD" > "$SPAN_FILE"
  printf '%s\n' "$SPAN_PAYLOAD" >> "$SPAN_FILE"
  run bash -c 'source "$1"; legion_adapter_provider_span_is_durable "$2"' _ "$CONTRACT" "$ATTEMPT"
  [ "$status" -eq 0 ]
  jq -e '.offset > 0' "$ATTEMPT.provider-span-ack"
}

@test "malformed acknowledgement paths cannot block on a FIFO or read outside telemetry" {
  printf '%s\n' "$SPAN_PAYLOAD" > "$SPAN_FILE"
  run bash -c 'source "$1"; legion_adapter_provider_span_is_durable "$2"' _ "$CONTRACT" "$ATTEMPT"
  [ "$status" -eq 0 ]
  local outside="$TEST_TMPDIR/outside.jsonl" fifo="$TEST_TMPDIR/blocked-fifo"
  printf '%s\n' "$SPAN_PAYLOAD" > "$outside"
  mkfifo "$fifo"
  for target in "$outside" "$fifo"; do
    jq --arg target "$target" '.telemetry_path=$target' "$ATTEMPT.provider-span-ack" \
      > "$TEST_TMPDIR/replaced-ack"
    mv "$TEST_TMPDIR/replaced-ack" "$ATTEMPT.provider-span-ack"
    run python3 - "$CONTRACT" "$ATTEMPT" <<'PY'
import subprocess
import sys

result = subprocess.run(
    ["bash", "-c", 'source "$1"; legion_adapter_provider_span_is_durable "$2"',
     "_", sys.argv[1], sys.argv[2]],
    timeout=5,
)
raise SystemExit(result.returncode)
PY
    [ "$status" -eq 0 ]
    jq -e --arg telemetry "$(realpath "$SPAN_FILE")" '.telemetry_path == $telemetry' \
      "$ATTEMPT.provider-span-ack"
  done
}

@test "a canonical telemetry leaf replaced with a FIFO fails promptly" {
  printf '%s\n' "$SPAN_PAYLOAD" > "$SPAN_FILE"
  run bash -c 'source "$1"; legion_adapter_provider_span_is_durable "$2"' _ "$CONTRACT" "$ATTEMPT"
  [ "$status" -eq 0 ]
  mv "$SPAN_FILE" "$TEST_TMPDIR/old-telemetry"
  mkfifo "$SPAN_FILE"
  run python3 - "$CONTRACT" "$ATTEMPT" <<'PY'
import subprocess
import sys

result = subprocess.run(
    ["bash", "-c", 'source "$1"; legion_adapter_provider_span_is_durable "$2"',
     "_", sys.argv[1], sys.argv[2]],
    timeout=5,
)
raise SystemExit(result.returncode)
PY
  [ "$status" -eq 1 ]
}

@test "append intent recovers a span after more than one MiB of later telemetry" {
  run bash -c '
    set -euo pipefail
    source "$1"
    emit_span() { printf "%s\n" "$SPAN_PAYLOAD" >> "$LEGION_TELEMETRY_DIR/$LEGION_ADAPTER_SPAN_DATE.jsonl"; }
    legion_adapter_emit_normal_provider_span "$2"
    span_path="$(jq -r '\''.telemetry_path'\'' "$2.provider-span-intent")"
    rm "$2.provider-span-ack"
    dd if=/dev/zero bs=1024 count=1025 2>/dev/null \
      >> "$span_path"
    printf "\n" >> "$span_path"
    legion_adapter_provider_span_is_durable "$2"
    jq -e '\''.offset >= 0'\'' "$2.provider-span-ack"
    [[ "$(head -n 1 "$span_path")" == "$SPAN_PAYLOAD" ]]
  ' _ "$CONTRACT" "$ATTEMPT"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }
}

@test "a nonempty telemetry file preserves the first span at the append intent boundary" {
  jq -c '.artifacts.attempt_receipt="unrelated-attempt"' <<<"$SPAN_PAYLOAD" > "$SPAN_FILE"
  local old_size
  old_size="$(wc -c < "$SPAN_FILE" | tr -d ' ')"
  run bash -c '
    set -euo pipefail
    source "$1"
    emit_span() { printf "%s\n" "$SPAN_PAYLOAD" >> "$LEGION_TELEMETRY_DIR/$LEGION_ADAPTER_SPAN_DATE.jsonl"; }
    legion_adapter_emit_normal_provider_span "$2"
  ' _ "$CONTRACT" "$ATTEMPT"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }
  [ "$(wc -l < "$SPAN_FILE" | tr -d ' ')" -eq 2 ]
  jq -e --argjson offset "$old_size" '.offset == $offset' "$ATTEMPT.provider-span-ack"
}

@test "the append intent binds the actual emission date across an attempt-midnight boundary" {
  jq '.started_at="1999-12-31T23:59:58Z" | .ended_at="1999-12-31T23:59:59Z"' \
    "$ATTEMPT" > "$TEST_TMPDIR/older-attempt"
  mv "$TEST_TMPDIR/older-attempt" "$ATTEMPT"
  run bash -c '
    set -euo pipefail
    source "$1"
    emit_span() { printf "%s\n" "$SPAN_PAYLOAD" >> "$LEGION_TELEMETRY_DIR/$LEGION_ADAPTER_SPAN_DATE.jsonl"; }
    legion_adapter_emit_normal_provider_span "$2"
    jq -e --arg date "$(date -u +%F)" '\''
      .telemetry_path | endswith("/" + $date + ".jsonl")'\'' "$2.provider-span-ack"
  ' _ "$CONTRACT" "$ATTEMPT"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }
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
