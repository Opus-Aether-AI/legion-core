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
provider="$7"
jq -cn --arg executable "$provider" '
  {schema:"legion.provider-launch.v1",status:"launch_failed",token:"untrusted",
   executable_path:$executable,reason:"malformed fixture",errno:2,extra:true}
' > "$receipt"
exit 127
SH
  chmod +x "$shim_dir/sandbox-exec"
  export LEGION_FS_SANDBOX_BIN="$shim_dir/sandbox-exec"
}

install_unsafe_launch_receipt_sandbox() {
  local shim_dir="$TEST_TMPDIR/unsafe-launch-receipt-sandbox"
  mkdir -p "$shim_dir"
  cat > "$shim_dir/sandbox-exec" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == -f && -f "${2:-}" ]]
shift 2
receipt="$3"
rm -f "$receipt"
case "$LEGION_TEST_UNSAFE_LAUNCH_RECEIPT" in
  symlink) ln -s "$LEGION_TEST_LAUNCH_RECEIPT_VICTIM" "$receipt" ;;
  hardlink) ln "$LEGION_TEST_LAUNCH_RECEIPT_VICTIM" "$receipt" ;;
  fifo) mkfifo "$receipt" ;;
  oversized) "$MOCK_REAL_PYTHON" -c 'print("x" * 4097)' > "$receipt" ;;
  *) exit 2 ;;
esac
exit 127
SH
  chmod +x "$shim_dir/sandbox-exec"
  export LEGION_FS_SANDBOX_BIN="$shim_dir/sandbox-exec"
}

install_pending_launch_sandbox() {
  local shim_dir="$TEST_TMPDIR/pending-sandbox"
  mkdir -p "$shim_dir"
  cat > "$shim_dir/sandbox-exec" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == -f && -f "${2:-}" ]]
shift 2
receipt="$3"
token_file="$4"
provider="$7"
python3 - "$receipt" "$provider" "$token_file" <<'PY'
import hashlib
import hmac
import json
from pathlib import Path
import sys

path, executable, token_path = sys.argv[1:]
token = Path(token_path).read_text(encoding="ascii").strip()
Path(token_path).unlink()
payload = {
    "schema": "legion.provider-launch.v1",
    "status": "pending",
    "executable_path": executable,
}

encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
payload["auth"] = hmac.new(token.encode(), encoded, hashlib.sha256).hexdigest()
Path(path).write_text(json.dumps(payload, separators=(",", ":")) + "\n", encoding="utf-8")
PY
: > "$MOCK_PENDING_LAUNCH_READY"
sleep 30
SH
  chmod +x "$shim_dir/sandbox-exec"
  export LEGION_FS_SANDBOX_BIN="$shim_dir/sandbox-exec"
}

install_delayed_started_python() {
  local shim_dir="$TEST_TMPDIR/delayed-start-python"
  mkdir -p "$shim_dir"
  export MOCK_REAL_PYTHON="$(command -v python3)"
  export MOCK_DELAYED_STARTED_HARNESS="$shim_dir/delayed-started-harness.py"
  cat > "$MOCK_DELAYED_STARTED_HARNESS" <<'PY'
import importlib.util
from pathlib import Path
import os
import sys
import time

wrapper = sys.argv[1]
spec = importlib.util.spec_from_file_location("legion_provider_launch_wrapper", wrapper)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
real_write_receipt = module.write_receipt

def delayed_write_receipt(receipt, payload, token):
    if payload.get("status") == "started":
        Path(os.environ["MOCK_DELAYED_STARTED_ASSIGNED"]).write_text(
            "assigned\n", encoding="utf-8"
        )
        deadline = time.monotonic() + 10
        release = Path(os.environ["MOCK_DELAYED_STARTED_RELEASE"])
        while not release.exists():
            if time.monotonic() >= deadline:
                raise RuntimeError("timed out waiting to publish started receipt")
            time.sleep(0.01)
    return real_write_receipt(receipt, payload, token)

module.write_receipt = delayed_write_receipt
sys.argv = sys.argv[1:]
raise SystemExit(module.main())
PY
  cat > "$shim_dir/python3" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == */provider-launch-wrapper.py ]]; then
  exec "$MOCK_REAL_PYTHON" "$MOCK_DELAYED_STARTED_HARNESS" "$@"
fi
exec "$MOCK_REAL_PYTHON" "$@"
SH
  chmod +x "$shim_dir/python3"
  export PATH="$shim_dir:$PATH"
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
  if [[ -n "${MOCK_PREPROVIDER_COLLISION_LEASE:-}" ]]; then
    mkdir -p "${MOCK_PREPROVIDER_COLLISION_LEASE%/*}"
    printf 'collision marker\n' > "$MOCK_PREPROVIDER_COLLISION_LEASE"
  fi
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

