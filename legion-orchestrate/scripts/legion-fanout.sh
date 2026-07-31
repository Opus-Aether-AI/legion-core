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
# Portable to bash 3.2 (batch-wait concurrency, no `wait -n`).
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

LEGION_DELEGATE="${LEGION_DELEGATE:-$(resolve_legion_cmd legion-delegate "$_self/../../legion-router/bin/legion-delegate")}"
LEGION_ROUTE="${LEGION_ROUTE:-$(resolve_legion_cmd legion-route "$_self/../../legion-router/bin/legion-route")}"
LEGION_TELEMETRY="${LEGION_TELEMETRY:-$(resolve_optional_legion_cmd legion-trace "$_self/../../legion-observability/bin/legion-trace")}"
# The harness driving this fan-out (Claude by default) — `self` slices come back
# for it to run inline. Harness-generic: not hardcoded to Opus.
FANOUT_PRIMARY="$("$LEGION_ROUTE" --primary 2>/dev/null || echo primary)"
_state_lib="$_self/../../legion-observability/scripts/lib/state.sh"
if [[ -f "$_state_lib" ]]; then
  # shellcheck disable=SC1090
  # shellcheck disable=SC1091
  source "$_state_lib"
fi

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
  [[ "$task_ledger_finalized" == "0" && -f "$work/task-ledger.json" ]] || return "$rc"
  set +e
  results="${results:-$work/results.jsonl}"
  [[ -f "$results" ]] || : > "$results"
  applied="${applied:-0}"
  apply_conflicts="${apply_conflicts:-0}"
  finalize_task_ledger
  task_ledger_finalized=1
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
  local pid="$1" child
  while IFS= read -r child; do
    [[ "$child" =~ ^[0-9]+$ ]] && snapshot_descendant_tree "$child"
  done < <(pgrep -P "$pid" 2>/dev/null || true)
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

  local pid pgid self_pgid
  while IFS= read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] && snapshot_descendant_tree "$pid"
  done < <(jobs -pr)

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
  trap - INT TERM HUP
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

slices_src="" ; task_src="" ; repo="$PWD" ; apply="" ; keep_slices=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --slices) slices_src="$2"; shift 2 ;;
    --task) task_src="$2"; shift 2 ;;
    --repo) repo="$2"; shift 2 ;;
    --max-concurrency) MAXC="$2"; shift 2 ;;
    --keep) keep_slices=1; shift ;; # retain slice worktrees after apply (default: reclaim them)
    --apply) apply="1"; shift ;;
    --json) shift ;; # output is already JSON; accepted for roadmap compatibility
    -h|--help) echo "usage: legion-fanout (--slices <file|-> | --task <file|->) [--repo DIR] [--max-concurrency N] [--keep] [--apply] [--json]"; exit 0 ;;
    *) echo "legion-fanout: unknown arg '$1'" >&2; exit 2 ;;
  esac
done
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

# Trace context: one trace per fan-out so every delegated slice's span hangs under
# a single OTel tree (rooted at the fan-out's own span below). Honor an inherited
# LEGION_TRACE_ID so a nested fan-out joins its caller's trace. Each delegate is a
# child of FANOUT_RUN_ID via the exported LEGION_PARENT_ID.
FANOUT_RUN_ID="fanout-$(date -u +%Y%m%d-%H%M%S)-$$"
FANOUT_TRACE_ID="${LEGION_TRACE_ID:-$FANOUT_RUN_ID}"
FANOUT_INHERITED_PARENT="${LEGION_PARENT_ID:-}"   # non-empty only for a nested fan-out
export LEGION_TRACE_ID="$FANOUT_TRACE_ID"
export LEGION_PARENT_ID="$FANOUT_RUN_ID"

