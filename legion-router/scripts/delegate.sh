#!/usr/bin/env bash
# legion-delegate — hand a scoped task to an external model agent (Codex / GPT-5.x)
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
#           [--budget-tokens N] [--apply] [--quiet]
#   review  --model M --base BRANCH [--repo DIR]
#   apply   --run RUN_ID [--repo DIR]          # apply a captured diff to the repo
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
# shellcheck source=lib/primary.sh
source "$_self_dir/lib/primary.sh"
# shellcheck disable=SC1091
# shellcheck source=lib/sandbox-setup.sh
source "$_self_dir/lib/sandbox-setup.sh"
_state_lib="$_self_dir/../../legion-observability/scripts/lib/state.sh"
if [[ -f "$_state_lib" ]]; then
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
trap 'cleanup_sandbox_dev_on_exit; cleanup_worktree_on_exit' EXIT

# codex is launched in the background and immediately waited on, so a terminating
# signal to this wrapper interrupts the `wait` and runs this handler — otherwise a
# `kill`/hangup of the wrapper would leave codex orphaned (still billing, its
# stream.jsonl still growing). Best-effort: TERM the tracked child plus any codex
# grandchild (review/resume wrap it in a `( cd … && codex )` subshell).
CODEX_CHILD_PID=""
kill_codex_child() {
  local pid="${CODEX_CHILD_PID:-}"
  [[ -n "$pid" ]] || return 0
  pkill -TERM -P "$pid" 2>/dev/null || true
  kill -TERM "$pid" 2>/dev/null || true
}
on_terminating_signal() {
  kill_codex_child
  exit 143   # 128 + SIGTERM; EXIT trap still runs (sandbox teardown)
}
trap on_terminating_signal INT TERM HUP

ROUTE_BIN="$_self_dir/legion-route.py"
REVIEW_SCHEMA="$_self_dir/../schema/review-verdict.schema.json"

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
  local text="$1"
  [[ "${LEGION_ALLOW_UNSAFE:-0}" == "1" ]] && return 0
  local norm
  norm="$(printf '%s' "$text" | tr -s '[:space:]' ' ')"
  local patterns='rm -rf|rm -fr|rm -[a-z]*r[a-z]* /|git push|--force|force[ -]push|:\(\)\{|/etc/(passwd|shadow)|\.ssh|id_rsa|\.aws/|\.netrc|AWS_SECRET|ANTHROPIC_API_KEY|OPENAI_API_KEY|(curl|wget|fetch)[^|]*\|[[:space:]]*(ba)?sh|nc |ncat|/dev/tcp|DROP TABLE|sudo'
  if printf '%s' "$norm" | grep -qiE "$patterns"; then
    die "task text matched a dangerous/injection pattern; refusing write delegation. Review the task, or set LEGION_ALLOW_UNSAFE=1 to override."
  fi
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

