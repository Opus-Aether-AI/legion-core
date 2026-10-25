#!/usr/bin/env bash
# Terminate a harness process together with everything it spawned.
#
# Signalling only a wrapper's own pid leaves its children running: they are
# re-parented to init and keep working (and billing) with nobody waiting for
# them. Adapters therefore run their harness in the background, `wait` on it,
# and call legion_terminate_process_tree from an INT/TERM/HUP trap.

# Print PID and its descendants, parents before children.
legion_process_tree_pids() {
  local pid="$1" child
  printf '%s\n' "$pid"
  while IFS= read -r child; do
    [[ -n "$child" ]] && legion_process_tree_pids "$child"
  done < <(pgrep -P "$pid" 2>/dev/null || true)
}

# A zombie has exited; it only waits to be reaped, so it counts as gone.
legion_process_alive() {
  local state
  state="$(ps -o stat= -p "$1" 2>/dev/null)" || return 1
  state="${state//[[:space:]]/}"
  [[ -n "$state" && "$state" != Z* ]]
}

# legion_terminate_process_tree PID [GRACE_SECONDS]
# TERM the tree, give it GRACE_SECONDS (default LEGION_KILL_GRACE_SECONDS, else
# 5) to exit, then KILL whatever is still running.
legion_terminate_process_tree() {
  local root="$1" grace="${2:-${LEGION_KILL_GRACE_SECONDS:-5}}" pid ticks alive
  local -a pids=()
  [[ "$root" =~ ^[0-9]+$ ]] || return 0
  [[ "$grace" =~ ^[0-9]+$ ]] || grace=5
  # Snapshot the tree BEFORE signalling: once a parent exits, its children are
  # re-parented to init and can no longer be found from the root.
  while IFS= read -r pid; do
    [[ -n "$pid" ]] && pids+=("$pid")
  done < <(legion_process_tree_pids "$root")
  kill -TERM "${pids[@]}" 2>/dev/null || true
  ticks=$(( grace * 10 ))
  while :; do
    alive=0
    for pid in "${pids[@]}"; do
      if legion_process_alive "$pid"; then alive=1; break; fi
    done
    [[ "$alive" -eq 1 ]] || return 0
    [[ "$ticks" -gt 0 ]] || break
    sleep 0.1
    ticks=$(( ticks - 1 ))
  done
  # KILL only what is still running: a pid that exited during the grace period
  # may already belong to an unrelated process.
  for pid in "${pids[@]}"; do
    if legion_process_alive "$pid"; then kill -KILL "$pid" 2>/dev/null || true; fi
  done
}
