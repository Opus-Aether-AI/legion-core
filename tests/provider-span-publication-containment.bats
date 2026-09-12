#!/usr/bin/env bats

load 'helpers/setup'

setup() {
  setup_test_env
  export LEGION_STATE_ROOT="$TEST_TMPDIR/state"
  export LEGION_TELEMETRY_DIR="$TEST_TMPDIR/spans"
  export LEGION_REGISTRY_DIR="$LEGION_STATE_ROOT/registry"
  export LEGION_COSTS_FILE="$REPO_ROOT/legion-router/config/costs.json"
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
  printf 'export const value = 1\n' > "$repo/foo.ts"
  git -C "$repo" add foo.ts
  git -C "$repo" commit -qm init
  printf '%s' "$repo"
}

assert_retained_publication_containment() {
  local result="$1" stage="$2" attempt worktree count
  jq -e '.status == "containment_failed"
    and ((.result // .reason) | contains("span publication is uncertain"))
    and (.attempt_receipt | type) == "string"' <<<"$result"
  attempt="$(jq -r '.attempt_receipt' <<<"$result")"
  worktree="$(jq -r '.worktree' <<<"$result")"
  [ -f "$attempt" ]
  [ -d "$worktree" ]
  count=0
  if compgen -G "$LEGION_TELEMETRY_DIR/*.jsonl" >/dev/null; then
    count="$(jq -s --arg attempt "$attempt" \
      '[.[] | select(.artifacts.provider_attempt == true
        and .artifacts.attempt_receipt == $attempt)] | length' \
      "$LEGION_TELEMETRY_DIR"/*.jsonl)"
  fi
  if [[ "$stage" == commit ]]; then
    [ "$count" -eq 1 ]
  else
    [ "$count" -eq 0 ]
  fi
}

@test "direct adapters retain containment for deterministic claim append and commit failures" {
  local adapter stage repo result model
  for adapter in cursor opencode deepseek claude pi hermes; do
    for stage in claim append commit; do
      repo="$(make_test_repo "$adapter-$stage")"
      model=openai/fixture-model
      [[ "$adapter" != pi ]] || model=openai/fixture-pi
      [[ "$adapter" != hermes ]] || model=openai/fixture-hermes
      if [[ "$adapter" == claude ]]; then
        LEGION_TEST_PROVIDER_SPAN_FAULTS=1 \
          LEGION_TEST_PROVIDER_SPAN_FAULT_STAGE="$stage" \
          run "$REPO_ROOT/legion-router/bin/legion-claude" run \
            --task inspect --model "$model" --repo "$repo" --no-fallback --quiet
      elif [[ "$adapter" == pi ]]; then
        LEGION_TEST_PROVIDER_SPAN_FAULTS=1 \
          LEGION_TEST_PROVIDER_SPAN_FAULT_STAGE="$stage" PI_BIN=pi \
          run "$REPO_ROOT/legion-router/bin/legion-pi" run \
            --task inspect --model "$model" --repo "$repo" --quiet
      elif [[ "$adapter" == hermes ]]; then
        LEGION_TEST_PROVIDER_SPAN_FAULTS=1 \
          LEGION_TEST_PROVIDER_SPAN_FAULT_STAGE="$stage" HERMES_BIN=hermes \
          run "$REPO_ROOT/legion-router/bin/legion-hermes" run \
            --task inspect --model "$model" --repo "$repo" --quiet
      elif [[ "$adapter" == deepseek ]]; then
        LEGION_TEST_PROVIDER_SPAN_FAULTS=1 \
          LEGION_TEST_PROVIDER_SPAN_FAULT_STAGE="$stage" \
          run "$REPO_ROOT/legion-router/bin/legion-deepseek" run \
            --task inspect --repo "$repo" --quiet
      else
        LEGION_TEST_PROVIDER_SPAN_FAULTS=1 \
          LEGION_TEST_PROVIDER_SPAN_FAULT_STAGE="$stage" \
          run "$REPO_ROOT/legion-router/bin/legion-$adapter" run \
            --task inspect --model "$model" --repo "$repo" --quiet
      fi
      [ "$status" -ne 0 ]
      result="$(printf '%s\n' "$output" | tail -n 1)"
      assert_retained_publication_containment "$result" "$stage"
    done
  done
}