# write/update the per-run state record (legion.run-state.v1) — the Console + handoff
# foundation. Best-effort: telemetry must NEVER break the run (the whole body is the LHS
# of `|| true`, so `set -e` is suppressed inside). Reads RUN_ID + caller scope (repo, wt,
# art, branch, model, sandbox, effort, base). Preserves started_at + bumps state_version.
# Arg: <phase>  (running | ok | failed | error | over_budget | …)
write_run_state() {
  local phase="$1"
  {
    mkdir -p "$LEGION_REGISTRY_DIR"
    local f="$LEGION_REGISTRY_DIR/$RUN_ID.json"
    local now started sv pgid host
    now="$(_now)"
    started="$now"; sv=0
    if [[ -f "$f" ]]; then
      local prev_started prev_sv
      prev_started="$(jq -r '.lifecycle.started_at // empty' "$f" 2>/dev/null)"
      prev_sv="$(jq -r '.state_version // 0' "$f" 2>/dev/null)"
      [[ -n "$prev_started" ]] && started="$prev_started"
      [[ "$prev_sv" =~ ^[0-9]+$ ]] && sv="$prev_sv"
    fi
    sv=$((sv + 1))
    pgid="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')"; [[ "$pgid" =~ ^[0-9]+$ ]] || pgid=0
    host="$(hostname 2>/dev/null || echo unknown)"
    jq -cn \
      --arg schema "legion.run-state.v1" --arg run "$RUN_ID" \
      --arg trace "${LEGION_TRACE_ID:-$RUN_ID}" --arg parent "${LEGION_PARENT_ID:-}" \
      --arg kind "${RUN_KIND:-run}" --arg repo "$repo" --arg run_dir "$art" \
      --arg wt "$wt" --arg branch "$branch" --arg model "$model" --arg sandbox "$sandbox" \
      --arg effort "$effort" --arg base "$base" --arg host "$host" --arg archetype "${archetype:-}" \
      --argjson pid "$$" --argjson pgid "$pgid" \
      --arg started "$started" --arg now "$now" --arg phase "$phase" --argjson sv "$sv" '
      {schema:$schema, run_id:$run, trace_id:$trace,
       parent_id:(if $parent=="" then null else $parent end),
       kind:$kind, state_version:$sv,
       repo_root:$repo, run_dir:$run_dir, worktree_dir:$wt, branch:$branch,
       model:$model, archetype:$archetype, sandbox:$sandbox, reasoning_effort:$effort, base_ref:$base,
       process:{pid:$pid, pgid:$pgid, started_at:$started, host:$host},
       lifecycle:{phase:$phase, started_at:$started, updated_at:$now}}' \
      > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f" && chmod 600 "$f" 2>/dev/null
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
  local -a aargs=(run --repo "$repo" --task "$task")
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
  local budget=0 do_apply=0 keep=0 preset_run_id=""
  local untrusted=0
  local forced_executor="" explicit_model=""
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
      --untrusted) untrusted=1; shift ;;
      --quiet) QUIET=1; shift ;;
      *) die "run: unknown arg '$1'" ;;
    esac
  done
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
  # Dispatch by executor. `self` is the primary's own inline work (never delegated);
  # codex (or an unclassified task) uses the native codex path below; any other
  # registered coding executor runs through its adapter.
  case "$r_exec" in
    self)
      die "executor=self — the primary harness ($(legion_primary)) does this inline, not via legion-delegate. (use --executor <name> to force a specific harness)" ;;
    ""|codex) : ;;
    *) dispatch_adapter "$r_exec" ;;   # execs the adapter and never returns
  esac
  [[ -n "$effort" ]] || effort="xhigh"   # codex always runs at xhigh unless explicitly overridden
  [[ -n "$model" ]] || die "run: --model or --archetype required"
  repo="$(cd "$repo" && pwd)"; require_git_repo "$repo"; resolve_runtime_state "$repo"

  RUN_ID="${preset_run_id:-$(_run_id)}"
  local wt="$repo/.legion/worktrees/$RUN_ID"
  local art="$repo/.legion/runs/$RUN_ID"
  mkdir -p "$art"
  # Keep all legion runtime state out of the target repo's git status / diffs.
  printf '*\n' > "$repo/.legion/.gitignore" 2>/dev/null || true
  local branch="legion/delegate-$RUN_ID"
  note "→ worktree $wt (branch $branch, base $base)"
  git -C "$repo" worktree add -q -b "$branch" "$wt" "$base" || die "worktree add failed"
  # Register for EXIT-trap cleanup so a crash/kill before the inline removal
  # below does not orphan the worktree + branch (WS6 worktree-leak guard).
  LEGION_WT_PATH="$wt"; LEGION_WT_BRANCH="$branch"; LEGION_WT_REPO="$repo"; LEGION_WT_KEEP="$keep"
  local sandbox_dev_pid=""
  if ! is_sandcastle_sandbox "$sandbox"; then
    sandbox_dev_pid="$(LEGION_SANDBOX_ARTIFACT_DIR="$art" LEGION_SANDBOX_QUIET="${QUIET:-0}" sandbox_setup "$wt" "$repo" "$untrusted" || true)"
    SANDBOX_DEV_PID_TO_TEARDOWN="$sandbox_dev_pid"
  fi
  write_run_state running

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

  local thread_id usage cost
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
    git -C "$wt" diff --cached >"$art/diff.patch" 2>/dev/null || diff_rc=1
  else
    [[ -f "$art/diff.patch" ]] || : > "$art/diff.patch"
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

  jq -cn --arg status "$status" --arg model "$model" --arg thread "$thread_id" \
    --arg wt "$wt_report" --arg diff "$art/diff.patch" --arg last "$art/last-message.txt" \
    --argjson usage "$usage" --argjson cost "${cost:-0}" --arg run "$RUN_ID" --argjson rc "${rc:-0}" '
    {run_id:$run, status:$status, model:$model, thread_id:$thread, codex_exit:$rc,
     worktree:$wt, diff_path:$diff, last_message_path:$last, usage:$usage, cost_usd:$cost}'
  # over_budget produced a usable diff (budget is advisory — codex can't be pre-empted),
  # so it exits 0; only a real failure/error is non-zero (M1: graceful degradation).
  case "$status" in
    ok|over_budget) exit 0 ;;
    *) exit 1 ;;
  esac
}

