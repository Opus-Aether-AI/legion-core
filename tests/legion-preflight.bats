#!/usr/bin/env bats

load 'helpers/setup'

setup() {
  setup_test_env
  export PREFLIGHT="$REPO_ROOT/legion-router/bin/legion-preflight"
  export LEGION_PREFLIGHT_CACHE_DIR="$TEST_TMPDIR/cache"
  export LEGION_EXECUTORS_FILE="$BATS_TEST_DIRNAME/fixtures/executor-contract/preflight-executors.toml"
  export PROVIDER_CALL_LOG="$TEST_TMPDIR/provider-calls"
  mkdir -p "$TEST_TMPDIR/bin"
  cat > "$TEST_TMPDIR/bin/fixture-provider" <<'SH'
#!/usr/bin/env bash
  if [[ "${1:-}" == "--version" ]]; then
  [[ -n "${VERSION_PROBE_LOG:-}" ]] && printf 'version-probe\n' >> "$VERSION_PROBE_LOG"
  printf 'fixture-provider %s\n' "${FIXTURE_VERSION:-1.2.3}"
  exit 0
fi
printf 'provider-call %s\n' "$*" >> "${PROVIDER_CALL_LOG:?}"
SH
  chmod +x "$TEST_TMPDIR/bin/fixture-provider"
  export PATH="$TEST_TMPDIR/bin:$PATH"
  export VERSION_PROBE_LOG="$TEST_TMPDIR/version-probes"
}

@test "legion-preflight: installed entrypoint is discoverable and returns supported JSON" {
  [ -x "$PREFLIGHT" ]
  local installed_bin="$TEST_TMPDIR/installed-bin"
  mkdir -p "$installed_bin"
  ln -s "$PREFLIGHT" "$installed_bin/legion-preflight"
  run env PATH="$installed_bin:$PATH" legion-preflight --json --executor fixture --sandbox read-only \
    --read-mode provider-tools --task-transport stdin --model fixture-model --effort high
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '
    .schema == "legion.preflight.v1"
    and .status == "supported"
    and .identity.binary_sha256
    and .identity.config_sha256
    and .cache.hit == false'
}

@test "legion-preflight: version cache identity invalidates on binary or relevant config change" {
  run "$PREFLIGHT" --json --executor fixture
  [ "$status" -eq 0 ]
  local first="$output"
  run "$PREFLIGHT" --json --executor fixture
  [ "$status" -eq 0 ]
  echo "$output" | jq -e --arg key "$(echo "$first" | jq -r .cache.key)" \
    '.cache.hit == true and .cache.key == $key'

  printf '\n# binary identity change\n' >> "$TEST_TMPDIR/bin/fixture-provider"
  run "$PREFLIGHT" --json --executor fixture
  [ "$status" -eq 0 ]
  local binary_changed="$output"
  echo "$binary_changed" | jq -e --arg key "$(echo "$first" | jq -r .cache.key)" \
    '.cache.hit == false and .cache.key != $key'

  FIXTURE_PROVIDER_MODE=new run "$PREFLIGHT" --json --executor fixture
  [ "$status" -eq 0 ]
  echo "$output" | jq -e --arg key "$(echo "$binary_changed" | jq -r .cache.key)" \
    '.cache.hit == false and .cache.key != $key'
}

@test "legion-preflight: incompatible and unavailable decisions fail closed" {
  run "$PREFLIGHT" --json --executor fixture --sandbox danger-full-access
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.status == "incompatible"'

  FIXTURE_PROVIDER_MODE=broken run "$PREFLIGHT" --json --executor fixture
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.status == "incompatible" and (.reason | contains("known-bad configuration"))'

  mv "$TEST_TMPDIR/bin/fixture-provider" "$TEST_TMPDIR/bin/fixture-provider.off"
  run "$PREFLIGHT" --json --executor fixture
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.status == "unavailable"'
}

@test "legion-preflight: unknown versions are untested and never launch the provider" {
  FIXTURE_VERSION=9.9.9 run "$PREFLIGHT" --json --executor fixture --model fixture-model
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "untested" and .identity.version == "9.9.9"'
  [ ! -e "$PROVIDER_CALL_LOG" ]
}

@test "legion-preflight: premium model requires explicit consent without provider launch" {
  run "$PREFLIGHT" --json --executor fixture --model fixture-premium
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '
    .status == "incompatible"
    and .compatibility.billing.class == "premium_credit"
    and .compatibility.billing.explicit_consent_required == true'
  [ ! -e "$PROVIDER_CALL_LOG" ]
  [ ! -e "$VERSION_PROBE_LOG" ]

  run "$PREFLIGHT" --json --executor fixture --model fixture-premium --explicit-consent
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "supported"'
  [ ! -e "$PROVIDER_CALL_LOG" ]
}
