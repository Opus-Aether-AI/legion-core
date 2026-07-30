#!/usr/bin/env bash
# legion-claude — delegate a scoped task to Claude headless, with automatic
# fallback to legion-delegate / Codex when Claude is unavailable or rate-limited.

set -euo pipefail

_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
# shellcheck source=lib/cost.sh
source "$_self_dir/lib/cost.sh"
# shellcheck disable=SC1091
# shellcheck source=lib/model-config.sh
source "$_self_dir/lib/model-config.sh"
# shellcheck disable=SC1091
# shellcheck source=lib/executor-context.sh
source "$_self_dir/lib/executor-context.sh"
_state_lib="$_self_dir/../../legion-observability/scripts/lib/state.sh"
if [[ -f "$_state_lib" ]]; then
  # shellcheck disable=SC1090
  # shellcheck disable=SC1091
  source "$_state_lib"
fi

CLAUDE_BIN="${CLAUDE_BIN:-claude}"
LEGION_CLAUDE_TMPDIR=""

die() { printf 'legion-claude: %s\n' "$*" >&2; exit 2; }
note() { [[ "${QUIET:-0}" == "1" ]] || printf '%s\n' "$*" >&2; }

_now()    { date -u +%Y-%m-%dT%H:%M:%SZ; }
_today()  { date -u +%Y-%m-%d; }
_run_id() { printf '%s-%s' "$(date -u +%Y%m%d-%H%M%S)" "${RANDOM}${RANDOM}"; }

emit_span() {
  local executor="$1" model="$2" status="$3" dur="$4" cost="$5" usage="$6" task="$7" artifacts="$8"
  {
    mkdir -p "$LEGION_TELEMETRY_DIR"
    local trace_id="${LEGION_TRACE_ID:-${RUN_ID:-}}"
    local parent_id="${LEGION_PARENT_ID:-}"
    jq -cn \
      --arg schema "legion.span.v1" --arg ts "$(_now)" \
      --arg run_id "${RUN_ID:-}" --arg trace_id "$trace_id" --arg parent_id "$parent_id" \
      --arg executor "$executor" --arg model "$model" --arg archetype "${LEGION_ARCHETYPE:-}" \
      --arg target_type "${LEGION_TARGET_TYPE:-}" --arg target_name "${LEGION_TARGET_NAME:-}" \
      --arg status "$status" --argjson dur "${dur:-0}" --argjson cost "${cost:-0}" \
      --argjson usage "$usage" --arg task "$task" --argjson artifacts "$artifacts" '
      {schema:$schema, ts:$ts, run_id:$run_id, trace_id:$trace_id,
       parent_id:(if $parent_id=="" then null else $parent_id end),
       executor:$executor, model:$model, archetype:$archetype, task:$task, status:$status,
       target_type:(if $target_type=="" then null else $target_type end),
       target_name:(if $target_name=="" then null else $target_name end),
       duration_ms:$dur, cost_usd:$cost, tokens:$usage, artifacts:$artifacts}' \
      >> "$LEGION_TELEMETRY_DIR/$(_today).jsonl"
  } 2>/dev/null || true
}

usage_json() {
  local file="$1"
  local usage
  usage="$(jq -c '.usage // {}' "$file" 2>/dev/null || true)"
  [[ -n "$usage" ]] && printf '%s' "$usage" || printf '{}'
}

cost_from_usage() {
  local model="$1" usage="$2"
  local input output cache_read cache_write v
  input="$(jq -r '.input_tokens // 0' <<<"$usage" 2>/dev/null || printf '0')"
  output="$(jq -r '.output_tokens // 0' <<<"$usage" 2>/dev/null || printf '0')"
  cache_read="$(jq -r '.cache_read_input_tokens // 0' <<<"$usage" 2>/dev/null || printf '0')"
  cache_write="$(jq -r '.cache_creation_input_tokens // 0' <<<"$usage" 2>/dev/null || printf '0')"
  for v in input output cache_read cache_write; do
    [[ "${!v}" =~ ^[0-9]+$ ]] || printf -v "$v" '%s' 0
  done
  cost_for_model "$model" "$input" "$output" "$cache_read" "$cache_write"
}

