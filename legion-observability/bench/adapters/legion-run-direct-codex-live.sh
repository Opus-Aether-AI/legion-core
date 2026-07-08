#!/usr/bin/env bash
set -euo pipefail

source_repo="${1:?usage: legion-run-direct-codex-live.sh SOURCE_REPO}"
workspace="${PWD}"
root="$workspace/direct-run-codex-live"
hook_bin="$root/bin"
target_repo="$root/repo"
state_root="${LEGION_STATE_ROOT:-$root/state}"
stdout_path="$root/legion-run.stdout"
stderr_path="$root/legion-run.stderr"
result_path="$workspace/direct-run-codex-live-result.json"
memory_before_path="$root/memory-before-legion-run.json"

mkdir -p "$hook_bin" "$target_repo" "$state_root" "$(dirname "$result_path")"

export LEGION_STATE_ROOT="$state_root"
export LEGION_TELEMETRY_DIR="${LEGION_TELEMETRY_DIR:-$state_root/spans}"
export LEGION_REGISTRY_DIR="${LEGION_REGISTRY_DIR:-$state_root/registry}"
export LEGION_REPOS_FILE="${LEGION_REPOS_FILE:-$state_root/repos.jsonl}"
export LEGION_BENCH_DIR="${LEGION_BENCH_DIR:-$state_root/bench}"
export LEGION_REPORTS_DIR="${LEGION_REPORTS_DIR:-$state_root/reports}"
export LEGION_MAX_CONCURRENCY="${LEGION_MAX_CONCURRENCY:-1}"
export PATH="$hook_bin:$source_repo/legion-orchestrate/bin:$source_repo/legion-observability/bin:$source_repo/legion-router/bin:$PATH"

if [ ! -d "$target_repo/.git" ]; then
  git -C "$target_repo" init -q
  git -C "$target_repo" config user.email legion-run-codex-live-bench@example.test
  git -C "$target_repo" config user.name "Legion Run Codex Live Bench"
  mkdir -p "$target_repo/fieldops" "$target_repo/tests"
  cat > "$target_repo/README.md" <<'MD'
# FieldOps Triage Codex Live Fixture

This fixture starts with an incomplete SLA triage module. The Codex-live benchmark task
is to implement deterministic dispatch planning for facility maintenance tickets.
MD
  cat > "$target_repo/fieldops/__init__.py" <<'PY'
from .triage import build_dispatch_plan, normalize_ticket

__all__ = ["build_dispatch_plan", "normalize_ticket"]
PY
  cat > "$target_repo/fieldops/triage.py" <<'PY'
"""SLA triage for FieldOps maintenance tickets."""


def normalize_ticket(raw):
    raise NotImplementedError("legion-run Codex-live benchmark should implement this")


def build_dispatch_plan(tickets):
    raise NotImplementedError("legion-run Codex-live benchmark should implement this")
PY
  git -C "$target_repo" add -A
  git -C "$target_repo" commit -qm init
fi

cat > "$hook_bin/bench-codex-live-plan" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
python3 - <<'PY'
import json
import os
from pathlib import Path

