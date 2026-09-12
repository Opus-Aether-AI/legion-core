#!/usr/bin/env bats

load 'helpers/setup'

setup() {
  setup_test_env
  export CONTRACT="$REPO_ROOT/legion-router/scripts/lib/adapter-contract.sh"
  export RECEIPTS="$REPO_ROOT/legion-observability/scripts"
  export ART="$TEST_TMPDIR/attempts"
  export RUN_ID=metering-run
  export LEGION_ADAPTER_CONFIG_IDENTITY=test-config
  export LEGION_ADAPTER_PREFLIGHT_CACHE_KEY=test-cache
  export LEGION_ADAPTER_PREVIOUS_ATTEMPT_ID=""
  mkdir -p "$ART"
  # shellcheck disable=SC1090
  source "$CONTRACT"
}

write_attempt() {
  local ordinal="$1" usage="$2" usage_status="$3" usage_source="$4"
  local cost="$5" cost_status="$6" cost_source="$7"
  legion_adapter_write_attempt "$ART" fixture fixture "$ordinal" \
    requested-model effective-model "" "" workspace-write succeeded \
    2026-01-01T00:00:00Z 2026-01-01T00:00:01Z 1000 \
    "$usage" "$usage_status" "$usage_source" \
    "$cost" "$cost_status" "$cost_source" \
    "" false false
}

validate_attempt() {
  PYTHONPATH="$RECEIPTS" python3 - "$1" <<'PY'
import json
import sys

from legion_receipts import validate_attempt

with open(sys.argv[1], encoding="utf-8") as handle:
    validate_attempt(json.load(handle))
PY
}

install_receipt_fsync_fault() {
  local shim_dir="$TEST_TMPDIR/fsync-fault"
  mkdir -p "$shim_dir"
  cat > "$shim_dir/sitecustomize.py" <<'PY'
import os
import stat

original_fsync = os.fsync

def faulting_fsync(fd):
    directory = os.environ.get("LEGION_TEST_FSYNC_DIR")
    prefix = os.environ.get("LEGION_TEST_FSYNC_PREFIX")
    if directory and prefix:
        info = os.fstat(fd)
        if stat.S_ISREG(info.st_mode):
            for entry in os.scandir(directory):
                if entry.name.startswith(prefix):
                    candidate = entry.stat(follow_symlinks=False)
                    if (candidate.st_dev, candidate.st_ino) == (info.st_dev, info.st_ino):
                        raise OSError("injected receipt inode fsync failure")
    return original_fsync(fd)

os.fsync = faulting_fsync
PY
  export PYTHONPATH="$shim_dir:${PYTHONPATH:-}"
  export LEGION_TEST_FSYNC_DIR="$ART"
}

@test "valid known provider metering is canonicalized and remains known" {
  write_attempt 1 '{"output_tokens":2,"input_tokens":1}' known provider_api \
    1.2300 known provider_api

  jq -e '
    .terminal_status == "succeeded"
    and .usage == {"input_tokens":1,"output_tokens":2}
    and .usage_status == "known"
    and .usage_source == "provider_api"
    and .cost_usd == 1.2300
    and .cost_status == "known"
    and .cost_source == "provider_api"
  ' "$ART/attempt-1.json"
  validate_attempt "$ART/attempt-1.json"
}

@test "malformed known usage degrades to unknown without poisoning valid cost" {
  local ordinal=0 usage attempt
  local -a invalid_usage=(
    '{"input_tokens":-1}'
    '{"input_tokens":1.5}'
    '{"input_tokens":1.0}'
    '{"input_tokens":true}'
    '{"input_tokens":1e999}'
    '{"input_tokens":[]}'
    '{"":1}'
    '[]'
    '"not-an-object"'
    '{'
    'null null'
  )

  for usage in "${invalid_usage[@]}"; do
    ordinal=$((ordinal + 1))
    write_attempt "$ordinal" "$usage" known provider_api 0.25 known provider_api
    attempt="$ART/attempt-$ordinal.json"
    jq -e '
      .terminal_status == "succeeded"
      and .usage == null
      and .usage_status == "unknown"
      and .usage_source == null
      and .cost_usd == 0.25
      and .cost_status == "known"
    ' "$attempt"
    validate_attempt "$attempt"
  done
}

@test "malformed known cost degrades to unknown without poisoning valid usage" {
  local ordinal=0 cost attempt
  local -a invalid_cost=(
    '-0.01'
    '"0.25"'
    '{}'
    '[]'
    'true'
    'NaN'
    'Infinity'
    '1e999'
    '{'
    '0.1 0.2'
  )

  for cost in "${invalid_cost[@]}"; do
    ordinal=$((ordinal + 1))
    write_attempt "$ordinal" '{"input_tokens":4}' known provider_api \
      "$cost" known provider_api
    attempt="$ART/attempt-$ordinal.json"
    jq -e '
      .terminal_status == "succeeded"
      and .usage == {"input_tokens":4}
      and .usage_status == "known"
      and .cost_usd == null
      and .cost_status == "unknown"
      and .cost_source == null
    ' "$attempt"
    validate_attempt "$attempt"
  done
}

