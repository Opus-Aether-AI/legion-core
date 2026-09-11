#!/usr/bin/env bats

load 'helpers/setup'

setup() {
  setup_test_env
  export LEGION_STATE_ROOT="$TEST_TMPDIR/state"
  export LEGION_TELEMETRY_DIR="$TEST_TMPDIR/spans"
  export LEGION_REGISTRY_DIR="$LEGION_STATE_ROOT/registry"
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
