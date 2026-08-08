#!/usr/bin/env bash
# legion-delegate — hand a scoped task to an external model agent (Codex)
# and bring back a verified, metered diff.
#
# The honest model: `codex exec` is an autonomous agent (task -> edits), not a chat
# endpoint, so GPT work runs OUT-OF-BAND here (not through the :8082 proxy). This
# wrapper isolates it in a git worktree, captures the diff + last message + token
# usage, prices it via cost.sh, emits a telemetry span, and best-effort POSTs the
# usage to the router /ingest sink so cost shows up next to Claude.
#
# Commands:
#   run     --model M [--sandbox S] [--task T | stdin] [--repo DIR] [--base REF]
#           [--budget-tokens N] [--scope PATHSPEC] [--detach] [--apply] [--quiet]
#   review  --model M --base REF [--head REF] [--max-attempts N] [--repo DIR]
#           [--task BOUNDED_REVIEW_INSTRUCTIONS]
#   apply   --run RUN_ID [--repo DIR]          # apply a captured diff to the repo
#   status  --run RUN_ID [--repo DIR]
#   cleanup [--run RUN_ID | --all] [--repo DIR]
#
# Safety: default sandbox is workspace-write for `run`, read-only for `review`.
#   docker/podman/vercel are optional Sandcastle-backed OS/VM sandboxes, used
#   only when explicitly requested.
#   danger-full-access is hard-blocked unless LEGION_ALLOW_DANGER=1.
#   Task text is scanned for injection/dangerous patterns before any write run
#   (override with LEGION_ALLOW_UNSAFE=1).
#
# Env: LEGION_ROUTER_URL (http://127.0.0.1:8082), LEGION_TELEMETRY_DIR,
#      LEGION_COSTS_FILE, CODEX_BIN (default: codex).

set -euo pipefail

_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
# shellcheck source=lib/codex-json.sh
source "$_self_dir/lib/codex-json.sh"
# shellcheck disable=SC1091
# shellcheck source=lib/cost.sh
source "$_self_dir/lib/cost.sh"
# shellcheck disable=SC1091
# shellcheck source=lib/model-config.sh
source "$_self_dir/lib/model-config.sh"
# shellcheck disable=SC1091
# shellcheck source=lib/executor-context.sh
source "$_self_dir/lib/executor-context.sh"
# shellcheck disable=SC1091
# shellcheck source=lib/task-scan.sh
source "$_self_dir/lib/task-scan.sh"

# shellcheck disable=SC1091
# shellcheck source=lib/primary.sh
source "$_self_dir/lib/primary.sh"
# shellcheck disable=SC1091
# shellcheck source=lib/sandbox-setup.sh
source "$_self_dir/lib/sandbox-setup.sh"
_state_lib="$_self_dir/../../legion-observability/scripts/lib/state.sh"
if [[ -f "$_state_lib" ]]; then
  # shellcheck disable=SC1090
  # shellcheck disable=SC1091
  source "$_state_lib"
fi

CODEX_BIN="${CODEX_BIN:-codex}"
LEGION_ROUTER_URL="${LEGION_ROUTER_URL:-http://127.0.0.1:8082}"

resolve_runtime_state() {
  if declare -F legion_resolve_state >/dev/null 2>&1; then
    legion_resolve_state "$1"
  else
    export LEGION_STATE_ROOT="${LEGION_STATE_ROOT:-$HOME/.legion/projects/default}"
    export LEGION_TELEMETRY_DIR="${LEGION_TELEMETRY_DIR:-$LEGION_STATE_ROOT/spans}"
    export LEGION_REGISTRY_DIR="${LEGION_REGISTRY_DIR:-$LEGION_STATE_ROOT/registry}"
    export LEGION_REPOS_FILE="${LEGION_REPOS_FILE:-$LEGION_STATE_ROOT/repos.jsonl}"
  fi
}
# Global, NON-purgeable run registry (Console/handoff foundation): a run stays
# discoverable here even after `cleanup --purge` wipes the repo's .legion/.

die() { printf 'legion-delegate: %s\n' "$*" >&2; exit 2; }
note() { [[ "${QUIET:-0}" == "1" ]] || printf '%s\n' "$*" >&2; }

SANDBOX_DEV_PID_TO_TEARDOWN=""
cleanup_sandbox_dev_on_exit() {
  sandbox_teardown "$SANDBOX_DEV_PID_TO_TEARDOWN" || true
  SANDBOX_DEV_PID_TO_TEARDOWN=""
}
# Worktree leak guard: cmd_run registers its worktree here right after creating
# it, so the EXIT trap removes it (+ its legion/delegate-* branch) even if the
# run crashes or is killed before the inline cleanup. The happy path clears
# LEGION_WT_PATH after its own removal, making this a no-op; --keep sets
# LEGION_WT_KEEP=1 so the worktree is retained.
LEGION_WT_PATH=""; LEGION_WT_BRANCH=""; LEGION_WT_REPO=""; LEGION_WT_KEEP=0
cleanup_worktree_on_exit() {
  [[ "$LEGION_WT_KEEP" == "1" ]] && return 0
  [[ -n "$LEGION_WT_PATH" && -n "$LEGION_WT_REPO" ]] || return 0
  git -C "$LEGION_WT_REPO" worktree remove --force "$LEGION_WT_PATH" >/dev/null 2>&1 || rm -rf "$LEGION_WT_PATH"
  [[ -n "$LEGION_WT_BRANCH" ]] && git -C "$LEGION_WT_REPO" branch -D "$LEGION_WT_BRANCH" >/dev/null 2>&1 || true
  git -C "$LEGION_WT_REPO" worktree prune >/dev/null 2>&1 || true
  LEGION_WT_PATH=""
}
trap 'declare -F legion_terminalize_adopted_run_on_exit >/dev/null 2>&1 && legion_terminalize_adopted_run_on_exit; cleanup_sandbox_dev_on_exit; cleanup_worktree_on_exit' EXIT

# codex is launched in the background and immediately waited on, so a terminating
# signal to this wrapper interrupts the `wait` and runs this handler — otherwise a
# `kill`/hangup of the wrapper would leave codex orphaned (still billing, its
# stream.jsonl still growing). Best-effort: TERM the tracked child plus any codex
# grandchild (review/resume wrap it in a `( cd … && codex )` subshell).
CODEX_CHILD_PID=""
REVIEW_RECEIPT_PATH=""
REVIEW_RECEIPT_RUN_ID=""
REVIEW_RECEIPT_MODEL=""
REVIEW_RECEIPT_ARCHETYPE=""
REVIEW_RECEIPT_BASE_SHA=""
REVIEW_RECEIPT_HEAD_SHA=""
REVIEW_RECEIPT_PATCH=""
REVIEW_RECEIPT_ATTEMPT=0
REVIEW_RECEIPT_MAX_ATTEMPTS=0
REVIEW_ART_PATH=""
REVIEW_WT_PATH=""
REVIEW_START_MS=0
kill_codex_child() {
  local pid="${CODEX_CHILD_PID:-}"
  [[ -n "$pid" ]] || return 0
  terminate_process_tree "$pid"
}
terminate_process_tree() {
  local pid="$1" child
  while IFS= read -r child; do
    [[ -n "$child" ]] && terminate_process_tree "$child"
  done < <(pgrep -P "$pid" 2>/dev/null || true)
  kill -TERM "$pid" 2>/dev/null || true
}
write_interrupted_review_receipt() {
  [[ -n "$REVIEW_RECEIPT_PATH" ]] || return 0
  mkdir -p "$(dirname "$REVIEW_RECEIPT_PATH")"
  jq -cn \
    --arg schema "legion.review-terminal.v1" --arg run "$REVIEW_RECEIPT_RUN_ID" \
    --arg status "failed" --arg reason "interrupted" \
    --arg model "$REVIEW_RECEIPT_MODEL" --arg archetype "$REVIEW_RECEIPT_ARCHETYPE" \
    --arg base "$REVIEW_RECEIPT_BASE_SHA" --arg head "$REVIEW_RECEIPT_HEAD_SHA" \
    --arg patch "$REVIEW_RECEIPT_PATCH" --arg completed "$(_now)" \
    --argjson attempts "$REVIEW_RECEIPT_ATTEMPT" \
    --argjson max_attempts "$REVIEW_RECEIPT_MAX_ATTEMPTS" '
    {schema:$schema, run_id:$run, status:$status, reason:$reason,
     executor:"codex-review", model:$model,
     archetype:(if $archetype=="" then null else $archetype end),
     reviewed_base_sha:$base, reviewed_head_sha:$head,
     review_patch:$patch, verdict_path:null,
     attempts:$attempts, max_attempts:$max_attempts, codex_exit:143,
     completed_at:$completed}' \
    > "$REVIEW_RECEIPT_PATH.tmp.$$" 2>/dev/null &&
    mv -f "$REVIEW_RECEIPT_PATH.tmp.$$" "$REVIEW_RECEIPT_PATH" 2>/dev/null || true
}
on_terminating_signal() {
  trap - INT TERM HUP
  kill_codex_child
  [[ -n "${CODEX_CHILD_PID:-}" ]] && wait "$CODEX_CHILD_PID" 2>/dev/null || true
  CODEX_CHILD_PID=""
  write_interrupted_review_receipt
  if [[ -n "$REVIEW_ART_PATH" && -n "${RUN_ID:-}" ]]; then
    local usage cost end_ms dur artifacts
    usage="$(aggregate_review_usage "$REVIEW_ART_PATH" "$REVIEW_RECEIPT_ATTEMPT" 2>/dev/null || printf '{}')"
    cost="$(cost_from_usage "$REVIEW_RECEIPT_MODEL" "$usage" 2>/dev/null || printf '0')"
    end_ms="$(date +%s000)"
    dur=$(( end_ms - REVIEW_START_MS ))
    [[ "$dur" -ge 0 ]] || dur=0
    artifacts="$(jq -cn --arg receipt "$REVIEW_RECEIPT_PATH" \
      --arg patch "$REVIEW_RECEIPT_PATCH" --arg base "$REVIEW_RECEIPT_BASE_SHA" \
      --arg head "$REVIEW_RECEIPT_HEAD_SHA" \
      '{terminal_receipt:$receipt, review_patch:$patch,
        reviewed_base_sha:$base, reviewed_head_sha:$head,
        reason:"interrupted", attempts:'"${REVIEW_RECEIPT_ATTEMPT:-0}"'}' 2>/dev/null || printf '{}')"
    emit_span "codex-review" "$REVIEW_RECEIPT_MODEL" "failed" "$dur" "$cost" "$usage" \
      "review --base $REVIEW_RECEIPT_BASE_SHA --head $REVIEW_RECEIPT_HEAD_SHA" "$artifacts" || true
    ingest_usage "$REVIEW_RECEIPT_MODEL" "codex" 143 "$usage" "$cost" || true
    write_run_state failed || true
    declare -F legion_disarm_adopted_run_guard >/dev/null 2>&1 && legion_disarm_adopted_run_guard
    write_run_artifact_status "$REVIEW_ART_PATH" "$RUN_ID" "failed" \
      "$REVIEW_WT_PATH" "" "failed" || true
  fi
  exit 143   # 128 + SIGTERM; EXIT trap still runs (sandbox teardown)
}
trap on_terminating_signal INT TERM HUP