@test "missing known provenance and invalid provider statuses degrade to unknown" {
  write_attempt 1 '{"input_tokens":1}' known "" 0.25 known ""
  write_attempt 2 '{"input_tokens":1}' partial mixed 0.25 typo mixed

  for attempt in "$ART/attempt-1.json" "$ART/attempt-2.json"; do
    jq -e '
      .terminal_status == "succeeded"
      and .usage == null
      and .usage_status == "unknown"
      and .usage_source == null
      and .cost_usd == null
      and .cost_status == "unknown"
      and .cost_source == null
    ' "$attempt"
    validate_attempt "$attempt"
  done
}

@test "unknown and not-applicable metering discard stale values and sources" {
  write_attempt 1 '{"input_tokens":99}' unknown stale 9.99 unknown stale
  write_attempt 2 '{"input_tokens":99}' not_applicable stale 9.99 not_applicable stale

  jq -e '
    .usage == null and .usage_status == "unknown" and .usage_source == null
    and .cost_usd == null and .cost_status == "unknown" and .cost_source == null
  ' "$ART/attempt-1.json"
  jq -e '
    .usage == null and .usage_status == "not_applicable" and .usage_source == null
    and .cost_usd == null and .cost_status == "not_applicable" and .cost_source == null
  ' "$ART/attempt-2.json"
  validate_attempt "$ART/attempt-1.json"
  validate_attempt "$ART/attempt-2.json"
}

@test "unknown malformed telemetry is excluded from reconciliation totals" {
  write_attempt 1 '{"input_tokens":3}' known provider_api 0.25 known provider_api
  write_attempt 2 '{"input_tokens":-100}' known provider_api -50 known provider_api

  PYTHONPATH="$RECEIPTS" python3 - "$ART/attempt-1.json" "$ART/attempt-2.json" <<'PY'
import json
import sys

from legion_receipts import reconcile_attempts, validate_attempt

attempts = []
for path in sys.argv[1:]:
    with open(path, encoding="utf-8") as handle:
        attempt = json.load(handle)
    validate_attempt(attempt)
    attempts.append(attempt)

total = reconcile_attempts(attempts)
assert total["usage_status"] == "partial"
assert total["known_usage"] == {"input_tokens": 3}
assert total["known_usage_attempts"] == 1
assert total["cost_status"] == "partial"
assert total["known_cost_usd"] == 0.25
assert total["known_cost_attempts"] == 1
PY
}

@test "receipt publication refuses a symlinked alias without touching its target" {
  local victim="$TEST_TMPDIR/victim.json"
  printf 'untouched\n' > "$victim"
  ln -s "$victim" "$ART/attempt.json"

  run write_attempt 1 '{}' unknown '' 0 unknown ''
  [ "$status" -ne 0 ]
  [ "$(cat "$victim")" = untouched ]
  [ -L "$ART/attempt.json" ]
  [ ! -e "$ART/attempt-1.json" ]
}

@test "numbered attempt publication is exclusive and preserves the first receipt" {
  write_attempt 1 '{"input_tokens":2}' known provider_api 0.5 known provider_api
  local original="$TEST_TMPDIR/original.json"
  cp "$ART/attempt-1.json" "$original"

  run write_attempt 1 '{"input_tokens":99}' known provider_api 99 known provider_api
  [ "$status" -ne 0 ]
  cmp -s "$original" "$ART/attempt-1.json"
  cmp -s "$original" "$ART/attempt.json"
}

@test "receipt publication refuses symlinked failure leaves without touching target" {
  local victim="$TEST_TMPDIR/victim-failure.json"
  printf 'untouched\n' > "$victim"
  ln -s "$victim" "$ART/failure.json"

  run legion_adapter_write_attempt "$ART" fixture fixture 1 \
    requested-model effective-model "" "" workspace-write failed \
    2026-01-01T00:00:00Z 2026-01-01T00:00:01Z 1000 \
    '{}' unknown '' 0 unknown '' provider_error false false 1 provider-error
  [ "$status" -ne 0 ]
  [ "$(cat "$victim")" = untouched ]
  [ -L "$ART/failure.json" ]
  [ ! -e "$ART/failure-1.json" ]
  [ ! -e "$ART/attempt-1.json" ]
}

