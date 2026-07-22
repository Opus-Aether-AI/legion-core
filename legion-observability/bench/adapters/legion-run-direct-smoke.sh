#!/usr/bin/env bash
set -euo pipefail

source_repo="${1:?usage: legion-run-direct-smoke.sh SOURCE_REPO}"
workspace="${PWD}"
root="$workspace/direct-run-smoke"
fake_bin="$root/bin"
target_repo="$root/repo"
state_root="${LEGION_STATE_ROOT:-$root/state}"
call_log="$root/calls.log"
stdout_path="$root/legion-run.stdout"
stderr_path="$root/legion-run.stderr"
result_path="$workspace/direct-run-result.json"
memory_before_path="$root/memory-before-legion-run.json"

mkdir -p "$fake_bin" "$target_repo" "$state_root" "$(dirname "$result_path")"
: > "$call_log"

export LEGION_STATE_ROOT="$state_root"
export LEGION_TELEMETRY_DIR="${LEGION_TELEMETRY_DIR:-$state_root/spans}"
export LEGION_REGISTRY_DIR="${LEGION_REGISTRY_DIR:-$state_root/registry}"
export LEGION_REPOS_FILE="${LEGION_REPOS_FILE:-$state_root/repos.jsonl}"
export LEGION_BENCH_DIR="${LEGION_BENCH_DIR:-$state_root/bench}"
export LEGION_REPORTS_DIR="${LEGION_REPORTS_DIR:-$state_root/reports}"
export LEGION_RUN_BENCH_CALL_LOG="$call_log"
export PATH="$fake_bin:$source_repo/legion-orchestrate/bin:$source_repo/legion-observability/bin:$source_repo/legion-router/bin:$PATH"

if [ ! -d "$target_repo/.git" ]; then
  git -C "$target_repo" init -q
  git -C "$target_repo" config user.email legion-run-bench@example.test
  git -C "$target_repo" config user.name "Legion Run Bench"
  mkdir -p "$target_repo/fieldops" "$target_repo/tests"
  cat > "$target_repo/README.md" <<'MD'
# FieldOps Triage Fixture

This fixture starts with an incomplete SLA triage module. The benchmark task is
to implement deterministic dispatch planning for facility maintenance tickets.
MD
  cat > "$target_repo/fieldops/__init__.py" <<'PY'
from .triage import build_dispatch_plan, normalize_ticket

__all__ = ["build_dispatch_plan", "normalize_ticket"]
PY
  cat > "$target_repo/fieldops/triage.py" <<'PY'
"""SLA triage for FieldOps maintenance tickets."""


def normalize_ticket(raw):
    raise NotImplementedError("legion-run benchmark should implement this")


def build_dispatch_plan(tickets):
    raise NotImplementedError("legion-run benchmark should implement this")
PY
  git -C "$target_repo" add -A
  git -C "$target_repo" commit -qm init
fi

cat > "$fake_bin/bench-plan" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'plan-command\n' >> "$LEGION_RUN_BENCH_CALL_LOG"
python3 - <<'PY'
import json
import os

