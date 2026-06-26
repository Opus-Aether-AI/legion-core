#!/usr/bin/env bats

load 'helpers/setup'

setup() {
  setup_test_env
  INTAKE="$REPO_ROOT/legion-router/scripts/legion-intake.sh"
  export CUSTOM_BIN="$TEST_TMPDIR/intake-mocks"
  mkdir -p "$CUSTOM_BIN"
  export PATH="$CUSTOM_BIN:$PATH"
  export MOCK_GH_COMMENTS="$TEST_TMPDIR/gh-comments.log"
  export MOCK_GH_ISSUE_JSON="$TEST_TMPDIR/gh-issue.json"
  export MOCK_DELEGATE_RESULT="$TEST_TMPDIR/delegate-result.json"
  export REPO_DIR="$(make_issue_repo)"
  write_mock_gh
  write_mock_delegate
}

make_issue_repo() {
  local repo="$TEST_TMPDIR/repo"
  local origin="$TEST_TMPDIR/origin.git"
  git init --bare -q "$origin"
  git -C "$origin" symbolic-ref HEAD refs/heads/main
  if ! git init -q --initial-branch=main "$repo" 2>/dev/null; then
    git init -q "$repo"
    git -C "$repo" branch -M main
  fi
  git -C "$repo" config user.email t@t.c
  git -C "$repo" config user.name t
  printf 'old\n' > "$repo/demo.txt"
  git -C "$repo" add demo.txt
  git -C "$repo" commit -qm init
  git -C "$repo" remote add origin "$origin"
  git -C "$repo" push -qu origin main
  echo "$repo"
}

write_mock_gh() {
  cat > "$CUSTOM_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'gh %s\n' "$*" >> "$MOCK_CALL_LOG"
if [[ "${MOCK_GH_AUTH_FAIL:-0}" == "1" && "$1" == "auth" && "$2" == "status" ]]; then
  echo "not logged in" >&2
  exit 1
fi
case "${1:-}" in
  auth) echo "ok";;
  issue)
    case "${2:-}" in
      view) cat "$MOCK_GH_ISSUE_JSON" ;;
      comment) cat > "$MOCK_GH_COMMENTS" ;;
    esac
    ;;
  pr)
    case "${2:-}" in
      create) ;;
    esac
    ;;
esac
EOF
  chmod +x "$CUSTOM_BIN/gh"
}

write_mock_delegate() {
  cat > "$CUSTOM_BIN/legion-delegate" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'legion-delegate %s\n' "$*" >> "$MOCK_CALL_LOG"
printf 'worker-env GH_TOKEN=%s GITHUB_TOKEN=%s CODEX_AUTH=%s OPENAI_API_KEY=%s ANTHROPIC_API_KEY=%s CURSOR_API_KEY=%s\n' \
  "${GH_TOKEN+set}" "${GITHUB_TOKEN+set}" "${CODEX_AUTH+set}" "${OPENAI_API_KEY+set}" \
  "${ANTHROPIC_API_KEY+set}" "${CURSOR_API_KEY+set}" >> "$MOCK_CALL_LOG"
cat "$MOCK_DELEGATE_RESULT"
EOF
  chmod +x "$CUSTOM_BIN/legion-delegate"
}

write_mock_cursor() {
  cat > "$CUSTOM_BIN/legion-cursor" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'legion-cursor %s\n' "$*" >> "$MOCK_CALL_LOG"
cat "$MOCK_DELEGATE_RESULT"
EOF
  chmod +x "$CUSTOM_BIN/legion-cursor"
}

make_patch() {
  local repo="$1" patch="$TEST_TMPDIR/change.patch"
  printf 'new\n' > "$repo/demo.txt"
  git -C "$repo" diff -- demo.txt > "$patch"
  git -C "$repo" checkout -- demo.txt
  echo "$patch"
}