@test "Pi pre-provider timeout refuses a colliding lease and retains containment" {
  local repo deadline result_file rc=0 lease
  repo="$(make_test_repo broker-expired-colliding-pi)"
  install_deadline_expiring_git colliding-pi
  lease="$repo/.legion/runs/broker-expired-colliding-pi/lease.json"
  export MOCK_PREPROVIDER_COLLISION_LEASE="$lease"
  deadline="$(python3 -c 'import time; print(time.monotonic_ns() + 4_000_000_000)')"
  result_file="$TEST_TMPDIR/pi-broker-expired-colliding.json"
  LEGION_CHILD_LEASE_DEADLINE_NS="$deadline" PI_BIN=pi \
    "$REPO_ROOT/legion-router/bin/legion-pi" run --task inspect \
      --model openai/fixture-model --repo "$repo" --run-id broker-expired-colliding-pi \
      --quiet > "$result_file" 2>/dev/null || rc=$?
  [ "$rc" -eq 70 ]
  jq -e '.status == "containment_failed" and .attempt_receipt == null' "$result_file"
  [ "$(cat "$lease")" = 'collision marker' ]
  [ -d "$repo/.legion/worktrees/broker-expired-colliding-pi" ]
}

@test "Pi pre-provider timeout retains containment when lease inode fsync fails" {
  local repo deadline result_file rc=0 lease shim_dir
  repo="$(make_test_repo broker-expired-fsync-pi)"
  install_deadline_expiring_git fsync-pi
  lease="$repo/.legion/runs/broker-expired-fsync-pi/lease.json"
  shim_dir="$TEST_TMPDIR/lease-fsync-fault"
  mkdir -p "$shim_dir"
  cat > "$shim_dir/sitecustomize.py" <<'PY'
import os
import stat

original_fsync = os.fsync

def faulting_fsync(fd):
    directory = os.environ.get("LEGION_TEST_LEASE_FSYNC_DIR")
    info = os.fstat(fd)
    if directory and stat.S_ISREG(info.st_mode) and os.path.isdir(directory):
        for entry in os.scandir(directory):
            if entry.name.startswith(".lease.json.tmp."):
                candidate = entry.stat(follow_symlinks=False)
                if (candidate.st_dev, candidate.st_ino) == (info.st_dev, info.st_ino):
                    raise OSError("injected lease inode fsync failure")
    return original_fsync(fd)

os.fsync = faulting_fsync
PY
  deadline="$(python3 -c 'import time; print(time.monotonic_ns() + 4_000_000_000)')"
  result_file="$TEST_TMPDIR/pi-broker-expired-fsync.json"
  PYTHONPATH="$shim_dir:${PYTHONPATH:-}" LEGION_TEST_LEASE_FSYNC_DIR="${lease%/*}" \
    LEGION_CHILD_LEASE_DEADLINE_NS="$deadline" PI_BIN=pi \
    "$REPO_ROOT/legion-router/bin/legion-pi" run --task inspect \
      --model openai/fixture-model --repo "$repo" --run-id broker-expired-fsync-pi \
      --quiet > "$result_file" 2>/dev/null || rc=$?
  [ "$rc" -eq 70 ]
  jq -e '.status == "containment_failed" and .attempt_receipt == null' "$result_file"
  [ ! -e "$lease" ]
  [ -d "$repo/.legion/worktrees/broker-expired-fsync-pi" ]
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
      and .executable_path == $executable and (.auth | length == 64)
      and (has("token") | not)
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

@test "Pi provider launch receipt rejects links FIFOs and oversized content with bounded reads" {
  local kind repo run_id result_file rc victim
  install_unsafe_launch_receipt_sandbox
  export MOCK_REAL_PYTHON="$(command -v python3)"
  for kind in symlink hardlink fifo oversized; do
    repo="$(make_test_repo "unsafe-launch-receipt-$kind")"
    run_id="unsafe-launch-receipt-$kind"
    result_file="$TEST_TMPDIR/$kind-result.json"
    victim="$TEST_TMPDIR/$kind-launch-victim"
    printf 'provider-controlled-target\n' > "$victim"
    rc=0
    LEGION_TEST_UNSAFE_LAUNCH_RECEIPT="$kind" \
      LEGION_TEST_LAUNCH_RECEIPT_VICTIM="$victim" PI_BIN=pi \
      "$REPO_ROOT/legion-router/bin/legion-pi" run --task inspect \
        --model openai/fixture-pi --repo "$repo" --run-id "$run_id" \
        --keep --quiet > "$result_file" 2>/dev/null || rc=$?
    [ "$rc" -ne 0 ]
    jq -e '
      .status == "containment_failed"
      and .usage == null and .usage_status == "unknown"
      and .cost_usd == null and .cost_status == "unknown"
      and (.reason | contains("provider launch evidence remained malformed"))
    ' "$result_file" || { cat "$result_file" >&2; return 1; }
    [[ "$(cat "$victim")" == provider-controlled-target ]]
  done
}

@test "Pi launch failure reason is reused from the verified receipt descriptor" {
  local helper="$TEST_TMPDIR/provider-launch-status.sh"
  local receipt="$TEST_TMPDIR/provider-launch-reason.json"
  local token provider evidence reason
  token="$(printf '%064d' 0)"
  provider="$TEST_TMPDIR/provider-for-reason"
  : > "$provider"
  python3 - "$receipt" "$token" "$provider" <<'PY'
import hashlib
import hmac
import json
import sys

path, token, executable = sys.argv[1:]
payload = {
    "schema": "legion.provider-launch.v1",
    "status": "launch_failed",
    "executable_path": executable,
    "errno": 2,
    "reason": "verified original reason",
}
encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
payload["auth"] = hmac.new(token.encode(), encoded, hashlib.sha256).hexdigest()
with open(path, "w", encoding="utf-8") as stream:
    json.dump(payload, stream, separators=(",", ":"))
PY
  {
    awk '
      /^provider_launch_status\(\)/ { emit=1 }
      emit { print }
      emit && /^PY$/ { getline; print; emit=0 }
    ' "$REPO_ROOT/legion-router/scripts/legion-pi-hermes.sh"
    sed -n '/^provider_launch_reason()/,/^}/p' \
      "$REPO_ROOT/legion-router/scripts/legion-pi-hermes.sh"
    cat <<'SH'
PROVIDER_LAUNCH_RECEIPT="$1"
PROVIDER_LAUNCH_TOKEN="$2"
PROVIDER_BIN="$3"
evidence="$(provider_launch_status)"
# Simulate a provider replacing the pathname after the verified descriptor has
# been consumed but before the caller classifies the failure reason.
printf '%s\n' '{"reason":"replacement-controlled reason"}' > "$PROVIDER_LAUNCH_RECEIPT"
printf '%s\n' "$evidence"
provider_launch_reason "$evidence"
SH
  } > "$helper"

  run bash "$helper" "$receipt" "$token" "$provider"

  [ "$status" -eq 0 ]
  evidence="$(printf '%s\n' "$output" | sed -n '1p')"
  reason="$(printf '%s\n' "$output" | sed -n '2p')"
  jq -e '.status == "launch_failed" and .reason == "verified original reason"' \
    <<<"$evidence"
  [ "$reason" = "verified original reason" ]
}

@test "Pi and Hermes type provider disappearance during post-admission re-resolution as no-launch" {
  local adapter repo provider run_id result_file preflight rc
  for adapter in pi hermes; do
    repo="$(make_test_repo "reresolve-disappears-$adapter")"
    provider="$TEST_TMPDIR/$adapter-self-removing-provider"
    cat > "$provider" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" || "${1:-}" == "version" ]]; then
  rm -f "$0"
  printf '1.0.0\n'
  exit 0
fi
printf 'provider must not execute\n' >&2
exit 99
SH
    chmod +x "$provider"
    run_id="reresolve-disappears-$adapter"
    result_file="$TEST_TMPDIR/$adapter-reresolve-disappears.json"
    rc=0
    if [[ "$adapter" == pi ]]; then
      PI_BIN="$provider" "$REPO_ROOT/legion-router/bin/legion-pi" run --task inspect \
        --model openai/fixture-pi --repo "$repo" --run-id "$run_id" --quiet \
        > "$result_file" 2>/dev/null || rc=$?
    else
      HERMES_BIN="$provider" "$REPO_ROOT/legion-router/bin/legion-hermes" run --task inspect \
        --model openai/fixture-hermes --repo "$repo" --run-id "$run_id" --quiet \
        > "$result_file" 2>/dev/null || rc=$?
    fi
    [ "$rc" -eq 1 ]
    jq -e --arg executor "$adapter" '
      .status == "failed" and .executor == $executor
      and (.reason | contains("binary disappeared or changed during version probe"))
      and .attempt_receipt == null and .failure_receipt == null
      and ((.provider_launch_receipt? // null) == null)
      and ((.provider_exit? // null) == null)
      and .usage == null and .tokens == null and .usage_status == "not_applicable"
      and .cost_usd == null and .cost_status == "not_applicable"
    ' "$result_file" || { cat "$result_file" >&2; return 1; }
    preflight="$(jq -r .preflight_receipt "$result_file")"
    jq -e '
      .schema == "legion.preflight.v1" and .status == "unavailable"
      and .compatibility.version.probe_status == "launch_failed"
      and (.compatibility.version.probe_reason
        | contains("binary disappeared or changed during version probe"))
      and .compatibility.version.probe_lease.schema == "legion.child-execution-lease.v1"
      and .compatibility.version.probe_lease.status == "completed"
      and (.compatibility.version.probe_lease.child_exit_code | type) == "number"
    ' "$preflight"
    [ ! -d "$repo/.legion/worktrees/$run_id" ]
  done
}

@test "malformed inner no-launch evidence is containment failure with conservative spend" {
  local repo result attempt launch
  repo="$(make_test_repo malformed)"
  install_malformed_launch_sandbox

  run env PI_BIN=pi "$REPO_ROOT/legion-router/bin/legion-pi" run --task inspect \
    --repo "$repo" --run-id malformed-launch --quiet
  [ "$status" -ne 0 ]
  result="$output"
  echo "$result" | jq -e '
    .status == "containment_failed" and .provider_exit == 127
    and (.attempt_receipt | type == "string")
    and (.failure_receipt | type == "string")
    and .usage == null and .tokens == null and .usage_status == "unknown"
    and .cost_usd == null and .cost_status == "unknown"
    and (.provider_launch_receipt | type == "string")
    and (.reason | contains("provider launch evidence remained malformed"))
    and (.worktree | contains("malformed-launch"))
  '
  attempt="$(echo "$result" | jq -r '.attempt_receipt')"
  jq -e '.terminal_status == "failed" and .failure.class == "internal"' "$attempt"
  launch="$(dirname "$(echo "$result" | jq -r '.lease_receipt')")/tmp/provider-launch.json"
  jq -e '.status == "launch_failed" and .extra == true' "$launch"
  [ "$(find "$(dirname "$launch")/.." -maxdepth 1 -name 'attempt-*.json' | wc -l | tr -d ' ')" -eq 1 ]
  [ "$(find "$(dirname "$launch")/.." -maxdepth 1 -name 'failure-*.json' | wc -l | tr -d ' ')" -eq 1 ]
  jq -s -e '[.[] | select(.artifacts.provider_attempt == true)] | length == 1' \
    "$LEGION_TELEMETRY_DIR"/*.jsonl
}

@test "Pi and Hermes signals in the pending launch window fail containment without spend" {
  local adapter signal adapter_signal repo run_id result_file error_file pid rc art launch
  for adapter_signal in pi:TERM hermes:HUP; do
    adapter="${adapter_signal%%:*}"
    signal="${adapter_signal##*:}"
    repo="$(make_test_repo "pending-signal-$adapter")"
    run_id="pending-signal-$adapter"
    result_file="$TEST_TMPDIR/$adapter-pending-signal.json"
    error_file="$TEST_TMPDIR/$adapter-pending-signal.err"
    export MOCK_PENDING_LAUNCH_READY="$TEST_TMPDIR/$adapter-pending-launch-ready"
    install_pending_launch_sandbox
    PI_BIN=pi HERMES_BIN=hermes \
      "$REPO_ROOT/legion-router/bin/legion-$adapter" run --task inspect \
        --repo "$repo" --run-id "$run_id" --quiet > "$result_file" 2> "$error_file" &
    pid=$!
    for _ in $(seq 1 200); do
      [[ -f "$MOCK_PENDING_LAUNCH_READY" ]] && break
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.05
    done
    [ -f "$MOCK_PENDING_LAUNCH_READY" ]
    kill -"$signal" "$pid"
    rc=0; wait "$pid" || rc=$?
    [ "$rc" -eq 70 ]
    [ ! -s "$result_file" ]
    art="$repo/.legion/runs/$run_id"
    launch="$art/tmp/provider-launch.json"
    jq -e '.schema == "legion.provider-launch.v1" and .status == "pending"
      and (.auth | type == "string" and length == 64) and (has("token") | not)' "$launch"
    [ "$(find "$art" -maxdepth 1 -name 'attempt-*.json' | wc -l | tr -d ' ')" -eq 0 ]
    [ "$(find "$art" -maxdepth 1 -name 'failure-*.json' | wc -l | tr -d ' ')" -eq 0 ]
    jq -e '.lifecycle.phase == "containment_failed"' "$LEGION_REGISTRY_DIR/$run_id.json"
    [ -d "$repo/.legion/worktrees/$run_id" ]
    assert_mock_not_called "$adapter"
  done
  if compgen -G "$LEGION_TELEMETRY_DIR/*.jsonl" >/dev/null; then
    run jq -s -e '[.[] | select(.artifacts.provider_attempt == true)] | length > 0' \
      "$LEGION_TELEMETRY_DIR"/*.jsonl
    [ "$status" -ne 0 ]
  fi
}

@test "Hermes terminal metering follows its canonical attempt receipt" {
  local repo result attempt
  repo="$(make_test_repo hermes-unknown-cost)"

  MOCK_HERMES_COST_STATUS=unknown MOCK_HERMES_COST_SOURCE=none HERMES_BIN=hermes \
    run "$REPO_ROOT/legion-router/bin/legion-hermes" run --task inspect \
      --model openai/fixture-hermes --repo "$repo" --quiet

  [ "$status" -eq 0 ]
  result="$output"
  attempt="$(jq -r '.attempt_receipt' <<<"$result")"
  jq -e '.usage_status == "known" and (.usage | type) == "object"
    and .cost_status == "unknown" and .cost_usd == null' <<<"$result"
  jq -e --argjson result "$result" '
    .usage == $result.usage and .usage_status == $result.usage_status
    and .cost_usd == $result.cost_usd and .cost_status == $result.cost_status
  ' "$attempt"
}

@test "Pi and Hermes provider spans use the observed model from their attempt receipts" {
  local kind repo result attempt
  for kind in pi hermes; do
    repo="$(make_test_repo "$kind-observed-model")"
    if [[ "$kind" == pi ]]; then
      MOCK_PI_RESPONSE_MODEL=fixture-pi-observed PI_BIN=pi \
        run "$REPO_ROOT/legion-router/bin/legion-pi" run --task inspect \
          --model openai/fixture-pi --repo "$repo" --quiet
    else
      MOCK_HERMES_USAGE_MODEL=openai/fixture-hermes-observed HERMES_BIN=hermes \
        run "$REPO_ROOT/legion-router/bin/legion-hermes" run --task inspect \
          --model openai/fixture-hermes --repo "$repo" --quiet
    fi
    [ "$status" -eq 0 ]
    result="$(printf '%s\n' "$output" | tail -n 1)"
    attempt="$(jq -r '.attempt_receipt' <<<"$result")"
    jq -e '.effective_model != .requested_model' "$attempt"
    jq -s -e --arg attempt "$attempt" --slurpfile receipt "$attempt" '
      [.[] | select(.artifacts.provider_attempt == true
        and .artifacts.attempt_receipt == $attempt)] as $spans
      | ($spans | length) == 1
        and $spans[0].model == $receipt[0].effective_model
    ' "$LEGION_TELEMETRY_DIR"/*.jsonl
  done
}

@test "Pi and Hermes provider token counters above 2^53 remain exact" {
  local kind repo result attempt
  for kind in pi hermes; do
    repo="$(make_test_repo "$kind-huge-tokens")"
    if [[ "$kind" == pi ]]; then
      MOCK_PI_HUGE_TOKENS=1 PI_BIN=pi \
        run "$REPO_ROOT/legion-router/bin/legion-pi" run --task inspect \
          --model openai/fixture-pi --repo "$repo" --quiet
    else
      MOCK_HERMES_HUGE_TOKENS=1 HERMES_BIN=hermes \
        run "$REPO_ROOT/legion-router/bin/legion-hermes" run --task inspect \
          --model openai/fixture-hermes --repo "$repo" --quiet
    fi
    [ "$status" -eq 0 ]
    result="$(printf '%s\n' "$output" | tail -n 1)"
    attempt="$(jq -r '.attempt_receipt' <<<"$result")"
    python3 - "$attempt" "$kind" "$result" <<'PY'
import json
from pathlib import Path
import sys
receipt = json.loads(Path(sys.argv[1]).read_text())
terminal = json.loads(sys.argv[3])
assert receipt["usage_status"] == "known"
if sys.argv[2] == "pi":
    assert receipt["usage"]["input_tokens"] == 9007199254740993
    assert terminal["usage"]["input_tokens"] == 9007199254740993
    assert terminal["tokens"]["input_tokens"] == 9007199254740993
else:
    assert receipt["usage"]["reasoning_output_tokens"] == 9007199254740992
    assert receipt["usage"]["output_tokens"] == 1
    assert terminal["usage"]["reasoning_output_tokens"] == 9007199254740992
PY
  done
}

@test "Pi malformed or negative provider cost remains unknown in canonical output" {
  local repo result attempt invalid_cost case_name
  for invalid_cost in -1 '"malformed"'; do
    case_name="${invalid_cost//[^[:alnum:]]/x}"
    repo="$(make_test_repo "pi-invalid-cost-$case_name")"

    run env MOCK_PI_FINAL_COST_TOTAL="$invalid_cost" PI_BIN=pi \
      "$REPO_ROOT/legion-router/bin/legion-pi" run --task inspect \
        --model openai/fixture-pi --repo "$repo" --quiet

    [ "$status" -ne 0 ]
    result="$(printf '%s\n' "$output" | tail -n 1)"
    jq -e '.usage_status == "known" and (.usage | type) == "object"
      and .cost_status == "unknown" and .cost_usd == null
      and (.attempt_receipt | type) == "string"' <<<"$result"
    attempt="$(jq -r '.attempt_receipt' <<<"$result")"
    jq -e --argjson result "$result" '
      .usage == $result.usage and .usage_status == $result.usage_status
      and .cost_usd == $result.cost_usd and .cost_status == $result.cost_status
      and .terminal_status == "failed" and .failure.class == "malformed_event"
    ' "$attempt"
  done
}

@test "Hermes launched pre-metering failure emits nullable unknown metering" {
  local repo result attempt
  repo="$(make_test_repo hermes-pre-metering-failure)"

  MOCK_HERMES_FAIL=1 HERMES_BIN=hermes \
    run "$REPO_ROOT/legion-router/bin/legion-hermes" run --task inspect \
      --model openai/fixture-hermes --repo "$repo" --quiet

  [ "$status" -ne 0 ]
  result="$output"
  jq -e '.status == "failed" and .provider_exit == 4
    and .usage == null and .tokens == null and .usage_status == "unknown"
    and .cost_usd == null and .cost_status == "unknown"
    and (.attempt_receipt | type) == "string"' <<<"$result"
  attempt="$(jq -r '.attempt_receipt' <<<"$result")"
  jq -e --argjson result "$result" '
    .usage == $result.usage and .usage_status == $result.usage_status
    and .cost_usd == $result.cost_usd and .cost_status == $result.cost_status
  ' "$attempt"
}

@test "Pi Hermes wrapper defers an assigned-child signal until the billable started receipt is durable" {
  local repo run_id art wrapper provider harness receipt token_file assigned release child_pid_file signal_file
  local wrapper_pid child_pid rc=0
  repo="$(make_test_repo delayed-started-receipt)"
  run_id=delayed-started-receipt
  PI_BIN=pi run "$REPO_ROOT/legion-router/bin/legion-pi" run --task inspect \
    --repo "$repo" --run-id "$run_id" --keep --quiet
  [ "$status" -eq 0 ]
  art="$repo/.legion/runs/$run_id"
  wrapper="$art/provider-launch-wrapper.py"
  [ -x "$wrapper" ]

  provider="$TEST_TMPDIR/delayed-start-provider"
  child_pid_file="$TEST_TMPDIR/delayed-start-child.pid"
  signal_file="$TEST_TMPDIR/delayed-start-child.signal"
  cat > "$provider" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$$" > "$MOCK_DELAYED_CHILD_PID_FILE"
trap 'printf "TERM\n" > "$MOCK_DELAYED_CHILD_SIGNAL_FILE"; exit 143' TERM
while :; do sleep 0.05; done
SH
  chmod +x "$provider"
  provider="$(cd "${provider%/*}" && pwd -P)/${provider##*/}"

  harness="$TEST_TMPDIR/delayed-start-harness.py"
  assigned="$TEST_TMPDIR/delayed-start-assigned"
  release="$TEST_TMPDIR/delayed-start-release"
  cat > "$harness" <<'PY'
import importlib.util
from pathlib import Path
import sys
import time

harness, wrapper, assigned, release, *wrapper_arguments = sys.argv
spec = importlib.util.spec_from_file_location("legion_provider_launch_wrapper", wrapper)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
real_write_receipt = module.write_receipt

def delayed_write_receipt(receipt, payload, token):
    if payload.get("status") == "started":
        Path(assigned).write_text("assigned\n", encoding="utf-8")
        deadline = time.monotonic() + 10
        while not Path(release).exists():
            if time.monotonic() >= deadline:
                raise RuntimeError("timed out waiting to release started receipt")
            time.sleep(0.01)
    return real_write_receipt(receipt, payload, token)

module.write_receipt = delayed_write_receipt
sys.argv = [wrapper, *wrapper_arguments]
raise SystemExit(module.main())
PY
  receipt="$TEST_TMPDIR/delayed-start-receipt.json"
  token_file="$TEST_TMPDIR/delayed-start-token"
  printf '%064d\n' 0 > "$token_file"
  MOCK_DELAYED_CHILD_PID_FILE="$child_pid_file" \
    MOCK_DELAYED_CHILD_SIGNAL_FILE="$signal_file" \
    python3 "$harness" "$wrapper" "$assigned" "$release" \
      "$receipt" "$token_file" "$art/child-exec-gate.py" -- "$provider" &
  wrapper_pid=$!
  for _ in $(seq 1 200); do
    [[ -f "$assigned" && -f "$child_pid_file" ]] && break
    kill -0 "$wrapper_pid" 2>/dev/null || break
    sleep 0.05
  done
  [ -f "$assigned" ]
  [ -f "$child_pid_file" ]
  child_pid="$(cat "$child_pid_file")"
  kill -TERM "$wrapper_pid"
  sleep 0.2
  kill -0 "$child_pid"
  [ ! -e "$signal_file" ]
  jq -e '.status == "pending"' "$receipt"

  : > "$release"
  wait "$wrapper_pid" || rc=$?
  [ "$rc" -eq 143 ]
  for _ in $(seq 1 100); do
    ! kill -0 "$child_pid" 2>/dev/null && break
    sleep 0.05
  done
  ! kill -0 "$child_pid" 2>/dev/null
  grep -qx TERM "$signal_file"
  jq -e --arg executable "$provider" '
    .schema == "legion.provider-launch.v1" and .status == "started"
    and .executable_path == $executable
    and (.provider_pid | type == "number" and . >= 1)
    and (.auth | type == "string" and length == 64)
    and (has("token") | not)
  ' "$receipt"
}

@test "Pi Hermes wrapper refuses a signal pending in its atomic provider launch region" {
  local repo run_id art wrapper harness receipt token_file rc=0
  repo="$(make_test_repo atomic-provider-signal)"
  run_id=atomic-provider-signal
  PI_BIN=pi run "$REPO_ROOT/legion-router/bin/legion-pi" run --task inspect \
    --repo "$repo" --run-id "$run_id" --keep --quiet
  [ "$status" -eq 0 ]
  art="$repo/.legion/runs/$run_id"
  wrapper="$art/provider-launch-wrapper.py"
  [ -x "$wrapper" ]

  harness="$TEST_TMPDIR/atomic-provider-signal-harness.py"
  cat > "$harness" <<'PY'
import importlib.util
import signal
import sys

wrapper, *wrapper_arguments = sys.argv[1:]
spec = importlib.util.spec_from_file_location("legion_atomic_provider_wrapper", wrapper)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
calls = []
module.signal.pthread_sigmask = lambda operation, signals: calls.append(operation) or set()
module.signal.sigpending = lambda: {signal.SIGTERM}
module.subprocess.Popen = lambda *_args, **_kwargs: (_ for _ in ()).throw(
    AssertionError("provider Popen ran with a launch signal pending")
)
sys.argv = [wrapper, *wrapper_arguments]
raise SystemExit(module.main())
PY
  receipt="$TEST_TMPDIR/atomic-provider-signal.json"
  token_file="$TEST_TMPDIR/atomic-provider-signal.token"
  printf '%064d\n' 0 > "$token_file"
  python3 "$harness" "$wrapper" "$receipt" "$token_file" \
    "$art/child-exec-gate.py" -- /fixture/provider || rc=$?
  [ "$rc" -eq 143 ]
  jq -e --argjson cancelled_errno "$(python3 -c 'import errno; print(errno.ECANCELED)')" '
    .schema == "legion.provider-launch.v1" and .status == "launch_failed"
    and .errno == $cancelled_errno
    and (.reason | contains("cancelled before process creation"))
    and (.auth | type == "string" and length == 64)
    and (has("provider_pid") | not) and (has("token") | not)
  ' "$receipt"
}

@test "Pi Hermes exec gate refuses cancellation after the waiting child starts" {
  local repo art wrapper harness receipt token_file marker rc=0
  repo="$(make_test_repo exec-gate-signal)"
  PI_BIN=pi run "$REPO_ROOT/legion-router/bin/legion-pi" run --task inspect \
    --repo "$repo" --run-id exec-gate-signal --keep --quiet
  [ "$status" -eq 0 ]
  art="$repo/.legion/runs/exec-gate-signal"
  wrapper="$art/provider-launch-wrapper.py"
  harness="$TEST_TMPDIR/exec-gate-signal-harness.py"
  marker="$TEST_TMPDIR/provider-executed"
  cat > "$harness" <<'PY'
import importlib.util
import os
import signal
import subprocess
import sys

wrapper, *arguments = sys.argv[1:]
spec = importlib.util.spec_from_file_location("legion_pi_exec_gate_signal", wrapper)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
real_popen = subprocess.Popen

def signal_after_waiting_child(*args, **kwargs):
    child = real_popen(*args, **kwargs)
    os.kill(os.getpid(), signal.SIGTERM)
    return child

module.subprocess.Popen = signal_after_waiting_child
sys.argv = [wrapper, *arguments]
raise SystemExit(module.main())
PY
  receipt="$TEST_TMPDIR/exec-gate-receipt.json"
  token_file="$TEST_TMPDIR/exec-gate-token"
  printf '%064d\n' 0 > "$token_file"
  python3 "$harness" "$wrapper" "$receipt" "$token_file" \
    "$art/child-exec-gate.py" -- python3 -c \
    "from pathlib import Path; Path('$marker').touch()" || rc=$?
  [ "$rc" -eq 143 ]
  [ ! -e "$marker" ]
  jq -e '.status == "launch_failed" and .errno > 0
    and (.auth | type == "string" and length == 64)
    and (has("provider_pid") | not)' "$receipt"
}

@test "Pi Hermes inner gate refuses a lease expiring after the waiting child starts" {
  local repo art wrapper harness receipt token_file marker deadline rc=0
  repo="$(make_test_repo exec-gate-expired)"
  PI_BIN=pi run "$REPO_ROOT/legion-router/bin/legion-pi" run --task inspect \
    --repo "$repo" --run-id exec-gate-expired --keep --quiet
  [ "$status" -eq 0 ]
  art="$repo/.legion/runs/exec-gate-expired"
  wrapper="$art/provider-launch-wrapper.py"
  harness="$TEST_TMPDIR/exec-gate-expired-harness.py"
  marker="$TEST_TMPDIR/provider-executed"
  cat > "$harness" <<'PY'
import importlib.util
import subprocess
import sys
import time

wrapper, *arguments = sys.argv[1:]
spec = importlib.util.spec_from_file_location("legion_pi_exec_gate_expired", wrapper)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
real_popen = subprocess.Popen

def expire_after_waiting_child(*args, **kwargs):
    child = real_popen(*args, **kwargs)
    time.sleep(0.7)
    return child

module.subprocess.Popen = expire_after_waiting_child
sys.argv = [wrapper, *arguments]
raise SystemExit(module.main())
PY
  receipt="$TEST_TMPDIR/exec-gate-expired-receipt.json"
  token_file="$TEST_TMPDIR/exec-gate-expired-token"
  printf '%064d\n' 0 > "$token_file"
  deadline="$(python3 -c 'import time; print(time.monotonic_ns()+500_000_000)')"
  LEGION_CHILD_LEASE_DEADLINE_NS="$deadline" \
    python3 "$harness" "$wrapper" "$receipt" "$token_file" \
      "$art/child-exec-gate.py" -- python3 -c \
      "from pathlib import Path; Path('$marker').touch()" || rc=$?
  [ "$rc" -eq 124 ]
  [ ! -e "$marker" ]
  jq -e '.status == "launch_failed" and (.reason | contains("deadline expired"))
    and (has("provider_pid") | not)' "$receipt"
}

@test "Pi production supervisor defers descendant shutdown until started receipt is durable" {
  local repo run_id art provider result_file error_file assigned release child_pid_file signal_file
  local adapter_pid child_pid rc=0 attempt
  repo="$(make_test_repo production-delayed-started)"
  run_id=production-delayed-started
  art="$repo/.legion/runs/$run_id"
  assigned="$art/tmp/delayed-started-assigned"
  release="$art/tmp/delayed-started-release"
  child_pid_file="$art/tmp/delayed-started-child.pid"
  signal_file="$art/tmp/delayed-started-child.signal"
  install_delayed_started_python

  provider="$TEST_TMPDIR/production-delayed-provider"
  cat > "$provider" <<'SH'
#!/usr/bin/env bash
set -eu
if [[ "${1:-}" == --version ]]; then printf 'pi 1.0.0\n'; exit 0; fi
printf '%s\n' "$$" > "$MOCK_DELAYED_STARTED_CHILD_PID"
trap 'printf "TERM\n" > "$MOCK_DELAYED_STARTED_CHILD_SIGNAL"; exit 143' TERM
while :; do sleep 0.05; done
SH
  chmod +x "$provider"
  provider="$(cd "${provider%/*}" && pwd -P)/${provider##*/}"
  result_file="$TEST_TMPDIR/production-delayed-started.out"
  error_file="$TEST_TMPDIR/production-delayed-started.err"
  MOCK_DELAYED_STARTED_ASSIGNED="$assigned" \
    MOCK_DELAYED_STARTED_RELEASE="$release" \
    MOCK_DELAYED_STARTED_CHILD_PID="$child_pid_file" \
    MOCK_DELAYED_STARTED_CHILD_SIGNAL="$signal_file" \
    PI_BIN="$provider" "$REPO_ROOT/legion-router/bin/legion-pi" run --task inspect \
      --repo "$repo" --run-id "$run_id" --keep --quiet >"$result_file" 2>"$error_file" &
  adapter_pid=$!
  for _ in $(seq 1 300); do
    [[ -f "$assigned" && -f "$child_pid_file" ]] && break
    kill -0 "$adapter_pid" 2>/dev/null || break
    sleep 0.05
  done
  [ -f "$assigned" ]
  [ -f "$child_pid_file" ]
  child_pid="$(cat "$child_pid_file")"
  kill -TERM "$adapter_pid"
  sleep 0.2
  kill -0 "$child_pid"
  [ ! -e "$signal_file" ]
  jq -e '.status == "pending"' "$art/tmp/provider-launch.json"

  : > "$release"
  wait "$adapter_pid" || rc=$?
  [ "$rc" -eq 143 ]
  for _ in $(seq 1 100); do
    ! kill -0 "$child_pid" 2>/dev/null && break
    sleep 0.05
  done
  ! kill -0 "$child_pid" 2>/dev/null
  grep -qx TERM "$signal_file"
  jq -e '.status == "started"' "$art/tmp/provider-launch.json"
  [ "$(find "$art" -maxdepth 1 -name 'attempt-*.json' | wc -l | tr -d ' ')" -eq 1 ]
  [ "$(find "$art" -maxdepth 1 -name 'failure-*.json' | wc -l | tr -d ' ')" -eq 1 ]
  attempt="$(cd "$art" && pwd -P)/attempt-1.json"
  jq -e '.terminal_status == "cancelled" and .failure.class == "cancelled"' "$attempt"
  jq -s -e --arg attempt "$attempt" '
    [.[] | select(.artifacts.provider_attempt == true
      and .artifacts.attempt_receipt == $attempt)] | length == 1
  ' "$LEGION_TELEMETRY_DIR"/*.jsonl
}

@test "a provider that really launches and exits 127 remains a billable attempt" {
  local repo provider result attempt lease launch
  repo="$(make_test_repo provider-127)"
  provider="$TEST_TMPDIR/pi-exits-127"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ "${1:-}" == --version ]]; then printf "pi 1.0.0\n"; exit 0; fi' \
    'exit 127' > "$provider"
  chmod +x "$provider"
  provider="$(cd "${provider%/*}" && pwd -P)/${provider##*/}"

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
  launch="$(dirname "$lease")/tmp/provider-launch.json"
  jq -e --arg executable "$provider" '
    .schema == "legion.provider-launch.v1" and .status == "started"
    and .executable_path == $executable
    and (.provider_pid | type == "number" and . >= 1)
    and (.auth | type == "string" and length == 64)
    and (has("token") | not)
  ' "$launch"
}
