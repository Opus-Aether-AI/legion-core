#!/usr/bin/env bats

load 'helpers/setup'

setup() {
  setup_test_env
  export LEGION_STATE_ROOT="$TEST_TMPDIR/state"
  export LEGION_TELEMETRY_DIR="$TEST_TMPDIR/spans"
  export LEGION_REGISTRY_DIR="$LEGION_STATE_ROOT/registry"
  export MOCK_REAL_GIT="$(command -v git)"
  export LEGION_EXECUTORS_FILE="$TEST_TMPDIR/executors.toml"
  cp "$REPO_ROOT/legion-router/config/executors.toml" "$LEGION_EXECUTORS_FILE"
  python3 - "$LEGION_EXECUTORS_FILE" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
for executor in ("pi", "hermes"):
    start = text.index(f"[executors.{executor}]")
    end = text.find("\n[executors.", start + 1)
    if end < 0:
        end = len(text)
    section = text[start:end].replace(
        "supported_version_patterns = []",
        'supported_version_patterns = ["^1[.]0[.]0$"]',
        1,
    )
    text = text[:start] + section + text[end:]
path.write_text(text, encoding="utf-8")
PY
}

make_test_repo() {
  local repo="$TEST_TMPDIR/repo-$1"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name test
  printf 'base\n' > "$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -qm init
  printf '%s' "$repo"
}

install_disappearing_provider_sandbox() {
  local shim_dir="$TEST_TMPDIR/disappearing-sandbox"
  mkdir -p "$shim_dir"
  cat > "$shim_dir/sandbox-exec" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == -f && -f "${2:-}" ]]
shift 2
mv "$MOCK_DISAPPEARING_PROVIDER" "$MOCK_DISAPPEARING_PROVIDER.removed"
exec "$@"
SH
  chmod +x "$shim_dir/sandbox-exec"
  export LEGION_FS_SANDBOX_BIN="$shim_dir/sandbox-exec"
}

install_malformed_launch_sandbox() {
  local shim_dir="$TEST_TMPDIR/malformed-sandbox"
  mkdir -p "$shim_dir"
  cat > "$shim_dir/sandbox-exec" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == -f && -f "${2:-}" ]]
shift 2
receipt="$3"
provider="$5"
jq -cn --arg token "$LEGION_PROVIDER_LAUNCH_TOKEN" --arg executable "$provider" '
  {schema:"legion.provider-launch.v1",status:"launch_failed",token:$token,
   executable_path:$executable,reason:"malformed fixture",errno:2,extra:true}
' > "$receipt"
exit 127
SH
  chmod +x "$shim_dir/sandbox-exec"
  export LEGION_FS_SANDBOX_BIN="$shim_dir/sandbox-exec"
}

install_deadline_expiring_sed() {
  local shim_dir="$TEST_TMPDIR/deadline-sed"
  mkdir -p "$shim_dir"
  export MOCK_REAL_SED
  MOCK_REAL_SED="$(command -v sed)"
  export MOCK_REAL_PYTHON
  MOCK_REAL_PYTHON="$(command -v python3)"
  export MOCK_SED_DELAY_MARKER="$TEST_TMPDIR/deadline-sed-used"
  cat > "$shim_dir/sed" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if mkdir "$MOCK_SED_DELAY_MARKER" 2>/dev/null; then
  "$MOCK_REAL_PYTHON" - "$LEGION_CHILD_LEASE_DEADLINE_NS" <<'PY'
import sys
import time

delay = (int(sys.argv[1]) - time.monotonic_ns()) / 1_000_000_000 + 0.1
if delay > 0:
    time.sleep(delay)
PY
fi
exec "$MOCK_REAL_SED" "$@"
SH
  chmod +x "$shim_dir/sed"
  export PATH="$shim_dir:$PATH"
}

install_deadline_expiring_git() {
  local shim_dir="$TEST_TMPDIR/deadline-git-$1"
  mkdir -p "$shim_dir"
  export MOCK_REAL_PYTHON
  MOCK_REAL_PYTHON="$(command -v python3)"
  export MOCK_GIT_DELAY_MARKER="$TEST_TMPDIR/deadline-git-used-$1"
  cat > "$shim_dir/git" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ " $* " == *" worktree add "* ]] && mkdir "$MOCK_GIT_DELAY_MARKER" 2>/dev/null; then
  "$MOCK_REAL_PYTHON" - "$LEGION_CHILD_LEASE_DEADLINE_NS" <<'PY'
import sys
import time

delay = (int(sys.argv[1]) - time.monotonic_ns()) / 1_000_000_000 + 0.1
if delay > 0:
    time.sleep(delay)
PY
fi
exec "$MOCK_REAL_GIT" "$@"
SH
  chmod +x "$shim_dir/git"
  export PATH="$shim_dir:$PATH"
}