@test "intake explore reads the issue and posts an assessment comment" {
  printf '{"title":"Bug title","body":"Bug body"}\n' > "$MOCK_GH_ISSUE_JSON"
  printf 'assessment\n' > "$TEST_TMPDIR/last-message.txt"
  printf '{"status":"ok","last_message_path":"%s"}\n' "$TEST_TMPDIR/last-message.txt" > "$MOCK_DELEGATE_RESULT"

  run bash -c "cd '$REPO_DIR' && env LEGION_DELEGATE_BIN=legion-delegate bash '$INTAKE' explore --issue 7 --repo acme/widgets"

  [ "$status" -eq 0 ]
  assert_mock_called gh "issue view 7 --repo acme/widgets --json title,body"
  assert_mock_called gh "issue comment 7 --repo acme/widgets --body-file -"
  assert_mock_called legion-delegate "--sandbox read-only --archetype second-opinion-review"
  grep -Fq -- "--untrusted" "$MOCK_CALL_LOG"
  grep -Fq "Title: Bug title" "$MOCK_CALL_LOG"
  grep -Fq "🤖 legion-intake explore" "$MOCK_GH_COMMENTS"
  grep -Fq "assessment" "$MOCK_GH_COMMENTS"
}

@test "intake explore can use the cursor worker contract" {
  write_mock_cursor
  printf '{"title":"Bug title","body":"Bug body"}\n' > "$MOCK_GH_ISSUE_JSON"
  printf 'cursor assessment\n' > "$TEST_TMPDIR/last-message.txt"
  printf '{"status":"ok","last_message_path":"%s"}\n' "$TEST_TMPDIR/last-message.txt" > "$MOCK_DELEGATE_RESULT"

  run bash -c "cd '$REPO_DIR' && env LEGION_CURSOR_BIN=legion-cursor bash '$INTAKE' explore --issue 8 --repo acme/widgets --worker cursor"

  [ "$status" -eq 0 ]
  assert_mock_called legion-cursor "--sandbox read-only --model cursor-auto"
  grep -Fq "cursor assessment" "$MOCK_GH_COMMENTS"
  if grep -F "legion-cursor " "$MOCK_CALL_LOG" | grep -q -- "--untrusted"; then
    echo "cursor worker should not receive delegate-only --untrusted flag" >&2
    cat "$MOCK_CALL_LOG" >&2
    false
  fi
}

@test "intake implement opens a PR when delegate returns a non-empty diff" {
  local patch; patch="$(make_patch "$REPO_DIR")"
  printf '{"title":"Fix bug","body":"Please patch it"}\n' > "$MOCK_GH_ISSUE_JSON"
  printf 'implemented summary\n' > "$TEST_TMPDIR/last-message.txt"
  printf '{"status":"ok","run_id":"r123","diff_path":"%s","last_message_path":"%s"}\n' "$patch" "$TEST_TMPDIR/last-message.txt" > "$MOCK_DELEGATE_RESULT"

  run bash -c "cd '$REPO_DIR' && env LEGION_DELEGATE_BIN=legion-delegate bash '$INTAKE' implement --issue 9 --repo acme/widgets"

  [ "$status" -eq 0 ]
  # Branch is suffixed with the delegate run id so reruns don't collide.
  assert_mock_called gh "pr create --repo acme/widgets --base main --head agent/issue-9-r123 --title Fix bug"
  assert_mock_called legion-delegate "--sandbox workspace-write --archetype implement-feature"
  grep -Fq -- "--untrusted" "$MOCK_CALL_LOG"
  [ "$(git -C "$REPO_DIR" branch --show-current)" = "agent/issue-9-r123" ]
  [ "$(git -C "$REPO_DIR" show HEAD:demo.txt)" = "new" ]
  git -C "$REPO_DIR" ls-remote --exit-code --heads origin agent/issue-9-r123 >/dev/null
  [ ! -f "$MOCK_GH_COMMENTS" ]
}

