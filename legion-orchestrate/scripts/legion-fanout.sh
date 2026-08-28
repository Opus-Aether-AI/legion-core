#!/usr/bin/env bash
# legion-fanout — dynamic multi-model fan-out. Run many scoped slices in PARALLEL across
# executors (Codex via legion-delegate; self/Claude slices are returned for Claude
# to do inline), collect verified diffs + cost, and report. The executable core of Legion's
# dynamic orchestrator (the ultracode "decompose -> fan out -> verify -> synthesize" loop).
#
#   legion-fanout --slices <file|-> [--repo DIR] [--max-concurrency N] [--keep] [--apply]
#   legion-fanout --task <file|-> [--repo DIR] [--json]
#
# Each slice is one JSON line: {"archetype":"implement-feature","task":"..."}
#   (optionally {"model":"$(legion-route --model-ref codex_workhorse)", ...}).
# Archetypes that route to executor=self are NOT delegated — they come back with
# status "inline" for Claude to handle.
# --task is a demo/runbook compatibility mode: it expands one task document into
# implement/test/review slices before running the same fan-out engine.
#
# Portable to bash 3.2 (completion polling, no `wait -n`).
set -euo pipefail

_self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

resolve_legion_cmd() {
  local cmd="$1" fallback="$2"
  if command -v "$cmd" >/dev/null 2>&1; then
    command -v "$cmd"
    return 0
  fi
  if [[ -x "$fallback" ]]; then
    printf '%s\n' "$fallback"
    return 0
  fi
  echo "legion-fanout: required Legion command '$cmd' not found on PATH and fallback missing: $fallback" >&2
  exit 2
}

resolve_optional_legion_cmd() {
  local cmd="$1" fallback="$2"
  if command -v "$cmd" >/dev/null 2>&1; then
    command -v "$cmd"
    return 0
  fi
  if [[ -x "$fallback" ]]; then
    printf '%s\n' "$fallback"
    return 0
  fi
  return 0
}

