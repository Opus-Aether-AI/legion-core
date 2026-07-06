#!/usr/bin/env python3
"""legion-run — enforced lifecycle runner for Legion heavy tasks.

Callers supply the task-specific pieces (plan, validate, evaluate), either
directly or through a domain plugin. Legion Core owns the fixed stage order and
evidence contract.
"""

from __future__ import annotations

import argparse
import datetime as dt
import html
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover - py<3.11
    tomllib = None


SCRIPT_DIR = Path(__file__).resolve().parent
ROOT = SCRIPT_DIR.parents[1]
OBS_SCRIPTS = ROOT / "legion-observability" / "scripts"
sys.path.insert(0, str(OBS_SCRIPTS))
import legion_state  # noqa: E402


HEAVY_TASK_PROFILE = "legion.heavy_task.v1"
FULL_APP_PROFILE = "legion.full_app.v1"
SUPPORTED_PROFILES = {HEAVY_TASK_PROFILE, FULL_APP_PROFILE}
PIPELINE_STAGES = [
    "doctor",
    "self-learn-hints",
    "plan",
    "route",
    "fanout-apply",
    "review",
    "validate",
    "evaluate",
    "report",
    "share",
    "self-learn",
    "heal-plan",
]
PIPELINE_REQUIRED_ARTIFACTS = [
    "doctor.json",
    "self-learn-hints.json",
    "plan.json",
    "slices.jsonl",
    "routes.json",
    "fanout.json",
    "review.json",
    "validation.json",
    "eval.json",
    "legion-report.json",
    "legion-report.html",
    "legion-observability.html",
    "share.json",
    "self-learn.json",
    "heal-plan.json",
    "artifact-manifest.json",
]
PIPELINE_STAGE_ARTIFACTS = {
    "doctor": ["doctor.json"],
    "self-learn-hints": ["self-learn-hints.json"],
    "plan": ["plan.json", "slices.jsonl"],
    "route": ["routes.json"],
    "fanout-apply": ["fanout.json"],
    "review": ["review.json"],
    "validate": ["validation.json"],
    "evaluate": ["eval.json"],
    "report": ["legion-report.json", "legion-report.html", "legion-observability.html"],
    "share": ["share.json"],
    "self-learn": ["self-learn.json"],
    "heal-plan": ["heal-plan.json"],
}

COMMAND_FALLBACKS = {
    "legion-doctor": ROOT / "legion-observability" / "bin" / "legion-doctor",
    "legion-self-learn": ROOT / "legion-observability" / "bin" / "legion-self-learn",
    "legion-report": ROOT / "legion-observability" / "bin" / "legion-report",
    "legion-share": ROOT / "legion-observability" / "bin" / "legion-share",
    "legion-heal": ROOT / "legion-observability" / "bin" / "legion-heal",
    "legion-route": ROOT / "legion-router" / "bin" / "legion-route",
    "legion-delegate": ROOT / "legion-router" / "bin" / "legion-delegate",
    "legion-fanout": ROOT / "legion-orchestrate" / "bin" / "legion-fanout",
}


class LegionRunError(RuntimeError):
    def __init__(self, message: str, code: int = 2):
        super().__init__(message)
        self.code = code


def _strip_inline_comment(line: str) -> str:
    in_string = False
    quote = ""
    escaped = False
    out: list[str] = []
    for ch in line:
        if escaped:
            out.append(ch)
            escaped = False
            continue
        if ch == "\\" and in_string:
            out.append(ch)
            escaped = True
            continue
        if ch in {"'", '"'} and (not in_string or quote == ch):
            in_string = not in_string
            quote = ch if in_string else ""
            out.append(ch)
            continue
        if ch == "#" and not in_string:
            break
        out.append(ch)
    return "".join(out).strip()


def _parse_scalar(raw: str) -> Any:
    raw = raw.strip()
    if raw in {"true", "false"}:
        return raw == "true"
    if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in {"'", '"'}:
        return raw[1:-1]
    return raw


def _load_toml(path: Path) -> dict[str, Any]:
    if tomllib is not None:
        with path.open("rb") as handle:
            data = tomllib.load(handle)
        return data if isinstance(data, dict) else {}

    data: dict[str, Any] = {}
    current: dict[str, Any] | None = None
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = _strip_inline_comment(raw)
        if not line:
            continue
        if line.startswith("[") and line.endswith("]"):
            current = data
            for part in line[1:-1].split("."):
                current = current.setdefault(part.strip(), {})
            continue
        if current is not None and "=" in line:
            key, value = line.split("=", 1)
            current[key.strip()] = _parse_scalar(value)
    return data