payload = {
    "schema": "legion.heavy-task.plan.v1",
    "mode": "legion-generate-slices",
    "task": os.environ["LEGION_TASK"],
    "planning_instruction": (
        "Implement a non-trivial Python coding task in the fixture repo: complete "
        "fieldops.triage so it normalizes maintenance tickets, derives severity "
        "from explicit fields and operational keywords, assigns SLA deadlines, "
        "selects dispatch trades, sorts the queue by urgency, and raises clear "
        "ValueError messages for malformed tickets. Add focused unittest coverage "
        "for critical freezer-down dispatch, ordering, keyword escalation, and "
        "input validation. Keep the implementation deterministic and dependency-free."
    ),
    "required_skills": ["ai-architect", "software-architect"],
    "quality_gates": ["python-unittest", "domain-smoke", "self-learning"],
    "eval_goal": "A freezer-down FieldOps ticket is routed first with a refrigeration dispatch and a 30-minute SLA.",
}
with open(os.environ["LEGION_RUN_PLAN_FILE"], "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
SH

cat > "$fake_bin/bench-validate" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'validate-command\n' >> "$LEGION_RUN_BENCH_CALL_LOG"
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
    timeout=30,
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
            "assert plan['tickets'][0]['priority'] == 'critical'; "
            "assert plan['tickets'][0]['dispatch_trade'] == 'refrigeration'; "
            "assert plan['tickets'][0]['sla_deadline'] == '2026-07-08T10:30:00Z'"
        ),
    ],
    cwd=repo,
    text=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    timeout=30,
)
ok = (
    {"red", "green", "refactor"}.issubset(set(phases))
    and test_proc.returncode == 0
    and smoke_proc.returncode == 0
)
(repo / "validate-marker.txt").write_text(
    "validate command executed\n",
    encoding="utf-8",
)
print(json.dumps({
    "ok": ok,
    "command": "bench-validate",
    "slice_count": len(slices),
    "phases": phases,
    "tests_passed": test_proc.returncode == 0,
    "domain_smoke_passed": smoke_proc.returncode == 0,
    "test_stdout": test_proc.stdout[-2000:],
    "test_stderr": test_proc.stderr[-4000:],
    "smoke_stderr": smoke_proc.stderr[-2000:],
    "learning_feedback": [
        {
            "id": "fieldops-cold-chain-escalation",
            "source": "validation-feedback",
            "target_type": "heavy-task",
            "target_name": "direct-plan-validate",
            "severity": "medium",
            "summary": (
                "Validation discovered a reusable FieldOps invariant: cold-chain outage "
                "keywords such as freezer down or product warming must override lower "
                "explicit severity and produce a critical refrigeration dispatch with a "
                "30-minute SLA."
            ),
            "evidence": {
                "validator": "bench-validate",
                "test": "test_freezer_down_routes_first_with_refrigeration_sla",
                "smoke": "freezer-down medium severity -> critical refrigeration 30-minute SLA",
                "passed": ok,
            },
            "metadata": {
                "feedback_kind": "validation-discovered-domain-invariant",
                "fixture": "fieldops-triage",
            },
        }
    ] if ok else [],
    "saw_generated_slices": any(
        item.get("generated_by") == "legion-run.default-tdd-planner"
        for item in slices
    ),
}, sort_keys=True))
raise SystemExit(0 if ok else 1)
PY
SH

cat > "$fake_bin/legion-doctor" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'doctor\n' >> "$LEGION_RUN_BENCH_CALL_LOG"
printf '{"ok":true,"fail":0,"warn":0,"source":"legion-run-direct-smoke"}\n'
SH

cat > "$fake_bin/legion-route" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
archetype="${1:-unknown}"
printf 'route:%s\n' "$archetype" >> "$LEGION_RUN_BENCH_CALL_LOG"
python3 - "$archetype" <<'PY'
import json
import sys

archetype = sys.argv[1]
is_final_review = archetype == "final-review"
sandbox = "read-only" if is_final_review else "workspace-write"
print(json.dumps({
    "executor": "claude" if is_final_review else "codex",
    "model": "test-model-claude" if is_final_review else "test-model-beta",
    "model_ref": "claude_default" if is_final_review else "codex_workhorse",
    "sandbox": sandbox,
    "reasoning_effort": "high" if is_final_review else "xhigh",
    "resolved": True,
}, sort_keys=True))
PY
SH

cat > "$fake_bin/legion-fanout" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'fanout-apply\n' >> "$LEGION_RUN_BENCH_CALL_LOG"
slices=""
repo=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --slices) slices="${2:-}"; shift 2 ;;
    --repo) repo="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done
python3 - "$slices" "$repo" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
repo = Path(sys.argv[2])
count = 0
if path.exists():
    count = sum(1 for line in path.read_text(encoding="utf-8").splitlines() if line.strip())

(repo / "fieldops").mkdir(parents=True, exist_ok=True)
(repo / "tests").mkdir(parents=True, exist_ok=True)