@test "Claude defers --apply until provider-span publication is acknowledged" {
  local stage repo result worktree
  for stage in claim append commit; do
    repo="$(make_test_repo "claude-apply-$stage")"
    LEGION_TEST_PROVIDER_SPAN_FAULTS=1 \
      LEGION_TEST_PROVIDER_SPAN_FAULT_STAGE="$stage" MOCK_CLAUDE_WRITE=1 \
      run "$REPO_ROOT/legion-router/bin/legion-claude" run \
        --task edit --model openai/fixture-model --repo "$repo" \
        --apply --no-fallback --quiet
    [ "$status" -ne 0 ]
    result="$(printf '%s\n' "$output" | tail -n 1)"
    assert_retained_publication_containment "$result" "$stage"
    [ ! -e "$repo/claude-unexpected.txt" ]
    worktree="$(jq -r .worktree <<<"$result")"
    [ -f "$worktree/claude-unexpected.txt" ]
  done

  repo="$(make_test_repo claude-apply-success)"
  MOCK_CLAUDE_WRITE=1 run "$REPO_ROOT/legion-router/bin/legion-claude" run \
    --task edit --model openai/fixture-model --repo "$repo" \
    --apply --no-fallback --quiet
  [ "$status" -eq 0 ]
  [ -f "$repo/claude-unexpected.txt" ]
}

@test "native run review and resume retain containment for every publication stage" {
  local path="$REPO_ROOT/legion-router/scripts/delegate.sh"
  local operation stage repo result initial run_id
  for operation in run review resume; do
    for stage in claim append commit; do
      repo="$(make_test_repo "native-$operation-$stage")"
      if [[ "$operation" == run ]]; then
        LEGION_TEST_PROVIDER_SPAN_FAULTS=1 \
          LEGION_TEST_PROVIDER_SPAN_FAULT_STAGE="$stage" \
          run "$path" run --model test-model-alpha --task inspect --repo "$repo" --quiet
      elif [[ "$operation" == review ]]; then
        LEGION_TEST_PROVIDER_SPAN_FAULTS=1 \
          LEGION_TEST_PROVIDER_SPAN_FAULT_STAGE="$stage" \
          run "$path" review --archetype security-review --base HEAD --repo "$repo" --quiet
      else
        initial="$($path run --model test-model-alpha --task initial --repo "$repo" --keep --quiet)"
        run_id="$(jq -r .run_id <<<"$initial")"
        LEGION_TEST_PROVIDER_SPAN_FAULTS=1 \
          LEGION_TEST_PROVIDER_SPAN_FAULT_STAGE="$stage" \
          run "$path" resume --run "$run_id" --task inspect --repo "$repo" --quiet
      fi
      [ "$status" -ne 0 ]
      result="$(printf '%s\n' "$output" | tail -n 1)"
      assert_retained_publication_containment "$result" "$stage"
    done
  done
}

@test "commit uncertainty retries reconcile to the existing durable span" {
  local repo result attempt before after
  repo="$(make_test_repo exact-once)"
  LEGION_TEST_PROVIDER_SPAN_FAULTS=1 LEGION_TEST_PROVIDER_SPAN_FAULT_STAGE=commit \
    run "$REPO_ROOT/legion-router/bin/legion-cursor" run \
      --task inspect --model openai/fixture-model --repo "$repo" --quiet
  [ "$status" -ne 0 ]
  result="$(printf '%s\n' "$output" | tail -n 1)"
  attempt="$(jq -r .attempt_receipt <<<"$result")"
  before="$(jq -s --arg attempt "$attempt" \
    '[.[] | select(.artifacts.provider_attempt == true
      and .artifacts.attempt_receipt == $attempt)] | length' \
    "$LEGION_TELEMETRY_DIR"/*.jsonl)"
  [ "$before" -eq 1 ]

  run bash -c '
    set -euo pipefail
    source "$1"
    LEGION_TELEMETRY_DIR="$2"
    emit_span() { return 99; }
    legion_adapter_emit_normal_provider_span "$3"
  ' _ "$REPO_ROOT/legion-router/scripts/lib/adapter-contract.sh" \
    "$LEGION_TELEMETRY_DIR" "$attempt"
  [ "$status" -eq 0 ]
  after="$(jq -s --arg attempt "$attempt" \
    '[.[] | select(.artifacts.provider_attempt == true
      and .artifacts.attempt_receipt == $attempt)] | length' \
    "$LEGION_TELEMETRY_DIR"/*.jsonl)"
  [ "$after" -eq 1 ]
}