# Read slices into numbered files (portable; tolerates blank lines). Preallocate a
# run_id per slice and write a queued record up-front, so pending slices show as
# "queued / up-next" in the Console while earlier batches run.
n=0
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  printf '%s\n' "$line" > "$work/slice-$n.in"
  s_arch="$(jq -r '.archetype // ""' <<<"$line" 2>/dev/null || echo "")"
  s_model="$(jq -r '.model // ""' <<<"$line" 2>/dev/null || echo "")"
  s_task="$(jq -r '.task // ""' <<<"$line" 2>/dev/null || echo "")"
  rid="$(date -u +%Y%m%d-%H%M%S)-${RANDOM}${RANDOM}-s$n"
  printf '%s\n' "$rid" > "$work/slice-$n.runid"
  [[ -n "$s_task" ]] && write_queued_record "$rid" "$s_arch" "$s_model" "$s_task"
  n=$((n + 1))
done < "$slices_src"
[[ "$n" -gt 0 ]] || { echo "legion-fanout: no slices" >&2; exit 2; }

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
    local route_out route_err route_rc
    route_out="$work/slice-$i.route.json"
    route_err="$work/slice-$i.route.err"
    set +e
    "$LEGION_ROUTE" "$arch" --preflight > "$route_out" 2> "$route_err"
    route_rc=$?
    set -e
    if [[ "$route_rc" -ne 0 ]]; then
      [[ -n "$rid" ]] && rm -f "$LEGION_REGISTRY_DIR/$rid.json" 2>/dev/null
      jq -cn --arg a "$arch" --arg t "$task" --arg e "$(tr '\n' ' ' < "$route_err")" \
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
  fi
  local args
  # NOTE: never forward --apply here. Parallel `git apply` to one worktree races/corrupts the
  # index; apply happens SEQUENTIALLY after the wait barrier (below). --keep so diffs survive.
  args=(run --repo "$repo" --quiet --keep)
  [[ -n "$rid" ]]   && args+=(--run-id "$rid")    # adopt the preallocated queued id
  [[ -n "$base_ref" ]] && args+=(--base "$base_ref")
  [[ -n "$arch" ]]  && args+=(--archetype "$arch")
  [[ -n "$model" ]] && args+=(--model "$model")
  args+=(--task "$task")
  "$LEGION_DELEGATE" "${args[@]}" > "$work/slice-$i.out" 2> "$work/slice-$i.err" || true
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
trap finalize_task_ledger_on_exit EXIT
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
  git -C "$repo" worktree add -q "$integration_wt" "$integration_branch"
}