resolve_executable_path() {
  local candidate="$1" link="" directory="" hops=0
  if [[ "$candidate" != */* ]]; then
    candidate="$(command -v "$candidate" 2>/dev/null)" || return 1
  fi
  while [[ -L "$candidate" ]]; do
    hops=$((hops + 1))
    [[ "$hops" -le 40 ]] || return 1
    directory="$(cd -P "$(dirname "$candidate")" >/dev/null 2>&1 && pwd)" \
      || return 1
    link="$(readlink "$candidate")" || return 1
    case "$link" in
      /*) candidate="$link" ;;
      *) candidate="$directory/$link" ;;
    esac
  done
  printf '%s\n' "$candidate"
}

LEGION_DELEGATE="${LEGION_DELEGATE:-$(resolve_legion_cmd legion-delegate "$_self/../../legion-router/bin/legion-delegate")}"
LEGION_ROUTE="${LEGION_ROUTE:-$(resolve_legion_cmd legion-route "$_self/../../legion-router/bin/legion-route")}"
LEGION_TELEMETRY="${LEGION_TELEMETRY:-$(resolve_optional_legion_cmd legion-trace "$_self/../../legion-observability/bin/legion-trace")}"
_run_id_lib="$_self/../../legion-router/scripts/lib/run-id.sh"
if [[ ! -f "$_run_id_lib" ]]; then
  if ! _delegate_path="$(resolve_executable_path "$LEGION_DELEGATE")"; then
    echo "legion-fanout: could not resolve legion-delegate executable" >&2
    exit 2
  fi
  _delegate_root="$(cd "$(dirname "$_delegate_path")/.." >/dev/null 2>&1 && pwd)"
  _run_id_lib="$_delegate_root/scripts/lib/run-id.sh"
fi
if [[ ! -f "$_run_id_lib" ]]; then
  echo "legion-fanout: required run-id helper not found beside legion-delegate" >&2
  exit 2
fi
# shellcheck disable=SC1090
source "$_run_id_lib"
# The harness driving this fan-out — `self` slices come back for it to run
# inline. The resolver's fallback is a compatibility default only.
FANOUT_PRIMARY="$("$LEGION_ROUTE" --primary 2>/dev/null || echo primary)"
_state_lib="$_self/../../legion-observability/scripts/lib/state.sh"
if [[ -f "$_state_lib" ]]; then
  # shellcheck disable=SC1090
  # shellcheck disable=SC1091
  source "$_state_lib"
fi

with_git_worktree_lock() {
  local repo="$1"
  shift
  if declare -F legion_with_git_worktree_lock >/dev/null 2>&1; then
    legion_with_git_worktree_lock "$repo" "$@"
  else
    "$@"
  fi
}

# Preallocate a queued run-state record so a fan-out's pending slices show as
# "queued / up-next" in the Console before they launch. The delegate adopts the id
# (--run-id) and rewrites it running->terminal. Best-effort (never block on telemetry).
write_queued_record() {
  local rid="$1" arch="$2" model="$3" task="$4"
  {
    (
    local temp="" record lock=""
    legion_validate_run_id "$rid" || return 0
    legion_prepare_private_registry "$LEGION_REGISTRY_DIR" || return 0
    record="$LEGION_REGISTRY_DIR/$rid.json"
    [[ ! -L "$record" && ( ! -e "$record" || -f "$record" ) ]] || return 0
    lock="$(legion_acquire_run_state_lock "$record")" || return 0
    trap 'rm -f "${temp:-}" 2>/dev/null || true; legion_release_run_state_lock "$lock"' EXIT
    [[ ! -L "$record" && ( ! -e "$record" || -f "$record" ) ]] || return 0
    temp="$(legion_create_run_state_temp "$record")" || return 0
    jq -cn --arg run "$rid" --arg trace "$FANOUT_TRACE_ID" --arg parent "$FANOUT_RUN_ID" \
      --arg repo "$repo" --arg arch "$arch" --arg model "$model" --arg task "$task" \
      --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
      {schema:"legion.run-state.v1", run_id:$run, trace_id:$trace, parent_id:$parent,
       kind:"run", state_version:1, repo_root:$repo, archetype:$arch, model:$model, task:$task,
       process:{pid:0,pgid:0,started_at:""},
       lifecycle:{phase:"queued", started_at:"", updated_at:$now}}' > "$temp" || return 0
    chmod 600 "$temp" || return 0
    mv -f "$temp" "$record"
    temp=""
    )
  } 2>/dev/null || true
}

init_task_ledger() {
  python3 - "$work" "$n" "$base_head" "$FANOUT_RUN_ID" "$FANOUT_TRACE_ID" <<'PY'
import datetime
import json
import os
import sys
from pathlib import Path

work = Path(sys.argv[1])
n = int(sys.argv[2])
now = datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")
dag = json.loads((work / "dag.json").read_text(encoding="utf-8"))
tasks = []
for i in range(n):
    source = json.loads((work / f"slice-{i}.in").read_text(encoding="utf-8"))
    task = dag["slices"][i]
    tasks.append({
        "index": i,
        "id": task["id"],
        "run_id": (work / f"slice-{i}.runid").read_text(encoding="utf-8").strip(),
        "archetype": str(source.get("archetype") or ""),
        "task": str(source.get("task") or ""),
        "depends_on": task["depends_on"],
        "state": "queued",
        "queued_at": now,
        "started_at": "",
        "completed_at": "",
        "base_ref": "",
        "result_status": "",
    })
payload = {
    "schema": "legion.task-ledger.v1",
    "fanout_run_id": sys.argv[4],
    "trace_id": sys.argv[5],
    "source_base_sha": sys.argv[3],
    "created_at": now,
    "updated_at": now,
    "status": "running",
    "tasks": tasks,
}
target = work / "task-ledger.json"
task_dir = work / "task-ledger.d"
task_dir.mkdir(parents=True, exist_ok=True)
for task in tasks:
    (task_dir / f"{task['index']}.json").write_text(
        json.dumps(task, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
temp = work / f".task-ledger.{os.getpid()}.tmp"
temp.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
os.replace(temp, target)
PY
}

update_task_ledger() {
  local i="$1" state="$2" result_status="${3:-}" base_ref="${4:-}" apply_status="${5:-}"
  python3 - "$work/task-ledger.d/$i.json" "$state" "$result_status" "$base_ref" "$apply_status" <<'PY'
import datetime
import json
import os
import sys
from pathlib import Path

target = Path(sys.argv[1])
state, result_status, base_ref, apply_status = sys.argv[2:6]
now = datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")
task = json.loads(target.read_text(encoding="utf-8"))
task["state"] = state
if state == "running" and not task.get("started_at"):
    task["started_at"] = now
if state in {"completed", "failed", "blocked", "inline", "integrated"}:
    task["completed_at"] = now
if result_status:
    task["result_status"] = result_status
if base_ref:
    task["base_ref"] = base_ref
if apply_status:
    task["apply_status"] = apply_status
temp = target.with_name(f".{target.name}.{os.getpid()}.tmp")
temp.write_text(json.dumps(task, indent=2, sort_keys=True) + "\n", encoding="utf-8")
os.replace(temp, target)
PY
}

finalize_task_ledger() {
  python3 - "$work/task-ledger.json" "$results" "$applied" "$apply_conflicts" "$repo" <<'PY'
import datetime
import json
import os
import subprocess
import sys
from pathlib import Path

target = Path(sys.argv[1])
results_path = Path(sys.argv[2])
now = datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")
payload = json.loads(target.read_text(encoding="utf-8"))
task_dir = target.with_name("task-ledger.d")
payload["tasks"] = [
    json.loads((task_dir / f"{index}.json").read_text(encoding="utf-8"))
    for index in range(len(payload["tasks"]))
]
results = [
    json.loads(line)
    for line in results_path.read_text(encoding="utf-8").splitlines()
    if line.strip()
]
by_id = {str(item.get("id") or ""): item for item in results}
for task in payload["tasks"]:
    result = by_id.get(task["id"], {})
    if result:
        if task.get("state") not in {"failed", "blocked"}:
            task["result_status"] = str(result.get("status") or task.get("result_status") or "")
        task["diff_path"] = str(result.get("diff_path") or "")
        task["model"] = str(result.get("model") or "")
    if task["state"] in {"queued", "running"}:
        task["state"] = "failed"
        task["completed_at"] = now
        task["result_status"] = task["result_status"] or "missing_terminal_result"
repo = sys.argv[5]
head = subprocess.run(
    ["git", "-C", repo, "rev-parse", "HEAD"],
    check=False,
    capture_output=True,
    text=True,
)
payload.update({
    "updated_at": now,
    "completed_at": now,
    "status": "failed" if any(
        task["state"] in {"failed", "blocked"} or task["result_status"] not in {"ok", "inline"}
        for task in payload["tasks"]
    ) or int(sys.argv[4]) else "completed",
    "apply": {
        "applied": int(sys.argv[3]),
        "conflicts": int(sys.argv[4]),
        "target_head_sha": head.stdout.strip() if head.returncode == 0 else "",
    },
})
temp = target.with_name(f".{target.name}.{os.getpid()}.tmp")
temp.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
os.replace(temp, target)
PY
}

task_ledger_finalized=0
finalize_task_ledger_on_exit() {
  local rc=$?
  if [[ "$task_ledger_finalized" == "0" && -f "$work/task-ledger.json" ]]; then
    set +e
    results="${results:-$work/results.jsonl}"
    [[ -f "$results" ]] || : > "$results"
    applied="${applied:-0}"
    apply_conflicts="${apply_conflicts:-0}"
    finalize_task_ledger
    task_ledger_finalized=1
  fi
  terminalize_interrupted_run_records
  cleanup_fanout_temp_files
  return "$rc"
}

terminalize_unfinished_run_record() {
  local rid="$1"
  {
    (
    local record temp="" lock="" now
    legion_validate_run_id "$rid" || return 0
    legion_prepare_private_registry "$LEGION_REGISTRY_DIR" || return 0
    record="$LEGION_REGISTRY_DIR/$rid.json"
    [[ -f "$record" && ! -L "$record" ]] || return 0
    lock="$(legion_acquire_run_state_lock "$record")" || return 0
    trap 'rm -f "${temp:-}" 2>/dev/null || true; legion_release_run_state_lock "$lock"' EXIT
    [[ -f "$record" && ! -L "$record" ]] || return 0
    jq -e --arg run "$rid" '
      .schema == "legion.run-state.v1"
      and .run_id == $run
      and ((.lifecycle.phase // "") == "queued"
           or (.lifecycle.phase // "") == "running")
    ' "$record" >/dev/null || return 0
    temp="$(legion_create_run_state_temp "$record")" || return 0
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    jq --arg now "$now" '
      .state_version = ((.state_version // 0) + 1)
      | .lifecycle.phase = "failed"
      | .lifecycle.updated_at = $now
    ' "$record" > "$temp" || return 0
    chmod 600 "$temp" || return 0
    mv -f "$temp" "$record"
    temp=""
    )
  } 2>/dev/null || true
}

terminalize_interrupted_run_records() {
  local i rid
  [[ -d "${LEGION_REGISTRY_DIR:-}" ]] || return 0

  for ((i = 0; i < n; i++)); do
    rid="$(cat "$work/slice-$i.runid" 2>/dev/null || echo "")"
    [[ -n "$rid" ]] || continue
    terminalize_unfinished_run_record "$rid"
  done
}

fanout_descendant_pids=()
fanout_descendant_pgids=()
snapshot_descendant_tree() {
  local pid="$1" child child_pids
  child_pids="$(mktemp "$work/descendant-pids.XXXXXX")"
  fanout_temp_files+=("$child_pids")
  pgrep -P "$pid" 2>/dev/null > "$child_pids" || true
  while IFS= read -r child; do
    [[ "$child" =~ ^[0-9]+$ ]] && snapshot_descendant_tree "$child"
  done < "$child_pids"
  rm -f "$child_pids"
  fanout_descendant_pids+=("$pid")
}

append_descendant_pgid() {
  local candidate="$1" existing
  for existing in "${fanout_descendant_pgids[@]+"${fanout_descendant_pgids[@]}"}"; do
    [[ "$existing" == "$candidate" ]] && return 0
  done
  fanout_descendant_pgids+=("$candidate")
}

terminate_descendant_process_groups() {
  fanout_descendant_pids=()
  fanout_descendant_pgids=()

  local pid pgid self_pgid job_pids
  job_pids="$(mktemp "$work/job-pids.XXXXXX")"
  fanout_temp_files+=("$job_pids")
  jobs -pr > "$job_pids" || true
  while IFS= read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] && snapshot_descendant_tree "$pid"
  done < "$job_pids"
  rm -f "$job_pids"

  self_pgid="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ' || true)"
  for pid in "${fanout_descendant_pids[@]+"${fanout_descendant_pids[@]}"}"; do
    pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
    if [[ "$pgid" =~ ^[0-9]+$ && "$pgid" -gt 0 && "$pgid" != "$self_pgid" ]]; then
      append_descendant_pgid "$pgid"
    fi
  done

  # Signal independent descendant groups first. The later KILL targets the
  # group again, so children forked by a TERM handler cannot escape the initial
  # process snapshot.
  for pgid in "${fanout_descendant_pgids[@]+"${fanout_descendant_pgids[@]}"}"; do
    kill -TERM "-$pgid" 2>/dev/null || true
  done
  # Background shell functions normally share this script's process group; do
  # not signal that group (it may include the caller). Terminate those members
  # individually, child-first, using the frozen descendant snapshot.
  for pid in "${fanout_descendant_pids[@]+"${fanout_descendant_pids[@]}"}"; do
    kill -TERM "$pid" 2>/dev/null || true
  done

  sleep 0.25
  for pgid in "${fanout_descendant_pgids[@]+"${fanout_descendant_pgids[@]}"}"; do
    kill -0 "-$pgid" 2>/dev/null && kill -KILL "-$pgid" 2>/dev/null || true
  done
  for pid in "${fanout_descendant_pids[@]+"${fanout_descendant_pids[@]}"}"; do
    kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
}

terminate_fanout() {
  # Ignore repeated signals until descendants and temporary worktrees are gone.
  # Restoring defaults here lets a second Ctrl-C interrupt the grace period and
  # strand subprocesses.
  trap '' INT TERM HUP
  set +e
  terminate_descendant_process_groups
  teardown_integration_base
  cleanup_slice_worktrees 1
  terminalize_interrupted_run_records
  # Make the cleanup-before-terminalization ordering explicit rather than
  # relying on the EXIT trap's implicit timing.
  finalize_task_ledger_on_exit
  exit 143
}
MAXC="${LEGION_MAX_CONCURRENCY:-4}"

slices_src="" ; routes_src="" ; task_src="" ; repo="$PWD" ; apply="" ; keep_slices=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --slices) slices_src="$2"; shift 2 ;;
    --routes) routes_src="$2"; shift 2 ;;
    --task) task_src="$2"; shift 2 ;;
    --repo) repo="$2"; shift 2 ;;
    --max-concurrency) MAXC="$2"; shift 2 ;;
    --keep) keep_slices=1; shift ;; # retain slice worktrees after apply (default: reclaim them)
    --apply) apply="1"; shift ;;
    --json) shift ;; # output is already JSON; accepted for roadmap compatibility
    -h|--help) echo "usage: legion-fanout (--slices <file|-> | --task <file|->) [--routes FILE] [--repo DIR] [--max-concurrency N] [--keep] [--apply] [--json]"; exit 0 ;;
    *) echo "legion-fanout: unknown arg '$1'" >&2; exit 2 ;;
  esac
done
[[ "$MAXC" =~ ^[1-9][0-9]*$ ]] || { echo "legion-fanout: --max-concurrency must be a positive integer" >&2; exit 2; }
if [[ -z "$slices_src" && -n "$task_src" ]]; then
  task_slices="$(mktemp)"
  if [[ "$task_src" == "-" ]]; then
    task_body="$(cat)"
  else
    task_body="$(cat "$task_src")"
  fi
  jq -cn --arg t "$task_body" \
    '{archetype:"implement-feature",task:$t}' > "$task_slices"
  jq -cn --arg t "$task_body" \
    '{archetype:"write-tests",task:("Write focused tests for: " + $t)}' >> "$task_slices"
  jq -cn --arg t "$task_body" \
    '{archetype:"final-review",task:("Review implementation, tests, and risk for: " + $t)}' >> "$task_slices"
  slices_src="$task_slices"
fi
[[ -n "$slices_src" ]] || { echo "legion-fanout: --slices or --task required" >&2; exit 2; }
[[ "$slices_src" == "-" ]] && slices_src=/dev/stdin
repo="$(cd "$repo" && pwd)"
if declare -F legion_resolve_state >/dev/null 2>&1; then
  legion_resolve_state "$repo"
else
  export LEGION_STATE_ROOT="${LEGION_STATE_ROOT:-$HOME/.legion/projects/default}"
  export LEGION_REGISTRY_DIR="${LEGION_REGISTRY_DIR:-$LEGION_STATE_ROOT/registry}"
fi

work="$repo/.legion/fanout/$(date -u +%Y%m%d-%H%M%S)-$$"
mkdir -p "$work"
fanout_temp_files=()

cleanup_fanout_temp_files() {
  local temp_file
  for temp_file in "${fanout_temp_files[@]+"${fanout_temp_files[@]}"}"; do
    rm -f "$temp_file" 2>/dev/null || true
  done
  fanout_temp_files=()
}

# Trace context: one trace per fan-out so every delegated slice's span hangs under
# a single OTel tree (rooted at the fan-out's own span below). Honor an inherited
# LEGION_TRACE_ID so a nested fan-out joins its caller's trace. Each delegate is a
# child of FANOUT_RUN_ID via the exported LEGION_PARENT_ID.
FANOUT_RUN_ID="fanout-$(date -u +%Y%m%d-%H%M%S)-$$"
FANOUT_TRACE_ID="${LEGION_TRACE_ID:-$FANOUT_RUN_ID}"
FANOUT_INHERITED_PARENT="${LEGION_PARENT_ID:-}"   # non-empty only for a nested fan-out
export LEGION_TRACE_ID="$FANOUT_TRACE_ID"
export LEGION_PARENT_ID="$FANOUT_RUN_ID"

# Read slices into numbered files (portable; tolerates blank lines). Run-state
# identities are not preallocated until the complete dependency graph validates.
n=0
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  printf '%s\n' "$line" > "$work/slice-$n.in"
  n=$((n + 1))
done < "$slices_src"
[[ "$n" -gt 0 ]] || { echo "legion-fanout: no slices" >&2; exit 2; }
if [[ -n "$routes_src" ]]; then
  [[ -f "$routes_src" ]] || { echo "legion-fanout: routes file not found: $routes_src" >&2; exit 2; }
  [[ "$(jq -r '.routes | length' "$routes_src" 2>/dev/null || echo invalid)" == "$n" ]] \
    || { echo "legion-fanout: routes file must contain one decision per slice" >&2; exit 2; }
  for ((i = 0; i < n; i++)); do
    jq -e --argjson i "$i" --slurpfile slice "$work/slice-$i.in" \
      '.routes[$i].slice == $slice[0] and (.routes[$i].route | type == "object")' \
      "$routes_src" >/dev/null \
      || { echo "legion-fanout: routes file does not match slice $i" >&2; exit 2; }
  done
fi

if ! python3 - "$work" "$n" > "$work/dag.json" <<'PY'
import json
import sys
from pathlib import Path

work = Path(sys.argv[1])
n = int(sys.argv[2])
slices = []
ids = {}
errors = []

for i in range(n):
    try:
        item = json.loads((work / f"slice-{i}.in").read_text(encoding="utf-8"))
    except Exception as exc:
        errors.append(f"slice {i}: invalid JSON: {exc}")
        item = {}
    if not isinstance(item, dict):
        errors.append(f"slice {i}: expected JSON object")
        item = {}
    sid = str(item.get("id") or f"s{i}").strip() or f"s{i}"
    if sid in ids:
        errors.append(f"duplicate slice id: {sid}")
    ids[sid] = i
    raw_deps = item.get("depends_on") or []
    if isinstance(raw_deps, str):
        raw_deps = [raw_deps]
    if not isinstance(raw_deps, list):
        errors.append(f"slice {sid}: depends_on must be an array")
        raw_deps = []
    deps = []
    for dep in raw_deps:
        dep = str(dep).strip()
        if dep:
            deps.append(dep)
    slices.append({"index": i, "id": sid, "depends_on": deps})

for item in slices:
    for dep in item["depends_on"]:
        if dep not in ids:
            errors.append(f"slice {item['id']}: unknown dependency {dep}")

visiting = set()
visited = set()

def visit(sid, stack):
    if sid in visited:
        return
    if sid in visiting:
        errors.append("dependency cycle: " + " -> ".join(stack + [sid]))
        return
    visiting.add(sid)
    for dep in slices[ids[sid]]["depends_on"]:
        if dep in ids:
            visit(dep, stack + [sid])
    visiting.remove(sid)
    visited.add(sid)

for item in slices:
    visit(item["id"], [])

if errors:
    print(json.dumps({"errors": errors}))
    sys.exit(1)

dependents = [[] for _ in slices]
for item in slices:
    dependency_indexes = [ids[dep] for dep in item["depends_on"]]
    (work / f"slice-{item['index']}.deps").write_text(
        "".join(f"{index}\n" for index in dependency_indexes), encoding="utf-8"
    )
    (work / f"slice-{item['index']}.dep-count").write_text(
        str(len(dependency_indexes)), encoding="utf-8"
    )
    for dependency_index in dependency_indexes:
        dependents[dependency_index].append(item["index"])
for index, child_indexes in enumerate(dependents):
    (work / f"slice-{index}.dependents").write_text(
        "".join(f"{child_index}\n" for child_index in child_indexes),
        encoding="utf-8",
    )

print(json.dumps({
    "slices": slices,
    "index_by_id": ids,
    "has_dependencies": any(item["depends_on"] for item in slices),
}, indent=2, sort_keys=True))
PY
then
  jq -c '{status:"error",stage:"dag",error:(.errors | join("; "))}' "$work/dag.json" 2>/dev/null \
    || echo '{"status":"error","stage":"dag","error":"invalid dependency graph"}'
  exit 0
fi

# With a valid graph, preallocate every slice identity before execution so later
# batches are visible as queued. Install the EXIT guard first so any subsequent
# setup failure terminalizes records already written by a partial loop.
trap finalize_task_ledger_on_exit EXIT
for ((i = 0; i < n; i++)); do
  line="$(cat "$work/slice-$i.in")"
  s_arch="$(jq -r '.archetype // ""' <<<"$line" 2>/dev/null || echo "")"
  s_model="$(jq -r '.model // ""' <<<"$line" 2>/dev/null || echo "")"
  s_task="$(jq -r '.task // ""' <<<"$line" 2>/dev/null || echo "")"
  rid="$(legion_new_run_id)-s$i"
  printf '%s\n' "$rid" > "$work/slice-$i.runid"
  [[ -n "$s_task" ]] && write_queued_record "$rid" "$s_arch" "$s_model" "$s_task"
done

launch_slice() {
  local i="$1" base_ref="${2:-HEAD}" base_sha="" line arch model task ex rid
  line="$(cat "$work/slice-$i.in")"
  rid="$(cat "$work/slice-$i.runid" 2>/dev/null || echo "")"
  arch="$(jq -r '.archetype // ""' <<<"$line" 2>/dev/null || echo "")"
  model="$(jq -r '.model // ""' <<<"$line" 2>/dev/null || echo "")"
  task="$(jq -r '.task // ""' <<<"$line" 2>/dev/null || echo "")"
  base_sha="$(git -C "$repo" rev-parse "$base_ref^{commit}" 2>/dev/null || true)"
  if [[ -z "$base_sha" ]]; then
    jq -cn --arg ref "$base_ref" \
      '{status:"error",stage:"base",error:("could not resolve immutable base " + $ref)}' \
      > "$work/slice-$i.out"
    update_task_ledger "$i" "failed" "error" ""
    return
  fi
  base_ref="$base_sha"
  update_task_ledger "$i" "running" "" "$base_ref"
  if [[ -z "$task" ]]; then
    [[ -n "$rid" ]] && rm -f "$LEGION_REGISTRY_DIR/$rid.json" 2>/dev/null
    echo '{"status":"error","error":"empty task"}' > "$work/slice-$i.out"
    update_task_ledger "$i" "failed" "error" "$base_ref"
    return
  fi
  # Self routes and nested routes from an already-delegated executor are
  # returned inline. Top-level same-harness subagents remain valid.
  if [[ -n "$arch" ]]; then
    local route_out route_err route_rc route_error route_model route_sandbox route_effort route_fallback
    route_out="$work/slice-$i.route.json"
    route_err="$work/slice-$i.route.err"
    route_rc=0
    if [[ -n "$routes_src" ]]; then
      jq -c --argjson i "$i" '.routes[$i].route' "$routes_src" > "$route_out" 2> "$route_err" \
        || route_rc=$?
    else
      set +e
      "$LEGION_ROUTE" "$arch" --preflight > "$route_out" 2> "$route_err"
      route_rc=$?
      set -e
    fi
    if [[ "$route_rc" -ne 0 ]]; then
      route_error="$(tr '\n' ' ' < "$route_err")"
      jq -cn --arg error "$route_error" \
        '{resolved:false,error:$error}' > "$route_out"
      [[ -n "$rid" ]] && rm -f "$LEGION_REGISTRY_DIR/$rid.json" 2>/dev/null
      jq -cn --arg a "$arch" --arg t "$task" --arg e "$route_error" \
        '{status:"error",stage:"route",archetype:$a,task:$t,error:$e}' > "$work/slice-$i.out"
      update_task_ledger "$i" "failed" "error" "$base_ref"
      return
    fi
    if ! jq -e 'type == "object"' "$route_out" >/dev/null 2>&1; then
      [[ -n "$rid" ]] && rm -f "$LEGION_REGISTRY_DIR/$rid.json" 2>/dev/null
      jq -cn --arg a "$arch" --arg t "$task" --arg e "$(cat "$route_out" 2>/dev/null)" \
        '{status:"error",stage:"route",archetype:$a,task:$t,error:("invalid route JSON: " + $e)}' > "$work/slice-$i.out"
      update_task_ledger "$i" "failed" "error" "$base_ref"
      return
    fi
    ex="$(jq -r '.effective_executor // .executor // ""' "$route_out" 2>/dev/null || echo "")"
    if [[ "$ex" == "self" ]]; then
      local route_reason
      route_reason="$(jq -r '.preflight.reason // "inline-self-route"' "$route_out" 2>/dev/null || echo inline-self-route)"
      [[ -n "$rid" ]] && rm -f "$LEGION_REGISTRY_DIR/$rid.json" 2>/dev/null
      jq -cn --arg a "$arch" --arg t "$task" --arg p "$FANOUT_PRIMARY" \
        --arg reason "$route_reason" \
        '{status:"inline",archetype:$a,task:$t,route_reason:$reason,
          note:($p + " (primary) does this inline")}' > "$work/slice-$i.out"
      update_task_ledger "$i" "inline" "inline" "$base_ref"
      return
    fi
    route_model="$(jq -r '.model // ""' "$route_out" 2>/dev/null || echo "")"
    route_sandbox="$(jq -r '.sandbox // ""' "$route_out" 2>/dev/null || echo "")"
    route_effort="$(jq -r '.reasoning_effort // ""' "$route_out" 2>/dev/null || echo "")"
    route_fallback="$(jq -r '(.fallback // []) | join(",")' "$route_out" 2>/dev/null || echo "")"
    [[ -n "$model" ]] || model="$route_model"
    if [[ "$model" != "$route_model" ]]; then
      jq -c --arg model "$model" '.model = $model' "$route_out" > "$route_out.tmp"
      mv "$route_out.tmp" "$route_out"
    fi
  elif [[ -n "$model" ]]; then
    ex="codex"
    route_out="$work/slice-$i.route.json"
    jq -cn --arg model "$model" \
      '{executor:"codex",effective_executor:"codex",model:$model,resolved:true}' \
      > "$route_out"
  fi
  local args delegate_rc=0
  # NOTE: never forward --apply here. Parallel `git apply` to one worktree races/corrupts the
  # index; apply happens SEQUENTIALLY after the wait barrier (below). --keep so diffs survive.
  args=(run --repo "$repo" --quiet --keep)
  [[ -n "$rid" ]]   && args+=(--run-id "$rid")    # adopt the preallocated queued id
  [[ -n "$base_ref" ]] && args+=(--base "$base_ref")
  [[ -n "$arch" ]]  && args+=(--archetype "$arch")
  [[ -n "${ex:-}" ]] && args+=(--executor "$ex")
  [[ -n "$model" ]] && args+=(--model "$model")
  [[ -n "${route_sandbox:-}" ]] && args+=(--sandbox "$route_sandbox")
  [[ -n "${route_effort:-}" ]] && args+=(--reasoning-effort "$route_effort")
  args+=(--task "$task")
  LEGION_ROUTE_PRE_RESOLVED="${arch:+1}" \
    LEGION_RESOLVED_EXECUTOR="${ex:-}" \
    LEGION_RESOLVED_FALLBACK="${route_fallback:-}" \
    "$LEGION_DELEGATE" "${args[@]}" > "$work/slice-$i.out" 2> "$work/slice-$i.err" \
    || delegate_rc=$?
  if [[ ! -s "$work/slice-$i.out" ]]; then
    jq -cn --argjson exit_code "$delegate_rc" --arg error_log "$work/slice-$i.err" \
      '{status:"error",stage:"delegate",error:"delegate produced no structured output",
        delegate_exit:$exit_code,error_log:$error_log}' > "$work/slice-$i.out"
  fi
  local result_status ledger_state
  result_status="$(jq -r '.status // "error"' "$work/slice-$i.out" 2>/dev/null || echo error)"
  ledger_state="failed"
  [[ "$result_status" == "ok" ]] && ledger_state="completed"
  [[ "$ledger_state" == "completed" || -z "$rid" ]] || terminalize_unfinished_run_record "$rid"
  update_task_ledger "$i" "$ledger_state" "$result_status" "$base_ref"
}

has_dependencies="$(jq -r '.has_dependencies' "$work/dag.json")"
base_head="$(git -C "$repo" rev-parse HEAD)"
init_task_ledger
integration_branch=""
integration_wt=""
integrated=0
integration_conflicts=0
integrated_tasks=()

setup_integration_base() {
  [[ -n "$integration_branch" ]] && return 0
  integration_branch="legion/fanout-${FANOUT_RUN_ID}"
  integration_wt="$work/integration"
  git -C "$repo" branch "$integration_branch" "$base_head"
  with_git_worktree_lock "$repo" \
    git -C "$repo" worktree add -q "$integration_wt" "$integration_branch"
}

teardown_integration_base() {
  local temporary_refs
  if [[ -n "$integration_wt" && -d "$integration_wt" ]]; then
    with_git_worktree_lock "$repo" \
      git -C "$repo" worktree remove --force "$integration_wt" >/dev/null 2>&1 \
      || rm -rf "$integration_wt"
  fi
  with_git_worktree_lock "$repo" \
    git -C "$repo" worktree prune >/dev/null 2>&1 || true
  [[ -n "$integration_branch" ]] && git -C "$repo" branch -D "$integration_branch" >/dev/null 2>&1 || true
  temporary_refs="$(mktemp "$work/temporary-refs.XXXXXX")"
  fanout_temp_files+=("$temporary_refs")
  (git -C "$repo" for-each-ref --format='%(refname)' "refs/legion/fanout/$FANOUT_RUN_ID/" \
    2>/dev/null || true) > "$temporary_refs"
  while IFS= read -r temporary_ref; do
    [[ -n "$temporary_ref" ]] && git -C "$repo" update-ref -d "$temporary_ref" >/dev/null 2>&1 || true
  done < "$temporary_refs"
  rm -f "$temporary_refs"
}

# Slices are delegated with --keep so their diffs survive until the sequential
# apply barrier. Once apply is done the worktrees are disposable (the diffs live
# under .legion/runs/<rid>), so reclaim exactly this fan-out's slice worktrees —
# not a blanket `cleanup --all`, which would disturb concurrent runs. --keep on
# the fan-out retains them for inspection.
cleanup_slice_worktrees() {
  local force="${1:-0}"
  [[ "$keep_slices" == "1" && "$force" != "1" ]] && return 0
  local i rid swt branch
  local -a slice_branches=()
  for ((i = 0; i < n; i++)); do    # slices are 0-indexed (slice-0 … slice-(n-1))
    rid="$(cat "$work/slice-$i.runid" 2>/dev/null || echo "")"
    [[ -n "$rid" ]] || continue
    swt="$repo/.legion/worktrees/$rid"
    slice_branches+=("legion/delegate-$rid")
    if [[ -d "$swt" ]]; then
      with_git_worktree_lock "$repo" \
        git -C "$repo" worktree remove --force "$swt" >/dev/null 2>&1 || rm -rf "$swt"
    fi
  done
  # A fallback rm leaves stale worktree administration behind. Prune once after
  # all removals so every branch is free before deletion without an O(n) global
  # repository scan for every slice.
  with_git_worktree_lock "$repo" \
    git -C "$repo" worktree prune >/dev/null 2>&1 || true
  for branch in "${slice_branches[@]+"${slice_branches[@]}"}"; do
    git -C "$repo" branch -D "$branch" >/dev/null 2>&1 || true
  done
}

# No delegated children or integration worktrees exist before this point, so
# install signal cleanup only after every cleanup helper is defined.
trap terminate_fanout INT TERM HUP

mark_blocked() {
  local i="$1" blocked_by_json="$2"
  jq -cn --argjson blocked_by "$blocked_by_json" \
    '{status:"blocked",stage:"dependency",blocked_by:$blocked_by,error:"blocked by failed prerequisite"}' \
    > "$work/slice-$i.out"
  local rid
  rid="$(cat "$work/slice-$i.runid" 2>/dev/null || echo "")"
  [[ -n "$rid" ]] && rm -f "$LEGION_REGISTRY_DIR/$rid.json" 2>/dev/null || true
  update_task_ledger "$i" "blocked" "blocked" ""
}

ref_root="refs/legion/fanout/$FANOUT_RUN_ID"
running=0
completed=0
reaped=0
ready_head=0
ready_queue=()
running_indices=()
slice_states=()
remaining_deps=()

materialize_slice_commit() {
  local i="$1" base_ref result dpath commit_ref
  base_ref="$(cat "$work/slice-$i.base")"
  result="$(cat "$work/slice-$i.out" 2>/dev/null || echo '{}')"
  dpath="$(jq -r '.diff_path // empty' <<<"$result" 2>/dev/null || echo "")"

  git -C "$integration_wt" reset --hard "$base_ref" >/dev/null
  git -C "$integration_wt" clean -fd >/dev/null
  if [[ -z "$dpath" || ! -s "$dpath" ]]; then
    commit_ref="$base_ref"
    update_task_ledger "$i" "completed" "ok" "$base_ref" "no_changes"
  elif git -C "$integration_wt" apply --check "$dpath" 2>/dev/null; then
    git -C "$integration_wt" apply "$dpath"
    git -C "$integration_wt" add -A
    git -C "$integration_wt" -c user.email=legion@local -c user.name=Legion \
      -c core.hooksPath=/dev/null commit -qm "legion fanout slice $i"
    commit_ref="$(git -C "$integration_wt" rev-parse HEAD)"
    update_task_ledger "$i" "completed" "ok" "$base_ref" "materialized"
  else
    integration_conflicts=$((integration_conflicts + 1))
    jq -c '. + {status:"error",stage:"dependency-materialize",error:"diff did not apply cleanly to its declared prerequisite base"}' \
      "$work/slice-$i.out" > "$work/slice-$i.out.tmp" \
      && mv "$work/slice-$i.out.tmp" "$work/slice-$i.out"
    update_task_ledger "$i" "failed" "error" "$base_ref" "conflict"
    return 1
  fi
  printf '%s\n' "$commit_ref" > "$work/slice-$i.commit"
  git -C "$repo" update-ref "$ref_root/slice-$i" "$commit_ref"
}

compose_dependency_base() {
  local i="$1" dep_count dep_i dep_commit composed_ref
  dep_count="$(cat "$work/slice-$i.dep-count")"
  if [[ "$dep_count" -eq 0 ]]; then
    printf '%s\n' "$base_head"
    return 0
  fi
  if [[ "$dep_count" -eq 1 ]]; then
    dep_i="$(head -n1 "$work/slice-$i.deps")"
    cat "$work/slice-$dep_i.commit"
    return 0
  fi

  git -C "$integration_wt" reset --hard "$base_head" >/dev/null
  git -C "$integration_wt" clean -fd >/dev/null
  while IFS= read -r dep_i; do
    [[ -n "$dep_i" ]] || continue
    dep_commit="$(cat "$work/slice-$dep_i.commit")"
    if ! git -C "$integration_wt" -c user.email=legion@local -c user.name=Legion \
      -c core.hooksPath=/dev/null merge --no-edit --no-ff "$dep_commit" >/dev/null 2>&1; then
      git -C "$integration_wt" merge --abort >/dev/null 2>&1 || true
      git -C "$integration_wt" reset --hard "$base_head" >/dev/null 2>&1 || true
      return 1
    fi
  done < "$work/slice-$i.deps"
  composed_ref="$(git -C "$integration_wt" rev-parse HEAD)"
  git -C "$repo" update-ref "$ref_root/base-$i" "$composed_ref"
  printf '%s\n' "$composed_ref"
}

mark_dependency_base_error() {
  local i="$1"
  jq -cn '{status:"error",stage:"dependency-base",error:"declared prerequisite changes could not be composed cleanly"}' \
    > "$work/slice-$i.out"
  update_task_ledger "$i" "failed" "error" "" "conflict"
}

launch_slice_async() {
  local i="$1" base_ref="$2"
  printf '%s\n' "$base_ref" > "$work/slice-$i.base"
  (
    trap ': > "$work/slice-$i.done"' EXIT
    launch_slice "$i" "$base_ref"
  ) &
  printf '%s\n' "$!" > "$work/slice-$i.pid"
  : > "$work/slice-$i.scheduled"
  slice_states[i]="running"
  running_indices+=("$i")
  running=$((running + 1))
}

blocked_ids_json() {
  python3 - "$work/dag.json" "$1" <<'PY'
import json
import sys

dag = json.load(open(sys.argv[1], encoding="utf-8"))
with open(sys.argv[2], encoding="utf-8") as source:
    indexes = sorted({int(line) for line in source if line.strip()})
print(json.dumps([dag["slices"][index]["id"] for index in indexes]))
PY
}

propagate_completion() {
  local i="$1" succeeded="$2" child blocked_json
  [[ "$has_dependencies" == "true" ]] || return 0
  while IFS= read -r child; do
    [[ -n "$child" ]] || continue
    remaining_deps[child]=$((remaining_deps[child] - 1))
    if [[ "$succeeded" != "1" ]]; then
      printf '%s\n' "$i" >> "$work/slice-$child.blocked-indices"
    fi
    if [[ "${remaining_deps[$child]}" -eq 0 ]]; then
      if [[ -s "$work/slice-$child.blocked-indices" ]]; then
        blocked_json="$(blocked_ids_json "$work/slice-$child.blocked-indices")"
        mark_blocked "$child" "$blocked_json"
        finish_slice "$child" 0
      else
        ready_queue+=("$child")
      fi
    fi
  done < "$work/slice-$i.dependents"
}

finish_slice() {
  local i="$1" succeeded="$2"
  : > "$work/slice-$i.processed"
  slice_states[i]="processed"
  completed=$((completed + 1))
  propagate_completion "$i" "$succeeded"
}

reap_completed_slices() {
  local i pid result_status succeeded
  local -a still_running=()
  reaped=0
  for i in "${running_indices[@]+"${running_indices[@]}"}"; do
    if [[ ! -f "$work/slice-$i.done" ]]; then
      still_running+=("$i")
      continue
    fi
    pid="$(cat "$work/slice-$i.pid")"
    wait "$pid" 2>/dev/null || true
    running=$((running - 1))
    reaped=1
    succeeded=0
    result_status="$(jq -r '.status // "error"' "$work/slice-$i.out" 2>/dev/null || echo error)"
    if [[ "$result_status" == "ok" ]]; then
      if [[ "$has_dependencies" != "true" ]] || materialize_slice_commit "$i"; then
        succeeded=1
      fi
    fi
    finish_slice "$i" "$succeeded"
  done
  running_indices=("${still_running[@]+"${still_running[@]}"}")
}

build_final_integration() {
  local i result_status dpath commit_ref before_merge
  git -C "$integration_wt" reset --hard "$base_head" >/dev/null
  git -C "$integration_wt" clean -fd >/dev/null
  for ((i = 0; i < n; i++)); do
    result_status="$(jq -r '.status // "error"' "$work/slice-$i.out" 2>/dev/null || echo error)"
    [[ "$result_status" == "ok" ]] || continue
    dpath="$(jq -r '.diff_path // empty' "$work/slice-$i.out" 2>/dev/null || echo "")"
    if [[ -z "$dpath" || ! -s "$dpath" ]]; then
      update_task_ledger "$i" "completed" "ok" "" "no_changes"
      continue
    fi
    commit_ref="$(cat "$work/slice-$i.commit")"
    before_merge="$(git -C "$integration_wt" rev-parse HEAD)"
    if git -C "$integration_wt" -c user.email=legion@local -c user.name=Legion \
      -c core.hooksPath=/dev/null merge --no-edit --no-ff "$commit_ref" >/dev/null 2>&1; then
      integrated=$((integrated + 1))
      integrated_tasks+=("$i")
      update_task_ledger "$i" "integrated" "ok" "" "staged"
    else
      integration_conflicts=$((integration_conflicts + 1))
      git -C "$integration_wt" merge --abort >/dev/null 2>&1 || true
      git -C "$integration_wt" reset --hard "$before_merge" >/dev/null 2>&1 || true
      jq -c '. + {status:"error",stage:"integration-merge",error:"prerequisite-scoped result conflicted with another completed slice"}' \
        "$work/slice-$i.out" > "$work/slice-$i.out.tmp" \
        && mv "$work/slice-$i.out.tmp" "$work/slice-$i.out"
      update_task_ledger "$i" "failed" "error" "" "conflict"
    fi
  done
}

for ((i = 0; i < n; i++)); do
  slice_states[i]="queued"
  remaining_deps[i]="$(cat "$work/slice-$i.dep-count")"
  : > "$work/slice-$i.blocked-indices"
  if [[ "$has_dependencies" == "true" && "${remaining_deps[$i]}" -eq 0 ]]; then
    ready_queue+=("$i")
  fi
done

if [[ "$has_dependencies" != "true" ]]; then
  next=0
  while [[ "$completed" -lt "$n" ]]; do
    while [[ "$next" -lt "$n" && "$running" -lt "$MAXC" ]]; do
      launch_slice_async "$next" "$base_head"
      next=$((next + 1))
    done
    reap_completed_slices
    [[ "$completed" -ge "$n" || "$reaped" -eq 1 ]] || sleep 0.02
  done
else
  setup_integration_base
  while [[ "$completed" -lt "$n" ]]; do
    progress=0
    reap_completed_slices
    [[ "$reaped" -eq 0 ]] || progress=1
    while [[ "$running" -lt "$MAXC" && "$ready_head" -lt "${#ready_queue[@]}" ]]; do
      i="${ready_queue[$ready_head]}"
      ready_head=$((ready_head + 1))
      [[ "${slice_states[$i]}" == "queued" ]] || continue
      if base_ref="$(compose_dependency_base "$i")"; then
        launch_slice_async "$i" "$base_ref"
      else
        mark_dependency_base_error "$i"
        finish_slice "$i" 0
      fi
      progress=1
    done

    if [[ "$progress" -eq 0 && "$running" -eq 0 ]]; then
      for ((i = 0; i < n; i++)); do
        if [[ "${slice_states[$i]}" == "queued" ]]; then
          mark_blocked "$i" '[]'
          finish_slice "$i" 0
        fi
      done
      break
    fi
    [[ "$progress" -eq 1 ]] || sleep 0.02
  done
  build_final_integration
fi

routes_path="$work/routes.json"
: > "$work/routes.jsonl"
for ((i = 0; i < n; i++)); do
  route_input="$(mktemp "$work/slice-$i.route.XXXXXX")"
  fanout_temp_files+=("$route_input")
  (if [[ -s "$work/slice-$i.route.json" ]]; then
    cat "$work/slice-$i.route.json"
  else
    printf '{}\n'
  fi) > "$route_input"
  jq -cn \
    --slurpfile slice "$work/slice-$i.in" \
    --slurpfile route "$route_input" \
    '{slice:$slice[0],route:$route[0]}' >> "$work/routes.jsonl"
  rm -f "$route_input"
done
jq -s '{routes:.}' "$work/routes.jsonl" > "$routes_path"

# Collect one JSON result per slice.
results="$work/results.jsonl"
: > "$results"
i=0
while [[ $i -lt $n ]]; do
  sid="$(jq -r --argjson i "$i" '.slices[$i].id' "$work/dag.json")"
  deps_json="$(jq -c --argjson i "$i" '.slices[$i].depends_on' "$work/dag.json")"
  if [[ -s "$work/slice-$i.out" ]]; then
    head -n1 "$work/slice-$i.out" \
      | jq -c --arg id "$sid" --argjson depends_on "$deps_json" \
        'if type == "object" then . + {id:$id, depends_on:$depends_on} else {status:"error", id:$id, depends_on:$depends_on, error:"non-object result"} end' \
      >> "$results"
  else
    jq -cn --arg id "$sid" --argjson depends_on "$deps_json" \
      --arg error_log "$work/slice-$i.err" \
      '{status:"error",id:$id,depends_on:$depends_on,error:"no output",
        error_log:$error_log}' >> "$results"
  fi
  i=$((i + 1))
done

# SEQUENTIAL apply (never concurrent — git apply isn't concurrency-safe). Slice diffs may
# conflict with each other (parallel codegen touching the same file); report cleanly so Opus
# resolves. Only when --apply was requested.
applied=0; apply_conflicts=0
if [[ -n "$apply" && "$has_dependencies" == "true" ]]; then
  integration_patch="$work/integration.patch"
  git -C "$repo" diff --binary "$base_head" "$integration_branch" > "$integration_patch"
  if [[ -s "$integration_patch" ]]; then
    if git -C "$repo" apply --check "$integration_patch" 2>/dev/null; then
      git -C "$repo" apply "$integration_patch" && applied="$integrated"
      for i in "${integrated_tasks[@]}"; do
        update_task_ledger "$i" "integrated" "ok" "" "applied"
      done
    else
      apply_conflicts=$((apply_conflicts + 1))
      for i in "${integrated_tasks[@]}"; do
        update_task_ledger "$i" "failed" "error" "" "conflict"
      done
    fi
  fi
elif [[ -n "$apply" ]]; then
  i=0
  while [[ "$i" -lt "$n" ]]; do
    result_status="$(jq -r '.status // "error"' "$work/slice-$i.out" 2>/dev/null || echo error)"
    dpath="$(jq -r '.diff_path // empty' "$work/slice-$i.out" 2>/dev/null || true)"
    if [[ "$result_status" != "ok" ]]; then
      i=$((i + 1))
      continue
    fi
    if [[ -z "$dpath" || ! -s "$dpath" ]]; then
      update_task_ledger "$i" "completed" "ok" "" "no_changes"
    elif git -C "$repo" apply --check "$dpath" 2>/dev/null; then
      git -C "$repo" apply "$dpath"
      applied=$((applied + 1))
      update_task_ledger "$i" "integrated" "ok" "" "applied"
    else
      apply_conflicts=$((apply_conflicts + 1))
      update_task_ledger "$i" "failed" "error" "" "conflict"
    fi
    i=$((i + 1))
  done
fi
if [[ "$has_dependencies" == "true" ]]; then
  apply_conflicts=$((apply_conflicts + integration_conflicts))
  teardown_integration_base
fi
cleanup_slice_worktrees
finalize_task_ledger
task_ledger_finalized=1

# Root span for the fan-out itself, so the delegate spans form a tree under it.
# Best-effort: telemetry is observability, never block the run on it.
if [[ -x "$LEGION_TELEMETRY" ]]; then
  total_cost="$(jq -s '[.[].cost_usd // 0] | add' "$results" 2>/dev/null || echo 0)"
  root_status="$(jq -rs 'if any(.[]; (.status != "ok" and .status != "inline")) then "failed" else "ok" end' "$results" 2>/dev/null || echo ok)"
  "$LEGION_TELEMETRY" emit \
    --executor orchestrator --model legion-fanout --status "${root_status:-ok}" \
    --run-id "$FANOUT_RUN_ID" --trace-id "$FANOUT_TRACE_ID" \
    --parent-id "$FANOUT_INHERITED_PARENT" \
    --cost "${total_cost:-0}" --task "fanout: $n slices" >/dev/null 2>&1 || true
fi

jq -s --argjson applied "$applied" --argjson conflicts "$apply_conflicts" \
  --arg task_ledger_path "$work/task-ledger.json" --arg routes_path "$routes_path" '{
  slices: length,
  ok:     ([.[] | select(.status == "ok")]     | length),
  inline: ([.[] | select(.status == "inline")] | length),
  failed: ([.[] | select(.status != "ok" and .status != "inline")] | length),
  total_cost_usd: ([.[].cost_usd // 0] | add),
  applied: $applied,
  apply_conflicts: $conflicts,
  task_ledger_path: $task_ledger_path,
  routes_path: $routes_path,
  by_model: (reduce .[] as $r ({}; .[($r.model // ($r.status // "unknown"))] += 1)),
  results: .
}' "$results"