ROUTE_BIN="$_self_dir/legion-route.py"
REVIEW_SCHEMA="$_self_dir/../schema/review-verdict.schema.json"
REVIEW_NORMALIZER="$_self_dir/normalize-review-verdict.py"

# resolve_archetype <name> -> "executor|model|sandbox|reasoning_effort|fallback_csv" ("||||" on failure)
resolve_archetype() {
  local j
  j="$(python3 "$ROUTE_BIN" "$1" 2>/dev/null)" || { echo "||||"; return 0; }
  printf '%s|%s|%s|%s|%s' \
    "$(jq -r '.executor // ""' <<<"$j")" \
    "$(jq -r '.model // ""' <<<"$j")" \
    "$(jq -r '.sandbox // ""' <<<"$j")" \
    "$(jq -r '.reasoning_effort // ""' <<<"$j")" \
    "$(jq -r '(.fallback // []) | join(",")' <<<"$j")"
}

# True if codex stderr indicates a quota / rate-limit / capacity condition (retry via fallback).
is_quota_error() {
  [[ -f "$1" ]] && grep -qiE 'rate.?limit|quota|usage limit|429|too many requests|insufficient_quota|overloaded|capacity|exceeded your' "$1"
}

# Benign optional-MCP infrastructure noise to remove from the signal-only stderr
# artifact. Every pattern is deliberately limited to Codex's MCP client logger plus
# an authentication or connection failure; do not add broad ERROR/MCP patterns here.
# Anything not confidently known to be unrelated infrastructure noise must remain
# signal, because hiding a real run failure is worse than retaining noisy stderr.
MCP_BENIGN_STDERR_PATTERNS=(
  'codex_rmcp_client::oauth::refresh_transaction:.*(failed to refresh OAuth tokens|OAuth token refresh failed)'
  'codex_rmcp_client::.*(failed to (connect|initialize) (to )?(MCP )?server|MCP server .* (connection|connect) (failed|error)|MCP (connection|transport).*(failed|error))'
)

# Preserve raw stderr and write the companion containing only run-level signal.
filter_codex_stderr() {
  local raw_err="$1" filtered_err="$2" pattern grep_rc
  local -a grep_patterns=()
  for pattern in "${MCP_BENIGN_STDERR_PATTERNS[@]}"; do
    grep_patterns+=(-e "$pattern")
  done
  [[ -f "$raw_err" ]] || { : > "$filtered_err"; return 0; }
  if grep -Eiv "${grep_patterns[@]}" "$raw_err" > "$filtered_err"; then
    return 0
  fi
  grep_rc=$?
  [[ "$grep_rc" -eq 1 ]] && return 0   # every raw line was known-benign noise
  return "$grep_rc"
}

error_log_summary() {
  local raw_err="$1" filtered_err="$2"
  if [[ -s "$filtered_err" ]]; then
    printf 'run-level errors: %s (raw stderr: %s)' "$filtered_err" "$raw_err"
  else
    printf 'no run-level errors were recorded (raw stderr: %s)' "$raw_err"
  fi
}

# Run codex exec for one model into $art files; sets the caller's $rc (dynamic scope).
# Reads $sandbox $wt $effort $task $art from the calling function.
run_codex() {
  set +e
  if [[ -n "$effort" ]]; then
    printf '%s' "$task" | "$CODEX_BIN" exec --json -m "$1" -s "$sandbox" -C "$wt" \
        --skip-git-repo-check -c "model_reasoning_effort=$effort" -o "$art/last-message.txt" - \
        >"$art/stream.jsonl" 2>"$art/codex.err" &
    CODEX_CHILD_PID=$!
  else
    printf '%s' "$task" | "$CODEX_BIN" exec --json -m "$1" -s "$sandbox" -C "$wt" \
        --skip-git-repo-check -o "$art/last-message.txt" - \
        >"$art/stream.jsonl" 2>"$art/codex.err" &
    CODEX_CHILD_PID=$!
  fi
  # Backgrounded + waited so on_terminating_signal can reap codex instead of
  # orphaning it; wait's status is codex's exit (== the old PIPESTATUS[1]).
  wait "$CODEX_CHILD_PID"; rc=$?
  CODEX_CHILD_PID=""
  set -e
}

is_sandcastle_sandbox() {
  case "$1" in docker|podman|vercel) return 0 ;; *) return 1 ;; esac
}

# Run Sandcastle for one model into $art files; sets the caller's $rc (dynamic scope).
# Sandcastle writes the diff directly to $art/diff.patch; the rest of the
# delegate flow consumes that same artifact path.
run_sandcastle() {
  local node_bin sandcastle_script
  node_bin="$(command -v node 2>/dev/null || true)"
  [[ -n "$node_bin" ]] || {
    printf 'legion-delegate: node is required for --sandbox %s. Run: npm i -D @ai-hero/sandcastle\n' "$sandbox" >&2
    rc=127
    return 0
  }
  sandcastle_script="$_self_dir/sandcastle-run.mjs"
  : > "$art/stream.jsonl"
  set +e
  jq -cn \
    --arg task "$task" --arg model "$1" --arg sandbox "$sandbox" \
    --arg cwd "$wt" --arg main_repo "$repo" --arg base "$base" --arg branch "$branch" \
    --arg diff "$art/diff.patch" --arg artifact_dir "$art" \
    --arg effort "$effort" --argjson untrusted "$untrusted" \
    '{task:$task, model:$model, sandbox:$sandbox, cwd:$cwd, base:$base, branch:$branch, diff_path:$diff,
      main_repo:$main_repo, artifact_dir:$artifact_dir, untrusted:$untrusted,
      effort:(if $effort=="" then null else $effort end)}' \
    | "$node_bin" "$sandcastle_script" >"$art/sandcastle-result.json" 2>"$art/codex.err"
  rc=${PIPESTATUS[1]}
  set -e
  # Surface the wrapper's stderr (e.g. the @ai-hero/sandcastle install hint on
  # exit 3) — it lands in codex.err, which cmd_run never prints otherwise.
  [[ "$rc" -ne 0 && -s "$art/codex.err" ]] && cat "$art/codex.err" >&2 || true
}

_now()    { date -u +%Y-%m-%dT%H:%M:%SZ; }
_today()  { date -u +%Y-%m-%d; }
_run_id() { printf '%s-%s' "$(date -u +%Y%m%d-%H%M%S)" "${RANDOM}${RANDOM}"; }

# ── Safety ───────────────────────────────────────────────────────────
validate_sandbox() {
  local s="$1"
  case "$s" in
    read-only|workspace-write|docker|podman|vercel) return 0 ;;
    danger-full-access)
      [[ "${LEGION_ALLOW_DANGER:-0}" == "1" ]] || \
        die "sandbox=danger-full-access is hard-blocked. Set LEGION_ALLOW_DANGER=1 to override (NOT recommended)."
      return 0 ;;
    *) die "invalid --sandbox '$s' (read-only|workspace-write|docker|podman|vercel|danger-full-access)" ;;
  esac
}

# Best-effort prompt-injection / dangerous-intent scan for write-capable runs.
# NOTE: this is a tripwire, not a security boundary — the real containment is the
# codex sandbox (read-only / workspace-write, danger hard-blocked). Whitespace is
# normalized first so "rm  -rf" / "rm -fr" can't trivially slip the pattern.
scan_task_text() {
  legion_scan_task_text "$1"
}

# ── Telemetry + metering ─────────────────────────────────────────────
LEGION_PRIMARY_BASELINE_EMITTED=0

# Synthetic "what the PRIMARY would have cost inline" span, so share accounting
# can see the delegated-vs-primary split. Harness-generic: the primary is
# whoever is driving the session (legion_primary). Back-compat: a Claude primary
# still emits the historical `opus-baseline` label + `synthetic_opus_baseline`
# marker that legion-share / legion-aggregate and their tests key on; other
# primaries emit `<primary>-baseline`. Toggle: LEGION_AUTO_PRIMARY_BASELINE
# (legacy alias LEGION_AUTO_OPUS_BASELINE), default on.
emit_primary_baseline_span() {
  local delegated_executor="$1" delegated_model="$2" delegated_task="$3"
  [[ "${LEGION_AUTO_PRIMARY_BASELINE:-${LEGION_AUTO_OPUS_BASELINE:-1}}" == "1" ]] || return 0
  [[ "$LEGION_PRIMARY_BASELINE_EMITTED" == "0" ]] || return 0
  # A parent orchestrator, such as legion-fanout, already emits the root span.
  [[ -z "${LEGION_PARENT_ID:-}" ]] || return 0
  [[ -n "${RUN_ID:-}" ]] || return 0
  local primary; primary="$(legion_primary 2>/dev/null || echo claude)"
  # No counterfactual when the primary IS the executor we delegated to. Match the
  # executor FAMILY so a codex primary also skips codex-review / codex-resume.
  [[ "${delegated_executor%%-*}" == "$primary" ]] && return 0

  LEGION_PRIMARY_BASELINE_EMITTED=1
  # Historical label for a Claude primary is "opus-baseline"; keep it so existing
  # reports/tests/spans stay valid. Generalize for any other primary.
  local label; case "$primary" in claude) label="opus-baseline" ;; *) label="${primary}-baseline" ;; esac
  mkdir -p "$LEGION_TELEMETRY_DIR"
  local baseline_run="${RUN_ID}-${label}"
  local trace_id="${LEGION_TRACE_ID:-$RUN_ID}"
  jq -cn \
    --arg schema "legion.span.v1" --arg ts "$(_now)" \
    --arg run_id "$baseline_run" --arg trace_id "$trace_id" \
    --arg executor "$label" --arg model "$label" --arg archetype "${archetype:-}" \
    --arg primary "$primary" \
    --arg target_type "${LEGION_TARGET_TYPE:-}" --arg target_name "${LEGION_TARGET_NAME:-}" \
    --arg task "legion-delegate orchestration baseline" \
    --arg delegated_task "$delegated_task" \
    --arg delegated_run_id "$RUN_ID" \
    --arg delegated_executor "$delegated_executor" \
    --arg delegated_model "$delegated_model" '
    {schema:$schema, ts:$ts, run_id:$run_id, trace_id:$trace_id, parent_id:null,
     executor:$executor, model:$model, archetype:$archetype, task:$task, status:"ok",
     target_type:(if $target_type=="" then null else $target_type end),
     target_name:(if $target_name=="" then null else $target_name end),
     duration_ms:0, cost_usd:0, tokens:{},
     artifacts:{synthetic_opus_baseline:true, synthetic_primary_baseline:true, primary:$primary,
                delegated_run_id:$delegated_run_id,
                delegated_executor:$delegated_executor,
                delegated_model:$delegated_model,
                delegated_task:$delegated_task}}' \
    >> "$LEGION_TELEMETRY_DIR/$(_today).jsonl"
}