(repo / "fieldops" / "triage.py").write_text(
    '''"""SLA triage for FieldOps maintenance tickets."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Any, Iterable


PRIORITY_RANK = {"critical": 0, "high": 1, "medium": 2, "low": 3}
SLA_MINUTES = {"critical": 30, "high": 120, "medium": 480, "low": 1440}
CRITICAL_KEYWORDS = ("freezer down", "product warming", "flood", "active leak")
HIGH_KEYWORDS = ("offline", "no power", "alarm", "blocked exit")


def _text(value: Any) -> str:
    return str(value or "").strip()


def _parse_opened_at(value: Any) -> datetime:
    text = _text(value)
    if not text:
        raise ValueError("opened_at is required")
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError as exc:
        raise ValueError("opened_at must be ISO-8601") from exc
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc).replace(microsecond=0)


def _format_utc(value: datetime) -> str:
    return value.astimezone(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _priority(severity: str, summary: str, asset: str) -> str:
    haystack = f"{summary} {asset}".lower()
    severity = severity.lower()
    if severity == "critical" or any(keyword in haystack for keyword in CRITICAL_KEYWORDS):
        return "critical"
    if severity == "high" or any(keyword in haystack for keyword in HIGH_KEYWORDS):
        return "high"
    if severity in {"medium", "low"}:
        return severity
    return "medium"


def _dispatch_trade(summary: str, asset: str) -> str:
    haystack = f"{summary} {asset}".lower()
    if any(word in haystack for word in ("freezer", "fridge", "cooler", "refrigerat")):
        return "refrigeration"
    if any(word in haystack for word in ("leak", "water", "drain", "plumb")):
        return "plumbing"
    if any(word in haystack for word in ("power", "breaker", "electrical", "lighting")):
        return "electrical"
    return "facilities"


def _tags(priority: str, summary: str, asset: str) -> list[str]:
    haystack = f"{summary} {asset}".lower()
    tags = {priority}
    if any(word in haystack for word in ("freezer", "fridge", "cooler", "refrigerat")):
        tags.add("cold-chain")
    if any(keyword in haystack for keyword in CRITICAL_KEYWORDS + HIGH_KEYWORDS):
        tags.add("keyword-escalated")
    return sorted(tags)


def normalize_ticket(raw: dict[str, Any]) -> dict[str, Any]:
    if not isinstance(raw, dict):
        raise ValueError("ticket must be a mapping")
    required = ["id", "site", "asset", "summary", "opened_at"]
    missing = [field for field in required if not _text(raw.get(field))]
    if missing:
        raise ValueError(f"missing required ticket fields: {', '.join(missing)}")

    opened_at = _parse_opened_at(raw["opened_at"])
    summary = _text(raw["summary"])
    asset = _text(raw["asset"])
    severity = _text(raw.get("severity") or "medium").lower()
    priority = _priority(severity, summary, asset)
    deadline = opened_at + timedelta(minutes=SLA_MINUTES[priority])

    return {
        "id": _text(raw["id"]),
        "site": _text(raw["site"]),
        "asset": asset,
        "summary": summary,
        "severity": severity,
        "priority": priority,
        "dispatch_trade": _dispatch_trade(summary, asset),
        "opened_at": _format_utc(opened_at),
        "sla_minutes": SLA_MINUTES[priority],
        "sla_deadline": _format_utc(deadline),
        "tags": _tags(priority, summary, asset),
    }


def build_dispatch_plan(tickets: Iterable[dict[str, Any]]) -> dict[str, Any]:
    normalized = [normalize_ticket(ticket) for ticket in tickets]
    ordered = sorted(
        normalized,
        key=lambda ticket: (
            PRIORITY_RANK[ticket["priority"]],
            ticket["sla_deadline"],
            ticket["opened_at"],
            ticket["id"],
        ),
    )
    return {
        "total": len(ordered),
        "critical": sum(1 for ticket in ordered if ticket["priority"] == "critical"),
        "tickets": ordered,
    }
''',
    encoding="utf-8",
)

