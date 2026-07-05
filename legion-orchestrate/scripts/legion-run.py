#!/usr/bin/env python3
"""legion-run — enforced pipeline runner for Legion domain plugins.

Domain plugins supply the business-specific pieces (plan, validate, evaluate).
Legion Core owns the fixed stage order and evidence contract.
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


FULL_APP_PROFILE = "legion.full_app.v1"
FULL_APP_STAGES = [
    "doctor",
    "self-learn-hints",
    "plugin-plan",
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
FULL_APP_REQUIRED_ARTIFACTS = [
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
]
FULL_APP_STAGE_ARTIFACTS = {
    "doctor": ["doctor.json"],
    "self-learn-hints": ["self-learn-hints.json"],
    "plugin-plan": ["plan.json", "slices.jsonl"],
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
        raise LegionRunError("--plugin or --plugin-manifest is required")
    for candidate in _manifest_candidates(repo, plugin):
        if candidate.exists():
            return candidate.resolve()
    raise LegionRunError(f"domain plugin manifest not found for '{plugin}'")


def load_plugin(manifest_path: Path, requested_plugin: str = "", requested_profile: str = FULL_APP_PROFILE) -> dict[str, Any]:
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
    if profile != requested_profile:
        raise LegionRunError(f"domain plugin must use approved profile '{requested_profile}'")
    if profile != FULL_APP_PROFILE:
        raise LegionRunError(f"unsupported pipeline profile: {profile}")

    required_commands = ["plan", "validate", "evaluate"]
    missing = [key for key in required_commands if not str(commands.get(key) or "").strip()]
    if missing:
        raise LegionRunError(f"domain plugin manifest missing commands: {', '.join(missing)}")

    return {
        "name": name,
        "kind": kind,
        "manifest": str(manifest_path),
        "pipeline": {"profile": profile, "entrypoint": entrypoint},
        "commands": {key: str(commands[key]).strip() for key in required_commands},
    }


def contract_payload(plugin: dict[str, Any], repo: Path, task: str) -> dict[str, Any]:
    return {
        "schema": "legion.run.contract.v1",
        "plugin": {
            "name": plugin["name"],
            "kind": plugin["kind"],
            "manifest": plugin["manifest"],
        },
        "repo": str(repo),
        "task": task,
        "pipeline": {
            "profile": FULL_APP_PROFILE,
            "stages": FULL_APP_STAGES,
            "required_artifacts": FULL_APP_REQUIRED_ARTIFACTS,
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


def load_slices(path: Path) -> list[dict[str, Any]]:
    slices: list[dict[str, Any]] = []
    if not path.exists():
        raise LegionRunError("plugin plan did not create slices.jsonl")
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
        raise LegionRunError("plugin plan produced no slices")
    return slices


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


def write_report_html(run_dir: Path, summary: dict[str, Any]) -> None:
    rows = "\n".join(
        "<tr><td>{stage}</td><td>PASS</td><td>{artifacts}</td></tr>".format(
            stage=html.escape(stage),
            artifacts=", ".join(
                f'<a href="{html.escape(name)}"><code>{html.escape(name)}</code></a>'
                for name in FULL_APP_STAGE_ARTIFACTS.get(stage, [])
            ),
        )
        for stage in FULL_APP_STAGES
    )
    artifacts = "\n".join(
        "<details><summary><code>{artifact}</code></summary><pre>{payload}</pre></details>".format(
            artifact=html.escape(artifact),
            payload=html.escape(_artifact_preview(run_dir, artifact)),
        )
        for artifact in FULL_APP_REQUIRED_ARTIFACTS
    )
    html_text = f"""<!doctype html>