# ── review (second opinion / cross-model) ────────────────────────────
cmd_review() {
  local model="" base="" repo="$PWD" archetype="" effort=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --model) model="$2"; shift 2 ;;
      --base) base="$2"; shift 2 ;;
      --repo) repo="$2"; shift 2 ;;
      --archetype) archetype="$2"; shift 2 ;;
      --reasoning-effort) effort="$2"; shift 2 ;;
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
  [[ -n "$effort" ]] || effort="xhigh"   # codex review always at xhigh unless overridden
  [[ -n "$base" ]] || die "review: --base BRANCH required"
  repo="$(cd "$repo" && pwd)"; require_git_repo "$repo"; resolve_runtime_state "$repo"
  RUN_ID="$(_run_id)"
  local art="$repo/.legion/runs/$RUN_ID"; mkdir -p "$art"
  local verdict_file="$art/verdict.json"

  # `codex exec review` takes NO -C / -s — run inside the repo; --output-schema forces
  # a structured verdict Opus can reconcile programmatically.
  local start_ms end_ms dur rc=0
  start_ms="$(date +%s000)"
  # </dev/null: `codex exec review` takes no task on stdin, so never let it inherit
  # (and block on / drain) the wrapper's stdin — a non-tty stdin (nohup, pipe,
  # `script -q`) otherwise fed it a stray EOF. Backgrounded + waited so a killed
  # wrapper reaps codex via on_terminating_signal instead of orphaning it.
  set +e
  if [[ -n "$effort" ]]; then
    ( cd "$repo" && "$CODEX_BIN" exec review --base "$base" -m "$model" --json \
        -c "model_reasoning_effort=$effort" --output-schema "$REVIEW_SCHEMA" \
        -o "$verdict_file" ) </dev/null >"$art/stream.jsonl" 2>"$art/codex.err" &
    CODEX_CHILD_PID=$!
  else
    ( cd "$repo" && "$CODEX_BIN" exec review --base "$base" -m "$model" --json \
        --output-schema "$REVIEW_SCHEMA" -o "$verdict_file" ) </dev/null >"$art/stream.jsonl" 2>"$art/codex.err" &
    CODEX_CHILD_PID=$!
  fi
  wait "$CODEX_CHILD_PID"; rc=$?
  CODEX_CHILD_PID=""
  set -e
  end_ms="$(date +%s000)"; dur=$(( end_ms - start_ms ))

  local verdict usage cost status="ok"
  if [[ -s "$verdict_file" ]]; then verdict="$(cat "$verdict_file")"; else verdict="$(codex_last_message "$art/stream.jsonl")"; fi
  usage="$(codex_usage "$art/stream.jsonl")"
  cost="$(cost_from_usage "$model" "$usage" 2>/dev/null || echo 0)"
  [[ "$rc" -ne 0 ]] && status="failed"

  emit_span "codex-review" "$model" "$status" "$dur" "$cost" "$usage" "review --base $base" \
    "$(jq -cn --arg v "$verdict_file" '{verdict:$v}')"
  ingest_usage "$model" "codex" "${rc:-0}" "$usage" "$cost"

  # Embed the verdict as JSON when it parses (schema-valid), else as a string.
  local verdict_json
  if jq -e . <<<"$verdict" >/dev/null 2>&1; then verdict_json="$verdict"; else verdict_json="$(jq -Rn --arg v "$verdict" '$v')"; fi
  jq -cn --arg status "$status" --arg model "$model" --arg run "$RUN_ID" \
    --argjson usage "$usage" --argjson cost "${cost:-0}" --argjson verdict "$verdict_json" '
    {run_id:$run, status:$status, model:$model, verdict:$verdict, usage:$usage, cost_usd:$cost}'
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
    cleanup) cmd_cleanup "$@" ;;
    -h|--help|help|"") cat >&2 <<'EOF'
legion-delegate — delegate a scoped task to an external model agent (Codex by
default; any registered executor via --executor)

  run      [--archetype A | --model M] [--executor codex|cursor|claude|opencode]
           [--sandbox read-only|workspace-write|docker|podman|vercel]
           [--reasoning-effort low|medium|high|xhigh] [--task T|stdin] [--repo DIR]
           [--base REF] [--budget-tokens N] [--apply] [--keep] [--untrusted]
  review   [--archetype A | --model M] --base BRANCH [--repo DIR] [--reasoning-effort E]
           -> structured verdict (codex --output-schema)
  resume   --run RUN_ID [--task T|stdin] [--model M] [--repo DIR] [--reasoning-effort E]
           -> continue a kept codex session (original run needs --keep)
  apply    --run RUN_ID [--repo DIR]
  cleanup  [--run RUN_ID | --all] [--purge] [--repo DIR]
           (run auto-deletes its own worktree on completion unless --keep; this
            reclaims --keep'd/resume worktrees + branches; --purge also drops run artifacts)

--archetype resolves model/sandbox/effort from routing.toml + models.toml. List them: legion-route --list
--executor forces a specific harness (symmetric reverse-delegate). List them: legion-route --list-executors
EOF
      [[ "$cmd" == "" ]] && exit 2 || exit 0 ;;
    *) die "unknown command '$cmd' (run|review|resume|apply|cleanup)" ;;
  esac
}

main "$@"