has_low_claude_credit() {
  printf '%s' "${LEGION_LOW_CREDIT:-}" | grep -qi 'claude'
}

is_limit_text() {
  printf '%s' "$1" | grep -qiE 'usage limit|rate.?limit|quota|exceeded|too many requests|overloaded|capacity|reached your'
}

resolve_delegate_bin() {
  if command -v legion-delegate >/dev/null 2>&1; then
    command -v legion-delegate
    return 0
  fi
  if [[ -x "$_self_dir/../bin/legion-delegate" ]]; then
    printf '%s\n' "$_self_dir/../bin/legion-delegate"
    return 0
  fi
  return 1
}

emit_terminal_json() {
  local executor="$1" model="$2" status="$3" result="$4" usage="$5" cost="$6" fell_back="$7" reason="${8:-}"
  # LEGION_CLAUDE_WORKTREE / _DIFF are set by cmd_run once a worktree exists, so a caller can
  # review the run as a diff instead of diffing the operator's tree by hand.
  jq -cn \
    --arg run_id "$RUN_ID" --arg executor "$executor" --arg model "$model" \
    --arg status "$status" --arg result "$result" --argjson usage "$usage" \
    --argjson cost "${cost:-0}" --argjson fell_back "$fell_back" --arg reason "$reason" \
    --arg wt "${LEGION_CLAUDE_WORKTREE:-}" --arg diff "${LEGION_CLAUDE_DIFF:-}" '
    {run_id:$run_id, executor:$executor, model:$model, status:$status, result:$result,
     usage:$usage, cost_usd:$cost, fell_back:$fell_back}
    + (if $reason == "" then {} else {fell_back_reason:$reason, reason:$reason} end)
    + (if $wt == "" then {} else {worktree:$wt} end)
    + (if $diff == "" then {} else {diff_path:$diff} end)'
}

run_fallback() {
  local reason="$1" task="$2" model="$3" repo="$4" sandbox="$5"
  local delegate_bin out rc fallback_status fallback_model fallback_usage fallback_cost fallback_result last_path

  delegate_bin="$(resolve_delegate_bin)" || {
    emit_terminal_json "codex" "$model" "failed" "" "{}" 0 true "$reason"
    return 1
  }

  note "→ legion-delegate run --model $model --sandbox $sandbox"
  set +e
  if [[ "${QUIET:-0}" == "1" ]]; then
    out="$("$delegate_bin" run --model "$model" --task "$task" --repo "$repo" --sandbox "$sandbox" --quiet)"
  else
    out="$("$delegate_bin" run --model "$model" --task "$task" --repo "$repo" --sandbox "$sandbox")"
  fi
  rc=$?
  set -e

  fallback_status="$(jq -r '.status // "failed"' <<<"$out" 2>/dev/null || printf 'failed')"
  fallback_model="$(jq -r '.model // empty' <<<"$out" 2>/dev/null || true)"
  [[ -n "$fallback_model" ]] || fallback_model="$model"
  fallback_usage="$(jq -c '.usage // {}' <<<"$out" 2>/dev/null || printf '{}')"
  fallback_cost="$(jq -r '.cost_usd // 0' <<<"$out" 2>/dev/null || printf '0')"
  fallback_result="$(jq -r '.result // .last_message // empty' <<<"$out" 2>/dev/null || true)"

  if [[ -z "$fallback_result" ]]; then
    last_path="$(jq -r '.last_message_path // empty' <<<"$out" 2>/dev/null || true)"
    if [[ -n "$last_path" && -f "$last_path" ]]; then
      fallback_result="$(cat "$last_path")"
    fi
  fi

  emit_terminal_json "codex" "$fallback_model" "$fallback_status" "$fallback_result" "$fallback_usage" "$fallback_cost" true "$reason"
  return "$rc"
}

