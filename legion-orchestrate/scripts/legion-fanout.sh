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
_state_lib="$_self/../../legion-observability/scripts/lib/state.sh"
if [[ -f "$_state_lib" ]]; then
  # shellcheck disable=SC1091
  source "$_state_lib"
fi

# Preallocate a queued run-state record so a fan-out's pending slices show as
# "queued / up-next" in the Console before they launch. The delegate adopts the id
# (--run-id) and rewrites it running->terminal. Best-effort (never block on telemetry).
write_queued_record() {
  local rid="$1" arch="$2" model="$3" task="$4"
  mkdir -p "$LEGION_REGISTRY_DIR" 2>/dev/null || return 0
  jq -cn --arg run "$rid" --arg trace "$FANOUT_TRACE_ID" --arg parent "$FANOUT_RUN_ID" \
    --arg repo "$repo" --arg arch "$arch" --arg model "$model" --arg task "$task" \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    {schema:"legion.run-state.v1", run_id:$run, trace_id:$trace, parent_id:$parent,
     kind:"run", state_version:1, repo_root:$repo, archetype:$arch, model:$model, task:$task,
     process:{pid:0,pgid:0,started_at:""},
     lifecycle:{phase:"queued", started_at:"", updated_at:$now}}' \
    > "$LEGION_REGISTRY_DIR/$rid.json.tmp.$$" 2>/dev/null \
    && mv -f "$LEGION_REGISTRY_DIR/$rid.json.tmp.$$" "$LEGION_REGISTRY_DIR/$rid.json" 2>/dev/null || true
}
MAXC="${LEGION_MAX_CONCURRENCY:-4}"

slices_src="" ; task_src="" ; repo="$PWD" ; apply="" ; json=0 ; keep_slices=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --slices) slices_src="$2"; shift 2 ;;
    --task) task_src="$2"; shift 2 ;;
    --repo) repo="$2"; shift 2 ;;
    --max-concurrency) MAXC="$2"; shift 2 ;;
    --keep) keep_slices=1; shift ;; # retain slice worktrees after apply (default: reclaim them)
    --apply) apply="1"; shift ;;
    --json) json=1; shift ;; # output is already JSON; accepted for roadmap compatibility
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
  local i="$1" base_ref="${2:-HEAD}" line arch model task ex rid
  line="$(cat "$work/slice-$i.in")"
  rid="$(cat "$work/slice-$i.runid" 2>/dev/null || echo "")"
  arch="$(jq -r '.archetype // ""' <<<"$line" 2>/dev/null || echo "")"
  model="$(jq -r '.model // ""' <<<"$line" 2>/dev/null || echo "")"
  task="$(jq -r '.task // ""' <<<"$line" 2>/dev/null || echo "")"
  if [[ -z "$task" ]]; then
    [[ -n "$rid" ]] && rm -f "$LEGION_REGISTRY_DIR/$rid.json" 2>/dev/null
    echo '{"status":"error","error":"empty task"}' > "$work/slice-$i.out"; return
  fi
  # self archetypes are NOT delegated — return for Opus to do inline (drop the queued
  # record: it's not a delegated agent).
  if [[ -n "$arch" ]]; then
    local route_out route_err route_rc
    route_out="$work/slice-$i.route.json"
    route_err="$work/slice-$i.route.err"
    set +e
    "$LEGION_ROUTE" "$arch" > "$route_out" 2> "$route_err"
    route_rc=$?
    set -e
    if [[ "$route_rc" -ne 0 ]]; then
      [[ -n "$rid" ]] && rm -f "$LEGION_REGISTRY_DIR/$rid.json" 2>/dev/null
      jq -cn --arg a "$arch" --arg t "$task" --arg e "$(tr '\n' ' ' < "$route_err")" \
        '{status:"error",stage:"route",archetype:$a,task:$t,error:$e}' > "$work/slice-$i.out"
      return
    fi
    if ! jq -e 'type == "object"' "$route_out" >/dev/null 2>&1; then
      [[ -n "$rid" ]] && rm -f "$LEGION_REGISTRY_DIR/$rid.json" 2>/dev/null
      jq -cn --arg a "$arch" --arg t "$task" --arg e "$(cat "$route_out" 2>/dev/null)" \
        '{status:"error",stage:"route",archetype:$a,task:$t,error:("invalid route JSON: " + $e)}' > "$work/slice-$i.out"
      return
    fi
    ex="$(jq -r '.executor // ""' "$route_out" 2>/dev/null || echo "")"
    if [[ "$ex" == "self" ]]; then
      [[ -n "$rid" ]] && rm -f "$LEGION_REGISTRY_DIR/$rid.json" 2>/dev/null
      jq -cn --arg a "$arch" --arg t "$task" '{status:"inline",archetype:$a,task:$t,note:"Opus should do this inline"}' > "$work/slice-$i.out"
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
}