assert_typed_pre_provider_timeout() {
  local result_file="$1" expected_reason="$2" repo="$3" adapter="$4"
  jq -e --arg executor "$adapter" --arg reason "$expected_reason" '
    .status == "timed_out" and .executor == $executor
    and (.reason | contains($reason))
    and .attempt_receipt == null and .failure_receipt == null
    and .provider_launch_receipt == null and .provider_exit == null
    and .usage == null and .tokens == null and .usage_status == "not_applicable"
    and .cost_usd == null and .cost_status == "not_applicable"
    and (.worktree | contains("removed"))
  ' "$result_file" || { cat "$result_file" >&2; return 1; }
  local lease
  lease="$(jq -r '.lease_receipt' "$result_file")"
  jq -e --arg reason "$expected_reason" '
    .schema == "legion.child-execution-lease.v1"
    and .status == "launch_failed" and (.reason | contains($reason))
    and (.max_runtime_seconds | type == "number" and . >= 1)
    and (has("child_exit_code") | not)
    and ((keys_unsorted - ["schema","status","reason","max_runtime_seconds"]) | length == 0)
  ' "$lease"
  [ ! -d "$repo/.legion/worktrees" ] \
    || [ -z "$(find "$repo/.legion/worktrees" -mindepth 1 -maxdepth 1 -print -quit)" ]
  [ "$(find "$(dirname "$lease")" -maxdepth 1 -name 'attempt-*.json' | wc -l | tr -d ' ')" -eq 0 ]
  [ "$(find "$(dirname "$lease")" -maxdepth 1 -name 'failure-*.json' | wc -l | tr -d ' ')" -eq 0 ]
  assert_mock_not_called "$adapter"
}

@test "Pi and Hermes preflight refusals use nullable not-applicable metering" {
  local adapter repo
  for adapter in pi hermes; do
    repo="$(make_test_repo "preflight-$adapter")"
    PI_BIN=pi HERMES_BIN=hermes run \
      "$REPO_ROOT/legion-router/bin/legion-$adapter" run --task inspect \
        --model unsupported-fixture-model --repo "$repo" --quiet
    [ "$status" -ne 0 ]
    echo "$output" | jq -e '
      .status == "refused"
      and .attempt_receipt == null and .failure_receipt == null
      and .usage == null and .tokens == null and .usage_status == "not_applicable"
      and .cost_usd == null and .cost_status == "not_applicable"
    '
  done
}

@test "Pi and Hermes expired lease at broker gate is a typed zero-attempt timeout" {
  local adapter repo deadline result_file rc
  for adapter in pi hermes; do
    repo="$(make_test_repo "broker-expired-$adapter")"
    install_deadline_expiring_git "$adapter"
    deadline="$(python3 -c 'import time; print(time.monotonic_ns() + 4_000_000_000)')"
    result_file="$TEST_TMPDIR/$adapter-broker-expired.json"
    rc=0
    LEGION_CHILD_LEASE_DEADLINE_NS="$deadline" PI_BIN=pi HERMES_BIN=hermes \
      "$REPO_ROOT/legion-router/bin/legion-$adapter" run --task inspect \
        --model openai/fixture-model --repo "$repo" --run-id "broker-expired-$adapter" \
        --keep --quiet > "$result_file" 2>/dev/null || rc=$?
    [ "$rc" -eq 1 ]
    assert_typed_pre_provider_timeout \
      "$result_file" "expired before handoff broker launch" "$repo" "$adapter"
  done
}

@test "Pi lease expiring during provider setup is a typed zero-attempt timeout" {
  local repo deadline result_file rc=0
  repo="$(make_test_repo provider-setup-expired-pi)"
  install_deadline_expiring_sed
  deadline="$(python3 -c 'import time; print(time.monotonic_ns() + 4_000_000_000)')"
  result_file="$TEST_TMPDIR/pi-provider-setup-expired.json"
  LEGION_CHILD_LEASE_DEADLINE_NS="$deadline" PI_BIN=pi \
    "$REPO_ROOT/legion-router/bin/legion-pi" run --task inspect \
      --model openai/fixture-pi --repo "$repo" --run-id provider-setup-expired-pi \
      --quiet > "$result_file" 2>/dev/null || rc=$?
  [ "$rc" -eq 1 ]
  assert_typed_pre_provider_timeout \
    "$result_file" "expired during provider launch setup" "$repo" pi
}