def _cmd(name: str) -> str:
    found = shutil.which(name)
    if found:
        return found
    fallback = COMMAND_FALLBACKS.get(name)
    if fallback and fallback.exists():
        return str(fallback)
    raise LegionRunError(f"required command not found: {name}", 2)


def _json_or_text(text: str) -> Any:
    stripped = text.strip()
    if not stripped:
        return {}
    try:
        return json.loads(stripped)
    except json.JSONDecodeError:
        return {"ok": True, "output": stripped}


def _write_json(path: Path, payload: Any) -> None:
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def _write_jsonl(path: Path, rows: list[dict[str, Any]]) -> None:
    path.write_text(
        "\n".join(json.dumps(row, sort_keys=True) for row in rows) + "\n",
        encoding="utf-8",
    )


def _slug(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-") or "plugin"


def _manifest_candidates(repo: Path, plugin: str) -> list[Path]:
    return [
        repo / ".legion" / "plugins" / plugin / "legion-plugin.toml",
        repo / ".legion" / "plugins" / plugin / "plugin.toml",
        repo / ".legion" / f"{plugin}.toml",
    ]


def find_manifest(repo: Path, plugin: str, explicit: str = "") -> Path:
    if explicit:
        path = Path(explicit).expanduser()
        return path if path.is_absolute() else (Path.cwd() / path).resolve()
    if not plugin:
        raise LegionRunError("--plugin/--plugin-manifest or --plan-command/--plan-file is required")
    for candidate in _manifest_candidates(repo, plugin):
        if candidate.exists():
            return candidate.resolve()
    raise LegionRunError(f"domain plugin manifest not found for '{plugin}'")


def load_plugin(manifest_path: Path, requested_plugin: str = "", requested_profile: str = "") -> dict[str, Any]:
    if not manifest_path.exists():
        raise LegionRunError(f"domain plugin manifest not found: {manifest_path}")
    data = _load_toml(manifest_path)
    plugin = data.get("plugin") if isinstance(data.get("plugin"), dict) else {}
    pipeline = data.get("pipeline") if isinstance(data.get("pipeline"), dict) else {}
    commands = data.get("commands") if isinstance(data.get("commands"), dict) else {}

    name = str(plugin.get("name") or requested_plugin or "").strip()
    kind = str(plugin.get("kind") or "").strip()
    profile = str(pipeline.get("profile") or "").strip()
    entrypoint = str(pipeline.get("entrypoint") or "").strip()

    if not name:
        raise LegionRunError("domain plugin manifest missing [plugin].name")
    if requested_plugin and name != requested_plugin:
        raise LegionRunError(f"domain plugin manifest name '{name}' does not match --plugin '{requested_plugin}'")
    if not kind.startswith("domain-"):
        raise LegionRunError("domain plugin manifest must set [plugin].kind to a domain-* value")
    if entrypoint != "legion-run":
        raise LegionRunError("domain plugin must run through legion-run: set [pipeline].entrypoint = \"legion-run\"")
    if requested_profile and profile != requested_profile:
        raise LegionRunError(f"domain plugin must use approved profile '{requested_profile}'")
    if profile not in SUPPORTED_PROFILES:
        raise LegionRunError(f"unsupported pipeline profile: {profile}")

    required_commands = ["plan", "validate", "evaluate"]
    missing = [key for key in required_commands if not str(commands.get(key) or "").strip()]
    if missing:
        raise LegionRunError(f"domain plugin manifest missing commands: {', '.join(missing)}")

    return {
        "name": name,
        "kind": kind,
        "manifest": str(manifest_path),
        "mode": "plugin",
        "target_type": "plugin",
        "pipeline": {"profile": profile, "entrypoint": entrypoint},
        "commands": {key: str(commands[key]).strip() for key in required_commands},
    }


def build_direct_runner(args: argparse.Namespace) -> dict[str, Any]:
    profile = args.profile or HEAVY_TASK_PROFILE
    if profile not in SUPPORTED_PROFILES:
        raise LegionRunError(f"unsupported pipeline profile: {profile}")
    name = _slug(args.name or args.task or "heavy-task")
    plan_command = str(args.plan_command or "").strip()
    plan_file = str(args.plan_file or "").strip()
    validate_command = str(args.validate_command or "").strip()
    evaluate_command = str(args.evaluate_command or "").strip()
    if not plan_command and not plan_file:
        raise LegionRunError("direct heavy-task mode requires --plan-command or --plan-file")
    if not validate_command:
        raise LegionRunError("direct heavy-task mode requires --validate-command")
    if not evaluate_command:
        evaluate_command = "printf '{\"ok\":true,\"skipped\":true,\"reason\":\"no evaluate command supplied\"}\\n'"
    return {
        "name": name,
        "kind": "heavy-task",
        "manifest": "",
        "mode": "direct",
        "target_type": "heavy-task",
        "pipeline": {"profile": profile, "entrypoint": "legion-run"},
        "commands": {
            "plan": plan_command,
            "validate": validate_command,
            "evaluate": evaluate_command,
        },
        "plan_file": plan_file,
    }


def contract_payload(runner: dict[str, Any], repo: Path, task: str) -> dict[str, Any]:
    return {
        "schema": "legion.run.contract.v1",
        "runner": {
            "mode": runner.get("mode", "plugin"),
            "name": runner["name"],
            "kind": runner["kind"],
        },
        "plugin": {
            "name": runner["name"],
            "kind": runner["kind"],
            "manifest": runner.get("manifest", ""),
        },
        "repo": str(repo),
        "task": task,
        "pipeline": {
            "profile": runner["pipeline"]["profile"],
            "stages": PIPELINE_STAGES,
            "required_artifacts": PIPELINE_REQUIRED_ARTIFACTS,
        },
    }


def run_process(argv: list[str], env: dict[str, str], cwd: Path, artifact: Path, *, shell: bool = False) -> Any:
    if shell:
        proc = subprocess.run(
            argv[0],
            shell=True,
            cwd=str(cwd),
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    else:
        proc = subprocess.run(
            argv,
            cwd=str(cwd),
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    payload = _json_or_text(proc.stdout)
    if isinstance(payload, dict):
        payload.setdefault("exit_code", proc.returncode)
        if proc.stderr.strip():
            payload.setdefault("stderr", proc.stderr.strip())
    _write_json(artifact, payload)
    if proc.returncode != 0:
        raise LegionRunError(f"stage failed ({artifact.name}): exit {proc.returncode}", 1)
    return payload


def _load_json_object(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {}
    return value if isinstance(value, dict) else {}


def _as_text(value: Any, fallback: str = "") -> str:
    if value is None:
        return fallback
    text = str(value).strip()
    return text or fallback


def _as_text_list(value: Any) -> list[str]:
    if isinstance(value, list):
        return [str(item).strip() for item in value if str(item).strip()]
    if isinstance(value, str) and value.strip():
        return [value.strip()]
    return []


def _sentence(label: str, items: list[str]) -> str:
    if not items:
        return ""
    return f"{label}: {', '.join(items)}. "


def default_tdd_slices(plan: dict[str, Any], plugin: dict[str, Any], task: str) -> list[dict[str, Any]]:
    """Create a compact TDD work queue from a plugin planning brief."""
    app = _as_text(plan.get("app") or plan.get("product"), plugin["name"])
    instruction = _as_text(
        plan.get("planning_instruction"),
        "Build the requested app TDD style: write failing tests first, implement the minimum code to pass, then refactor after green.",
    )
    context_files = _as_text_list(plan.get("context_files") or plan.get("plan_source"))
    skills = _as_text_list(plan.get("required_skills") or plan.get("legion_code_skills"))
    gates = _as_text_list(plan.get("quality_gates"))
    eval_goal = _as_text(plan.get("eval_goal"), "the requested domain workflow works end to end")

    context = (
        f"{instruction} "
        f"Task: {task}. "
        f"App/domain: {app}. "
        f"{_sentence('Read these context files first', context_files)}"
        f"{_sentence('Use these skills when relevant', skills)}"
    ).strip()
    gate_text = ", ".join(gates) if gates else "lint, typecheck, tests, build, and any repo-native E2E gate"

    common = {
        "generated_by": "legion-run.default-tdd-planner",
        "plugin": plugin["name"],
        "profile": plugin["pipeline"]["profile"],
        "source_plan_mode": _as_text(plan.get("mode"), "legion-generate-slices"),
    }
    return [
        {
            **common,
            "id": "red-core-tests",
            "phase": "red",
            "archetype": "write-tests",
            "task": (
                f"RED: {context} Add failing unit/integration tests for the core domain, "
                "data contracts, AI/schema fallbacks, scheduling or business rules, and API/service boundaries. "
                "Do not implement production code in this slice."
            ),
        },
        {
            **common,
            "id": "green-core-implementation",
            "phase": "green",
            "depends_on": ["red-core-tests"],
            "archetype": "implement-feature",
            "task": (
                f"GREEN: {context} Implement the minimal backend/domain/AI/persistence code needed "
                "to make the red core tests pass. Keep deterministic fallbacks for missing external services."
            ),
        },
        {
            **common,
            "id": "red-demo-flow-tests",
            "phase": "red",
            "depends_on": ["green-core-implementation"],
            "archetype": "write-tests",
            "task": (
                f"RED: Add failing browser or integration tests for the main demo workflow. "
                f"The eval goal is: {eval_goal}. Cover the user-visible path plus export/report evidence."
            ),
        },
        {
            **common,
            "id": "green-demo-flow",
            "phase": "green",
            "depends_on": ["red-demo-flow-tests"],
            "archetype": "implement-feature",
            "task": (
                f"GREEN: Build the UI/API/demo workflow needed to pass the demo-flow tests for {app}. "
                "Keep the first screen usable, local-first, and backed by fixed seed data."
            ),
        },
        {
            **common,
            "id": "refactor-and-gate",
            "phase": "refactor",
            "depends_on": ["green-demo-flow"],
            "archetype": "refactor-module",
            "task": (
                f"REFACTOR: Clean boundaries, remove duplication, update demo docs, and run gates: {gate_text}. "
                "Keep behavior green and leave clear evidence for validation and evaluation."
            ),
        },
    ]


def has_jsonl_rows(path: Path) -> bool:
    if not path.exists():
        return False
    return any(line.strip() for line in path.read_text(encoding="utf-8", errors="replace").splitlines())


def ensure_slices(path: Path, plan_path: Path, plugin: dict[str, Any], task: str) -> None:
    if has_jsonl_rows(path):
        return
    plan = _load_json_object(plan_path)
    slices = default_tdd_slices(plan, plugin, task)
    _write_jsonl(path, slices)


def load_slices(path: Path) -> list[dict[str, Any]]:
    slices: list[dict[str, Any]] = []
    if not path.exists():
        raise LegionRunError("plan did not create slices.jsonl")
    for idx, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        if not raw.strip():
            continue
        try:
            item = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise LegionRunError(f"invalid slices.jsonl line {idx}: {exc}") from exc
        if not isinstance(item, dict):
            raise LegionRunError(f"invalid slices.jsonl line {idx}: expected object")
        slices.append(item)
    if not slices:
        raise LegionRunError("plan produced no slices")
    return slices


def write_plan_from_file(plan_file: str, plan_path: Path, runner: dict[str, Any], task: str, base_dir: Path) -> dict[str, Any]:
    source = Path(plan_file).expanduser()
    if not source.is_absolute():
        source = (base_dir / source).resolve()
    if not source.exists():
        raise LegionRunError(f"plan file not found: {source}")
    text = source.read_text(encoding="utf-8", errors="replace")
    if source.suffix.lower() == ".json":
        try:
            payload = json.loads(text)
        except json.JSONDecodeError as exc:
            raise LegionRunError(f"invalid plan JSON: {exc}") from exc
        if not isinstance(payload, dict):
            raise LegionRunError("plan JSON must be an object")
    else:
        payload = {
            "schema": "legion.heavy-task.plan.v1",
            "mode": "legion-generate-slices",
            "task": task,
            "planning_instruction": text.strip(),
            "plan_source": str(source),
        }
    payload.setdefault("schema", "legion.heavy-task.plan.v1")
    payload.setdefault("mode", "legion-generate-slices")
    payload.setdefault("task", task)
    payload["runner"] = runner["name"]
    payload["profile"] = runner["pipeline"]["profile"]
    _write_json(plan_path, payload)
    return payload


def normalize_plan_file(plan_path: Path, runner: dict[str, Any], task: str) -> dict[str, Any]:
    if not plan_path.exists():
        payload: dict[str, Any] = {
            "schema": "legion.heavy-task.plan.v1",
            "mode": "legion-generate-slices",
            "runner": runner["name"],
            "task": task,
            "profile": runner["pipeline"]["profile"],
        }
        _write_json(plan_path, payload)
        return payload
    payload = _load_json_object(plan_path)
    payload.setdefault("schema", "legion.heavy-task.plan.v1")
    payload.setdefault("mode", "legion-generate-slices")
    payload.setdefault("task", task)
    payload["runner"] = runner["name"]
    payload["profile"] = runner["pipeline"]["profile"]
    _write_json(plan_path, payload)
    return payload


def _artifact_preview(run_dir: Path, artifact: str) -> str:
    path = run_dir / artifact
    if not path.exists():
        return "not generated yet"
    if path.suffix == ".html":
        return "HTML artifact generated alongside this report."
    text = path.read_text(encoding="utf-8", errors="replace")
    if artifact.endswith(".json"):
        try:
            text = json.dumps(json.loads(text), indent=2, sort_keys=True)
        except json.JSONDecodeError:
            pass
    return text[:20000]


def _new_stage_records() -> list[dict[str, Any]]:
    return [
        {
            "stage": stage,
            "status": "pending",
            "artifacts": PIPELINE_STAGE_ARTIFACTS.get(stage, []),
        }
        for stage in PIPELINE_STAGES
    ]


def _set_stage_status(stages: list[dict[str, Any]], stage: str, status: str, error: str = "") -> None:
    for item in stages:
        if item["stage"] == stage:
            item["status"] = status
            if error:
                item["error"] = error
            return


def _skip_pending_stages(stages: list[dict[str, Any]]) -> None:
    for item in stages:
        if item.get("status") == "pending":
            item["status"] = "skipped"


def write_stage_status(run_dir: Path, stages: list[dict[str, Any]]) -> None:
    _write_json(run_dir / "stage-status.json", {"schema": "legion.run.stage-status.v1", "stages": stages})


def write_artifact_manifest(run_dir: Path) -> dict[str, Any]:
    names = set(PIPELINE_REQUIRED_ARTIFACTS)
    names.update(path.name for path in run_dir.iterdir() if path.is_file())
    artifacts = []
    for name in sorted(names):
        path = run_dir / name
        artifacts.append(
            {
                "path": name,
                "exists": path.exists(),
                "size_bytes": path.stat().st_size if path.exists() else 0,
            }
        )
    payload = {"schema": "legion.artifact-manifest.v1", "artifacts": artifacts}
    _write_json(run_dir / "artifact-manifest.json", payload)
    return payload


def write_report_html(run_dir: Path, summary: dict[str, Any]) -> None:
    stage_records = summary.get("stage_status") or _load_json_object(run_dir / "stage-status.json").get("stages") or []
    if not stage_records:
        stage_records = _new_stage_records()
    status_label = {
        "passed": "PASS",
        "running": "RUNNING",
        "pending": "PENDING",
        "skipped": "SKIPPED",
        "failed": "FAILED",
    }
    rows = "\n".join(
        "<tr><td>{stage}</td><td><strong>{status}</strong>{error}</td><td>{artifacts}</td></tr>".format(
            stage=html.escape(str(item.get("stage", ""))),
            status=html.escape(status_label.get(str(item.get("status", "")), str(item.get("status", "")))),
            error=(
                "<br><small>{}</small>".format(html.escape(str(item.get("error", ""))))
                if item.get("error")
                else ""
            ),
            artifacts=", ".join(
                f'<a href="{html.escape(name)}"><code>{html.escape(name)}</code></a>'
                for name in item.get("artifacts", [])
            ),
        )
        for item in stage_records
    )
    artifacts = "\n".join(
        "<details><summary><code>{artifact}</code></summary><pre>{payload}</pre></details>".format(
            artifact=html.escape(artifact),
            payload=html.escape(_artifact_preview(run_dir, artifact)),
        )
        for artifact in PIPELINE_REQUIRED_ARTIFACTS
    )
    title = "Legion Heavy Task Pipeline" if summary.get("pipeline", {}).get("profile") == HEAVY_TASK_PROFILE else "Legion Domain Plugin Pipeline"
    failed = summary.get("failed_stage")
    failure_html = (
        f"<p><strong>Failed stage:</strong> {html.escape(str(failed))}</p>"
        f"<p><strong>Error:</strong> {html.escape(str(summary.get('error', '')))}</p>"
        if failed
        else ""
    )
    html_text = f"""<!doctype html>
<html><head><meta charset="utf-8"><title>Legion Run Report</title>
<style>body{{font-family:system-ui,sans-serif;margin:32px;line-height:1.45;color:#111827}}table{{border-collapse:collapse;width:100%;margin:16px 0}}td,th{{border:1px solid #d1d5db;padding:8px 10px;text-align:left;vertical-align:top}}code{{background:#f3f4f6;padding:2px 4px;border-radius:4px}}details{{border:1px solid #d1d5db;margin:8px 0;padding:8px 10px}}pre{{white-space:pre-wrap;overflow:auto;background:#f9fafb;padding:12px}}small{{color:#6b7280}}</style>
</head><body>
<h1>{html.escape(title)}</h1>
<p><strong>Runner:</strong> {html.escape(summary["runner"]["name"])} ({html.escape(summary["runner"]["mode"])})</p>
<p><strong>Profile:</strong> {html.escape(summary["pipeline"]["profile"])}</p>
<p><strong>Task:</strong> {html.escape(summary["task"])}</p>
{failure_html}
<h2>Stages</h2><table><thead><tr><th>Stage</th><th>Status</th><th>Output</th></tr></thead><tbody>{rows}</tbody></table>
<h2>Full Pipeline Outputs</h2>{artifacts}
</body></html>
"""
    (run_dir / "legion-report.html").write_text(html_text, encoding="utf-8")
    (run_dir / "legion-observability.html").write_text(html_text.replace("Run Report", "Observability"), encoding="utf-8")


def best_effort_process(argv: list[str], env: dict[str, str], cwd: Path, artifact: Path, *, shell: bool = False) -> Any:
    try:
        if shell:
            proc = subprocess.run(
                argv[0],
                shell=True,
                cwd=str(cwd),
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
        else:
            proc = subprocess.run(
                argv,
                cwd=str(cwd),
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
        payload = _json_or_text(proc.stdout)
        if isinstance(payload, dict):
            payload.setdefault("exit_code", proc.returncode)
            if proc.stderr.strip():
                payload.setdefault("stderr", proc.stderr.strip())
        _write_json(artifact, payload)
        return payload
    except Exception as exc:  # pragma: no cover - defensive finalization path
        payload = {"ok": False, "error": str(exc)}
        _write_json(artifact, payload)
        return payload


def execute(runner: dict[str, Any], repo: Path, task: str, json_output: bool) -> int:
    state = legion_state.resolve_state(str(repo))
    run_id = dt.datetime.utcnow().strftime("%Y%m%dT%H%M%SZ") + f"-{_slug(runner['name'])}"
    run_dir = Path(state["state_root"]) / "runs" / "legion-run" / run_id
    run_dir.mkdir(parents=True, exist_ok=True)
    profile = runner["pipeline"]["profile"]
    stages = _new_stage_records()
    current_stage = ""

    env = dict(os.environ)
    env.update(
        {
            "LEGION_STATE_ROOT": state["state_root"],
            "LEGION_TELEMETRY_DIR": state["telemetry_dir"],
            "LEGION_REGISTRY_DIR": state["registry_dir"],
            "LEGION_REPOS_FILE": state["repos_file"],
            "LEGION_BENCH_DIR": state["bench_dir"],
            "LEGION_REPORTS_DIR": state["reports_dir"],
            "LEGION_RUN_ID": run_id,
            "LEGION_RUN_DIR": str(run_dir),
            "LEGION_RUN_PLAN_FILE": str(run_dir / "plan.json"),
            "LEGION_RUN_SLICES_FILE": str(run_dir / "slices.jsonl"),
            "LEGION_REPO": str(repo),
            "LEGION_TASK": task,
            "LEGION_PLUGIN_NAME": runner["name"],
            "LEGION_RUNNER_NAME": runner["name"],
            "LEGION_RUNNER_MODE": runner.get("mode", "plugin"),
            "LEGION_PIPELINE_PROFILE": profile,
            "LEGION_TARGET_TYPE": runner.get("target_type", runner.get("mode", "plugin")),
            "LEGION_TARGET_NAME": runner["name"],
        }
    )

    def stage_run(stage: str, argv: list[str], artifact: Path, *, shell: bool = False) -> Any:
        nonlocal current_stage
        current_stage = stage
        _set_stage_status(stages, stage, "running")
        write_stage_status(run_dir, stages)
        payload = run_process(argv, env, repo, artifact, shell=shell)
        _set_stage_status(stages, stage, "passed")
        write_stage_status(run_dir, stages)
        return payload

    def finalize_success() -> dict[str, Any]:
        summary = contract_payload(runner, repo, task)
        summary.update({"ok": True, "run_id": run_id, "run_dir": str(run_dir), "stage_status": stages})
        _write_json(run_dir / "summary.json", summary)
        write_stage_status(run_dir, stages)
        write_artifact_manifest(run_dir)
        write_report_html(run_dir, summary)
        write_artifact_manifest(run_dir)
        missing = [artifact for artifact in PIPELINE_REQUIRED_ARTIFACTS if not (run_dir / artifact).exists()]
        if missing:
            raise LegionRunError(f"pipeline missing required artifacts: {', '.join(missing)}", 1)
        return summary

    def finalize_failure(exc: LegionRunError) -> dict[str, Any]:
        failed_stage = current_stage or "unknown"
        _set_stage_status(stages, failed_stage, "failed", str(exc))
        _skip_pending_stages(stages)
        write_stage_status(run_dir, stages)
        failure = {
            "schema": "legion.run.failure.v1",
            "failed_stage": failed_stage,
            "message": str(exc),
            "exit_code": exc.code,
            "run_id": run_id,
            "run_dir": str(run_dir),
        }
        _write_json(run_dir / "failure.json", failure)
        if not (run_dir / "legion-report.json").exists():
            best_effort_process([_cmd("legion-report"), "--trace", "latest", "--json"], env, repo, run_dir / "legion-report.json")
        record = best_effort_process(
            [
                _cmd("legion-self-learn"),
                "record",
                "--entity",
                f"{runner.get('target_type', 'runner')}:{runner['name']}",
                "--summary",
                f"legion-run failed at {failed_stage}: {exc}",
                "--source",
                "legion-run",
                "--evidence",
                str(run_dir),
                "--json",
            ],
            env,
            repo,
            run_dir / "self-learn-record.json",
        )
        _write_json(run_dir / "self-learn.json", {"record": record, "run": {"skipped": True, "reason": "pipeline failed"}})
        best_effort_process([_cmd("legion-heal"), "plan", "--repo", str(repo), "--json"], env, repo, run_dir / "heal-plan.json")
        summary = contract_payload(runner, repo, task)
        summary.update(
            {
                "ok": False,
                "failed_stage": failed_stage,
                "error": str(exc),
                "run_id": run_id,
                "run_dir": str(run_dir),
                "stage_status": stages,
            }
        )
        _write_json(run_dir / "partial-summary.json", summary)
        _write_json(run_dir / "summary.json", summary)
        write_artifact_manifest(run_dir)
        write_report_html(run_dir, summary)
        write_artifact_manifest(run_dir)
        return summary

    try:
        stage_run("doctor", [_cmd("legion-doctor"), "--repo", str(repo), "--strict-demo", "--json"], run_dir / "doctor.json")
        stage_run("self-learn-hints", [_cmd("legion-self-learn"), "hints", "--entity", f"{runner.get('target_type', 'runner')}:{runner['name']}", "--json"], run_dir / "self-learn-hints.json")

        current_stage = "plan"
        _set_stage_status(stages, "plan", "running")
        write_stage_status(run_dir, stages)
        plan_path = run_dir / "plan.json"
        if runner.get("plan_file"):
            write_plan_from_file(str(runner["plan_file"]), plan_path, runner, task, repo)
            _write_json(run_dir / "plan-command.json", {"ok": True, "source": "plan-file", "path": runner["plan_file"]})
        else:
            run_process([runner["commands"]["plan"]], env, repo, run_dir / "plan-command.json", shell=True)
            normalize_plan_file(plan_path, runner, task)
        slices_path = run_dir / "slices.jsonl"
        ensure_slices(slices_path, plan_path, runner, task)
        slices = load_slices(slices_path)
        _set_stage_status(stages, "plan", "passed")
        write_stage_status(run_dir, stages)

        current_stage = "route"
        _set_stage_status(stages, "route", "running")
        write_stage_status(run_dir, stages)
        routes = []
        for item in slices:
            archetype = str(item.get("archetype") or "").strip()
            if not archetype:
                raise LegionRunError("slice missing archetype")
            route = run_process(
                [_cmd("legion-route"), archetype, "--task", str(item.get("task") or "")],
                env,
                repo,
                run_dir / f"route-{len(routes)}.json",
            )
            routes.append({"slice": item, "route": route})
        _write_json(run_dir / "routes.json", {"routes": routes})
        _set_stage_status(stages, "route", "passed")
        write_stage_status(run_dir, stages)

        stage_run("fanout-apply", [_cmd("legion-fanout"), "--slices", str(slices_path), "--repo", str(repo), "--apply", "--json"], run_dir / "fanout.json")
        stage_run("review", [_cmd("legion-delegate"), "review", "--archetype", "final-review", "--repo", str(repo), "--base", "HEAD"], run_dir / "review.json")
        stage_run("validate", [runner["commands"]["validate"]], run_dir / "validation.json", shell=True)
        stage_run("evaluate", [runner["commands"]["evaluate"]], run_dir / "eval.json", shell=True)
        stage_run("report", [_cmd("legion-report"), "--trace", "latest", "--json"], run_dir / "legion-report.json")
        stage_run("share", [_cmd("legion-share"), "--window", "1d", "--json"], run_dir / "share.json")

        current_stage = "self-learn"
        _set_stage_status(stages, "self-learn", "running")
        write_stage_status(run_dir, stages)
        record = run_process(
            [
                _cmd("legion-self-learn"),
                "record",
                "--entity",
                f"{runner.get('target_type', 'runner')}:{runner['name']}",
                "--summary",
                f"legion-run completed profile {profile}",
                "--source",
                "legion-run",
                "--evidence",
                str(run_dir),
                "--json",
            ],
            env,
            repo,
            run_dir / "self-learn-record.json",
        )
        learn = run_process([_cmd("legion-self-learn"), "run", "--repo", str(repo), "--apply-memory", "--json"], env, repo, run_dir / "self-learn-run.json")
        _write_json(run_dir / "self-learn.json", {"record": record, "run": learn})
        _set_stage_status(stages, "self-learn", "passed")
        write_stage_status(run_dir, stages)

        stage_run("heal-plan", [_cmd("legion-heal"), "plan", "--repo", str(repo), "--json"], run_dir / "heal-plan.json")
        summary = finalize_success()
        if json_output:
            print(json.dumps(summary, indent=2, sort_keys=True))
        else:
            print(f"legion-run ok: {run_dir}")
        return 0
    except LegionRunError as exc:
        summary = finalize_failure(exc)
        if json_output:
            print(json.dumps(summary, indent=2, sort_keys=True))
        else:
            print(f"legion-run failed at {summary['failed_stage']}: {summary['error']}", file=sys.stderr)
            print(f"partial report: {run_dir / 'legion-observability.html'}", file=sys.stderr)
        return exc.code


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="legion-run")
    parser.add_argument("--plugin", default="")
    parser.add_argument("--plugin-manifest", default="")
    parser.add_argument("--profile", default="")
    parser.add_argument("--name", default="")
    parser.add_argument("--plan-command", "--plan", dest="plan_command", default="")
    parser.add_argument("--plan-file", default="")
    parser.add_argument("--validate-command", "--validate", dest="validate_command", default="")
    parser.add_argument("--evaluate-command", "--evaluate", dest="evaluate_command", default="")
    parser.add_argument("--repo", default=os.getcwd())
    parser.add_argument("--task", required=True)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)

    try:
        repo = Path(args.repo).expanduser().resolve()
        if args.plugin or args.plugin_manifest:
            manifest = find_manifest(repo, args.plugin, args.plugin_manifest)
            runner = load_plugin(manifest, args.plugin, args.profile)
        else:
            runner = build_direct_runner(args)
        if args.dry_run:
            payload = contract_payload(runner, repo, args.task)
            if args.json:
                print(json.dumps(payload, indent=2, sort_keys=True))
            else:
                print(f"{runner['name']} -> {runner['pipeline']['profile']}")
                for stage in PIPELINE_STAGES:
                    print(f"- {stage}")
            return 0
        return execute(runner, repo, args.task, args.json)
    except LegionRunError as exc:
        print(f"legion-run: {exc}", file=sys.stderr)
        return exc.code


if __name__ == "__main__":
    raise SystemExit(main())
