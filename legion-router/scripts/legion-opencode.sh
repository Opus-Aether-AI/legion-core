#!/usr/bin/env bash
# legion-opencode — delegate a scoped task to opencode headless (`opencode run
# --format json`) and capture a metered Legion span + diff. opencode's JSON
# format is a JSONL EVENT STREAM (not one object): `message.updated` events carry
# an AssistantMessage with a PRECOMPUTED `cost` (USD) and nested `tokens`
# ({input,output,reasoning,cache:{read,write}}); text streams via
# `message.part.updated`. This mirrors legion-cursor.sh (worktree + diff + span)
# with opencode-specific invocation and parsing.

set -euo pipefail

_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
# shellcheck source=lib/cost.sh
source "$_self_dir/lib/cost.sh"
# shellcheck disable=SC1091
# shellcheck source=lib/model-config.sh
source "$_self_dir/lib/model-config.sh"
_state_lib="$_self_dir/../../legion-observability/scripts/lib/state.sh"
if [[ -f "$_state_lib" ]]; then
  # shellcheck disable=SC1091
  source "$_state_lib"
fi

OPENCODE_BIN="${OPENCODE_BIN:-}"

die() { printf 'legion-opencode: %s\n' "$*" >&2; exit 2; }
note() { [[ "${QUIET:-0}" == "1" ]] || printf '%s\n' "$*" >&2; }

_now()    { date -u +%Y-%m-%dT%H:%M:%SZ; }
_today()  { date -u +%Y-%m-%d; }
_run_id() { printf '%s-%s' "$(date -u +%Y%m%d-%H%M%S)" "${RANDOM}${RANDOM}"; }

# Resolve the opencode binary. PIN $HOME/.opencode/bin first: a stray `opencode`
# on PATH (e.g. OpenWork's bundled build) is a different, incompatible binary.
resolve_opencode_bin() {
  if [[ -n "$OPENCODE_BIN" ]]; then
    command -v "$OPENCODE_BIN" 2>/dev/null && return 0
    [[ -x "$OPENCODE_BIN" ]] && { printf '%s\n' "$OPENCODE_BIN"; return 0; }
    return 1
  fi
  [[ -x "$HOME/.opencode/bin/opencode" ]] && { printf '%s\n' "$HOME/.opencode/bin/opencode"; return 0; }
  command -v opencode 2>/dev/null && return 0
  return 1
}

require_git_repo() {
  git -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git repo: $1"
}

validate_sandbox() {
  case "$1" in
    read-only|workspace-write) return 0 ;;
    *) die "invalid --sandbox '$1' (read-only|workspace-write)" ;;
  esac
}

scan_task_text() {
  local text="$1"
  [[ "${LEGION_ALLOW_UNSAFE:-0}" == "1" ]] && return 0
  local norm
  norm="$(printf '%s' "$text" | tr -s '[:space:]' ' ')"
  local patterns='rm -rf|rm -fr|rm -[a-z]*r[a-z]* /|git push|--force|force[ -]push|:\(\)\{|/etc/(passwd|shadow)|\.ssh|id_rsa|\.aws/|\.netrc|AWS_SECRET|ANTHROPIC_API_KEY|OPENAI_API_KEY|(curl|wget|fetch)[^|]*\|[[:space:]]*(ba)?sh|nc |ncat|/dev/tcp|DROP TABLE|sudo'
  if printf '%s' "$norm" | grep -qiE "$patterns"; then
    die "task text matched a dangerous/injection pattern; refusing write delegation. Review the task, or set LEGION_ALLOW_UNSAFE=1 to override."
  fi
}