has_dependencies="$(jq -r '.has_dependencies' "$work/dag.json")"
base_head="$(git -C "$repo" rev-parse HEAD)"
integration_branch=""
integration_wt=""
integrated=0
integration_conflicts=0

setup_integration_base() {
  [[ -n "$integration_branch" ]] && return 0
  integration_branch="legion/fanout-${FANOUT_RUN_ID}"
  integration_wt="$work/integration"
  git -C "$repo" branch "$integration_branch" "$base_head"
  git -C "$repo" worktree add -q "$integration_wt" "$integration_branch"
}

teardown_integration_base() {
  [[ -n "$integration_wt" && -d "$integration_wt" ]] && git -C "$repo" worktree remove --force "$integration_wt" >/dev/null 2>&1 || true
  [[ -n "$integration_branch" ]] && git -C "$repo" branch -D "$integration_branch" >/dev/null 2>&1 || true
  git -C "$repo" worktree prune >/dev/null 2>&1 || true
}

# Slices are delegated with --keep so their diffs survive until the sequential
# apply barrier. Once apply is done the worktrees are disposable (the diffs live
# under .legion/runs/<rid>), so reclaim exactly this fan-out's slice worktrees —
# not a blanket `cleanup --all`, which would disturb concurrent runs. --keep on
# the fan-out retains them for inspection.
cleanup_slice_worktrees() {
  [[ "$keep_slices" == "1" ]] && return 0
  local i rid swt
  for ((i = 1; i <= n; i++)); do
    rid="$(cat "$work/slice-$i.runid" 2>/dev/null || echo "")"
    [[ -n "$rid" ]] || continue
    swt="$repo/.legion/worktrees/$rid"
    [[ -d "$swt" ]] || continue
    git -C "$repo" worktree remove --force "$swt" >/dev/null 2>&1 || rm -rf "$swt"
    git -C "$repo" branch -D "legion/delegate-$rid" >/dev/null 2>&1 || true
  done
  git -C "$repo" worktree prune >/dev/null 2>&1 || true
}

mark_blocked() {
  local i="$1" blocked_by_json="$2"
  jq -cn --argjson blocked_by "$blocked_by_json" \
    '{status:"blocked",stage:"dependency",blocked_by:$blocked_by,error:"blocked by failed prerequisite"}' \
    > "$work/slice-$i.out"
  local rid
  rid="$(cat "$work/slice-$i.runid" 2>/dev/null || echo "")"
  [[ -n "$rid" ]] && rm -f "$LEGION_REGISTRY_DIR/$rid.json" 2>/dev/null || true
}

integrate_slice_diff() {
  local i="$1" result dpath
  result="$(cat "$work/slice-$i.out" 2>/dev/null || echo '{}')"
  dpath="$(jq -r '.diff_path // empty' <<<"$result" 2>/dev/null || echo "")"
  [[ -n "$dpath" && -s "$dpath" ]] || return 0
  if git -C "$integration_wt" apply --check "$dpath" 2>/dev/null; then
    git -C "$integration_wt" apply "$dpath"
    git -C "$integration_wt" add -A
    git -C "$integration_wt" -c user.email=legion@local -c user.name=Legion commit -qm "legion fanout slice $i"
    integrated=$((integrated + 1))
  else
    integration_conflicts=$((integration_conflicts + 1))
    jq -c '. + {status:"error",stage:"integration-apply",error:"diff did not apply cleanly to integration base"}' \
      "$work/slice-$i.out" > "$work/slice-$i.out.tmp" \
      && mv "$work/slice-$i.out.tmp" "$work/slice-$i.out"
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
    else
      apply_conflicts=$((apply_conflicts + 1))
    fi
  fi
elif [[ -n "$apply" ]]; then
  while IFS= read -r dpath; do
    [[ -n "$dpath" && -s "$dpath" ]] || continue
    if git -C "$repo" apply --check "$dpath" 2>/dev/null; then
      git -C "$repo" apply "$dpath" && applied=$((applied + 1))
    else
      apply_conflicts=$((apply_conflicts + 1))
    fi
  done < <(jq -r '.[] | select(.status=="ok") | .diff_path // empty' <(jq -s '.' "$results"))
fi
if [[ "$has_dependencies" == "true" ]]; then
  apply_conflicts=$((apply_conflicts + integration_conflicts))
  teardown_integration_base
fi
cleanup_slice_worktrees

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

jq -s --argjson applied "$applied" --argjson conflicts "$apply_conflicts" '{
  slices: length,
  ok:     ([.[] | select(.status == "ok")]     | length),
  inline: ([.[] | select(.status == "inline")] | length),
  failed: ([.[] | select(.status != "ok" and .status != "inline")] | length),
  total_cost_usd: ([.[].cost_usd // 0] | add),
  applied: $applied,
  apply_conflicts: $conflicts,
  by_model: (reduce .[] as $r ({}; .[($r.model // ($r.status // "unknown"))] += 1)),
  results: .
}' "$results"