@test "intake scrubs GitHub and provider secrets from the worker env" {
  printf '{"title":"Bug title","body":"Bug body"}\n' > "$MOCK_GH_ISSUE_JSON"
  printf 'assessment\n' > "$TEST_TMPDIR/last-message.txt"
  printf '{"status":"ok","last_message_path":"%s"}\n' "$TEST_TMPDIR/last-message.txt" > "$MOCK_DELEGATE_RESULT"

  run bash -c "cd '$REPO_DIR' && env GH_TOKEN=gh GITHUB_TOKEN=gh CODEX_AUTH=secret OPENAI_API_KEY=secret ANTHROPIC_API_KEY=secret CURSOR_API_KEY=secret LEGION_DELEGATE_BIN=legion-delegate bash '$INTAKE' explore --issue 10 --repo acme/widgets"

  [ "$status" -eq 0 ]
  grep -Fq "worker-env GH_TOKEN= GITHUB_TOKEN= CODEX_AUTH= OPENAI_API_KEY= ANTHROPIC_API_KEY= CURSOR_API_KEY=" "$MOCK_CALL_LOG"
}

@test "intake implement comments instead of opening a PR when the diff is empty" {
  : > "$MOCK_GH_COMMENTS"
  : > "$TEST_TMPDIR/empty.patch"
  printf '{"title":"No-op","body":"Nothing to do"}\n' > "$MOCK_GH_ISSUE_JSON"
  printf 'no changes\n' > "$TEST_TMPDIR/last-message.txt"
  printf '{"status":"ok","diff_path":"%s","last_message_path":"%s"}\n' "$TEST_TMPDIR/empty.patch" "$TEST_TMPDIR/last-message.txt" > "$MOCK_DELEGATE_RESULT"

  run bash -c "cd '$REPO_DIR' && env LEGION_DELEGATE_BIN=legion-delegate bash '$INTAKE' implement --issue 11 --repo acme/widgets"

  [ "$status" -eq 0 ]
  assert_mock_called gh "issue comment 11 --repo acme/widgets --body-file -"
  grep -Fq "🤖 legion-intake implement" "$MOCK_GH_COMMENTS"
  grep -Fq "no changes produced" "$MOCK_GH_COMMENTS"
  grep -Fq "no changes" "$MOCK_GH_COMMENTS"
  if grep -Fq "gh pr create" "$MOCK_CALL_LOG"; then
    echo "unexpected pr create call" >&2
    cat "$MOCK_CALL_LOG" >&2
    false
  fi
}

@test "intake accepts an explicit model override" {
  printf '{"title":"Bug title","body":"Bug body"}\n' > "$MOCK_GH_ISSUE_JSON"
  printf 'assessment\n' > "$TEST_TMPDIR/last-message.txt"
  printf '{"status":"ok","last_message_path":"%s"}\n' "$TEST_TMPDIR/last-message.txt" > "$MOCK_DELEGATE_RESULT"

  run bash -c "cd '$REPO_DIR' && env LEGION_DELEGATE_BIN=legion-delegate bash '$INTAKE' explore --issue 7 --repo acme/widgets --model gpt-5.5"

  [ "$status" -eq 0 ]
  assert_mock_called legion-delegate "--sandbox read-only --model gpt-5.5"
  if grep -Fq -- "--archetype" "$MOCK_CALL_LOG"; then
    echo "unexpected archetype when explicit model was passed" >&2
    cat "$MOCK_CALL_LOG" >&2
    false
  fi
}

@test "intake fails clearly when gh is not authenticated" {
  printf '{"title":"Bug title","body":"Bug body"}\n' > "$MOCK_GH_ISSUE_JSON"

  run bash -c "cd '$REPO_DIR' && env MOCK_GH_AUTH_FAIL=1 LEGION_DELEGATE_BIN=legion-delegate bash '$INTAKE' explore --issue 13 --repo acme/widgets"

  [ "$status" -eq 2 ]
  [[ "$output" == *"gh not authenticated"* ]]
}