emit_span() {
  local executor="$1" model="$2" status="$3" dur="$4" cost="$5" usage="$6" task="$7" artifacts="$8"
  {
    mkdir -p "$LEGION_TELEMETRY_DIR"
    local trace_id="${LEGION_TRACE_ID:-${RUN_ID:-}}"
    local parent_id="${LEGION_PARENT_ID:-}"
    jq -cn \
      --arg schema "legion.span.v1" --arg ts "$(_now)" \
      --arg run_id "${RUN_ID:-}" --arg trace_id "$trace_id" --arg parent_id "$parent_id" \
      --arg executor "$executor" --arg model "$model" --arg archetype "${archetype:-}" \
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

# Parse the opencode JSONL event stream into a compact
# {cost, model, usage:{…canonical snake_case…}, result} object (one jq pass).
# A message streams as many message.updated events sharing one id; take the LAST
# state per id (group_by(.id)|map(.[-1])) then SUM across distinct assistant
# messages so a multi-turn run is metered correctly (never per-event double-count).
parse_opencode_output() {
  local file="$1" out
  out="$(jq -s -c '
    ([.[] | select(.type=="message.updated" and (.properties.info.role? == "assistant"))
       | .properties.info] | group_by(.id) | map(.[-1])) as $msgs
    | ([.[] | select(.type=="message.part.updated" and (.properties.part.type? == "text"))]
       | group_by(.properties.part.id) | map(.[-1].properties.part.text) | join("\n")) as $text
    | {
        cost:  ([$msgs[].cost] | add // 0),
        model: ($msgs | last | if . == null then "" else ((.providerID // "") + "/" + (.modelID // "")) end),
        usage: {
          input_tokens:                ([$msgs[].tokens.input]       | add // 0),
          output_tokens:               ([$msgs[].tokens.output]      | add // 0),
          reasoning_output_tokens:     ([$msgs[].tokens.reasoning]   | add // 0),
          cache_read_input_tokens:     ([$msgs[].tokens.cache.read]  | add // 0),
          cache_creation_input_tokens: ([$msgs[].tokens.cache.write] | add // 0)
        },
        result: ($text // "")
      }' "$file" 2>/dev/null)" || out=""
  [[ -n "$out" ]] && printf '%s' "$out" || printf '{"cost":0,"model":"","usage":{},"result":""}'
}

cmd_run() {
  local default_model
  default_model="$(legion_model_ref opencode_default)" || die "could not resolve opencode_default in models.toml"

  local task="" model="${LEGION_OPENCODE_MODEL:-${OPENCODE_MODEL:-$default_model}}" repo="$PWD" base="HEAD" sandbox="workspace-write"
  local archetype="${LEGION_ARCHETYPE:-}"
  local do_apply=0 keep=0 oc_bin="" start_ms=0 end_ms=0 dur=0 rc=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --task) task="$2"; shift 2 ;;
      --model) model="$2"; shift 2 ;;
      --archetype) archetype="$2"; shift 2 ;;
      --repo) repo="$2"; shift 2 ;;
      --base) base="$2"; shift 2 ;;
      --sandbox) sandbox="$2"; shift 2 ;;
      --apply) do_apply=1; shift ;;
      --keep) keep=1; shift ;;
      --quiet) QUIET=1; shift ;;
      *) die "run: unknown arg '$1'" ;;
    esac
  done

  [[ -n "$task" ]] || task="$(cat)"
  [[ -n "$task" ]] || die "run: empty task"
  validate_sandbox "$sandbox"
  [[ "$sandbox" == "read-only" ]] || scan_task_text "$task"
  oc_bin="$(resolve_opencode_bin)" || die "opencode CLI not found. Install opencode or set OPENCODE_BIN (expected \$HOME/.opencode/bin/opencode)."
  repo="$(cd "$repo" && pwd)"; require_git_repo "$repo"
  if declare -F legion_resolve_state >/dev/null 2>&1; then
    legion_resolve_state "$repo"
  else
    export LEGION_STATE_ROOT="${LEGION_STATE_ROOT:-$HOME/.legion/projects/default}"
    export LEGION_TELEMETRY_DIR="${LEGION_TELEMETRY_DIR:-$LEGION_STATE_ROOT/spans}"
  fi

  RUN_ID="$(_run_id)"
  local wt="$repo/.legion/worktrees/$RUN_ID"
  local art="$repo/.legion/runs/$RUN_ID"
  local branch="legion/opencode-$RUN_ID"
  mkdir -p "$art"
  printf '*\n' > "$repo/.legion/.gitignore" 2>/dev/null || true

  note "-> opencode worktree $wt (branch $branch, base $base)"
  git -C "$repo" worktree add -q -b "$branch" "$wt" "$base" || die "worktree add failed"

  local out_file="$art/opencode.out.jsonl"
  local err_file="$art/opencode.err"
  local -a cmd
  cmd=("$oc_bin" run --format json)
  [[ -n "$model" ]] && cmd+=(-m "$model")
  [[ -n "${LEGION_OPENCODE_VARIANT:-}" ]] && cmd+=(--variant "$LEGION_OPENCODE_VARIANT")
  # read-only maps to the non-writing `plan` agent (mirrors cursor's --mode plan).
  [[ "$sandbox" == "read-only" ]] && cmd+=(--agent plan)
  cmd+=("$task")

  note "-> ${cmd[*]}"
  start_ms="$(date +%s000)"
  set +e
  ( cd "$wt" && "${cmd[@]}" >"$out_file" 2>"$err_file" )
  rc=$?
  set -e
  end_ms="$(date +%s000)"; dur=$(( end_ms - start_ms ))

  local parsed usage cost result actual_model diff_rc=0 status="ok"
  parsed="$(parse_opencode_output "$out_file")"
  usage="$(jq -c '.usage // {}' <<<"$parsed" 2>/dev/null || printf '{}')"
  cost="$(jq -r '.cost // 0' <<<"$parsed" 2>/dev/null || printf '0')"
  actual_model="$(jq -r '.model // ""' <<<"$parsed" 2>/dev/null || printf '')"
  [[ -n "$actual_model" && "$actual_model" != "/" ]] || actual_model="$model"
  result="$(jq -r '.result // ""' <<<"$parsed" 2>/dev/null || printf '')"

  git -C "$wt" add -A 2>/dev/null || diff_rc=1
  git -C "$wt" diff --cached >"$art/diff.patch" 2>/dev/null || diff_rc=1
  [[ "$rc" -ne 0 ]] && status="failed"
  [[ "$diff_rc" -ne 0 && "$status" == "ok" ]] && status="error"
  if [[ "$sandbox" == "read-only" && -s "$art/diff.patch" && "$status" == "ok" ]]; then
    status="error"
    [[ -n "$result" ]] && result="${result}"$'\n'
    result="${result}opencode produced file changes during a read-only run; refusing to apply or report ok."
  fi
  printf '%s\n' "$result" > "$art/last-message.txt"

  local artifacts
  artifacts="$(jq -cn --arg wt "$wt" --arg diff "$art/diff.patch" --arg last "$art/last-message.txt" \
    --arg stdout "$out_file" --arg stderr "$err_file" \
    '{worktree:$wt, diff:$diff, last_message:$last, stdout:$stdout, stderr:$stderr}')"
  emit_span "opencode" "$actual_model" "$status" "$dur" "$cost" "$usage" "$task" "$artifacts"

  if [[ "$do_apply" -eq 1 && "$status" == "ok" && -s "$art/diff.patch" ]]; then
    if git -C "$repo" apply --check "$art/diff.patch" 2>/dev/null; then
      git -C "$repo" apply "$art/diff.patch" && note "diff applied to $repo"
    else
      note "diff did not apply cleanly; left in $art/diff.patch"
    fi
  fi

  local wt_report="$wt"
  if [[ "$keep" -eq 0 ]]; then
    git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
    git -C "$repo" branch -D "$branch" >/dev/null 2>&1 || true
    git -C "$repo" worktree prune >/dev/null 2>&1 || true
    wt_report="(removed; rerun with --keep to retain the worktree)"
  fi

  jq -cn --arg run "$RUN_ID" --arg status "$status" --arg model "$actual_model" \
    --arg wt "$wt_report" --arg diff "$art/diff.patch" --arg last "$art/last-message.txt" \
    --arg result "$result" --argjson usage "$usage" --argjson cost "${cost:-0}" --argjson rc "$rc" '
    {run_id:$run, status:$status, executor:"opencode", model:$model, opencode_exit:$rc,
     result:$result, worktree:$wt, diff_path:$diff, last_message_path:$last,
     usage:$usage, cost_usd:$cost}'
  [[ "$status" == "ok" ]] || exit 1
}

usage() {
  cat <<'EOF'
legion-opencode — delegate a scoped task to opencode headless.

Usage:
  legion-opencode run --task "TASK" [--model provider/model] [--archetype NAME] [--repo DIR]
                      [--base REF] [--sandbox read-only|workspace-write] [--apply] [--keep] [--quiet]
  legion-opencode run [--repo DIR] < task.txt

Model is provider/model (e.g. minimax/MiniMax-M2); default resolves from
legion-router/config/models.toml (opencode_default). Set OPENCODE_BIN to override
the binary; Legion pins $HOME/.opencode/bin/opencode first. LEGION_OPENCODE_VARIANT
sets the reasoning variant (high|max|minimal).
EOF
}

main() {
  local subcmd="${1:-}"
  case "$subcmd" in
    run) shift; cmd_run "$@" ;;
    ""|-h|--help|help) usage ;;
    *) die "unknown command '$subcmd'" ;;
  esac
}

main "$@"