@test "post-attempt containment is a separate receipt and cannot reclassify a numbered attempt" {
  local original="$TEST_TMPDIR/original-attempt.json"
  write_attempt 1 '{"input_tokens":2}' known provider_api 0.5 known provider_api
  cp "$ART/attempt-1.json" "$original"

  legion_adapter_fail_recorded_attempt "$ART" fixture 1 internal 70 'post-attempt cleanup failed'
  cmp -s "$original" "$ART/attempt-1.json"
  cmp -s "$original" "$ART/attempt.json"
  jq -e --arg attempt "$(jq -r .attempt_id "$original")" '
    .schema == "legion.failure.v1" and .attempt_id == $attempt
    and .class == "internal" and .message == "post-attempt cleanup failed"
  ' "$ART/post-attempt-failure-1.json"
  cmp -s "$ART/post-attempt-failure-1.json" "$ART/failure.json"
  [ "$LEGION_ADAPTER_FAILURE_PATH" = "$ART/post-attempt-failure-1.json" ]
}

@test "post-attempt failure refuses symlinked leaves and leaves targets untouched" {
  local victim="$TEST_TMPDIR/post-attempt-victim" original="$TEST_TMPDIR/original-attempt.json"
  write_attempt 1 '{}' unknown '' 0 unknown ''
  cp "$ART/attempt-1.json" "$original"
  printf 'untouched\n' > "$victim"
  ln -s "$victim" "$ART/post-attempt-failure-1.json"

  run legion_adapter_fail_recorded_attempt "$ART" fixture 1 internal 70 cleanup-failed
  [ "$status" -ne 0 ]
  [ "$(cat "$victim")" = untouched ]
  cmp -s "$original" "$ART/attempt-1.json"
  [ ! -e "$ART/failure.json" ]
}

@test "post-attempt publication ignores predictable legacy temp symlinks" {
  local victim="$TEST_TMPDIR/legacy-temp-victim"
  write_attempt 1 '{}' unknown '' 0 unknown ''
  printf 'untouched\n' > "$victim"
  ln -s "$victim" "$ART/attempt-1.json.tmp.$$"
  ln -s "$victim" "$ART/failure-1.json.tmp.$$"

  legion_adapter_fail_recorded_attempt "$ART" fixture 1 internal 70 cleanup-failed
  [ "$(cat "$victim")" = untouched ]
  jq -e '.class == "internal"' "$ART/post-attempt-failure-1.json"
}

@test "post-attempt publication refuses a symlinked failure alias" {
  local victim="$TEST_TMPDIR/alias-victim"
  write_attempt 1 '{}' unknown '' 0 unknown ''
  printf 'untouched\n' > "$victim"
  ln -s "$victim" "$ART/failure.json"

  run legion_adapter_fail_recorded_attempt "$ART" fixture 1 internal 70 cleanup-failed
  [ "$status" -ne 0 ]
  [ "$(cat "$victim")" = untouched ]
  [ ! -e "$ART/post-attempt-failure-1.json" ]
}

@test "numbered attempt is not published when its inode cannot be fsynced" {
  install_receipt_fsync_fault
  export LEGION_TEST_FSYNC_PREFIX='.attempt-1.'
  run write_attempt 1 '{}' unknown '' 0 unknown ''
  [ "$status" -ne 0 ]
  [ ! -e "$ART/attempt-1.json" ]
  [ ! -e "$ART/attempt.json" ]
}

@test "numbered failure and attempt stay unpublished when failure inode fsync fails" {
  install_receipt_fsync_fault
  export LEGION_TEST_FSYNC_PREFIX='.failure-1.'
  run legion_adapter_write_attempt "$ART" fixture fixture 1 \
    requested-model effective-model "" "" workspace-write failed \
    2026-01-01T00:00:00Z 2026-01-01T00:00:01Z 1000 \
    '{}' unknown '' 0 unknown '' provider_error false false 1 provider-error
  [ "$status" -ne 0 ]
  [ ! -e "$ART/failure-1.json" ]
  [ ! -e "$ART/attempt-1.json" ]
}

@test "final-gate no-launch evidence is not published when fsync fails" {
  install_receipt_fsync_fault
  export LEGION_TEST_FSYNC_PREFIX='.final-gate-lease.'
  local lease="$ART/lease.json"
  run legion_adapter_write_final_gate_no_launch "$lease" 30 15
  [ "$status" -ne 0 ]
  [ ! -e "$lease" ]
}

@test "preflight alias is not published when its temporary inode cannot be fsynced" {
  install_receipt_fsync_fault
  export LEGION_TEST_FSYNC_PREFIX='.pi-preflight.'
  run legion_adapter_preflight pi "$ART" workspace-write argv '' '' 0 pi
  [ "$status" -ne 0 ]
  [ ! -e "$ART/pi-preflight.json" ]
  [ ! -e "$ART/preflight.json" ]
}

@test "preflight receipt is not replaced when alias temporary fsync fails" {
  install_receipt_fsync_fault
  export LEGION_TEST_FSYNC_PREFIX='.preflight-alias.'
  run legion_adapter_preflight pi "$ART" workspace-write argv '' '' 0 pi
  [ "$status" -ne 0 ]
  [ ! -e "$ART/pi-preflight.json" ]
  [ ! -e "$ART/preflight.json" ]
}