@test "Pi and Hermes authenticate provider disappearance after admission as no-spend" {
  local adapter repo provider run_id result_file lease launch art rc
  for adapter in pi hermes; do
    repo="$(make_test_repo "disappears-$adapter")"
    provider="$TEST_TMPDIR/$adapter-provider"
    cp "$REPO_ROOT/tests/mocks/bin/$adapter" "$provider"
    chmod +x "$provider"
    provider="$(cd "${provider%/*}" && pwd -P)/${provider##*/}"
    export MOCK_DISAPPEARING_PROVIDER="$provider"
    install_disappearing_provider_sandbox
    run_id="disappears-$adapter"
    result_file="$TEST_TMPDIR/$adapter-disappears.json"
    rc=0
    if [[ "$adapter" == pi ]]; then
      PI_BIN="$provider" "$REPO_ROOT/legion-router/bin/legion-pi" run --task inspect \
        --repo "$repo" --run-id "$run_id" --quiet > "$result_file" 2>/dev/null || rc=$?
    else
      HERMES_BIN="$provider" "$REPO_ROOT/legion-router/bin/legion-hermes" run --task inspect \
        --repo "$repo" --run-id "$run_id" --quiet > "$result_file" 2>/dev/null || rc=$?
    fi
    [ "$rc" -ne 0 ]
    jq -e --arg executor "$adapter" '
      .status == "failed" and .executor == $executor and .provider_exit == 127
      and .attempt_receipt == null and .failure_receipt == null
      and .usage == null and .tokens == null and .usage_status == "not_applicable"
      and .cost_usd == null and .cost_status == "not_applicable"
      and (.reason | contains("provider launch failed before process creation"))
      and (.provider_launch_receipt | type == "string" and length > 0)
    ' "$result_file"
    lease="$(jq -r '.lease_receipt' "$result_file")"
    launch="$(jq -r '.provider_launch_receipt' "$result_file")"
    jq -e '.status == "completed" and .child_exit_code == 127' "$lease"
    jq -e --arg executable "$provider" '
      .schema == "legion.provider-launch.v1" and .status == "launch_failed"
      and .executable_path == $executable and (.token | length == 64)
      and (has("child_exit_code") | not)
    ' "$launch"
    art="$repo/.legion/runs/$run_id"
    [ "$(find "$art" -maxdepth 1 -name 'attempt-*.json' | wc -l | tr -d ' ')" -eq 0 ]
    [ "$(find "$art" -maxdepth 1 -name 'failure-*.json' | wc -l | tr -d ' ')" -eq 0 ]
  done
  if compgen -G "$LEGION_TELEMETRY_DIR/*.jsonl" >/dev/null; then
    run jq -s -e '[.[] | select(.artifacts.provider_attempt == true)] | length > 0' \
      "$LEGION_TELEMETRY_DIR"/*.jsonl
    [ "$status" -ne 0 ]
  fi
}

@test "malformed inner no-launch evidence fails closed as a provider attempt" {
  local repo result attempt launch
  repo="$(make_test_repo malformed)"
  install_malformed_launch_sandbox

  run env PI_BIN=pi "$REPO_ROOT/legion-router/bin/legion-pi" run --task inspect \
    --repo "$repo" --run-id malformed-launch --quiet
  [ "$status" -ne 0 ]
  result="$output"
  echo "$result" | jq -e '
    .status == "failed" and .provider_exit == 127
    and (.attempt_receipt | type == "string")
    and (.failure_receipt | type == "string")
    and .provider_launch_receipt == null
  '
  attempt="$(echo "$result" | jq -r '.attempt_receipt')"
  jq -e '.terminal_status == "failed" and .failure.class == "provider"' "$attempt"
  launch="$(dirname "$(echo "$result" | jq -r '.lease_receipt')")/tmp/provider-launch.json"
  jq -e '.status == "launch_failed" and .extra == true' "$launch"
  jq -s -e '[.[] | select(.artifacts.provider_attempt == true)] | length == 1' \
    "$LEGION_TELEMETRY_DIR"/*.jsonl
}

@test "a provider that really launches and exits 127 remains a billable attempt" {
  local repo provider result attempt lease
  repo="$(make_test_repo provider-127)"
  provider="$TEST_TMPDIR/pi-exits-127"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ "${1:-}" == --version ]]; then printf "pi 1.0.0\n"; exit 0; fi' \
    'exit 127' > "$provider"
  chmod +x "$provider"

  run env PI_BIN="$provider" "$REPO_ROOT/legion-router/bin/legion-pi" run --task inspect \
    --repo "$repo" --run-id provider-exits-127 --quiet
  [ "$status" -ne 0 ]
  result="$output"
  echo "$result" | jq -e '
    .status == "failed" and .provider_exit == 127
    and (.attempt_receipt | type == "string")
    and (.failure_receipt | type == "string")
    and .provider_launch_receipt == null
  '
  attempt="$(echo "$result" | jq -r '.attempt_receipt')"
  jq -e '.terminal_status == "failed" and .failure.class == "provider"' "$attempt"
  lease="$(echo "$result" | jq -r '.lease_receipt')"
  jq -e '.status == "completed" and .child_exit_code == 127' "$lease"
  [ ! -e "$(dirname "$lease")/tmp/provider-launch.json" ]
}