cmd_run() {
  local default_model default_fallback_model
  default_model="$(legion_model_ref claude_default)" || die "could not resolve claude_default in models.toml"
  default_fallback_model="$(legion_model_ref codex_workhorse)" || die "could not resolve codex_workhorse in models.toml"

  local task="" model="${LEGION_CLAUDE_MODEL:-${CLAUDE_MODEL:-$default_model}}" repo="$PWD" fallback_model="${LEGION_CLAUDE_FALLBACK_MODEL:-${CODEX_MODEL:-$default_fallback_model}}"
  local allow_fallback=1 tmpdir="" out_file="" err_file="" artifacts="{}"
  local start_ms=0 end_ms=0 dur=0 rc=0 is_error="false" result="" usage="{}" cost="0"
  local reason="" status="failed" low_credit=0 json_ok=0 combined_text=""
  local effort="" append_sys="" skip_perms=0
  local base="HEAD" do_apply=0 keep=0 sandbox="" archetype=""
  local wt="" branch="" wt_report="" diff_path="" diff_rc=0
  local read_only_violation=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --task) task="$2"; shift 2 ;;
      --model) model="$2"; shift 2 ;;
      --repo) repo="$2"; shift 2 ;;
      --quiet) QUIET=1; shift ;;
      --no-fallback) allow_fallback=0; shift ;;
      --fallback-model) fallback_model="$2"; shift 2 ;;
      --effort) effort="$2"; shift 2 ;;                       # reasoning effort passthrough
      --append-system-prompt) append_sys="$2"; shift 2 ;;     # extra system prompt passthrough
      --dangerously-skip-permissions) skip_perms=1; shift ;;  # autonomous headless runs (opt-in)
      --base) base="$2"; shift 2 ;;                           # worktree base ref
      --apply) do_apply=1; shift ;;                           # apply the returned diff to the repo
      --keep) keep=1; shift ;;                                # retain the worktree after the run
      --sandbox) sandbox="$2"; shift 2 ;;                     # accepted for diff-contract parity
      --archetype) archetype="$2"; shift 2 ;;                 # accepted for diff-contract parity
      *) die "run: unknown arg '$1'" ;;
    esac
  done
  [[ -n "$sandbox" ]] || sandbox="workspace-write"
  case "$sandbox" in
    read-only|workspace-write) ;;
    *) die "invalid --sandbox '$sandbox' (read-only|workspace-write)" ;;
  esac
  if [[ "$sandbox" == "read-only" && "$skip_perms" -eq 1 ]]; then
    die "--dangerously-skip-permissions cannot be combined with --sandbox read-only"
  fi
  : "${archetype:-}"

  [[ -n "$task" ]] || task="$(cat)"
  [[ -n "$task" ]] || die "run: empty task"
  legion_require_top_level_executor "claude" || return $?
  repo="$(cd "$repo" && pwd)" || die "run: repo not found: $repo"
  if declare -F legion_resolve_state >/dev/null 2>&1; then
    legion_resolve_state "$repo"
  else
    export LEGION_STATE_ROOT="${LEGION_STATE_ROOT:-$HOME/.legion/projects/default}"
    export LEGION_TELEMETRY_DIR="${LEGION_TELEMETRY_DIR:-$LEGION_STATE_ROOT/spans}"
  fi
  RUN_ID="$(_run_id)"

  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/legion-claude.${RUN_ID}.XXXXXX")"
  LEGION_CLAUDE_TMPDIR="$tmpdir"
  out_file="$tmpdir/claude.out.json"
  err_file="$tmpdir/claude.err"
  artifacts="$(jq -cn --arg stdout "$out_file" --arg stderr "$err_file" '{stdout:$stdout, stderr:$stderr}')"
  trap 'rm -rf "$LEGION_CLAUDE_TMPDIR"' EXIT

  if has_low_claude_credit; then
    low_credit=1
  fi

  if ! command -v "$CLAUDE_BIN" >/dev/null 2>&1 || [[ "$low_credit" -eq 1 ]]; then
    reason="claude_unavailable"
    if [[ "$allow_fallback" -eq 1 ]]; then
      [[ "$low_credit" -eq 1 ]] && note "⚠ LEGION_LOW_CREDIT=claude: skipping Claude and falling back to $fallback_model"
      [[ "$low_credit" -eq 0 ]] && note "⚠ Claude CLI unavailable: falling back to $fallback_model"
      run_fallback "$reason" "$task" "$fallback_model" "$repo" "$sandbox"
      return $?
    fi
    emit_span "claude" "$model" "failed" 0 0 "{}" "$task" "$artifacts"
    emit_terminal_json "claude" "$model" "failed" "" "{}" 0 false "$reason"
    return 1
  fi

  # Isolate the run. Previously claude inherited the caller's working directory, so a delegated
  # run edited whatever tree the operator happened to be standing in — `--repo` only ever fed the
  # state paths. A worktree makes the work reviewable as a diff, like every other coding executor.
  if ! git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    note "⚠ repository is not a git worktree"
    emit_span "claude" "$model" "failed" 0 0 "{}" "$task" "$artifacts"
    emit_terminal_json "claude" "$model" "failed" "" "{}" 0 false "worktree_setup_failed"
    return 1
  fi
  wt="$repo/.legion/worktrees/$RUN_ID"
  branch="legion/claude-$RUN_ID"
  mkdir -p "$repo/.legion/worktrees"
  if git -C "$repo" worktree add -q -b "$branch" "$wt" "$base" 2>/dev/null; then
    # Artifacts live under the repo's run dir, not tmpdir — the EXIT trap deletes tmpdir, and
    # the diff is the reviewable output of the run.
    mkdir -p "$repo/.legion/runs/$RUN_ID"
    diff_path="$repo/.legion/runs/$RUN_ID/diff.patch"
    note "→ claude worktree $wt (branch $branch, base $base)"
  else
    note "⚠ worktree add failed"
    emit_span "claude" "$model" "failed" 0 0 "{}" "$task" "$artifacts"
    emit_terminal_json "claude" "$model" "failed" "" "{}" 0 false "worktree_setup_failed"
    return 1
  fi

  local -a claude_cmd=("$CLAUDE_BIN" -p --output-format json --model "$model")
  [[ "$sandbox" == "read-only" ]] && claude_cmd+=(--permission-mode plan)
  [[ -n "$effort" ]] && claude_cmd+=(--effort "$effort")
  [[ -n "$append_sys" ]] && claude_cmd+=(--append-system-prompt "$append_sys")
  [[ "$skip_perms" -eq 1 ]] && claude_cmd+=(--dangerously-skip-permissions)
  note "→ ${claude_cmd[*]}"
  start_ms="$(date +%s000)"
  set +e
  printf '%s' "$task" | (
    legion_activate_executor_context "$RUN_ID"
    cd "${wt:-$repo}"
    "${claude_cmd[@]}"
  ) >"$out_file" 2>"$err_file"
  rc=${PIPESTATUS[1]}
  set -e

  if [[ -n "$wt" ]]; then
    git -C "$wt" add -A 2>/dev/null || diff_rc=1
    git -C "$wt" diff --cached >"$diff_path" 2>/dev/null || diff_rc=1
    [[ "$diff_rc" -ne 0 ]] && note "⚠ could not capture a diff from $wt"
    if [[ "$sandbox" == "read-only" && -s "$diff_path" ]]; then
      read_only_violation=1
      note "⚠ Claude produced file changes during a read-only run; refusing the result"
    fi
    if [[ "$do_apply" -eq 1 && "$read_only_violation" -eq 0 && -s "$diff_path" ]]; then
      if git -C "$repo" apply --check "$diff_path" 2>/dev/null; then
        git -C "$repo" apply "$diff_path" && note "diff applied to $repo"
      else
        note "diff did not apply cleanly; left in $diff_path"
      fi
    fi
    wt_report="$wt"
    if [[ "$keep" -ne 1 ]]; then
      # The worktree goes; the patch stays. It already lives outside the worktree.
      git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1 || true
      git -C "$repo" branch -D "$branch" >/dev/null 2>&1 || true
      git -C "$repo" worktree prune >/dev/null 2>&1 || true
      wt_report="(removed; rerun with --keep to retain the worktree)"
    fi
    artifacts="$(jq -cn --arg stdout "$out_file" --arg stderr "$err_file" \
      --arg wt "$wt_report" --arg diff "$diff_path" \
      '{stdout:$stdout, stderr:$stderr, worktree:$wt, diff:$diff}')"
    export LEGION_CLAUDE_WORKTREE="$wt_report" LEGION_CLAUDE_DIFF="$diff_path"
  fi
  end_ms="$(date +%s000)"
  dur=$(( end_ms - start_ms ))

  if jq -e . "$out_file" >/dev/null 2>&1; then
    json_ok=1
    is_error="$(jq -r '.is_error // false' "$out_file" 2>/dev/null || printf 'false')"
    result="$(jq -r '.result // ""' "$out_file" 2>/dev/null || true)"
    usage="$(usage_json "$out_file")"
    if jq -e '.total_cost_usd | numbers' "$out_file" >/dev/null 2>&1; then
      cost="$(jq -r '.total_cost_usd' "$out_file")"
    else
      cost="$(cost_from_usage "$model" "$usage" 2>/dev/null || printf '0')"
    fi
  fi

  combined_text="$result"
  if [[ -s "$err_file" ]]; then
    combined_text="${combined_text}"$'\n'"$(cat "$err_file")"
  fi

  if [[ "$read_only_violation" -eq 1 ]]; then
    reason="read_only_violation"
    status="failed"
    [[ -n "$result" ]] && result="${result}"$'\n'
    result="${result}Claude produced file changes during a read-only run."
    emit_span "claude" "$model" "$status" "$dur" "$cost" "$usage" "$task" "$artifacts"
    emit_terminal_json "claude" "$model" "$status" "$result" "$usage" "$cost" false "$reason"
    return 1
  fi

  if [[ "$rc" -eq 0 && "$json_ok" -eq 1 && "$is_error" != "true" ]]; then
    status="ok"
    emit_span "claude" "$model" "$status" "$dur" "$cost" "$usage" "$task" "$artifacts"
    emit_terminal_json "claude" "$model" "$status" "$result" "$usage" "$cost" false
    return 0
  fi

  if { [[ "$is_error" == "true" ]] || [[ "$rc" -ne 0 ]]; } && is_limit_text "$combined_text"; then
    reason="claude_limit"
  else
    reason="claude_error"
  fi

  if [[ "$allow_fallback" -eq 1 ]]; then
    status="$([[ "$reason" == "claude_limit" ]] && printf blocked || printf failed)"
    emit_span "claude" "$model" "$status" "$dur" "$cost" "$usage" "$task" "$artifacts"
    note "⚠ Claude failed ($reason): falling back to $fallback_model"
    run_fallback "$reason" "$task" "$fallback_model" "$repo" "$sandbox"
    return $?
  fi

  if [[ "$reason" == "claude_limit" ]]; then
    status="blocked"
  else
    status="failed"
  fi
  emit_span "claude" "$model" "$status" "$dur" "$cost" "$usage" "$task" "$artifacts"
  emit_terminal_json "claude" "$model" "$status" "$result" "$usage" "$cost" false "$reason"
  return 1
}

