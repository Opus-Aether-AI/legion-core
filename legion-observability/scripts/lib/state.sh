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

legion_prepare_private_registry() {
  local registry="$1"
  [[ ! -L "$registry" ]] || return 1
  [[ ! -e "$registry" || -d "$registry" ]] || return 1
  (umask 077; mkdir -p "$registry") || return 1
  [[ -d "$registry" && ! -L "$registry" ]] || return 1
  chmod 700 "$registry" || return 1
}

# Bash 3.2/macOS has no portable flock(1). An atomic mkdir is the primary lock.
# Release and dead-owner recovery first claim that exact directory generation,
# then atomically rename it into a same-parent quarantine before cleanup. A new
# owner can therefore reuse the canonical path without a delayed cleanup ever
# touching it. Empty/invalid locks and interrupted claims fail closed: portable
# shell cannot safely infer that a paused creator or claimant is dead. This is a
# cooperative protocol for Legion processes inside the private (0700) registry;
# hostile same-UID pathname replacement requires native filesystem primitives.
legion_claim_run_state_lock_mutation() {
  local lock="$1" claim="$1/.claim"
  [[ -d "$lock" && ! -L "$lock" ]] || return 1
  (umask 077; mkdir "$claim") 2>/dev/null || return 1
  if [[ ! -d "$lock" || -L "$lock" || ! -d "$claim" || -L "$claim" ]]; then
    [[ ! -L "$claim" ]] && rmdir "$claim" 2>/dev/null || true
    return 1
  fi
  printf '%s\n' "$claim"
}

legion_release_run_state_lock_claim() {
  local claim="$1"
  [[ -d "$claim" && ! -L "$claim" ]] || return 0
  rmdir "$claim" 2>/dev/null || true
}

legion_read_claimed_run_state_lock_owner() {
  local lock="$1" pid_file="$1/pid"
  [[ -f "$pid_file" && ! -L "$pid_file" ]] || return 1
  cat "$pid_file"
}

legion_quarantine_claimed_run_state_lock() {
  local lock="$1" directory="${1%/*}" quarantine="" held=""
  quarantine="$(umask 077; mktemp -d "$directory/.legion-lock-reap.XXXXXX")" || {
    legion_release_run_state_lock_claim "$lock/.claim"
    return 1
  }
  if [[ ! -d "$quarantine" || -L "$quarantine" ]]; then
    legion_release_run_state_lock_claim "$lock/.claim"
    return 1
  fi
  held="$quarantine/held"
  if ! mv "$lock" "$held" 2>/dev/null; then
    legion_release_run_state_lock_claim "$lock/.claim"
    rmdir "$quarantine" 2>/dev/null || true
    return 1
  fi

  # Cleanup only the claimed generation. Unexpected contents remain isolated in
  # the private quarantine rather than being recursively removed or followed.
  if [[ -d "$held" && ! -L "$held" \
    && -f "$held/pid" && ! -L "$held/pid" \
    && -d "$held/.claim" && ! -L "$held/.claim" ]]; then
    rm -f "$held/pid" 2>/dev/null || true
    rmdir "$held/.claim" 2>/dev/null || true
    rmdir "$held" 2>/dev/null || true
    rmdir "$quarantine" 2>/dev/null || true
  fi
}

legion_recover_dead_run_state_lock() {
  local lock="$1" claim="" owner=""
  claim="$(legion_claim_run_state_lock_mutation "$lock")" || return 0
  if ! owner="$(legion_read_claimed_run_state_lock_owner "$lock" 2>/dev/null)"; then
    legion_release_run_state_lock_claim "$claim"
    return 0
  fi
  if [[ "$owner" =~ ^[1-9][0-9]*$ ]] && ! kill -0 "$owner" 2>/dev/null; then
    legion_quarantine_claimed_run_state_lock "$lock"
  else
    legion_release_run_state_lock_claim "$claim"
  fi
}