<html><head><meta charset="utf-8"><title>Legion Run Report</title>
<style>body{{font-family:system-ui,sans-serif;margin:32px;line-height:1.45;color:#111827}}table{{border-collapse:collapse;width:100%;margin:16px 0}}td,th{{border:1px solid #d1d5db;padding:8px 10px;text-align:left;vertical-align:top}}code{{background:#f3f4f6;padding:2px 4px;border-radius:4px}}details{{border:1px solid #d1d5db;margin:8px 0;padding:8px 10px}}pre{{white-space:pre-wrap;overflow:auto;background:#f9fafb;padding:12px}}</style>
</head><body>
<h1>Legion Domain Plugin Pipeline</h1>
<p><strong>Plugin:</strong> {html.escape(summary["plugin"]["name"])}</p>
<p><strong>Profile:</strong> {html.escape(summary["pipeline"]["profile"])}</p>
<p><strong>Task:</strong> {html.escape(summary["task"])}</p>
<h2>Stages</h2><table><thead><tr><th>Stage</th><th>Status</th><th>Output</th></tr></thead><tbody>{rows}</tbody></table>
<h2>Full Pipeline Outputs</h2>{artifacts}
</body></html>
"""
    (run_dir / "legion-report.html").write_text(html_text, encoding="utf-8")
    (run_dir / "legion-observability.html").write_text(html_text.replace("Run Report", "Observability"), encoding="utf-8")


def execute(plugin: dict[str, Any], repo: Path, task: str, json_output: bool) -> int:
    state = legion_state.resolve_state(str(repo))
    run_id = dt.datetime.utcnow().strftime("%Y%m%dT%H%M%SZ") + f"-{_slug(plugin['name'])}"
    run_dir = Path(state["state_root"]) / "runs" / "legion-run" / run_id
    run_dir.mkdir(parents=True, exist_ok=True)

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
            "LEGION_PLUGIN_NAME": plugin["name"],
            "LEGION_PIPELINE_PROFILE": FULL_APP_PROFILE,
        }
    )

    run_process([_cmd("legion-doctor"), "--repo", str(repo), "--strict-demo", "--json"], env, repo, run_dir / "doctor.json")
    run_process([_cmd("legion-self-learn"), "hints", "--entity", f"plugin:{plugin['name']}", "--json"], env, repo, run_dir / "self-learn-hints.json")

    run_process([plugin["commands"]["plan"]], env, repo, run_dir / "plan-command.json", shell=True)
    plan_path = run_dir / "plan.json"
    if not plan_path.exists():
        _write_json(plan_path, {"schema": "legion.plugin.plan.v1", "plugin": plugin["name"], "task": task})
    slices_path = run_dir / "slices.jsonl"
    slices = load_slices(slices_path)

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

    run_process([_cmd("legion-fanout"), "--slices", str(slices_path), "--repo", str(repo), "--apply", "--json"], env, repo, run_dir / "fanout.json")
    run_process([_cmd("legion-delegate"), "review", "--archetype", "final-review", "--repo", str(repo), "--base", "HEAD"], env, repo, run_dir / "review.json")
    run_process([plugin["commands"]["validate"]], env, repo, run_dir / "validation.json", shell=True)
    run_process([plugin["commands"]["evaluate"]], env, repo, run_dir / "eval.json", shell=True)
    run_process([_cmd("legion-report"), "--trace", "latest", "--json"], env, repo, run_dir / "legion-report.json")
    run_process([_cmd("legion-share"), "--window", "1d", "--json"], env, repo, run_dir / "share.json")
    record = run_process(
        [
            _cmd("legion-self-learn"),
            "record",
            "--entity",
            f"plugin:{plugin['name']}",
            "--summary",
            f"legion-run completed profile {FULL_APP_PROFILE}",
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
    run_process([_cmd("legion-heal"), "plan", "--repo", str(repo), "--json"], env, repo, run_dir / "heal-plan.json")

    summary = contract_payload(plugin, repo, task)
    summary.update({"ok": True, "run_id": run_id, "run_dir": str(run_dir)})
    write_report_html(run_dir, summary)
    missing = [artifact for artifact in FULL_APP_REQUIRED_ARTIFACTS if not (run_dir / artifact).exists()]
    if missing:
        raise LegionRunError(f"pipeline missing required artifacts: {', '.join(missing)}", 1)
    _write_json(run_dir / "summary.json", summary)

    if json_output:
        print(json.dumps(summary, indent=2, sort_keys=True))
    else:
        print(f"legion-run ok: {run_dir}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="legion-run")
    parser.add_argument("--plugin", default="")
    parser.add_argument("--plugin-manifest", default="")
    parser.add_argument("--profile", default=FULL_APP_PROFILE)
    parser.add_argument("--repo", default=os.getcwd())
    parser.add_argument("--task", required=True)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)

    try:
        repo = Path(args.repo).expanduser().resolve()
        manifest = find_manifest(repo, args.plugin, args.plugin_manifest)
        plugin = load_plugin(manifest, args.plugin, args.profile)
        if args.dry_run:
            payload = contract_payload(plugin, repo, args.task)
            if args.json:
                print(json.dumps(payload, indent=2, sort_keys=True))
            else:
                print(f"{plugin['name']} -> {FULL_APP_PROFILE}")
                for stage in FULL_APP_STAGES:
                    print(f"- {stage}")
            return 0
        return execute(plugin, repo, args.task, args.json)
    except LegionRunError as exc:
        print(f"legion-run: {exc}", file=sys.stderr)
        return exc.code


if __name__ == "__main__":
    raise SystemExit(main())