# emit_span <executor> <model> <status> <duration_ms> <cost_usd> <usage_json> <task> <artifacts_json>
emit_span() {
  local executor="$1" model="$2" status="$3" dur="$4" cost="$5" usage="$6" task="$7" artifacts="$8"
  mkdir -p "$LEGION_TELEMETRY_DIR"
  case "$executor" in
    codex*) [[ "$status" == "ok" ]] && emit_primary_baseline_span "$executor" "$model" "$task" ;;
  esac
  # Trace context: a parent orchestrator (e.g. legion-fanout) exports
  # LEGION_TRACE_ID + LEGION_PARENT_ID so sibling delegate spans hang under one
  # OTel trace tree. A standalone run falls back to being its own root
  # (trace_id = run_id, no parent).
  local trace_id="${LEGION_TRACE_ID:-${RUN_ID:-}}"
  local parent_id="${LEGION_PARENT_ID:-}"
  # archetype comes from the caller's scope (cmd_run sets it; empty for review/resume).
  # Recording it lets the routing optimizer score per-archetype executor outcomes.
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
}

legion_delegated_context() {
  legion_executor_context_active
}

# Refuse literal self routes and nested Legion calls made from an executor that
# was already delegated by Legion. Top-level same-harness subagents remain valid;
# executor context, rather than harness family, is the recursion boundary.
route_preflight() {
  local target_executor="${1:-codex}" target_model="${2:-}"
  local route_archetype="${4:-}" primary reason="" art receipt payload artifacts
  : "${3:-}"  # task text is intentionally never persisted for blocked routes
  primary="$(legion_primary)"
  if [[ "$target_executor" == "self" ]]; then
    reason="inline-self-route"
  elif legion_delegated_context; then
    reason="nested-delegation"
  else
    return 0
  fi

  if [[ -L "$repo/.legion" || ( -e "$repo/.legion" && ! -d "$repo/.legion" ) ||
        -L "$repo/.legion/runs" || ( -e "$repo/.legion/runs" && ! -d "$repo/.legion/runs" ) ]]; then
    art="$LEGION_STATE_ROOT/blocked-routes/$RUN_ID"
  else
    art="$repo/.legion/runs/$RUN_ID"
  fi
  receipt="$art/route-preflight.json"
  mkdir -p "$art"
  if [[ "$art" == "$repo/"* && ! -L "$repo/.legion/.gitignore" ]]; then
    printf '*\n' > "$repo/.legion/.gitignore" 2>/dev/null || true
  fi
  payload="$(jq -cn \
    --arg schema "legion.route-preflight.v1" --arg run "$RUN_ID" \
    --arg status "blocked" --arg reason "$reason" --arg primary "$primary" \
    --arg executor "$target_executor" --arg model "$target_model" \
    --arg archetype "$route_archetype" --arg receipt "$receipt" '
    {schema:$schema, run_id:$run, status:$status, reason:$reason,
     primary:$primary, executor:$executor,
     model:(if $model=="" then null else $model end),
     archetype:(if $archetype=="" then null else $archetype end),
     receipt:$receipt,
     message:(if $reason=="inline-self-route"
              then "executor=self is inline work for the active primary"
              else "Legion is already inside a delegated executor; implement directly instead of nesting Legion"
              end)}')"
  printf '%s\n' "$payload" > "$receipt.tmp.$$"
  mv -f "$receipt.tmp.$$" "$receipt"
  artifacts="$(jq -cn --arg receipt "$receipt" --arg reason "$reason" \
    --arg primary "$primary" --arg executor "$target_executor" \
    --arg model "$target_model" '
    {preflight_receipt:$receipt, reason:$reason, primary:$primary,
     target_executor:$executor,
     target_model:(if $model=="" then null else $model end)}')"
  emit_span "legion-route" "${target_model:-unresolved}" "blocked" 0 0 '{}' \
    "route blocked: $reason" "$artifacts"
  printf '%s\n' "$payload"
  return 2
}

# write/update the per-run state record (legion.run-state.v1) — the Console + handoff
# foundation. Best-effort: telemetry must NEVER break the run (the whole body is the LHS
# of `|| true`, so `set -e` is suppressed inside). Reads RUN_ID + caller scope (repo, wt,
# art, branch, model, sandbox, effort, base). Preserves started_at + bumps state_version.
# Arg: <phase>  (running | ok | failed | error | over_budget | …)
write_run_state() {
  local phase="$1"
  {
    local now
    now="$(_now)"
    legion_write_adapter_run_state "$phase" "$RUN_ID" "$repo" "$art" "$wt" \
      "$branch" "$model" "$sandbox" "$base" "${archetype:-}" "$effort" "${RUN_KIND:-run}"
    # Register the repo for cross-repo discovery (dedup, best-effort).
    mkdir -p "$(dirname "$LEGION_REPOS_FILE")"
    if [[ ! -f "$LEGION_REPOS_FILE" ]] || ! grep -qF "$repo" "$LEGION_REPOS_FILE" 2>/dev/null; then
      printf '{"repo_root":%s,"seen_at":"%s"}\n' "$(jq -Rn --arg r "$repo" '$r')" "$now" >> "$LEGION_REPOS_FILE"
    fi
  } 2>/dev/null || true
  case "$phase" in ok|failed|error|over_budget|cancelled) prune_run_registry ;; esac
  return 0
}

# The global run registry is intentionally NON-purgeable (Console/handoff needs
# runs discoverable even after `cleanup --purge`), but it previously grew without
# bound (WS6: 1400+ records). Opportunistically drop only TERMINAL records older
# than the retention window (default 30d, LEGION_REGISTRY_RETAIN_DAYS) so recent
# and still-running runs stay discoverable. Best-effort and cheap: runs once per
# terminal transition, and re-confirms the phase before deleting.
prune_run_registry() {
  local retain_days="${LEGION_REGISTRY_RETAIN_DAYS:-30}"
  [[ "$retain_days" =~ ^[0-9]+$ ]] || retain_days=30
  [[ "$retain_days" -gt 0 && -d "$LEGION_REGISTRY_DIR" ]] || return 0
  local f phase
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    phase="$(jq -r '.lifecycle.phase // ""' "$f" 2>/dev/null)"
    case "$phase" in
      ok|failed|error|over_budget|cancelled) rm -f "$f" 2>/dev/null ;;
    esac
  done < <(find "$LEGION_REGISTRY_DIR" -maxdepth 1 -name '*.json' -type f -mtime +"$retain_days" 2>/dev/null)
}

# ingest_usage <model> <upstream> <status> <usage_json> <cost_usd>  (best-effort)
ingest_usage() {
  local model="$1" upstream="$2" status="$3" usage="$4" cost="$5"
  command -v curl >/dev/null 2>&1 || return 0
  local body
  body="$(jq -cn --arg model "$model" --arg upstream "$upstream" \
    --argjson status "$status" --argjson usage "$usage" --argjson cost "$cost" \
    '{model:$model, upstream:$upstream, status:$status, usage:$usage, cost_usd:$cost}')"
  curl -fsS -m 3 -X POST "$LEGION_ROUTER_URL/ingest" \
    -H 'content-type: application/json' -d "$body" >/dev/null 2>&1 || true
}

# usage(codex) -> cost.sh args. input billed = total-cached; output billed = output+reasoning.
cost_from_usage() {
  local model="$1" usage="$2"
  local in cached out reason billed_in billed_out
  in="$(jq -r '.input_tokens // 0' <<<"$usage")"
  cached="$(jq -r '.cached_input_tokens // 0' <<<"$usage")"
  out="$(jq -r '.output_tokens // 0' <<<"$usage")"
  reason="$(jq -r '.reasoning_output_tokens // 0' <<<"$usage")"
  billed_in=$(( in - cached )); (( billed_in < 0 )) && billed_in=0
  billed_out=$(( out + reason ))
  cost_for_model "$model" "$billed_in" "$billed_out" "$cached" 0
}

# ── git helpers ──────────────────────────────────────────────────────
require_git_repo() {
  git -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git repo: $1"
}

cleanup_generated_diff_noise() {
  local target="$1"
  # Test runs often create Python bytecode. Those files are generated artifacts,
  # and plain `git diff` records .pyc additions as non-applicable binary entries.
  find "$target" -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true
  find "$target" -type f \( -name '*.pyc' -o -name '*.pyo' \) -delete 2>/dev/null || true
}