@test "signal-path publication failure terminalizes retained containment" {
  local adapter repo run_id out err pid rc marker delay_name art
  local -a args extra_env
  for adapter in cursor opencode deepseek claude pi hermes; do
    repo="$(make_test_repo "signal-$adapter")"
    run_id="signal-publication-$adapter"
    out="$TEST_TMPDIR/$adapter-signal.out"
    err="$TEST_TMPDIR/$adapter-signal.err"
    art="$repo/.legion/runs/$run_id"
    args=("$REPO_ROOT/legion-router/bin/legion-$adapter" run --task wait
      --repo "$repo" --run-id "$run_id" --quiet)
    extra_env=()
    case "$adapter" in
      cursor) marker='agent -p'; delay_name=MOCK_CURSOR_DELAY ;;
      opencode)
        marker='opencode run'; delay_name=MOCK_OPENCODE_ERROR_DELAY
        extra_env+=(MOCK_OPENCODE_ERROR_EVENT=1)
        ;;
      deepseek) marker='dsh --profile'; delay_name=MOCK_DSH_DELAY ;;
      claude)
        marker='claude -p'; delay_name=MOCK_CLAUDE_DELAY
        args+=(--no-fallback)
        ;;
      pi)
        marker='pi -p'; delay_name=MOCK_PI_DELAY
        args+=(--model openai/fixture-pi)
        extra_env+=(PI_BIN=pi)
        ;;
      hermes)
        marker='hermes --oneshot'; delay_name=MOCK_HERMES_DELAY
        args+=(--model openai/fixture-hermes)
        extra_env+=(HERMES_BIN=hermes)
        ;;
    esac
    env LEGION_TEST_PROVIDER_SPAN_FAULTS=1 \
      LEGION_TEST_PROVIDER_SPAN_FAULT_STAGE=claim "$delay_name=30" \
      "${extra_env[@]}" "${args[@]}" >"$out" 2>"$err" &
    pid=$!
    for _ in $(seq 1 200); do
      grep -q "$marker" "$MOCK_CALL_LOG" 2>/dev/null && break
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.05
    done
    grep -q "$marker" "$MOCK_CALL_LOG"
    if [[ "$adapter" == pi || "$adapter" == hermes ]]; then
      for _ in $(seq 1 200); do
        jq -e '.status == "started"' "$art/tmp/provider-launch.json" >/dev/null 2>&1 && break
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.05
      done
      jq -e '.status == "started"' "$art/tmp/provider-launch.json" >/dev/null
    fi
    kill -TERM "$pid"
    rc=0
    wait "$pid" || rc=$?
    [ "$rc" -eq 70 ]
    jq -e '.terminal_status == "cancelled" and .failure.class == "cancelled"' \
      "$art/attempt-1.json"
    jq -e --slurpfile attempt "$art/attempt-1.json" \
      '.class == "internal" and (.message | contains("span publication is uncertain"))
      and .attempt_id == $attempt[0].attempt_id' "$art/post-attempt-failure-1.json"
    [ -d "$repo/.legion/worktrees/$run_id" ]
    jq -e '.lifecycle.phase == "containment_failed"' \
      "$LEGION_REGISTRY_DIR/$run_id.json"
  done
}
