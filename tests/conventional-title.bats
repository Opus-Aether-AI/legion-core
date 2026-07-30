#!/usr/bin/env bats

setup() {
  VALIDATOR="$BATS_TEST_DIRNAME/../scripts/validate-conventional-title.sh"
  RELEASE_CONFIG="$BATS_TEST_DIRNAME/../release-please-config.json"
}

@test "accepts a release-producing Conventional Commit title" {
  run "$VALIDATOR" "feat(release): publish Legion defaults"

  [ "$status" -eq 0 ]
}

@test "accepts configured release types, scopes, and breaking markers" {
  local title
  for title in \
    "fix: restore publishing" \
    "perf(router): reduce routing latency" \
    "feat!: remove the legacy bridge" \
    "chore(main): release 0.19.0"; do
    run "$VALIDATOR" "$title"
    [ "$status" -eq 0 ]
  done
}

@test "accepts every changelog type configured for Release Please" {
  local type
  while IFS= read -r type; do
    run "$VALIDATOR" "${type}: validate configured type"
    [ "$status" -eq 0 ]
  done < <(jq -r '.packages["."]."changelog-sections"[].type' "$RELEASE_CONFIG")
}

@test "rejects the non-conventional title that skipped the release" {
  run "$VALIDATOR" "Make Legion the default across coding harnesses"

  [ "$status" -eq 1 ]
  [[ "$output" == *"feat(setup): make Legion the default"* ]]
}

@test "rejects unsupported types and malformed summaries" {
  local title
  for title in \
    "feature: publish Legion defaults" \
    "FEAT: publish Legion defaults" \
    "feat publish Legion defaults" \
    "feat: "; do
    run "$VALIDATOR" "$title"
    [ "$status" -eq 1 ]
  done
}

@test "reports command misuse separately from an invalid title" {
  run "$VALIDATOR"

  [ "$status" -eq 2 ]
  [[ "$output" == *"usage:"* ]]
}
