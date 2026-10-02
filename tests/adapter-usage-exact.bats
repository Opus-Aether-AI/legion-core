#!/usr/bin/env bats

load 'helpers/setup'

setup() {
  setup_test_env
  export RUN_ID=exact-usage-receipt
  export LEGION_ADAPTER_CONFIG_IDENTITY=test-config
  export LEGION_ADAPTER_PREFLIGHT_CACHE_KEY=test-cache
}

write_attempt() {
  local art="$1" usage="$2"
  mkdir -p "$art"
  bash -c '
    source "$1"
    legion_adapter_write_attempt "$2" opencode opencode 1 \
      openai/fixture-model openai/fixture-model "" "" workspace-write succeeded \
      2026-09-12T00:00:00Z 2026-09-12T00:00:01Z 1000 \
      "$3" known opencode-jsonl 0.01 known opencode-jsonl \
      "" false true "" done
  ' _ "$REPO_ROOT/legion-router/scripts/lib/adapter-contract.sh" "$art" "$usage"
}

@test "canonical attempt serialization preserves odd token integers above 2^53" {
  local art="$TEST_TMPDIR/exact" usage
  usage='{"input_tokens":9007199254740993,"output_tokens":1}'
  run write_attempt "$art" "$usage"
  [ "$status" -eq 0 ]
  python3 - "$art/attempt-1.json" <<'PY'
import json
from pathlib import Path
import sys
receipt = json.loads(Path(sys.argv[1]).read_text())
assert receipt["usage_status"] == "known"
assert receipt["usage"]["input_tokens"] == 9007199254740993
assert receipt["usage"]["output_tokens"] == 1
PY
}

@test "attempt serialization never sends token JSON through jq argjson" {
  local art="$TEST_TMPDIR/jq16" shim="$TEST_TMPDIR/jq16-bin" usage
  mkdir -p "$shim"
  export MOCK_REAL_JQ="$(command -v jq)"
  cat > "$shim/jq" <<'SH'
#!/usr/bin/env bash
args=("$@")
for ((i = 0; i + 2 < ${#args[@]}; i++)); do
  if [[ "${args[i]}" == --argjson && "${args[i+1]}" == usage ]]; then
    args[i+2]="$(python3 - "${args[i+2]}" <<'PY'
import json
import sys
usage = json.loads(sys.argv[1])
for key, value in usage.items():
    if type(value) is int and value > 2**53:
        usage[key] = int(float(value))
print(json.dumps(usage, separators=(",", ":")))
PY
)"
  fi
done
exec "$MOCK_REAL_JQ" "${args[@]}"
SH
  chmod +x "$shim/jq"
  export PATH="$shim:$PATH"
  usage='{"input_tokens":9007199254740993,"output_tokens":1}'
  run write_attempt "$art" "$usage"
  [ "$status" -eq 0 ]
  python3 - "$art/attempt-1.json" <<'PY'
import json
from pathlib import Path
import sys
receipt = json.loads(Path(sys.argv[1]).read_text())
assert receipt["usage"]["input_tokens"] == 9007199254740993
PY
}

@test "malformed token values downgrade instead of becoming known" {
  local art="$TEST_TMPDIR/invalid" usage
  usage='{"input_tokens":true,"output_tokens":-1}'
  run write_attempt "$art" "$usage"
  [ "$status" -eq 0 ]
  jq -e '.usage_status == "unknown" and .usage == null' "$art/attempt-1.json"
}