legion_acquire_run_state_lock() {
  local record="$1"
  local lock="$record.lock" attempt=0
  # A coverage-instrumented or heavily contended host can spend several seconds
  # just starting the competing shells. Keep the lock bounded, but give every
  # writer a realistic chance to observe a release instead of silently dropping
  # a state transition after the previous five-second retry window.
  while [[ "$attempt" -lt 3000 ]]; do
    if (umask 077; mkdir "$lock") 2>/dev/null; then
      if (set -C; umask 077; printf '%s\n' "$$" > "$lock/pid") 2>/dev/null; then
        printf '%s\n' "$lock"
        return 0
      fi
      rmdir "$lock" 2>/dev/null || true
      return 1
    fi
    [[ ! -L "$lock" ]] || return 1
    if [[ ! -d "$lock" ]]; then
      attempt=$((attempt + 1))
      sleep 0.01
      continue
    fi
    # `mkdir` makes the directory visible just before its owner writes pid.
    # Treat that short, incomplete generation as live rather than making every
    # contender claim and release `.claim`; the resulting claim storm can starve
    # the owner on a busy CI host. Non-regular metadata is never trusted.
    [[ ! -L "$lock/pid" ]] || return 1
    [[ ! -e "$lock/pid" || -f "$lock/pid" ]] || return 1
    if [[ ! -f "$lock/pid" ]]; then
      attempt=$((attempt + 1))
      sleep 0.01
      continue
    fi
    legion_recover_dead_run_state_lock "$lock"
    attempt=$((attempt + 1))
    sleep 0.01
  done
  return 1
}

legion_release_run_state_lock() {
  local lock="$1" claim="" owner="" attempt=0
  while [[ "$attempt" -lt 500 ]]; do
    [[ -d "$lock" && ! -L "$lock" ]] || return 0
    if claim="$(legion_claim_run_state_lock_mutation "$lock")"; then
      if ! owner="$(legion_read_claimed_run_state_lock_owner "$lock" 2>/dev/null)"; then
        legion_release_run_state_lock_claim "$claim"
        return 0
      fi
      if [[ "$owner" == "$$" ]]; then
        legion_quarantine_claimed_run_state_lock "$lock"
      else
        legion_release_run_state_lock_claim "$claim"
      fi
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 0.01
  done
}

legion_create_run_state_temp() {
  local record="$1"
  local directory="${record%/*}" name="${record##*/}" temp=""
  temp="$(umask 077; mktemp "$directory/.$name.tmp.XXXXXX")" || return 1
  [[ -f "$temp" && ! -L "$temp" ]] || return 1
  printf '%s\n' "$temp"
}