(repo / "tests" / "test_triage.py").write_text(
    '''import unittest

from fieldops.triage import build_dispatch_plan, normalize_ticket


class FieldOpsTriageTests(unittest.TestCase):
    def test_freezer_down_routes_first_with_refrigeration_sla(self):
        plan = build_dispatch_plan([
            {
                "id": "T-100",
                "site": "Store 42",
                "asset": "walk-in freezer",
                "summary": "walk-in freezer down and product warming",
                "severity": "medium",
                "opened_at": "2026-07-08T10:00:00Z",
            },
            {
                "id": "T-200",
                "site": "Store 42",
                "asset": "front door",
                "summary": "door closer is noisy",
                "severity": "low",
                "opened_at": "2026-07-08T09:00:00Z",
            },
        ])

        first = plan["tickets"][0]
        self.assertEqual(plan["critical"], 1)
        self.assertEqual(first["id"], "T-100")
        self.assertEqual(first["priority"], "critical")
        self.assertEqual(first["dispatch_trade"], "refrigeration")
        self.assertEqual(first["sla_deadline"], "2026-07-08T10:30:00Z")
        self.assertIn("cold-chain", first["tags"])

    def test_keyword_escalates_low_severity_report(self):
        ticket = normalize_ticket({
            "id": "T-300",
            "site": "Store 7",
            "asset": "rear exit",
            "summary": "blocked exit alarm offline",
            "severity": "low",
            "opened_at": "2026-07-08T11:00:00+00:00",
        })

        self.assertEqual(ticket["priority"], "high")
        self.assertEqual(ticket["sla_deadline"], "2026-07-08T13:00:00Z")
        self.assertIn("keyword-escalated", ticket["tags"])

    def test_orders_by_priority_then_deadline_then_id(self):
        plan = build_dispatch_plan([
            {
                "id": "T-9",
                "site": "A",
                "asset": "lights",
                "summary": "lighting flickers",
                "severity": "low",
                "opened_at": "2026-07-08T08:00:00Z",
            },
            {
                "id": "T-2",
                "site": "A",
                "asset": "sink",
                "summary": "active leak under prep sink",
                "severity": "medium",
                "opened_at": "2026-07-08T12:00:00Z",
            },
            {
                "id": "T-1",
                "site": "A",
                "asset": "breaker",
                "summary": "no power at checkout",
                "severity": "medium",
                "opened_at": "2026-07-08T09:00:00Z",
            },
        ])

        self.assertEqual([ticket["id"] for ticket in plan["tickets"]], ["T-2", "T-1", "T-9"])

    def test_missing_required_fields_raise_clear_error(self):
        with self.assertRaisesRegex(ValueError, "missing required ticket fields: site, opened_at"):
            normalize_ticket({
                "id": "T-404",
                "asset": "freezer",
                "summary": "freezer down",
                "severity": "critical",
            })


if __name__ == "__main__":
    unittest.main()
''',
    encoding="utf-8",
)

changed = ["fieldops/triage.py", "tests/test_triage.py"]
print(json.dumps({
    "ok": True,
    "applied": count,
    "failed": 0,
    "changed_files": changed,
    "results": [{"status": "applied", "id": f"slice-{idx}", "changed_files": changed} for idx in range(count)],
}, sort_keys=True))
PY
SH

cat > "$fake_bin/legion-delegate" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'delegate-review\n' >> "$LEGION_RUN_BENCH_CALL_LOG"
printf '{"status":"ok","verdict":"approved","model":"test-model-beta","findings":[]}\n'
SH

cat > "$fake_bin/legion-claude" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'claude-review\n' >> "$LEGION_RUN_BENCH_CALL_LOG"
printf '{"status":"ok","model":"test-model-claude","result":"{\\"verdict\\":\\"approve\\",\\"summary\\":\\"independent review approved\\",\\"findings\\":[]}"}\n'
SH

cat > "$fake_bin/legion-report" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'report\n' >> "$LEGION_RUN_BENCH_CALL_LOG"
printf '{"ok":true,"html":"legion-observability.html","source":"legion-run-direct-smoke"}\n'
SH

cat > "$fake_bin/legion-share" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'share\n' >> "$LEGION_RUN_BENCH_CALL_LOG"
printf '{"status":"met","target":0.5,"codex_runs":5,"opus_runs":0,"failed_runs":0}\n'
SH

cat > "$fake_bin/legion-heal" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'heal-plan\n' >> "$LEGION_RUN_BENCH_CALL_LOG"
printf '{"ok":true,"findings":0,"fixable":0,"source":"legion-run-direct-smoke"}\n'
SH