teardown_integration_base() {
  if [[ -n "$integration_wt" && -d "$integration_wt" ]]; then
    git -C "$repo" worktree remove --force "$integration_wt" >/dev/null 2>&1 || rm -rf "$integration_wt"
  fi
  git -C "$repo" worktree prune >/dev/null 2>&1 || true
  [[ -n "$integration_branch" ]] && git -C "$repo" branch -D "$integration_branch" >/dev/null 2>&1 || true
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
      git -C "$repo" worktree remove --force "$swt" >/dev/null 2>&1 || rm -rf "$swt"
    fi
  done
  # A fallback rm leaves stale worktree administration behind. Prune once after
  # all removals so every branch is free before deletion without an O(n) global
  # repository scan for every slice.
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

integrate_slice_diff() {
  local i="$1" result dpath
  result="$(cat "$work/slice-$i.out" 2>/dev/null || echo '{}')"
  dpath="$(jq -r '.diff_path // empty' <<<"$result" 2>/dev/null || echo "")"
  if [[ -z "$dpath" || ! -s "$dpath" ]]; then
    update_task_ledger "$i" "completed" "ok" "" "no_changes"
    return 0
  fi
  if git -C "$integration_wt" apply --check "$dpath" 2>/dev/null; then
    git -C "$integration_wt" apply "$dpath"
    git -C "$integration_wt" add -A
    git -C "$integration_wt" -c user.email=legion@local -c user.name=Legion commit -qm "legion fanout slice $i"
    integrated=$((integrated + 1))
    integrated_tasks+=("$i")
    update_task_ledger "$i" "integrated" "ok" "" "staged"
  else
    integration_conflicts=$((integration_conflicts + 1))
    jq -c '. + {status:"error",stage:"integration-apply",error:"diff did not apply cleanly to integration base"}' \
      "$work/slice-$i.out" > "$work/slice-$i.out.tmp" \
      && mv "$work/slice-$i.out.tmp" "$work/slice-$i.out"
    update_task_ledger "$i" "failed" "error" "" "conflict"
  fi
}

if [[ "$has_dependencies" != "true" ]]; then
  # Launch in batches of MAXC (bash 3.2-safe; no `wait -n`).
  i=0
  while [[ $i -lt $n ]]; do
    launch_slice "$i" "HEAD" &
    i=$((i + 1))
    if [[ $((i % MAXC)) -eq 0 ]]; then wait; fi
  done
  wait
else
  setup_integration_base
  completed=0
  while [[ "$completed" -lt "$n" ]]; do
    ready=()
    progress=0
    i=0
    while [[ "$i" -lt "$n" ]]; do
      if [[ -s "$work/slice-$i.out" ]]; then
        i=$((i + 1))
        continue
      fi
      blocked_by=()
      waiting=0
      while IFS= read -r dep; do
        [[ -n "$dep" ]] || continue
        dep_i="$(jq -r --arg d "$dep" '.index_by_id[$d]' "$work/dag.json")"
        if [[ ! -s "$work/slice-$dep_i.out" ]]; then
          waiting=1
          continue
        fi
        dep_status="$(jq -r '.status // "error"' "$work/slice-$dep_i.out" 2>/dev/null || echo error)"
        if [[ "$dep_status" != "ok" ]]; then
          blocked_by+=("$dep")
        fi
      done < <(jq -r --argjson i "$i" '.slices[$i].depends_on[]?' "$work/dag.json")
      if [[ "${#blocked_by[@]}" -gt 0 ]]; then
        blocked_json="$(printf '%s\n' "${blocked_by[@]}" | jq -R . | jq -s .)"
        mark_blocked "$i" "$blocked_json"
        completed=$((completed + 1))
        progress=1
      elif [[ "$waiting" -eq 0 ]]; then
        ready+=("$i")
      fi
      i=$((i + 1))
    done

    if [[ "${#ready[@]}" -eq 0 ]]; then
      if [[ "$progress" -eq 1 ]]; then
        continue
      fi
      i=0
      while [[ "$i" -lt "$n" ]]; do
        if [[ ! -s "$work/slice-$i.out" ]]; then
          mark_blocked "$i" '[]'
          completed=$((completed + 1))
        fi
        i=$((i + 1))
      done
      break
    fi

    launched=0
    for i in "${ready[@]}"; do
      launch_slice "$i" "$integration_branch" &
      launched=$((launched + 1))
      if [[ $((launched % MAXC)) -eq 0 ]]; then wait; fi
    done
    wait
    for i in "${ready[@]}"; do
      completed=$((completed + 1))
      if [[ "$(jq -r '.status // "error"' "$work/slice-$i.out" 2>/dev/null || echo error)" == "ok" ]]; then
        integrate_slice_diff "$i"
      fi
    done
  done
fi

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
      '{status:"error",id:$id,depends_on:$depends_on,error:"no output"}' >> "$results"
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
  --arg task_ledger_path "$work/task-ledger.json" '{
  slices: length,
  ok:     ([.[] | select(.status == "ok")]     | length),
  inline: ([.[] | select(.status == "inline")] | length),
  failed: ([.[] | select(.status != "ok" and .status != "inline")] | length),
  total_cost_usd: ([.[].cost_usd // 0] | add),
  applied: $applied,
  apply_conflicts: $conflicts,
  task_ledger_path: $task_ledger_path,
  by_model: (reduce .[] as $r ({}; .[($r.model // ($r.status // "unknown"))] += 1)),
  results: .
}' "$results"