plan = {
    "schema": "legion.heavy-task.plan.v1",
    "mode": "legion-live-slices",
    "task": os.environ["LEGION_TASK"],
    "planning_instruction": (
        "Complete the Python FieldOps triage fixture. The target API is "
        "fieldops.triage.normalize_ticket(raw) and build_dispatch_plan(tickets). "
        "Use only the Python standard library. Preserve deterministic output."
    ),
    "required_skills": ["ai-architect", "software-architect"],
    "quality_gates": ["python-unittest", "domain-smoke", "self-learning"],
    "eval_goal": "A freezer-down FieldOps ticket routes first with refrigeration dispatch and a 30-minute SLA.",
}
slices = [
    {
        "id": "implement-fieldops-triage",
        "phase": "green",
        "archetype": "implement-feature",
        "task": (
            "Implement fieldops.triage.normalize_ticket(raw) and build_dispatch_plan(tickets), and add "
            "focused unittest coverage under tests/test_triage.py. Use this exact contract. "
            "normalize_ticket returns a dict with id, site, asset, summary, severity, priority, "
            "dispatch_trade, opened_at, sla_minutes, sla_deadline, and tags. build_dispatch_plan returns "
            "a dict with total, critical, and tickets. Validate required fields id/site/asset/summary/"
            "opened_at and raise clear ValueError messages. Parse ISO-8601 timestamps including Z and "
            "format UTC timestamps with a trailing Z. Derive priority from explicit severity plus "
            "operational keywords. Cold-chain outage terms like freezer down/product warming override "
            "lower severity to priority critical. Offline/blocked exit/no power/alarm keywords escalate "
            "to high. Assign dispatch_trade refrigeration/plumbing/electrical/facilities. Assign SLA "
            "deadlines critical=30, high=120, medium=480, low=1440 minutes. Sort dispatch plan tickets "
            "by priority, sla_deadline, opened_at, then id. Use only Python stdlib."
        ),
    },
    {
        "id": "refactor-fieldops-gate",
        "phase": "refactor",
        "depends_on": ["implement-fieldops-triage"],
        "archetype": "refactor-module",
        "task": (
            "Refactor the FieldOps triage implementation for clarity without changing behavior. "
            "Run python -m unittest discover -s tests -v before finishing. The public contract must remain: "
            "build_dispatch_plan returns {total, critical, tickets}, each normalized ticket has priority, "
            "dispatch_trade, sla_deadline, and the freezer-down medium-severity smoke case remains critical "
            "refrigeration with SLA deadline 2026-07-08T10:30:00Z. Keep the repo dependency-free."
        ),
    },
]
Path(os.environ["LEGION_RUN_PLAN_FILE"]).write_text(
    json.dumps(plan, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
Path(os.environ["LEGION_RUN_SLICES_FILE"]).write_text(
    "\n".join(json.dumps(item, sort_keys=True) for item in slices) + "\n",
    encoding="utf-8",
)
print(json.dumps({"ok": True, "slices": len(slices)}, sort_keys=True))
PY
SH

cat > "$hook_bin/bench-codex-live-validate" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
python3 - <<'PY'
import json
import os
import subprocess
import sys
from pathlib import Path

repo = Path(os.environ["LEGION_REPO"])
run_dir = Path(os.environ["LEGION_RUN_DIR"])
slices_path = run_dir / "slices.jsonl"
slices = [
    json.loads(line)
    for line in slices_path.read_text(encoding="utf-8").splitlines()
    if line.strip()
]
phases = sorted({str(item.get("phase", "")) for item in slices if item.get("phase")})
test_proc = subprocess.run(
    [sys.executable, "-m", "unittest", "discover", "-s", "tests", "-v"],
    cwd=repo,
    text=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    timeout=60,
)
smoke_proc = subprocess.run(
    [
        sys.executable,
        "-c",
        (
            "from fieldops.triage import build_dispatch_plan; "
            "plan = build_dispatch_plan([{'id':'T-1','site':'Store 42','asset':'walk-in freezer',"
            "'summary':'walk-in freezer down and product warming','severity':'medium',"
            "'opened_at':'2026-07-08T10:00:00Z'}]); "
            "ticket = plan['tickets'][0]; "
            "assert ticket['priority'] == 'critical', ticket; "
            "assert ticket['dispatch_trade'] == 'refrigeration', ticket; "
            "assert ticket['sla_deadline'] == '2026-07-08T10:30:00Z', ticket"
        ),
    ],
    cwd=repo,
    text=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    timeout=60,
)
ok = (
    {"green", "refactor"}.issubset(set(phases))
    and test_proc.returncode == 0
    and smoke_proc.returncode == 0
)
print(json.dumps({
    "ok": ok,
    "command": "bench-codex-live-validate",
    "slice_count": len(slices),
    "phases": phases,
    "tests_passed": test_proc.returncode == 0,
    "domain_smoke_passed": smoke_proc.returncode == 0,
    "test_stdout": test_proc.stdout[-2000:],
    "test_stderr": test_proc.stderr[-4000:],
    "smoke_stderr": smoke_proc.stderr[-2000:],
    "learning_feedback": [
        {
            "id": "fieldops-cold-chain-live-escalation",
            "source": "validation-feedback",
            "target_type": "heavy-task",
            "target_name": "direct-codex-live-plan-validate",
            "severity": "medium",
            "summary": (
                "Codex live validation discovered a reusable FieldOps invariant: cold-chain outage "
                "keywords such as freezer down or product warming must override lower explicit "
                "severity and produce a critical refrigeration dispatch with a 30-minute SLA."
            ),
            "evidence": {
                "validator": "bench-codex-live-validate",
                "smoke": "freezer-down medium severity -> critical refrigeration 30-minute SLA",
                "passed": ok,
            },
            "metadata": {
                "feedback_kind": "validation-discovered-domain-invariant",
                "fixture": "fieldops-triage-live",
            },
        }
    ] if ok else [],
}, sort_keys=True))
raise SystemExit(0 if ok else 1)
PY
SH

chmod +x "$hook_bin"/*

"$source_repo/legion-observability/bin/legion-self-learn" record \
  --logs "$LEGION_STATE_ROOT" \
  --entity heavy-task:direct-codex-live-plan-validate \
  --summary "Prior live direct legion-run benchmark hint must be loaded before planning." \
  --source legion-run-codex-live-benchmark \
  --evidence "seeded by legion-run Codex-live benchmark" \
  --json > "$root/prior-self-learn-record.json"

"$source_repo/legion-observability/bin/legion-self-learn" run \
  --repo "$source_repo" \
  --logs "$LEGION_STATE_ROOT" \
  --apply-memory \
  --json > "$root/prior-self-learn-run.json"

cp "$LEGION_STATE_ROOT/self-learn/harness-memory.json" "$memory_before_path"

set +e
legion-run \
  --repo "$target_repo" \
  --task "Implement FieldOps SLA triage: normalize tickets, infer priority from freezer-down/offline/leak keywords, assign dispatch trades and SLA deadlines, sort the dispatch queue, and cover it with unittest tests." \
  --name direct-codex-live-plan-validate \
  --plan-command bench-codex-live-plan \
  --validate-command bench-codex-live-validate \
  --json > "$stdout_path" 2> "$stderr_path"
run_status=$?
set -e

python3 - "$run_status" "$stdout_path" "$stderr_path" "$result_path" "$target_repo" "$state_root" "$memory_before_path" <<'PY'
import html
import json
import os
import subprocess
import sys
from pathlib import Path

run_status = int(sys.argv[1])
stdout_path = Path(sys.argv[2])
stderr_path = Path(sys.argv[3])
result_path = Path(sys.argv[4])
target_repo = Path(sys.argv[5])
state_root = Path(sys.argv[6])
memory_before_path = Path(sys.argv[7])

def read_json(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}

def read_jsonl(path: Path):
    rows = []
    try:
        for line in path.read_text(encoding="utf-8").splitlines():
            if line.strip():
                rows.append(json.loads(line))
    except Exception:
        pass
    return rows

summary = read_json(stdout_path)
run_dir = Path(summary.get("run_dir") or "")
stage_status = summary.get("stage_status") if isinstance(summary.get("stage_status"), list) else []

def artifact(name):
    return read_json(run_dir / name) if run_dir else {}

def has_artifact(name):
    return bool(run_dir) and (run_dir / name).is_file() and (run_dir / name).stat().st_size > 0

slices = read_jsonl(run_dir / "slices.jsonl") if run_dir else []
routes = artifact("routes.json").get("routes", [])
fanout = artifact("fanout.json")
review = artifact("review.json")
validation = artifact("validation.json")
learning_feedback = artifact("learning-feedback.json")
self_learn = artifact("self-learn.json")
memory = read_json(state_root / "self-learn" / "harness-memory.json")
memory_before = read_json(memory_before_path)
memory_key = "heavy-task:direct-codex-live-plan-validate"
memory_entry = memory.get("entities", {}).get(memory_key, {})
memory_entry_before = memory_before.get("entities", {}).get(memory_key, {})
proposal_ids = set(memory_entry.get("proposal_ids", []))
proposal_ids_before = set(memory_entry_before.get("proposal_ids", []))
hints = memory_entry.get("hints", [])
hints_before = set(memory_entry_before.get("hints", []))
triage_path = target_repo / "fieldops" / "triage.py"
test_path = target_repo / "tests" / "test_triage.py"
triage_text = triage_path.read_text(encoding="utf-8") if triage_path.exists() else ""
test_text = test_path.read_text(encoding="utf-8") if test_path.exists() else ""
overview_path = result_path.with_name("legion-run-codex-live-benchmark.html")
run_report_path = run_dir / "legion-report.html"
observability_path = run_dir / "legion-observability.html"
artifact_manifest_path = run_dir / "artifact-manifest.json"
span_rows = []
for span_path in sorted((state_root / "spans").glob("*.jsonl")):
    span_rows.extend(read_jsonl(span_path))
codex_spans = [
    row for row in span_rows
    if str(row.get("executor", "")).startswith("codex")
    and row.get("status") in {"ok", "over_budget"}
]
status_proc = subprocess.run(
    ["git", "-C", str(target_repo), "status", "--short"],
    text=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
)

checks = {
    "run_exited_zero": run_status == 0,
    "contract_is_direct": summary.get("runner", {}).get("mode") == "direct",
    "profile_is_heavy_task": summary.get("pipeline", {}).get("profile") == "legion.heavy_task.v1",
    "required_artifacts_present": all(has_artifact(name) for name in summary.get("pipeline", {}).get("required_artifacts", [])),
    "all_stages_passed": bool(stage_status) and all(item.get("status") == "passed" for item in stage_status),
    "plan_command_used": artifact("plan-command.json").get("ok") is True,
    "custom_codex_slices_used": [item.get("id") for item in slices] == [
        "implement-fieldops-triage",
        "refactor-fieldops-gate",
    ],
    "routes_generated_for_all_slices": len(routes) == len(slices) and len(routes) > 0,
    "codex_slices_ran": (
        fanout.get("slices") == len(slices)
        and fanout.get("failed") == 0
        and len(fanout.get("results", [])) == len(slices)
        and any(item.get("model") for item in fanout.get("results", []))
    ),
    "codex_model_telemetry_recorded": len(codex_spans) >= 2,
    "review_ran": review.get("status") == "ok",
    "validate_command_used": validation.get("command") == "bench-codex-live-validate" and validation.get("ok") is True,
    "coding_task_implemented": (
        validation.get("tests_passed") is True
        and validation.get("domain_smoke_passed") is True
        and "NotImplementedError" not in triage_text
        and "build_dispatch_plan" in triage_text
        and "freezer" in test_text.lower()
    ),
    "validation_feedback_recorded": (
        learning_feedback.get("recorded", 0) >= 1
        and learning_feedback.get("outcomes", [{}])[0].get("source") == "validation-feedback"
    ),
    "self_learning_memory_updated_by_validation_feedback": (
        bool(proposal_ids - proposal_ids_before)
        and any("Codex live validation discovered a reusable FieldOps invariant" in str(hint) for hint in hints)
        and any(hint not in hints_before for hint in hints)
        and self_learn.get("run", {}).get("summary", {}).get("outcomes", 0) >= 1
    ),
    "html_reports_generated": (
        overview_path.exists() or True
    ) and run_report_path.exists() and observability_path.exists(),
    "heal_plan_ran": artifact("heal-plan.json").get("exit_code") == 0,
}

def esc(value):
    return html.escape(str(value or ""))

def rel(path):
    try:
        return os.path.relpath(str(path), start=str(result_path.parent))
    except ValueError:
        return str(path)

def badge(ok):
    label = "PASS" if ok else "FAIL"
    klass = "good" if ok else "bad"
    return f'<span class="badge {klass}">{label}</span>'

def pre(value):
    return f"<pre>{esc(value)}</pre>"

def json_pretty(value):
    return json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False)

def render_overview():
    feedback_outcomes = learning_feedback.get("outcomes") if isinstance(learning_feedback.get("outcomes"), list) else []
    feedback = feedback_outcomes[0] if feedback_outcomes and isinstance(feedback_outcomes[0], dict) else {}
    check_rows = "\n".join(
        f"<tr><td><code>{esc(name)}</code></td><td>{badge(bool(ok))}</td></tr>"
        for name, ok in sorted(checks.items())
    )
    stage_rows = "\n".join(
        "<tr>"
        f"<td>{esc(item.get('stage'))}</td>"
        f"<td>{badge(item.get('status') == 'passed')} <strong>{esc(item.get('status'))}</strong></td>"
        f"<td>{', '.join(f'<code>{esc(name)}</code>' for name in item.get('artifacts', []))}</td>"
        "</tr>"
        for item in stage_status
    )
    links = [
        ("Benchmark overview", overview_path),
        ("Legion run report", run_report_path),
        ("Legion observability report", observability_path),
        ("Artifact manifest", artifact_manifest_path),
        ("Target fixture repo", target_repo),
    ]
    link_items = "\n".join(
        f'<li><a href="{esc(rel(path))}">{esc(label)}</a><br><small>{esc(path)}</small></li>'
        for label, path in links
    )
    return f"""<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>Legion Run Codex Live Benchmark</title>
  <style>
    body {{ font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; margin: 32px; color: #111827; line-height: 1.5; }}
    h1, h2 {{ margin-bottom: 8px; }}
    .grid {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 12px; margin: 18px 0; }}
    .panel {{ border: 1px solid #d1d5db; border-radius: 8px; padding: 14px 16px; background: #fff; }}
    .metric {{ font-size: 28px; font-weight: 700; }}
    .subtle, small {{ color: #6b7280; }}
    table {{ border-collapse: collapse; width: 100%; margin: 14px 0 24px; }}
    th, td {{ border: 1px solid #d1d5db; padding: 8px 10px; text-align: left; vertical-align: top; }}
    code {{ background: #f3f4f6; border-radius: 4px; padding: 2px 4px; }}
    pre {{ white-space: pre-wrap; overflow: auto; background: #f9fafb; border: 1px solid #e5e7eb; border-radius: 8px; padding: 12px; max-height: 360px; }}
    details {{ border: 1px solid #d1d5db; border-radius: 8px; padding: 10px 12px; margin: 10px 0; }}
    summary {{ cursor: pointer; font-weight: 650; }}
    .badge {{ border-radius: 999px; padding: 2px 8px; font-size: 12px; font-weight: 700; }}
    .good {{ background: #dcfce7; color: #166534; }}
    .bad {{ background: #fee2e2; color: #991b1b; }}
  </style>
</head>
<body>
  <h1>Legion Run Codex Live Benchmark</h1>
  <p class="subtle">This opt-in benchmark spends real Codex model calls through <code>legion-run</code> direct mode.</p>

  <div class="grid">
    <div class="panel"><div class="metric">{esc("PASS" if all(checks.values()) else "FAIL")}</div><div>Overall result</div></div>
    <div class="panel"><div class="metric">{esc(len(slices))}</div><div>Planned slices</div></div>
    <div class="panel"><div class="metric">{esc(len(codex_spans))}</div><div>Codex spans</div></div>
    <div class="panel"><div class="metric">{esc(learning_feedback.get("recorded", 0))}</div><div>Validation lessons recorded</div></div>
  </div>

  <h2>Task</h2>
  <p>Implement FieldOps SLA triage: normalize tickets, infer priority from cold-chain and operational keywords, assign dispatch trades and SLA deadlines, sort the dispatch queue, and cover the behavior with Python unittest tests.</p>

  <h2>Open The Evidence</h2>
  <ul>{link_items}</ul>

  <h2>Codex Live Evidence</h2>
  <details open><summary>fanout.json</summary>{pre(json_pretty(fanout))}</details>
  <details><summary>review.json</summary>{pre(json_pretty(review))}</details>
  <details><summary>Codex spans</summary>{pre(json_pretty(codex_spans))}</details>

  <h2>Lifecycle Stages</h2>
  <table><thead><tr><th>Stage</th><th>Status</th><th>Artifacts</th></tr></thead><tbody>{stage_rows}</tbody></table>

  <h2>Benchmark Checks</h2>
  <table><thead><tr><th>Check</th><th>Status</th></tr></thead><tbody>{check_rows}</tbody></table>

  <h2>Validation-Discovered Learning</h2>
  <p><strong>Outcome:</strong> {esc(feedback.get("summary"))}</p>
  <details open><summary>learning-feedback.json</summary>{pre(json_pretty(learning_feedback))}</details>
  <details><summary>self-learn.json</summary>{pre(json_pretty(self_learn))}</details>

  <h2>Implemented Code</h2>
  <details><summary>fieldops/triage.py</summary>{pre(triage_text)}</details>
  <details><summary>tests/test_triage.py</summary>{pre(test_text)}</details>

  <h2>Target Repo Status</h2>
  {pre(status_proc.stdout)}

  <h2>Raw Run Contract</h2>
  <details><summary>legion-run stdout contract</summary>{pre(json_pretty(summary))}</details>
  <details><summary>stderr tail</summary>{pre(stderr_path.read_text(encoding="utf-8")[-4000:] if stderr_path.exists() else "")}</details>
</body>
</html>
"""

overview_path.write_text(render_overview(), encoding="utf-8")
checks["html_reports_generated"] = (
    overview_path.exists()
    and run_report_path.exists()
    and observability_path.exists()
    and "Codex Live Evidence" in overview_path.read_text(encoding="utf-8")
)
overview_path.write_text(render_overview(), encoding="utf-8")

html_artifacts = {
    "benchmark_overview": str(overview_path),
    "legion_run_report": str(run_report_path),
    "legion_observability": str(observability_path),
}
payload = {
    "ok": all(checks.values()),
    "mode": summary.get("runner", {}).get("mode"),
    "profile": summary.get("pipeline", {}).get("profile"),
    "run_status": run_status,
    "run_dir": str(run_dir) if run_dir else "",
    "html_artifacts": html_artifacts,
    "checks": checks,
    "codex_span_count": len(codex_spans),
    "contract": summary,
    "stderr": stderr_path.read_text(encoding="utf-8")[-4000:] if stderr_path.exists() else "",
}
result_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(json.dumps(payload, indent=2, sort_keys=True))
raise SystemExit(0 if payload["ok"] else 1)
PY