# Update one adapter-owned run record while preserving fields written by a
# fanout's queued preallocation. Best-effort telemetry must never break a run.
legion_write_adapter_run_state() {
  local phase="$1" run_id="$2" repo="$3" run_dir="$4" worktree="$5"
  local branch="$6" model="$7" sandbox="$8" base="$9"
  local archetype="${10:-}" effort="${11:-}" kind="${12:-${RUN_KIND:-}}"
  {
    (
      local registry="${LEGION_REGISTRY_DIR:?}" record source temp="" lock="" now pgid host
      local trace="${LEGION_TRACE_ID:-}" parent="${LEGION_PARENT_ID:-}"
      legion_validate_run_id "$run_id" || return 0
      legion_prepare_private_registry "$registry" || return 0
      record="$registry/$run_id.json"
      [[ ! -L "$record" && ( ! -e "$record" || -f "$record" ) ]] || return 0
      lock="$(legion_acquire_run_state_lock "$record")" || return 0
      trap 'rm -f "${temp:-}" 2>/dev/null || true; legion_release_run_state_lock "$lock"' EXIT
      source="$record"
      [[ -f "$source" && ! -L "$source" ]] || source=/dev/null
      temp="$(legion_create_run_state_temp "$record")" || return 0
      now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      pgid="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')"
      [[ "$pgid" =~ ^[0-9]+$ ]] || pgid=0
      host="$(hostname 2>/dev/null || echo unknown)"
      if jq -cn --slurpfile prior "$source" \
          --arg schema "legion.run-state.v1" --arg run "$run_id" \
          --arg trace "$trace" --arg parent "$parent" --arg repo "$repo" \
          --arg run_dir "$run_dir" --arg wt "$worktree" --arg branch "$branch" \
          --arg model "$model" --arg sandbox "$sandbox" --arg effort "$effort" \
          --arg base "$base" --arg host "$host" --arg archetype "$archetype" \
          --arg kind "$kind" --arg phase "$phase" --arg now "$now" \
          --argjson pid "$$" --argjson pgid "$pgid" '
          def terminal:
            . == "ok" or . == "completed" or . == "failed" or . == "error"
            or . == "over_budget" or . == "cancelled" or . == "blocked"
            or . == "timed_out";
          ($prior[0] // {}) as $old
          | ($old.lifecycle.phase // "") as $old_phase
          | if ($old_phase | terminal) then
              $old
            else
              ($old.lifecycle.started_at // "") as $old_started
              | (if $old_started == "" then $now else $old_started end) as $started
              | $old
              | .schema = $schema
              | .run_id = $run
              | .trace_id = (if $trace == "" then ($old.trace_id // $run) else $trace end)
              | .parent_id = (if $parent == "" then ($old.parent_id // null) else $parent end)
              | .kind = (if $kind == "" then ($old.kind // "run") else $kind end)
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
            end
        ' > "$temp"; then
        chmod 600 "$temp" || return 0
        mv -f "$temp" "$record"
        temp=""
      fi
    )
  } 2>/dev/null || true
  return 0
}

LEGION_ADOPTED_RUN_PENDING=0
LEGION_ADOPTED_RUN_ID=""
LEGION_ADOPTED_REPO=""
LEGION_ADOPTED_RUN_DIR=""
LEGION_ADOPTED_WORKTREE=""
LEGION_ADOPTED_BRANCH=""
LEGION_ADOPTED_MODEL=""
LEGION_ADOPTED_SANDBOX=""
LEGION_ADOPTED_BASE=""
LEGION_ADOPTED_ARCHETYPE=""
LEGION_ADOPTED_EFFORT=""

legion_arm_adopted_run_guard() {
  LEGION_ADOPTED_RUN_PENDING=1
  LEGION_ADOPTED_RUN_ID="$1"
  LEGION_ADOPTED_REPO="$2"
  LEGION_ADOPTED_RUN_DIR="$3"
  LEGION_ADOPTED_WORKTREE="$4"
  LEGION_ADOPTED_BRANCH="$5"
  LEGION_ADOPTED_MODEL="$6"
  LEGION_ADOPTED_SANDBOX="$7"
  LEGION_ADOPTED_BASE="$8"
  LEGION_ADOPTED_ARCHETYPE="$9"
  LEGION_ADOPTED_EFFORT="${10:-}"
}

legion_disarm_adopted_run_guard() {
  LEGION_ADOPTED_RUN_PENDING=0
}

legion_terminalize_adopted_run_on_exit() {
  [[ "${LEGION_ADOPTED_RUN_PENDING:-0}" == "1" ]] || return 0
  LEGION_ADOPTED_RUN_PENDING=0
  legion_write_adapter_run_state failed \
    "$LEGION_ADOPTED_RUN_ID" "$LEGION_ADOPTED_REPO" "$LEGION_ADOPTED_RUN_DIR" \
    "$LEGION_ADOPTED_WORKTREE" "$LEGION_ADOPTED_BRANCH" "$LEGION_ADOPTED_MODEL" \
    "$LEGION_ADOPTED_SANDBOX" "$LEGION_ADOPTED_BASE" \
    "$LEGION_ADOPTED_ARCHETYPE" "$LEGION_ADOPTED_EFFORT"
}