# The source checkout can legitimately be dirty, but a worktree starts only at
# its requested base. Make that visibility gap explicit before creating it.
warn_dirty_source() {
  local source_repo="$1" source_base="$2"
  local line path total=0 shown=0
  local -a tracked=() untracked=()
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    path="${line:3}"
    # `.legion/` is runtime state, including the .gitignore written just before
    # this check. It must never cause a warning about user work.
    case "$path" in .legion|.legion/*) continue ;; esac
    total=$((total + 1))
    if [[ "${line:0:2}" == "??" ]]; then
      untracked+=("$path")
    else
      tracked+=("$path")
    fi
  done < <(git -C "$source_repo" status --porcelain --untracked-files=all -- \
    . ':(exclude).legion' ':(exclude).legion/**')
  [[ "$total" -gt 0 ]] || return 0

  note "⚠ WARNING: the delegated agent will NOT see these files because its worktree is created from '$source_base'."
  if [[ "${#tracked[@]}" -gt 0 ]]; then
    note "  modified tracked files (${#tracked[@]}):"
    for path in "${tracked[@]}"; do
      [[ "$shown" -lt 20 ]] || break
      note "    $path"
      shown=$((shown + 1))
    done
  fi
  if [[ "${#untracked[@]}" -gt 0 ]]; then
    note "  untracked files (${#untracked[@]}):"
    for path in "${untracked[@]}"; do
      [[ "$shown" -lt 20 ]] || break
      note "    $path"
      shown=$((shown + 1))
    done
  fi
  [[ "$shown" -ge "$total" ]] || note "  … and $((total - shown)) more"
  note "  Remedy: commit the files, or pass an explicit --base that contains them."
}

# Record lifecycle state next to the run artifacts so `status` does not depend
# on the mutable global registry.
write_run_artifact_status() {
  local run_art="$1" run_id="$2" phase="$3" run_wt="$4" pid="${5:-}" result="${6:-}"
  local pid_json="null"
  [[ "$pid" =~ ^[0-9]+$ ]] && pid_json="$pid"
  jq -cn --arg run "$run_id" --arg status "$phase" --arg wt "$run_wt" --arg dir "$run_art" \
    --arg result "$result" --argjson pid "$pid_json" '
    {run_id:$run, status:$status, worktree:$wt, run_dir:$dir, pid:$pid,
     result_status:(if $result=="" then null else $result end)}' \
    > "$run_art/status.json.tmp.$$" && mv -f "$run_art/status.json.tmp.$$" "$run_art/status.json"
}

# Show every changed path grouped by top-level directory. When scopes are
# present, save the selected list too and make exclusions visible.
summarize_changed_paths() {
  local target="$1" run_art="$2" diff_range="$3"; shift 3
  local all_paths="$run_art/changed-paths.txt" scoped_paths="$run_art/scoped-changed-paths.txt"
  local path excluded=0
  if [[ "$diff_range" == "--cached" ]]; then
    git -C "$target" diff --cached --name-only > "$all_paths"
  else
    git -C "$target" diff --name-only "$diff_range" > "$all_paths"
  fi
  [[ -s "$all_paths" ]] || return 0
  note "→ changed paths:"
  while IFS= read -r path; do
    note "$path"
  done < <(awk '
    {
      split($0, parts, "/"); top=(index($0, "/") ? parts[1] : ".")
      if (!(top in seen)) { seen[top]=1; order[++count]=top }
      grouped[top]=grouped[top] "    " $0 "\n"
    }
    END { for (i=1; i<=count; i++) printf "  %s/\n%s", order[i], grouped[order[i]] }
  ' "$all_paths")

  [[ "$#" -gt 0 ]] || return 0
  if [[ "$diff_range" == "--cached" ]]; then
    git -C "$target" diff --cached --name-only -- "$@" > "$scoped_paths"
  else
    git -C "$target" diff --name-only "$diff_range" -- "$@" > "$scoped_paths"
  fi
  while IFS= read -r path; do
    grep -Fqx -- "$path" "$scoped_paths" >/dev/null 2>&1 && continue
    if [[ "$excluded" -eq 0 ]]; then
      note "→ changes excluded by --scope:"
      excluded=1
    fi
    note "  $path"
  done < "$all_paths"
}

# Dispatch a scoped run to a non-codex executor's adapter (the Legion runner
# contract: `<adapter> run --repo … --task … [--model …] …`). Reads the adapter
# and its I/O contract from executors.toml via legion-route, builds the right
# argument set, and execs it so the adapter's JSON result + exit code become
# ours. Runs in cmd_run's dynamic scope (repo/task/archetype/sandbox/base/
# do_apply/keep/explicit_model). Never returns.
dispatch_adapter() {
  local ex="$1" info adapter contract model_ref adapter_bin use_model
  info="$(python3 "$ROUTE_BIN" --executor-info "$ex" 2>/dev/null)" \
    || die "unknown executor '$ex' — not in executors.toml (see legion-route --list-executors)"
  adapter="$(jq -r '.adapter // ""' <<<"$info")"
  contract="$(jq -r '.contract // ""' <<<"$info")"
  model_ref="$(jq -r '.model_ref // ""' <<<"$info")"
  [[ -n "$adapter" && -n "$contract" && "$contract" != "native" ]] \
    || die "executor '$ex' is primary-only — it can drive a session but cannot be delegated a coding task."
  adapter_bin="$(command -v "$adapter" 2>/dev/null || echo "$_self_dir/../bin/$adapter")"
  [[ -x "$adapter_bin" ]] || die "executor '$ex' adapter '$adapter' not found on PATH or in bin/ — build/install it first."
  # Model priority: explicit --model  >  the archetype's resolved model (ONLY when
  # the archetype routed here — not a forced --executor, whose archetype model may
  # name a model this harness can't run)  >  the executor's own default role. This
  # lets one executor serve multiple per-archetype models (e.g. the claude executor
  # runs Opus for frontend-polish but Fable for frontend-review).
  use_model="$explicit_model"
  [[ -n "$use_model" || -n "$forced_executor" || -z "$model" ]] || use_model="$model"
  [[ -n "$use_model" || -z "$model_ref" ]] || use_model="$(legion_model_ref "$model_ref" 2>/dev/null || true)"
  # Identity is part of the adapter contract. Never retry without it: doing so
  # would strand fanout's preallocated record in queued state.
  local -a aargs=(run --repo "$repo" --task "$task" --run-id "$RUN_ID")
  [[ -n "$use_model" ]] && aargs+=(--model "$use_model")
  [[ "${QUIET:-0}" == "1" ]] && aargs+=(--quiet)
  case "$contract" in
    diff)     # worktree + diff producers (cursor, opencode): full arg set
      [[ -n "$archetype" ]] && aargs+=(--archetype "$archetype")
      [[ -n "$sandbox" ]] && aargs+=(--sandbox "$sandbox")
      [[ "$base" != "HEAD" ]] && aargs+=(--base "$base")
      [[ "$do_apply" == "1" ]] && aargs+=(--apply)
      [[ "$keep" == "1" ]] && aargs+=(--keep)
      ;;
    prompt)   # prompt executors (claude): task/model/repo + effort passthrough
      [[ -n "$effort" ]] && aargs+=(--effort "$effort")
      ;;
    *) die "executor '$ex' has an unknown contract '$contract' in executors.toml." ;;
  esac
  note "→ dispatch to $ex via $adapter${use_model:+ -m $use_model}"
  exec "$adapter_bin" "${aargs[@]}"
}

# ── run ──────────────────────────────────────────────────────────────
cmd_run() {
  local model="" sandbox="" task="" repo="$PWD" base="HEAD" archetype="" effort=""
  local budget=0 do_apply=0 keep=0 detach=0 dirty_warn=1 preset_run_id=""
  local untrusted=0
  local forced_executor="" explicit_model="" detached_worker=0 sandbox_dev_pid_from_parent=""
  local -a scopes=()
  [[ "${LEGION_UNTRUSTED:-0}" == "1" ]] && untrusted=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --model) model="$2"; explicit_model="$2"; shift 2 ;;
      --executor) forced_executor="$2"; shift 2 ;;   # force a specific harness (symmetric reverse-delegate)
      --run-id) preset_run_id="$2"; shift 2 ;;   # adopt a preallocated id (fanout queued records)
      --sandbox) sandbox="$2"; shift 2 ;;
      --archetype) archetype="$2"; shift 2 ;;
      --reasoning-effort) effort="$2"; shift 2 ;;
      --task) task="$2"; shift 2 ;;
      --repo) repo="$2"; shift 2 ;;
      --base) base="$2"; shift 2 ;;
      --budget-tokens) budget="$2"; shift 2 ;;
      --apply) do_apply=1; shift ;;
      --keep) keep=1; shift ;;
      --detach) detach=1; shift ;;
      --no-dirty-warn) dirty_warn=0; shift ;;
      --scope) scopes+=("$2"); shift 2 ;;
      --untrusted) untrusted=1; shift ;;
      --_detached-worker) detached_worker=1; shift ;;
      --_sandbox-dev-pid) sandbox_dev_pid_from_parent="$2"; shift 2 ;;
      --quiet) QUIET=1; shift ;;
      *) die "run: unknown arg '$1'" ;;
    esac
  done
  if [[ -n "$preset_run_id" ]]; then
    declare -F legion_write_adapter_run_state >/dev/null 2>&1 \
      || die "run: shared run-state helper is unavailable"
    legion_validate_run_id "$preset_run_id" \
      || die "run: invalid --run-id '$preset_run_id'"
  fi
  repo="$(cd "$repo" && pwd)" || die "run: repo does not exist: $repo"
  resolve_runtime_state "$repo"
  RUN_ID="${preset_run_id:-$(_run_id)}"
  local wt="$repo/.legion/worktrees/$RUN_ID"
  local art="$repo/.legion/runs/$RUN_ID"
  local branch="legion/delegate-$RUN_ID"
  if [[ -n "$preset_run_id" ]]; then
    legion_arm_adopted_run_guard "$RUN_ID" "$repo" "$art" "$wt" "$branch" \
      "$model" "${sandbox:-workspace-write}" "$base" "$archetype" "$effort"
  fi
  require_git_repo "$repo"
  # Archetype fills model/sandbox/effort/fallback from routing + model config; explicit flags win.
  local r_exec="" r_fallback=""
  if [[ -n "$archetype" ]]; then
    local r_model r_sandbox r_effort
    IFS='|' read -r r_exec r_model r_sandbox r_effort r_fallback <<< "$(resolve_archetype "$archetype")"
    [[ -n "$model" ]]   || model="$r_model"
    [[ -n "$sandbox" ]] || sandbox="$r_sandbox"
    [[ -n "$effort" ]]  || effort="$r_effort"
  fi
  # --executor forces a specific harness (symmetric reverse-delegate: any primary
  # can hand work to any other harness). Apply it BEFORE the low-credit bias and the
  # dispatch below so both see the final resolved target.
  [[ -n "$forced_executor" ]] && r_exec="$forced_executor"
  # Low-credit bias — steer away from the depleted provider (self-handle low credits).
  case "${LEGION_LOW_CREDIT:-}" in
    claude)       # Claude low -> prefer GPT, even for normally-self work
      if [[ "$r_exec" == "self" ]]; then
        r_exec="codex"
        # A self archetype carries a Claude model which codex can't run — force the configured Codex model.
        case "${model:-}" in gpt-*|codex*) ;; *) model="$(legion_model_ref codex_workhorse)" || die "could not resolve codex_workhorse in models.toml" ;; esac
        # always surface the substitution (even under --quiet) so it's never silent.
        printf '⚠ LEGION_LOW_CREDIT=claude: delegating a normally-self task to GPT (%s)\n' "$model" >&2
      fi ;;
    codex|gpt)    # GPT low -> refuse ONLY when the actual target IS the depleted codex path;
                  # a --executor pivot to another harness (cursor/opencode/claude) is the point.
      case "$r_exec" in
        ""|codex)
          [[ "${LEGION_FORCE_DELEGATE:-}" == "1" ]] || \
            die "LEGION_LOW_CREDIT=$LEGION_LOW_CREDIT: GPT/codex credits low — the primary ($(legion_primary)) should run this inline, not delegate. (set LEGION_FORCE_DELEGATE=1 to override)" ;;
      esac ;;
  esac
  # Materialize the task (stdin), default+validate the sandbox, and run the safety
  # scan BEFORE dispatch, so an adapter path (cursor/opencode/claude) gets a real
  # task, a sane sandbox, and the same injection tripwire the native codex path gets.
  [[ -n "$sandbox" ]] || sandbox="workspace-write"
  validate_sandbox "$sandbox"
  [[ -n "$task" ]] || task="$(cat)"        # read from stdin if not given
  [[ -n "$task" ]] || die "run: empty task"
  [[ "$sandbox" == "read-only" ]] || scan_task_text "$task"
  if [[ -n "$preset_run_id" ]]; then
    legion_arm_adopted_run_guard "$RUN_ID" "$repo" "$art" "$wt" "$branch" \
      "$model" "$sandbox" "$base" "$archetype" "$effort"
  fi
  route_preflight "${r_exec:-codex}" "$model" "$task" "$archetype" || return $?
  # Dispatch by executor. `self` is the primary's own inline work (never delegated);
  # codex (or an unclassified task) uses the native codex path below; any other
  # registered coding executor runs through its adapter.
  case "$r_exec" in
    self)
      die "internal error: executor=self passed route preflight" ;;
    ""|codex) : ;;
    *)
      [[ "$detach" -eq 0 && "$detached_worker" -eq 0 ]] || \
        die "run: --detach is supported only by native codex execution"
      [[ "${#scopes[@]}" -eq 0 ]] || \
        die "run: --scope is supported only by native codex execution"
      dispatch_adapter "$r_exec" ;;   # execs the adapter and never returns
  esac
  [[ -n "$effort" ]] || effort="xhigh"   # codex always runs at xhigh unless explicitly overridden
  [[ -n "$model" ]] || die "run: --model or --archetype required"

  if [[ "$detach" -eq 1 ]] && ! command -v setsid >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
    die "run: --detach requires setsid or python3"
  fi

  local sandbox_dev_pid=""
  if [[ "$detached_worker" -eq 1 ]]; then
    [[ -d "$art" && -d "$wt" ]] || die "run: detached worker setup is missing for '$RUN_ID'"
  else
    mkdir -p "$art"
    # Keep all legion runtime state out of the target repo's git status / diffs.
    printf '*\n' > "$repo/.legion/.gitignore" 2>/dev/null || true
    [[ "$dirty_warn" -eq 0 ]] || warn_dirty_source "$repo" "$base"
    note "→ worktree $wt (branch $branch, base $base)"
    git -C "$repo" worktree add -q -b "$branch" "$wt" "$base" || die "worktree add failed"
  fi
  # Register for EXIT-trap cleanup so a crash/kill before the inline removal
  # below does not orphan the worktree + branch (WS6 worktree-leak guard).
  LEGION_WT_PATH="$wt"; LEGION_WT_BRANCH="$branch"; LEGION_WT_REPO="$repo"; LEGION_WT_KEEP="$keep"
  if [[ "$detached_worker" -eq 1 ]]; then
    sandbox_dev_pid="$sandbox_dev_pid_from_parent"
    SANDBOX_DEV_PID_TO_TEARDOWN="$sandbox_dev_pid"
  elif ! is_sandcastle_sandbox "$sandbox"; then
    sandbox_dev_pid="$(
      unset LEGION_ACTIVE LEGION_EXECUTOR LEGION_DEPTH LEGION_RUN_ID
      LEGION_SANDBOX_ARTIFACT_DIR="$art" LEGION_SANDBOX_QUIET="${QUIET:-0}" \
        sandbox_setup "$wt" "$repo" "$untrusted" || true
    )"
    SANDBOX_DEV_PID_TO_TEARDOWN="$sandbox_dev_pid"
  fi
  write_run_state running
  if [[ "$detached_worker" -eq 1 ]]; then
    printf '%s\n' "$$" > "$art/pid"
    write_run_artifact_status "$art" "$RUN_ID" "executing" "$wt" "$$"
  else
    write_run_artifact_status "$art" "$RUN_ID" "executing" "$wt"
  fi

  if [[ "$detach" -eq 1 ]]; then
    local -a worker_args=(run --_detached-worker --run-id "$RUN_ID" --model "$model" \
      --sandbox "$sandbox" --reasoning-effort "$effort" --task "$task" --repo "$repo" --base "$base" \
      --budget-tokens "$budget" --no-dirty-warn)
    [[ -n "$archetype" ]] && worker_args+=(--archetype "$archetype")
    [[ -n "$forced_executor" ]] && worker_args+=(--executor "$forced_executor")
    [[ "$do_apply" -eq 1 ]] && worker_args+=(--apply)
    [[ "$keep" -eq 1 ]] && worker_args+=(--keep)
    [[ "$untrusted" -eq 1 ]] && worker_args+=(--untrusted)
    if [[ "${#scopes[@]}" -gt 0 ]]; then
      for path in "${scopes[@]}"; do worker_args+=(--scope "$path"); done
    fi
    [[ -n "$sandbox_dev_pid" ]] && worker_args+=(--_sandbox-dev-pid "$sandbox_dev_pid")

    # The parent must retain neither the worktree nor the sandbox-dev process:
    # the worker owns both until it reaches the normal cleanup path.
    LEGION_WT_KEEP=1
    SANDBOX_DEV_PID_TO_TEARDOWN=""
    if command -v setsid >/dev/null 2>&1; then
      nohup setsid "$BASH" "$0" "${worker_args[@]}" </dev/null >"$art/result.json" 2>"$art/worker.err" &
    else
      nohup python3 -c 'import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' \
        "$BASH" "$0" "${worker_args[@]}" </dev/null >"$art/result.json" 2>"$art/worker.err" &
    fi
    local worker_pid=$!
    printf '%s\n' "$worker_pid" > "$art/pid"
    write_run_artifact_status "$art" "$RUN_ID" "executing" "$wt" "$worker_pid"
    jq -cn --arg run "$RUN_ID" --arg wt "$wt" --arg dir "$art" \
      '{run_id:$run, worktree:$wt, run_dir:$dir, status:"detached"}'
    declare -F legion_disarm_adopted_run_guard >/dev/null 2>&1 && legion_disarm_adopted_run_guard
    return 0
  fi

  # Mark only the executor process (and its direct children) as delegated.
  # Sandbox install/dev setup above must not inherit Legion role state.
  legion_activate_executor_context "$RUN_ID"
  local start_ms end_ms dur rc=0 used_model=""
  start_ms="$(date +%s000)"
  # Try the chosen model, then the archetype's fallback chain on a quota/rate-limit error.
  local model_list="$model"
  [[ -n "$r_fallback" ]] && model_list="$model_list,$r_fallback"
  local tried="" attempt
  for attempt in ${model_list//,/ }; do
    [[ -z "$attempt" ]] && continue
    case ",$tried," in *",$attempt,"*) continue ;; esac    # dedup
    tried="${tried:+$tried,}$attempt"
    used_model="$attempt"
    if is_sandcastle_sandbox "$sandbox"; then
      note "→ sandcastle run -m $attempt --sandbox $sandbox${effort:+ (effort=$effort)}"
      run_sandcastle "$attempt"
    else
      note "→ codex exec -m $attempt -s $sandbox${effort:+ (effort=$effort)}"
      run_codex "$attempt"
    fi
    [[ "$rc" -eq 0 ]] && break
    if is_quota_error "$art/codex.err"; then
      note "⚠ $attempt hit quota/rate-limit — trying next fallback model"
      continue
    fi
    break    # non-quota failure: stop, don't burn the fallback chain
  done
  model="$used_model"
  printf '%s\n' "$used_model" > "$art/model.txt"   # persisted so `resume` inherits it (M2)
  end_ms="$(date +%s000)"; dur=$(( end_ms - start_ms ))

  local thread_id usage cost filtered_err error_log
  filtered_err="$art/codex.filtered.err"
  filter_codex_stderr "$art/codex.err" "$filtered_err"
  error_log="$(error_log_summary "$art/codex.err" "$filtered_err")"
  thread_id="$(codex_thread_id "$art/stream.jsonl")"
  usage="$(codex_usage "$art/stream.jsonl")"
  # Sandcastle runs codex inside the sandbox, so the local stream is empty — take
  # the token usage the wrapper summed from the run instead of reporting a false
  # zero (which would also defeat --budget-tokens). null usage => leave the zeros
  # but flag it so cost isn't silently presented as $0 for a real run.
  if is_sandcastle_sandbox "$sandbox"; then
    local sc_usage
    sc_usage="$(jq -c '.usage' "$art/sandcastle-result.json" 2>/dev/null || echo null)"
    if [[ -n "$sc_usage" && "$sc_usage" != "null" ]]; then
      usage="$sc_usage"
    else
      note "⚠ sandcastle run reported no token usage (provider usage unavailable); cost is unmeasured"
    fi
  fi
  # Cost math must never abort the run (codex already did the work); default to 0.
  cost="$(cost_from_usage "$model" "$usage" 2>/dev/null || echo 0)"

  local diff_rc=0
  if ! is_sandcastle_sandbox "$sandbox"; then
    cleanup_generated_diff_noise "$wt"
    git -C "$wt" add -A 2>/dev/null || diff_rc=1
    if [[ "${#scopes[@]}" -gt 0 ]]; then
      git -C "$wt" diff --cached -- "${scopes[@]}" >"$art/diff.patch" 2>/dev/null || diff_rc=1
    else
      git -C "$wt" diff --cached >"$art/diff.patch" 2>/dev/null || diff_rc=1
    fi
    if [[ "$diff_rc" -eq 0 ]]; then
      if [[ "${#scopes[@]}" -gt 0 ]]; then
        summarize_changed_paths "$wt" "$art" --cached "${scopes[@]}" || note "⚠ could not summarize changed paths"
      else
        summarize_changed_paths "$wt" "$art" --cached || note "⚠ could not summarize changed paths"
      fi
    fi
  else
    [[ -f "$art/diff.patch" ]] || : > "$art/diff.patch"
    local sandcastle_branch sandcastle_range
    sandcastle_branch="$(jq -r '.branch // empty' "$art/sandcastle-result.json" 2>/dev/null || true)"
    if [[ -n "$sandcastle_branch" ]]; then
      sandcastle_range="$base...$sandcastle_branch"
      if [[ "${#scopes[@]}" -gt 0 ]]; then
        git -C "$wt" diff "$sandcastle_range" -- "${scopes[@]}" >"$art/diff.patch" 2>/dev/null || diff_rc=1
      fi
      if [[ "$diff_rc" -eq 0 ]]; then
        if [[ "${#scopes[@]}" -gt 0 ]]; then
          summarize_changed_paths "$wt" "$art" "$sandcastle_range" "${scopes[@]}" || note "⚠ could not summarize changed paths"
        else
          summarize_changed_paths "$wt" "$art" "$sandcastle_range" || note "⚠ could not summarize changed paths"
        fi
      fi
    else
      note "⚠ could not summarize changed paths (sandcastle result branch unavailable)"
    fi
  fi

  local total_tokens status="ok"
  total_tokens="$(jq -r '((.input_tokens//0)+(.output_tokens//0)+(.reasoning_output_tokens//0)) | floor' <<<"$usage" 2>/dev/null || echo 0)"
  [[ "$total_tokens" =~ ^[0-9]+$ ]] || total_tokens=0   # guard: never let a non-int abort the -gt test
  if [[ "$rc" -ne 0 ]]; then
    status="failed"
  elif [[ "$diff_rc" -ne 0 ]]; then
    status="error"   # codex ran but the diff couldn't be captured — don't claim ok
    note "⚠ could not capture diff from worktree"
  elif [[ "$budget" -gt 0 && "$total_tokens" -gt "$budget" ]]; then
    status="over_budget"
    note "⚠ budget exceeded: $total_tokens > $budget tokens (advisory — codex cannot be pre-empted mid-run)"
  fi

  local artifacts copied_secret_names
  copied_secret_names="[]"
  if [[ -s "$art/copied-secrets.json" ]]; then
    copied_secret_names="$(jq -c '.copied_secret_names // []' "$art/copied-secrets.json" 2>/dev/null || echo '[]')"
  fi
  artifacts="$(jq -cn --arg wt "$wt" --arg diff "$art/diff.patch" --arg last "$art/last-message.txt" --arg stream "$art/stream.jsonl" \
    --argjson copied_secret_names "$copied_secret_names" \
    '{worktree:$wt, diff:$diff, last_message:$last, stream:$stream, copied_secret_names:$copied_secret_names}')"
  emit_span "codex" "$model" "$status" "$dur" "$cost" "$usage" "$task" "$artifacts"
  ingest_usage "$model" "codex" "${rc:-0}" "$usage" "$cost"
  write_run_state "$status"
  declare -F legion_disarm_adopted_run_guard >/dev/null 2>&1 && legion_disarm_adopted_run_guard

  if [[ "$do_apply" -eq 1 && "$status" == "ok" && -s "$art/diff.patch" ]]; then
    if git -C "$repo" apply --check "$art/diff.patch" 2>/dev/null; then
      git -C "$repo" apply "$art/diff.patch" && note "✓ diff applied to $repo"
    else
      note "⚠ diff did not apply cleanly; left in $art/diff.patch"
    fi
  fi

  # The captured diff/last-message/stream live under runs/ (preserved); the worktree
  # itself is disposable. Remove it + its branch unless --keep, so runs don't leak
  # worktrees and orphaned legion/delegate-* branches across a long autonomous loop.
  cleanup_sandbox_dev_on_exit
  local wt_report="$wt"
  if [[ "$keep" -eq 0 ]]; then
    # Redirect stdout too — `git branch -D` prints "Deleted branch …" which would
    # otherwise corrupt the JSON result on this function's stdout.
    git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
    git -C "$repo" branch -D "$branch" >/dev/null 2>&1 || true
    git -C "$repo" worktree prune >/dev/null 2>&1 || true
    wt_report="(removed; rerun with --keep to retain the worktree)"
    LEGION_WT_PATH=""   # removed here; stop the EXIT trap from retrying
  fi

  local lifecycle_status="completed"
  case "$status" in failed|error) lifecycle_status="failed" ;; esac
  write_run_artifact_status "$art" "$RUN_ID" "$lifecycle_status" "$wt_report" "" "$status"

  jq -cn --arg status "$status" --arg model "$model" --arg thread "$thread_id" \
    --arg wt "$wt_report" --arg diff "$art/diff.patch" --arg last "$art/last-message.txt" \
    --arg error_log "$error_log" --argjson usage "$usage" --argjson cost "${cost:-0}" --arg run "$RUN_ID" --argjson rc "${rc:-0}" '
    {run_id:$run, status:$status, model:$model, thread_id:$thread, codex_exit:$rc,
     worktree:$wt, diff_path:$diff, last_message_path:$last, error_log:$error_log, usage:$usage, cost_usd:$cost}'
  # over_budget produced a usable diff (budget is advisory — codex can't be pre-empted),
  # so it exits 0; only a real failure/error is non-zero (M1: graceful degradation).
  case "$status" in
    ok|over_budget) exit 0 ;;
    *) exit 1 ;;
  esac
}

# ── review (second opinion / cross-model) ────────────────────────────
is_review_transient_failure() {
  local exit_code="$1" err_file="$2"
  case "$exit_code" in 124|130|137|143) return 0 ;; esac
  [[ -f "$err_file" ]] && grep -qiE \
    'rate.?limit|quota|429|overloaded|capacity|timed?[ -]?out|timeout|temporar(il)?y unavailable|connection (reset|closed)|broken pipe|interrupted|transport.*(closed|error)' \
    "$err_file"
}

review_verdict_is_valid() {
  local verdict_file="$1"
  [[ -s "$verdict_file" ]] &&
    jq -e '
      (.verdict == "approve" or .verdict == "request_changes" or .verdict == "comment")
      and (.summary | type == "string")
      and (.findings | type == "array")
      and ((keys - ["verdict", "summary", "findings"]) | length == 0)
      and all(.findings[];
        type == "object"
        and ((keys - ["severity", "title", "file", "line", "detail"]) | length == 0)
        and (.severity == "critical" or .severity == "high"
             or .severity == "medium" or .severity == "low")
        and (.title | type == "string")
        and ((has("file") | not) or (.file | type == "string"))
        and ((has("line") | not) or (.line | type == "number" and floor == .))
        and ((has("detail") | not) or (.detail | type == "string"))
      )
      and ((.verdict == "request_changes") or all(.findings[];
        .severity == "low"
      ))
    ' "$verdict_file" >/dev/null 2>&1
}

aggregate_review_usage() {
  local art="$1" attempts="$2" i
  for ((i = 1; i <= attempts; i++)); do
    codex_usage "$art/attempt-$i.stream.jsonl"
  done | jq -sc '
    reduce .[] as $u
      ({input_tokens:0,cached_input_tokens:0,output_tokens:0,reasoning_output_tokens:0};
       .input_tokens += ($u.input_tokens // 0)
       | .cached_input_tokens += ($u.cached_input_tokens // 0)
       | .output_tokens += ($u.output_tokens // 0)
       | .reasoning_output_tokens += ($u.reasoning_output_tokens // 0))
  '
}

write_review_terminal_receipt() {
  local receipt="$1" status="$2" reason="$3" model="$4" archetype="$5"
  local base_sha="$6" head_sha="$7" patch_path="$8" verdict_path="$9"
  local attempts="${10}" max_attempts="${11}" exit_code="${12}" error_log="${13}"
  jq -cn \
    --arg schema "legion.review-terminal.v1" --arg run "$RUN_ID" \
    --arg status "$status" --arg reason "$reason" --arg model "$model" \
    --arg archetype "$archetype" --arg base "$base_sha" --arg head "$head_sha" \
    --arg patch "$patch_path" --arg verdict "$verdict_path" \
    --arg error_log "$error_log" --arg completed "$(_now)" \
    --argjson attempts "$attempts" --argjson max_attempts "$max_attempts" \
    --argjson exit_code "$exit_code" '
    {schema:$schema, run_id:$run, status:$status, reason:$reason,
     executor:"codex-review", model:$model,
     archetype:(if $archetype=="" then null else $archetype end),
     reviewed_base_sha:$base, reviewed_head_sha:$head,
     review_patch:$patch,
     verdict_path:(if $verdict=="" then null else $verdict end),
     attempts:$attempts, max_attempts:$max_attempts, codex_exit:$exit_code,
     error_log:$error_log, completed_at:$completed}' \
    > "$receipt.tmp.$$"
  mv -f "$receipt.tmp.$$" "$receipt"
}

cmd_review() {
  local RUN_KIND="review"
  local model="" base="" head="" repo="$PWD" archetype="" effort="" task=""
  local max_attempts="${LEGION_REVIEW_MAX_ATTEMPTS:-2}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --model) model="$2"; shift 2 ;;
      --base) base="$2"; shift 2 ;;
      --head) head="$2"; shift 2 ;;
      --repo) repo="$2"; shift 2 ;;
      --archetype) archetype="$2"; shift 2 ;;
      --reasoning-effort) effort="$2"; shift 2 ;;
      --max-attempts) max_attempts="$2"; shift 2 ;;
      --task) task="$2"; shift 2 ;;
      --quiet) QUIET=1; shift ;;
      *) die "review: unknown arg '$1'" ;;
    esac
  done
  if [[ -n "$archetype" ]]; then
    local r_exec r_model r_sandbox r_effort
    local _r_fb
    IFS='|' read -r r_exec r_model r_sandbox r_effort _r_fb <<< "$(resolve_archetype "$archetype")"
    [[ "$r_exec" == "codex" ]] || die "review archetype '$archetype' routes to executor=$r_exec; invoke its executor-specific review adapter"
    [[ -n "$model" ]]  || model="$r_model"
    [[ -n "$effort" ]] || effort="$r_effort"
  fi
  [[ -n "$model" ]] || model="$(legion_model_ref codex_review)" || die "could not resolve codex_review in models.toml"
  [[ -n "$effort" ]] || effort="xhigh"
  [[ -n "$base" ]] || die "review: --base REF required"
  [[ "$max_attempts" =~ ^[1-9][0-9]*$ ]] || die "review: --max-attempts must be a positive integer"
  [[ "${#task}" -le 16384 ]] || die "review: --task exceeds 16384 characters"
  [[ -z "$task" ]] || scan_task_text "$task"

  repo="$(cd "$repo" && pwd)"; require_git_repo "$repo"; resolve_runtime_state "$repo"
  local base_sha head_sha
  base_sha="$(git -C "$repo" rev-parse --verify "$base^{commit}" 2>/dev/null)" \
    || die "review: could not resolve --base '$base' to a commit"
  [[ -n "$head" ]] || head="HEAD"
  head_sha="$(git -C "$repo" rev-parse --verify "$head^{commit}" 2>/dev/null)" \
    || die "review: could not resolve --head '$head' to a commit"

  RUN_ID="$(_run_id)"
  route_preflight "codex" "$model" "review --base $base_sha --head $head_sha" "$archetype" || return $?
  legion_activate_executor_context "$RUN_ID"
  local art="$repo/.legion/runs/$RUN_ID"; mkdir -p "$art"
  local wt="$repo/.legion/worktrees/$RUN_ID"
  local branch="" sandbox="read-only"
  local patch_path="$art/review.patch" receipt="$art/terminal.json"
  local verdict_file="$art/verdict.json"

  git -C "$repo" diff --binary "$base_sha...$head_sha" > "$patch_path" \
    || die "review: could not capture immutable review patch"
  note "→ review worktree $wt (head $head_sha, base $base_sha)"
  git -C "$repo" worktree add -q --detach "$wt" "$head_sha" || die "review: detached worktree add failed"
  LEGION_WT_PATH="$wt"; LEGION_WT_BRANCH=""; LEGION_WT_REPO="$repo"; LEGION_WT_KEEP=0
  write_run_state running
  write_run_artifact_status "$art" "$RUN_ID" "executing" "$wt"

  REVIEW_RECEIPT_PATH="$receipt"
  REVIEW_RECEIPT_RUN_ID="$RUN_ID"
  REVIEW_RECEIPT_MODEL="$model"
  REVIEW_RECEIPT_ARCHETYPE="$archetype"
  REVIEW_RECEIPT_BASE_SHA="$base_sha"
  REVIEW_RECEIPT_HEAD_SHA="$head_sha"
  REVIEW_RECEIPT_PATCH="$patch_path"
  REVIEW_RECEIPT_ATTEMPT=0
  REVIEW_RECEIPT_MAX_ATTEMPTS="$max_attempts"
  REVIEW_ART_PATH="$art"
  REVIEW_WT_PATH="$wt"

  # Each attempt gets immutable inputs, optional bounded review guidance, and
  # separate raw artifacts; only the terminal attempt is copied to stable paths.
  local start_ms end_ms dur rc=0 attempt=0 status="failed" reason="review-failed"
  local attempt_stream attempt_err attempt_verdict
  start_ms="$(date +%s000)"
  REVIEW_START_MS="$start_ms"
  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    REVIEW_RECEIPT_ATTEMPT="$attempt"
    attempt_stream="$art/attempt-$attempt.stream.jsonl"
    attempt_err="$art/attempt-$attempt.codex.err"
    attempt_verdict="$art/attempt-$attempt.verdict.json"
    rm -f "$attempt_verdict"
    note "→ codex review attempt $attempt/$max_attempts (base $base_sha, head $head_sha)"
    local -a codex_review_args=(exec -s "$sandbox" review --base "$base_sha")
    local review_prompt=""
    if [[ -n "$task" ]]; then
      review_prompt="Review only the immutable diff $base_sha...$head_sha. $task"
    fi
    codex_review_args+=(-m "$model" --json)
    [[ -n "$effort" ]] && codex_review_args+=(-c "model_reasoning_effort=$effort")
    if [[ -n "$review_prompt" ]]; then
      local encoded_review_prompt
      encoded_review_prompt="$(jq -Rn --arg value "$review_prompt" '$value')"
      codex_review_args+=(-c "developer_instructions=$encoded_review_prompt")
    fi
    codex_review_args+=(--output-schema "$REVIEW_SCHEMA" -o "$attempt_verdict")
    set +e
    ( cd "$wt" && "$CODEX_BIN" "${codex_review_args[@]}" ) \
      </dev/null >"$attempt_stream" 2>"$attempt_err" &
    CODEX_CHILD_PID=$!
    wait "$CODEX_CHILD_PID"; rc=$?
    CODEX_CHILD_PID=""
    set -e

    if [[ "$rc" -eq 0 ]]; then
      if [[ ! -s "$attempt_verdict" ]]; then
        reason="missing-verdict"
        break
      fi
      if ! review_verdict_is_valid "$attempt_verdict"; then
        python3 "$REVIEW_NORMALIZER" "$attempt_verdict" --repo "$wt" \
          >/dev/null 2>&1 || true
        if ! review_verdict_is_valid "$attempt_verdict"; then
          reason="invalid-verdict"
          break
        fi
      fi
      status="ok"
      reason="completed"
      break
    fi
    # A nonzero exit does not always mean no review happened. Codex can emit a
    # complete review and still exit nonzero -- it does so when its prose output
    # does not satisfy --output-schema, which is the documented quirk this
    # normalizer exists for. Discarding that result reports a finished review as
    # a failure, and downstream that becomes a retryable "review unavailable"
    # rather than the verdict the reviewer actually reached.
    #
    # Recovery is deliberately one-directional: only a NON-approving verdict is
    # honored from a failed run. An approval is the outcome that authorizes
    # publishing, so it must come from a reviewer that exited cleanly; a
    # rejection recovered here can only ever withhold permission.
    if [[ -s "$attempt_verdict" ]]; then
      if ! review_verdict_is_valid "$attempt_verdict"; then
        python3 "$REVIEW_NORMALIZER" "$attempt_verdict" --repo "$wt" \
          >/dev/null 2>&1 || true
      fi
      if review_verdict_is_valid "$attempt_verdict" &&
         [[ "$(jq -r '.verdict' "$attempt_verdict" 2>/dev/null)" != "approve" ]]; then
        note "⚠ reviewer exited $rc but produced a usable non-approving verdict; honoring it"
        status="ok"
        reason="completed"
        break
      fi
    fi
    if is_review_transient_failure "$rc" "$attempt_err"; then
      reason="transient-exhausted"
      if [[ "$attempt" -lt "$max_attempts" ]]; then
        note "⚠ transient review failure (exit $rc); retrying with the same immutable SHAs"
        continue
      fi
    else
      reason="review-failed"
    fi
    break
  done
  end_ms="$(date +%s000)"; dur=$(( end_ms - start_ms ))

  cp "$attempt_stream" "$art/stream.jsonl"
  cp "$attempt_err" "$art/codex.err"
  [[ -s "$attempt_verdict" ]] && cp "$attempt_verdict" "$verdict_file"
  local usage cost filtered_err error_log verdict_json="null"
  usage="$(aggregate_review_usage "$art" "$attempt")"
  cost="$(cost_from_usage "$model" "$usage" 2>/dev/null || echo 0)"
  filtered_err="$art/codex.filtered.err"
  filter_codex_stderr "$art/codex.err" "$filtered_err"
  error_log="$(error_log_summary "$art/codex.err" "$filtered_err")"
  if [[ "$status" == "ok" ]]; then
    verdict_json="$(cat "$verdict_file")"
  fi

  write_review_terminal_receipt "$receipt" "$status" "$reason" "$model" "$archetype" \
    "$base_sha" "$head_sha" "$patch_path" \
    "$([[ "$status" == "ok" ]] && printf '%s' "$verdict_file")" \
    "$attempt" "$max_attempts" "$rc" "$error_log"
  local artifacts
  artifacts="$(jq -cn --arg receipt "$receipt" --arg verdict "$verdict_file" \
    --arg patch "$patch_path" --arg base "$base_sha" --arg head "$head_sha" \
    --arg reason "$reason" --argjson attempts "$attempt" '
    {terminal_receipt:$receipt, verdict:$verdict, review_patch:$patch,
     reviewed_base_sha:$base, reviewed_head_sha:$head,
     reason:$reason, attempts:$attempts}')"
  emit_span "codex-review" "$model" "$status" "$dur" "$cost" "$usage" \
    "review --base $base_sha --head $head_sha" "$artifacts"
  ingest_usage "$model" "codex" "${rc:-0}" "$usage" "$cost"
  write_run_state "$status"
  write_run_artifact_status "$art" "$RUN_ID" \
    "$([[ "$status" == "ok" ]] && printf completed || printf failed)" \
    "$wt" "" "$status"

  git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1 || true
  git -C "$repo" worktree prune >/dev/null 2>&1 || true
  LEGION_WT_PATH=""
  REVIEW_RECEIPT_PATH=""
  REVIEW_ART_PATH=""
  REVIEW_WT_PATH=""
  REVIEW_START_MS=0

  jq -cn --arg status "$status" --arg reason "$reason" --arg model "$model" \
    --arg run "$RUN_ID" --arg receipt "$receipt" --arg patch "$patch_path" \
    --arg base "$base_sha" --arg head "$head_sha" --arg error_log "$error_log" \
    --argjson attempts "$attempt" --argjson max_attempts "$max_attempts" \
    --argjson usage "$usage" --argjson cost "${cost:-0}" \
    --argjson verdict "$verdict_json" '
    {run_id:$run, status:$status, reason:$reason, model:$model,
     reviewed_base_sha:$base, reviewed_head_sha:$head,
     review_patch:$patch, terminal_receipt:$receipt,
     attempts:$attempts, max_attempts:$max_attempts,
     verdict:$verdict, error_log:$error_log, usage:$usage, cost_usd:$cost}'
  [[ "$status" == "ok" ]] || exit 1
}

# ── resume (continue a kept codex session for iterative refinement) ──
cmd_resume() {
  local run="" task="" model="" repo="$PWD" effort=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --run) run="$2"; shift 2 ;;
      --task) task="$2"; shift 2 ;;
      --model) model="$2"; shift 2 ;;
      --repo) repo="$2"; shift 2 ;;
      --reasoning-effort) effort="$2"; shift 2 ;;
      --quiet) QUIET=1; shift ;;
      *) die "resume: unknown arg '$1'" ;;
    esac
  done
  [[ -n "$run" ]] || die "resume: --run RUN_ID required"
  repo="$(cd "$repo" && pwd)"; require_git_repo "$repo"; resolve_runtime_state "$repo"
  [[ -n "$task" ]] || task="$(cat)"
  [[ -n "$task" ]] || die "resume: empty follow-up task"
  scan_task_text "$task"
  local art="$repo/.legion/runs/$run"
  [[ -d "$art" ]] || die "resume: no run '$run' under $repo/.legion/runs"
  local wt="$repo/.legion/worktrees/$run"
  [[ -d "$wt" ]] || die "resume: worktree for '$run' is gone — the original run must use --keep to be resumable"
  local thread_id; thread_id="$(codex_thread_id "$art/stream.jsonl")"
  [[ -n "$thread_id" ]] || die "resume: no codex thread id recorded for run '$run'"
  # Inherit the original run's model (persisted by `run`) so resume doesn't silently drift (M2).
  [[ -n "$model" ]] || model="$(cat "$art/model.txt" 2>/dev/null || true)"
  [[ -n "$model" ]] || model="$(legion_model_ref codex_workhorse)" || die "could not resolve codex_workhorse in models.toml"
  [[ -n "$effort" ]] || effort="xhigh"   # codex always at xhigh unless overridden

  RUN_ID="$run"
  legion_activate_executor_context "$RUN_ID"
  local start_ms end_ms dur rc=0
  start_ms="$(date +%s000)"
  note "→ codex exec resume $thread_id (run $run)"
  set +e
  if [[ -n "$effort" ]]; then
    printf '%s' "$task" | ( cd "$wt" && "$CODEX_BIN" exec resume "$thread_id" --json \
        -m "$model" -c "model_reasoning_effort=$effort" --skip-git-repo-check \
        -o "$art/resume-last-message.txt" - ) >"$art/resume-stream.jsonl" 2>"$art/resume.err" &
    CODEX_CHILD_PID=$!
  else
    printf '%s' "$task" | ( cd "$wt" && "$CODEX_BIN" exec resume "$thread_id" --json \
        -m "$model" --skip-git-repo-check \
        -o "$art/resume-last-message.txt" - ) >"$art/resume-stream.jsonl" 2>"$art/resume.err" &
    CODEX_CHILD_PID=$!
  fi
  # Backgrounded + waited so on_terminating_signal can reap codex; wait's status
  # is the codex subshell's exit (== the old PIPESTATUS[1]).
  wait "$CODEX_CHILD_PID"; rc=$?
  CODEX_CHILD_PID=""
  set -e
  end_ms="$(date +%s000)"; dur=$(( end_ms - start_ms ))

  local usage cost diff_rc=0 status="ok"
  usage="$(codex_usage "$art/resume-stream.jsonl")"
  cost="$(cost_from_usage "$model" "$usage" 2>/dev/null || echo 0)"
  cleanup_generated_diff_noise "$wt"
  git -C "$wt" add -A 2>/dev/null || diff_rc=1
  git -C "$wt" diff --cached >"$art/diff.patch" 2>/dev/null || diff_rc=1
  [[ "$rc" -ne 0 ]] && status="failed"
  [[ "$diff_rc" -ne 0 && "$status" == "ok" ]] && status="error"

  emit_span "codex-resume" "$model" "$status" "$dur" "$cost" "$usage" "resume $run: $task" \
    "$(jq -cn --arg wt "$wt" --arg diff "$art/diff.patch" '{worktree:$wt, diff:$diff}')"
  ingest_usage "$model" "codex" "${rc:-0}" "$usage" "$cost"

  jq -cn --arg status "$status" --arg model "$model" --arg thread "$thread_id" \
    --arg wt "$wt" --arg diff "$art/diff.patch" --arg run "$run" \
    --argjson usage "$usage" --argjson cost "${cost:-0}" '
    {run_id:$run, status:$status, model:$model, thread_id:$thread, worktree:$wt, diff_path:$diff, usage:$usage, cost_usd:$cost}'
  [[ "$status" == "ok" ]] || exit 1
}

# ── apply / cleanup ──────────────────────────────────────────────────
cmd_apply() {
  local run="" repo="$PWD"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --run) run="$2"; shift 2 ;;
      --repo) repo="$2"; shift 2 ;;
      --quiet) QUIET=1; shift ;;
      *) die "apply: unknown arg '$1'" ;;
    esac
  done
  [[ -n "$run" ]] || die "apply: --run RUN_ID required"
  repo="$(cd "$repo" && pwd)"; resolve_runtime_state "$repo"
  local diff="$repo/.legion/runs/$run/diff.patch"
  [[ -s "$diff" ]] || die "apply: no diff at $diff"
  git -C "$repo" apply --check "$diff" || die "apply: diff does not apply cleanly"
  git -C "$repo" apply "$diff"
  note "✓ applied $diff"
}

# Report a run from its local artifacts. Detached workers update status.json on
# start and finish; a still-live recorded pid is the authoritative running bit.
cmd_status() {
  local run="" repo="$PWD"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --run) run="$2"; shift 2 ;;
      --repo) repo="$2"; shift 2 ;;
      --quiet) QUIET=1; shift ;;
      *) die "status: unknown arg '$1'" ;;
    esac
  done
  [[ -n "$run" ]] || die "status: --run RUN_ID required"
  repo="$(cd "$repo" && pwd)"
  local art="$repo/.legion/runs/$run" state_file="$repo/.legion/runs/$run/status.json"
  [[ -d "$art" ]] || die "status: no run '$run' under $repo/.legion/runs"

  local phase="" result="" wt="" pid="" pid_json="null"
  if [[ -s "$state_file" ]] && jq -e . "$state_file" >/dev/null 2>&1; then
    phase="$(jq -r '.status // empty' "$state_file")"
    result="$(jq -r '.result_status // empty' "$state_file")"
    wt="$(jq -r '.worktree // empty' "$state_file")"
    pid="$(jq -r '.pid // empty' "$state_file")"
  fi
  if [[ -s "$art/pid" ]]; then
    local recorded_pid
    recorded_pid="$(cat "$art/pid" 2>/dev/null || true)"
    [[ "$recorded_pid" =~ ^[0-9]+$ ]] && pid="$recorded_pid"
  fi

  case "$phase" in
    completed|failed) ;;
    *)
      if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
        phase="executing"
      else
        phase="failed"
        [[ -n "$result" ]] || result="worker exited without a terminal status"
      fi
      ;;
  esac
  [[ "$pid" =~ ^[0-9]+$ ]] && pid_json="$pid"
  jq -cn --arg run "$run" --arg status "$phase" --arg wt "$wt" --arg dir "$art" \
    --arg result "$result" --argjson pid "$pid_json" '
    {run_id:$run, status:$status, worktree:$wt, run_dir:$dir, pid:$pid,
     result_status:(if $result=="" then null else $result end)}'
}

# Bulk/targeted cleanup of delegation worktrees + branches (+ run artifacts with --purge).
# `run` auto-deletes its own worktree on completion (unless --keep); this reclaims --keep'd
# runs, resume sessions, and anything orphaned by a crash.
cmd_cleanup() {
  local run="" all=0 repo="$PWD" purge=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --run) run="$2"; shift 2 ;;
      --all) all=1; shift ;;
      --purge) purge=1; shift ;;   # also delete run artifacts (diffs/streams), not just worktrees
      --repo) repo="$2"; shift 2 ;;
      --quiet) QUIET=1; shift ;;
      *) die "cleanup: unknown arg '$1'" ;;
    esac
  done
  repo="$(cd "$repo" && pwd)"; require_git_repo "$repo"; resolve_runtime_state "$repo"
  local wtroot="$repo/.legion/worktrees" runsroot="$repo/.legion/runs"
  local n_wt=0 n_br=0 n_runs=0 wt b extra=""
  if [[ "$all" -eq 1 ]]; then
    if [[ -d "$wtroot" ]]; then
      for wt in "$wtroot"/*; do
        [[ -d "$wt" ]] || continue
        git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
        n_wt=$((n_wt + 1))
      done
    fi
    while IFS= read -r b; do
      [[ -z "$b" ]] && continue
      git -C "$repo" branch -D "$b" >/dev/null 2>&1 && n_br=$((n_br + 1)) || true
    done < <(git -C "$repo" branch --list 'legion/delegate-*' --format '%(refname:short)')
    git -C "$repo" worktree prune >/dev/null 2>&1 || true
    if [[ "$purge" -eq 1 && -d "$runsroot" ]]; then
      n_runs="$(find "$runsroot" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
      rm -rf "$runsroot"
      extra=" + $n_runs run artifact(s)"
    fi
    note "✓ cleaned $n_wt worktree(s) + $n_br branch(es)$extra"
  elif [[ -n "$run" ]]; then
    local run_wt="$wtroot/$run" run_art="$runsroot/$run"
    if [[ -d "$run_wt" ]]; then
      git -C "$repo" worktree remove --force "$run_wt" >/dev/null 2>&1 || rm -rf "${run_wt:?}"
      n_wt=1
    fi
    git -C "$repo" branch -D "legion/delegate-$run" >/dev/null 2>&1 && n_br=1 || true
    git -C "$repo" worktree prune >/dev/null 2>&1 || true
    if [[ "$purge" -eq 1 && -d "$run_art" ]]; then rm -rf "${run_art:?}"; extra=" + artifacts"; fi
    note "✓ cleaned run $run ($n_wt worktree, $n_br branch)$extra"
  else
    die "cleanup: --run RUN_ID | --all required (add --purge to also delete run artifacts)"
  fi
}

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    run)     cmd_run "$@" ;;
    review)  cmd_review "$@" ;;
    resume)  cmd_resume "$@" ;;
    apply)   cmd_apply "$@" ;;
    status)  cmd_status "$@" ;;
    cleanup) cmd_cleanup "$@" ;;
    -h|--help|help|"") cat >&2 <<'EOF'
legion-delegate — delegate a scoped task to an external model agent (Codex by
default; any registered executor via --executor)

  run      [--archetype A | --model M] [--executor codex|cursor|claude|opencode]
           [--sandbox read-only|workspace-write|docker|podman|vercel]
           [--reasoning-effort low|medium|high|xhigh] [--task T|stdin] [--repo DIR]
           [--base REF] [--budget-tokens N] [--scope PATHSPEC ...] [--detach] [--apply] [--keep]
           [--no-dirty-warn] [--untrusted]
  review   [--archetype A | --model M] --base REF [--head REF] [--max-attempts N]
           [--repo DIR] [--reasoning-effort E] [--task T]
           -> immutable-SHA structured verdict + terminal receipt
  resume   --run RUN_ID [--task T|stdin] [--model M] [--repo DIR] [--reasoning-effort E]
           -> continue a kept codex session (original run needs --keep)
  apply    --run RUN_ID [--repo DIR]
  status   --run RUN_ID [--repo DIR]
  cleanup  [--run RUN_ID | --all] [--purge] [--repo DIR]
           (run auto-deletes its own worktree on completion unless --keep; this
            reclaims --keep'd/resume worktrees + branches; --purge also drops run artifacts)

--archetype resolves model/sandbox/effort from routing.toml + models.toml. List them: legion-route --list
--executor forces a specific harness (symmetric reverse-delegate). List them: legion-route --list-executors
--scope may be repeated; it limits the captured diff to those git pathspecs.
--detach returns after setup and leaves the worker running in a new session; use status --run RUN_ID to poll it.
EOF
      [[ "$cmd" == "" ]] && exit 2 || exit 0 ;;
    *) die "unknown command '$cmd' (run|review|resume|apply|status|cleanup)" ;;
  esac
}

main "$@"
