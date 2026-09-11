#!/usr/bin/env bats

load 'helpers/setup'

setup() {
  setup_test_env
  export LEGION_TELEMETRY_DIR="$TEST_TMPDIR/spans"
  export LEGION_STATE_ROOT="$TEST_TMPDIR/state"
  export LEGION_REGISTRY_DIR="$LEGION_STATE_ROOT/registry"
  DELEGATE="$REPO_ROOT/legion-router/scripts/delegate.sh"
}

make_test_repo() {
  local repo="$TEST_TMPDIR/repo-$1"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@t.c
  git -C "$repo" config user.name t
  printf 'base\n' > "$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -qm init
  printf '%s' "$repo"
}

install_prelaunch_timeout_python() {
  local shim_dir="$TEST_TMPDIR/native-timeout-python" real_python
  real_python="$(command -v python3)"
  mkdir -p "$shim_dir"
  cat > "$shim_dir/python3" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == */legion-process-supervisor.py && " $* " == *" --launch-gate-file "* ]]; then
  status_file="" launch_gate="" launch_token="" max_runtime=30
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --status-file) status_file="$2"; shift 2 ;;
      --max-runtime-seconds) max_runtime="$2"; shift 2 ;;
      --launch-gate-file) launch_gate="$2"; shift 2 ;;
      --launch-gate-token) launch_token="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  temp="$(mktemp "${launch_gate%/*}/.native-timeout-ready.XXXXXX")" || exit 70
  jq -cn --arg token "$launch_token" --argjson pid "$$" \
    '{schema:"legion.child-launch-gate.v1",status:"ready",token:$token,supervisor_pid:$pid}' > "$temp"
  chmod 600 "$temp"; mv -f "$temp" "$launch_gate"
  for ((i = 0; i < 500; i++)); do
    jq -e --arg token "$launch_token" --argjson pid "$$" \
      '.status == "go" and .token == $token and .supervisor_pid == $pid' \
      "$launch_gate" >/dev/null 2>&1 && break
    /bin/sleep 0.02
  done
  jq -cn --argjson runtime "$max_runtime" '
    {schema:"legion.child-execution-lease.v1",status:"launch_failed",
     reason:"inherited child lease deadline expired during launch setup",
     max_runtime_seconds:$runtime}' > "$status_file"
  exit 124
fi
exec "$LEGION_TEST_REAL_PYTHON" "$@"
SH
  chmod +x "$shim_dir/python3"
  export LEGION_TEST_REAL_PYTHON="$real_python"
  export PATH="$shim_dir:$PATH"
}

assert_no_launch_timeout() {
  local result="$1" lease
  jq -e '
    .status == "timed_out"
    and (.reason | test("deadline expired|lease expired"))
    and ((.attempt_receipt? // null) == null)
    and ((.failure_receipt? // null) == null)
  ' <<<"$result" || { printf 'result=%s\n' "$result" >&2; return 1; }
  lease="$(jq -r '.lease_receipt // empty' <<<"$result")"
  [ -n "$lease" ]
  jq -e '
    .schema == "legion.child-execution-lease.v1"
    and .status == "launch_failed"
    and (.reason | contains("deadline expired"))
    and (has("child_exit_code") | not)
  ' "$lease"
}

@test "native Codex run review and resume keep authenticated prelaunch rc124 as timed_out" {
  local repo result output_file rc seed run_id calls_before calls_after
  install_prelaunch_timeout_python

  repo="$(make_test_repo run)"
  rc=0
  "$DELEGATE" run --model test-model-alpha --task inspect --repo "$repo" --quiet \
    > "$TEST_TMPDIR/run.out" 2> "$TEST_TMPDIR/run.err" || rc=$?
  [ "$rc" -ne 0 ]
  result="$(tail -n 1 "$TEST_TMPDIR/run.out")"
  assert_no_launch_timeout "$result"

  repo="$(make_test_repo review)"
  rc=0
  "$DELEGATE" review --archetype security-review --base HEAD --repo "$repo" --quiet \
    > "$TEST_TMPDIR/review.out" 2> "$TEST_TMPDIR/review.err" || rc=$?
  [ "$rc" -ne 0 ]
  result="$(tail -n 1 "$TEST_TMPDIR/review.out")"
  jq -e '.status == "timed_out" and (.reason | test("deadline expired|lease expired"))' \
    <<<"$result" || { cat "$TEST_TMPDIR/review.out" >&2; cat "$TEST_TMPDIR/review.err" >&2; return 1; }
  lease="$(jq -r '.lease_receipt // empty' <<<"$result")"
  [ -n "$lease" ]
  jq -e '.status == "launch_failed" and (.reason | contains("deadline expired"))' "$lease"

  # Seed a resumable run with the real supervisor, then put the timeout fixture
  # back in front of Python only for the resume launch gate.
  export PATH="${PATH#*:}"
  repo="$(make_test_repo resume)"
  seed="$("$DELEGATE" run --model test-model-alpha --task initial --repo "$repo" --keep --quiet)"
  run_id="$(jq -r .run_id <<<"$seed")"
  install_prelaunch_timeout_python
  calls_before="$(grep -Fc 'codex exec resume' "$MOCK_CALL_LOG" || true)"
  rc=0
  "$DELEGATE" resume --run "$run_id" --task follow-up --repo "$repo" --quiet \
    > "$TEST_TMPDIR/resume.out" 2> "$TEST_TMPDIR/resume.err" || rc=$?
  [ "$rc" -ne 0 ]
  result="$(tail -n 1 "$TEST_TMPDIR/resume.out")"
  assert_no_launch_timeout "$result"
  calls_after="$(grep -Fc 'codex exec resume' "$MOCK_CALL_LOG" || true)"
  [ "$calls_after" -eq "$calls_before" ]

  # No provider process was reached in either of the two fresh operations.
  [ "$(grep -Ec '^codex exec .*test-model-alpha' "$MOCK_CALL_LOG" || true)" -eq 1 ]
}
