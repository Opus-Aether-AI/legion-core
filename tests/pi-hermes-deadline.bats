#!/usr/bin/env bats

load 'helpers/setup'

setup() {
  setup_test_env
  export LEGION_STATE_ROOT="$TEST_TMPDIR/state"
  export LEGION_TELEMETRY_DIR="$TEST_TMPDIR/spans"
  export LEGION_REGISTRY_DIR="$LEGION_STATE_ROOT/registry"
}

make_repo() {
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

@test "Pi and Hermes export one absolute deadline through brokered handoff" {
  local adapter repo deadline_log provider_deadline child_deadline
  for adapter in pi hermes; do
    repo="$(make_repo "$adapter")"
    deadline_log="$TEST_TMPDIR/$adapter-deadlines"
    MOCK_CHILD_DEADLINE_LOG="$deadline_log" MOCK_PROVIDER_HANDOFF_EXECUTOR=cursor \
      PI_BIN=pi HERMES_BIN=hermes run \
      "$REPO_ROOT/legion-router/bin/legion-$adapter" run --task bounded --repo "$repo" \
        --max-runtime-seconds 10 --quiet
    [ "$status" -eq 0 ]
    provider_deadline="$(sed -n 's/^provider=//p' "$deadline_log")"
    child_deadline="$(sed -n 's/^child=//p' "$deadline_log")"
    [[ "$provider_deadline" =~ ^[1-9][0-9]*$ ]]
    [ "$child_deadline" = "$provider_deadline" ]
  done
}