usage() {
  cat <<'EOF'
legion-claude — delegate a scoped task to Claude headless, with fallback to Codex.

Usage:
  legion-claude run --task "TASK" [--model MODEL] [--repo DIR] [--effort LEVEL]
                    [--base REF] [--apply] [--keep]
                    [--sandbox read-only|workspace-write] [--archetype NAME]
                    [--append-system-prompt TEXT] [--dangerously-skip-permissions]
                    [--quiet] [--no-fallback] [--fallback-model MODEL]
  legion-claude run [--model MODEL] [--repo DIR] [...] < task.txt

The run happens in a git worktree under <repo>/.legion/worktrees/ and returns a diff at
<repo>/.legion/runs/<run-id>/diff.patch, so it never edits the caller's working tree.
--keep retains the worktree; --apply applies the diff to the repo.
Read-only runs use Claude plan mode and fail if the worktree still changes.

--effort / --append-system-prompt / --dangerously-skip-permissions pass through to
`claude -p` (skip-permissions is for autonomous headless/cron runs — opt-in).
Defaults resolve from legion-router/config/models.toml.
EOF
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    run) shift; cmd_run "$@" ;;
    ""|-h|--help|help) usage ;;
    *) die "unknown command '$cmd'" ;;
  esac
}

main "$@"
