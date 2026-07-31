#!/usr/bin/env bash
# Shared shell helper for resolving Legion runtime state.

legion_resolve_state() {
  local repo="${1:-$PWD}"
  local here py
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  py="${LEGION_STATE_PY:-$here/legion_state.py}"
  if [[ -f "$py" ]] && command -v python3 >/dev/null 2>&1; then
    # Capture-then-eval instead of `source <(python3 …)`. Process substitution +
    # the `source`/`.` builtin is unreliable on bash 3.2 (the macOS system bash
    # that `#!/usr/bin/env bash` resolves to when no newer bash is installed):
    # `source` reopens the /dev/fd pipe by name and races the writer, so under
    # non-interactive / backgrounded / piped stdio it sources NOTHING and leaves
    # the LEGION_* vars unset — which then aborts callers under `set -u` and leaks
    # the writer's "BrokenPipeError: [Errno 32] Broken pipe" to stderr. A plain
    # command substitution fully drains the child's stdout before we eval it.
    # legion_state.py shell-quotes every value, so eval of its `export …` lines is safe.
    local _legion_state_exports
    if _legion_state_exports="$(python3 "$py" --repo "$repo" --shell)" \
       && [[ -n "$_legion_state_exports" ]]; then
      eval "$_legion_state_exports"
      return 0
    fi
  fi

  export LEGION_STATE_ROOT="${LEGION_STATE_ROOT:-$HOME/.legion/projects/default}"
  export LEGION_TELEMETRY_DIR="${LEGION_TELEMETRY_DIR:-$LEGION_STATE_ROOT/spans}"
  export LEGION_REGISTRY_DIR="${LEGION_REGISTRY_DIR:-$LEGION_STATE_ROOT/registry}"
  export LEGION_REPOS_FILE="${LEGION_REPOS_FILE:-$LEGION_STATE_ROOT/repos.jsonl}"
  export LEGION_BENCH_DIR="${LEGION_BENCH_DIR:-$LEGION_STATE_ROOT/bench}"
  export LEGION_REPORTS_DIR="${LEGION_REPORTS_DIR:-$LEGION_STATE_ROOT/reports}"
}

legion_validate_run_id() {
  local run_id="${1:-}"
  [[ "${#run_id}" -le 128 && "$run_id" =~ ^[[:alnum:]][[:alnum:]_.-]*$ ]]
}

# Update one adapter-owned run record while preserving fields written by a
# fanout's queued preallocation. Best-effort telemetry must never break a run.
legion_write_adapter_run_state() {
  local phase="$1" run_id="$2" repo="$3" run_dir="$4" worktree="$5"
  local branch="$6" model="$7" sandbox="$8" base="$9"
  local archetype="${10:-}" effort="${11:-}"
  {
    local registry="${LEGION_REGISTRY_DIR:?}" record source temp now pgid host
    local trace="${LEGION_TRACE_ID:-}" parent="${LEGION_PARENT_ID:-}"
    mkdir -p "$registry"
    chmod 700 "$registry" 2>/dev/null || true
    record="$registry/$run_id.json"
    source="$record"
    [[ -f "$source" ]] || source=/dev/null
    temp="$record.tmp.$$"
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    pgid="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')"
    [[ "$pgid" =~ ^[0-9]+$ ]] || pgid=0
    host="$(hostname 2>/dev/null || echo unknown)"
    if (
      umask 077
      jq -cn --slurpfile prior "$source" \
        --arg schema "legion.run-state.v1" --arg run "$run_id" \
        --arg trace "$trace" --arg parent "$parent" --arg repo "$repo" \
        --arg run_dir "$run_dir" --arg wt "$worktree" --arg branch "$branch" \
        --arg model "$model" --arg sandbox "$sandbox" --arg effort "$effort" \
        --arg base "$base" --arg host "$host" --arg archetype "$archetype" \
        --arg phase "$phase" --arg now "$now" --argjson pid "$$" --argjson pgid "$pgid" '
        ($prior[0] // {}) as $old
        | ($old.lifecycle.started_at // "") as $old_started
        | (if $old_started == "" then $now else $old_started end) as $started
        | $old
        | .schema = $schema
        | .run_id = $run
        | .trace_id = (if $trace == "" then ($old.trace_id // $run) else $trace end)
        | .parent_id = (if $parent == "" then ($old.parent_id // null) else $parent end)
        | .kind = ($old.kind // "run")
        | .state_version = ((if ($old.state_version | type) == "number" then $old.state_version else 0 end) + 1)
        | .repo_root = $repo
        | .run_dir = $run_dir
        | .worktree_dir = $wt
        | .branch = $branch
        | .model = $model
        | .archetype = $archetype
        | .sandbox = $sandbox
        | .reasoning_effort = $effort
        | .base_ref = $base
        | .process = {pid:$pid, pgid:$pgid, started_at:$started, host:$host}
        | .lifecycle = {phase:$phase, started_at:$started, updated_at:$now}
      ' > "$temp"
    ); then
      chmod 600 "$temp" 2>/dev/null || true
      mv -f "$temp" "$record"
    else
      rm -f "$temp"
    fi
  } 2>/dev/null || true
  return 0
}