chmod +x "$fake_bin"/*

"$source_repo/legion-observability/bin/legion-self-learn" record \
  --logs "$LEGION_STATE_ROOT" \
  --entity heavy-task:direct-plan-validate \
  --summary "Prior direct legion-run benchmark hint must be loaded before planning." \
  --source legion-run-direct-benchmark \
  --evidence "seeded by legion-run direct benchmark" \
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
  --name direct-plan-validate \
  --allow-generated-slices \
  --plan-command bench-plan \
  --validate-command bench-validate \
  --json > "$stdout_path" 2> "$stderr_path"
run_status=$?
set -e

python3 - "$run_status" "$stdout_path" "$stderr_path" "$call_log" "$result_path" "$target_repo" "$state_root" "$memory_before_path" <<'PY'
import html
import json
import os
import sys
from pathlib import Path

run_status = int(sys.argv[1])
stdout_path = Path(sys.argv[2])
stderr_path = Path(sys.argv[3])
call_log_path = Path(sys.argv[4])
result_path = Path(sys.argv[5])
target_repo = Path(sys.argv[6])
state_root = Path(sys.argv[7])
memory_before_path = Path(sys.argv[8])

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
required = summary.get("pipeline", {}).get("required_artifacts", [])
stage_status = summary.get("stage_status", [])
calls = call_log_path.read_text(encoding="utf-8").splitlines() if call_log_path.exists() else []

def artifact(name):
    return read_json(run_dir / name) if run_dir else {}

def has_artifact(name):
    return bool(run_dir) and (run_dir / name).is_file() and (run_dir / name).stat().st_size > 0

def called_in_order(names):
    pos = -1
    for name in names:
        try:
            next_pos = next(idx for idx, call in enumerate(calls) if idx > pos and call == name)
        except StopIteration:
            return False
        pos = next_pos
    return True

slices = read_jsonl(run_dir / "slices.jsonl") if run_dir else []
routes = artifact("routes.json").get("routes", [])
fanout = artifact("fanout.json")
learning_feedback = artifact("learning-feedback.json")
self_learn = artifact("self-learn.json")
self_learn_hints = artifact("self-learn-hints.json")
memory = read_json(state_root / "self-learn" / "harness-memory.json")
memory_before = read_json(memory_before_path)
eval_json = artifact("eval.json")
validation = artifact("validation.json")
record = self_learn.get("record", {})
run_payload = self_learn.get("run", {})
memory_key = "heavy-task:direct-plan-validate"
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
overview_path = result_path.with_name("legion-run-direct-benchmark.html")
run_report_path = run_dir / "legion-report.html"
observability_path = run_dir / "legion-observability.html"
artifact_manifest_path = run_dir / "artifact-manifest.json"

checks = {
    "run_exited_zero": run_status == 0,
    "contract_is_direct": summary.get("runner", {}).get("mode") == "direct",
    "profile_is_heavy_task": summary.get("pipeline", {}).get("profile") == "legion.heavy_task.v1",
    "required_artifacts_present": bool(required) and all(has_artifact(name) for name in required),
    "all_stages_passed": bool(stage_status) and all(item.get("status") == "passed" for item in stage_status),
    "plan_command_used": "plan-command" in calls and artifact("plan-command.json").get("exit_code") == 0,
    "default_slices_generated": len(slices) == 5 and any(
        item.get("generated_by") == "legion-run.default-tdd-planner" for item in slices
    ),
    "routes_generated_for_all_slices": len(routes) == len(slices) and len(routes) > 0,
    "fanout_apply_ran": "fanout-apply" in calls and fanout.get("failed") == 0,
    "final_review_ran": (
        "claude-review" in calls
        and "approve" in str(artifact("review.json").get("result", ""))
    ),
    "validate_command_used": (
        "validate-command" in calls
        and validation.get("command") == "bench-validate"
        and validation.get("ok") is True
        and (target_repo / "validate-marker.txt").exists()
    ),
    "coding_task_implemented": (
        validation.get("tests_passed") is True
        and validation.get("domain_smoke_passed") is True
        and {"fieldops/triage.py", "tests/test_triage.py"}.issubset(set(fanout.get("changed_files", [])))
        and "def build_dispatch_plan" in triage_text
        and "CRITICAL_KEYWORDS" in triage_text
        and "test_freezer_down_routes_first_with_refrigeration_sla" in test_text
    ),
    "default_eval_used": eval_json.get("skipped") is True and "no evaluate command" in eval_json.get("reason", ""),
    "report_and_share_ran": (
        "report" in calls
        and "share" in calls
        and artifact("share.json").get("status") == "met"
        and has_artifact("legion-observability.html")
    ),
    "hints_consumed": memory_key in self_learn_hints.get("entities", {}),
    "self_learning_recorded": (
        record.get("schema") == "legion.outcome.v1"
        and record.get("target_type") == "heavy-task"
        and record.get("target_name") == "direct-plan-validate"
    ),
    "self_learning_memory_applied": (
        run_payload.get("applied_memory") is True
        and memory_key in memory.get("entities", {})
    ),
    "validation_feedback_recorded": (
        learning_feedback.get("recorded") == 1
        and learning_feedback.get("outcomes", [{}])[0].get("source") == "validation-feedback"
        and learning_feedback.get("outcomes", [{}])[0].get("target_name") == "direct-plan-validate"
    ),
    "self_learning_memory_updated_by_validation_feedback": (
        bool(proposal_ids - proposal_ids_before)
        and any("Validation discovered a reusable FieldOps invariant" in hint for hint in hints)
        and any("cold-chain outage" in hint for hint in hints)
        and any(hint not in hints_before for hint in hints)
        and run_payload.get("summary", {}).get("outcomes", 0) >= 1
    ),
    "heal_plan_ran": "heal-plan" in calls and artifact("heal-plan.json").get("ok") is True,
    "stage_order_preserved": called_in_order([
        "doctor",
        "plan-command",
        "fanout-apply",
        "validate-command",
        "claude-review",
        "report",
        "share",
        "heal-plan",
    ]),
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
    memory_hint = next((hint for hint in hints if "Validation discovered" in str(hint)), "")
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
  <title>Legion Run Direct Benchmark</title>
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
  <h1>Legion Run Direct Benchmark</h1>
  <p class="subtle">A no-spend demo benchmark that runs the real <code>legion-run</code> direct path against a temporary FieldOps coding task.</p>

  <div class="grid">
    <div class="panel"><div class="metric">{esc("PASS" if all(checks.values()) else "FAIL")}</div><div>Overall result</div></div>
    <div class="panel"><div class="metric">{esc(len(slices))}</div><div>TDD slices generated</div></div>
    <div class="panel"><div class="metric">{esc(validation.get("slice_count", 0))}</div><div>Validated slices</div></div>
    <div class="panel"><div class="metric">{esc(learning_feedback.get("recorded", 0))}</div><div>Validation lessons recorded</div></div>
  </div>

  <h2>Task</h2>
  <p>Implement FieldOps SLA triage: normalize tickets, infer priority from cold-chain and operational keywords, assign dispatch trades and SLA deadlines, sort the dispatch queue, and cover the behavior with Python unittest tests.</p>

  <h2>Open The Evidence</h2>
  <ul>{link_items}</ul>

  <h2>Lifecycle Stages</h2>
  <table><thead><tr><th>Stage</th><th>Status</th><th>Artifacts</th></tr></thead><tbody>{stage_rows}</tbody></table>

  <h2>Benchmark Checks</h2>
  <table><thead><tr><th>Check</th><th>Status</th></tr></thead><tbody>{check_rows}</tbody></table>

  <h2>Validation-Discovered Learning</h2>
  <p><strong>Outcome:</strong> {esc(feedback.get("summary"))}</p>
  <p><strong>Memory hint written:</strong> {esc(memory_hint)}</p>
  <details open><summary>learning-feedback.json</summary>{pre(json_pretty(learning_feedback))}</details>
  <details><summary>self-learn.json</summary>{pre(json_pretty(self_learn))}</details>

  <h2>Implemented Code</h2>
  <details><summary>fieldops/triage.py</summary>{pre(triage_text)}</details>
  <details><summary>tests/test_triage.py</summary>{pre(test_text)}</details>

  <h2>Raw Run Contract</h2>
  <details><summary>legion-run stdout contract</summary>{pre(json_pretty(summary))}</details>
</body>
</html>
"""

overview_path.write_text(render_overview(), encoding="utf-8")
checks["html_reports_generated"] = (
    overview_path.exists()
    and run_report_path.exists()
    and observability_path.exists()
    and "Validation-Discovered Learning" in overview_path.read_text(encoding="utf-8")
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
    "calls": calls,
    "contract": summary,
    "stderr": stderr_path.read_text(encoding="utf-8")[-4000:] if stderr_path.exists() else "",
}
result_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(json.dumps(payload, indent=2, sort_keys=True))
raise SystemExit(0 if payload["ok"] else 1)
PY
