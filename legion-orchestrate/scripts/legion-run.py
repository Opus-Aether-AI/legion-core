#!/usr/bin/env python3
"""legion-run — enforced lifecycle runner for Legion heavy tasks.

Callers supply the task-specific pieces (plan, validate, evaluate), either
directly or through a domain plugin. Legion Core owns the fixed stage order and
evidence contract.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import html
import json
import os
import re
import shlex
import shutil
import signal
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
    "validate",
    "review",
    "evaluate",
    "report",
    "share",
    "self-learn",
    "heal-plan",
]
PIPELINE_REQUIRED_ARTIFACTS = [
    "doctor.json",
    "self-learn-hints.json",
    "learning-context.json",
    "learning-usage.json",
    "learning-context-receipt.json",
    "learning-receipts.json",
    "plan.json",
    "slices.jsonl",
    "routes.json",
    "fanout.json",
    "task-ledger.json",
    "review.json",
    "review-input.json",
    "validation.json",
    "eval.json",
    "learning-feedback.json",
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
    "learning-context": [
        "learning-context.json",
        "learning-usage.json",
        "learning-context-receipt.json",
        "learning-receipts.json",
    ],
    "plan": ["plan.json", "slices.jsonl"],
    "route": ["routes.json"],
    "fanout-apply": ["fanout.json", "task-ledger.json"],
    "validate": ["validation.json"],
    "review": ["review.json", "review-input.json"],
    "evaluate": ["eval.json"],
    "report": ["legion-report.json", "legion-report.html", "legion-observability.html"],
    "share": ["share.json"],
    "self-learn": ["learning-feedback.json", "self-learn.json"],
    "heal-plan": ["heal-plan.json"],
}

LEARNING_CONTEXT_MODES = {"off", "observe", "advisory", "required"}
LEARNING_CONTEXT_BOUNDARIES = ("plan", "fanout", "validate", "review")
MAX_LEARNING_HINTS = 100
MAX_LEARNING_TOKENS = 10_000
MAX_LEARNING_CONTEXT_BYTES = 262_144
MAX_LEARNING_IDENTIFIER_CHARS = 160
MAX_LEARNING_BOUNDARY_CHARS = 256
_LEARNING_SAFE_HINT_FIELDS = {
    "id",
    "scope",
    "guidance",
    "selection_reason",
    "token_count",
    "entity",
    "stage",
}

COMMAND_FALLBACKS = {
    "legion-doctor": ROOT / "legion-observability" / "bin" / "legion-doctor",
    "legion-self-learn": ROOT / "legion-observability" / "bin" / "legion-self-learn",
    "legion-report": ROOT / "legion-observability" / "bin" / "legion-report",
    "legion-share": ROOT / "legion-observability" / "bin" / "legion-share",
    "legion-heal": ROOT / "legion-observability" / "bin" / "legion-heal",
    "legion-route": ROOT / "legion-router" / "bin" / "legion-route",
    "legion-delegate": ROOT / "legion-router" / "bin" / "legion-delegate",
    "legion-claude": ROOT / "legion-router" / "bin" / "legion-claude",
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
    path.chmod(0o600)


def _append_jsonl(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(payload, sort_keys=True, ensure_ascii=False))
        handle.write("\n")
    path.chmod(0o600)


def _write_jsonl(path: Path, rows: list[dict[str, Any]]) -> None:
    path.write_text(
        "\n".join(json.dumps(row, sort_keys=True) for row in rows) + "\n",
        encoding="utf-8",
    )
    path.chmod(0o600)


def _slug(value: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-") or "plugin"
    return slug[:80].strip("-") or "plugin"


def _stable_id(parts: list[Any]) -> str:
    raw = json.dumps(parts, sort_keys=True, ensure_ascii=True, default=str)
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:16]


def _iso_utc() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def reserve_run_directory(
    state_root: Path,
    runner_name: str,
    *,
    now: dt.datetime | None = None,
) -> tuple[str, Path]:
    """Atomically reserve a readable, collision-free legion-run directory."""

    timestamp = now or dt.datetime.now(dt.timezone.utc)
    if timestamp.tzinfo is not None:
        timestamp = timestamp.astimezone(dt.timezone.utc)
    base_id = timestamp.strftime("%Y%m%dT%H%M%SZ") + f"-{_slug(runner_name)}"
    runs_root = state_root / "runs" / "legion-run"
    runs_root.mkdir(mode=0o700, parents=True, exist_ok=True)
    runs_root.chmod(0o700)

    suffix = 1
    while True:
        run_id = base_id if suffix == 1 else f"{base_id}-{suffix}"
        run_dir = runs_root / run_id
        try:
            run_dir.mkdir(mode=0o700)
        except FileExistsError:
            suffix += 1
            continue
        return run_id, run_dir


def _short(text: Any, limit: int = 500) -> str:
    collapsed = " ".join(str(text or "").strip().split())
    if len(collapsed) <= limit:
        return collapsed
    return collapsed[: limit - 3].rstrip() + "..."


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
    plan_files = [str(item).strip() for item in (args.plan_files or []) if str(item).strip()]
    slices_file = str(args.slices_file or "").strip()
    validate_command = str(args.validate_command or "").strip()
    evaluate_command = str(args.evaluate_command or "").strip()
    if not plan_command and not plan_files:
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
        "plan_file": plan_files[0] if len(plan_files) == 1 else "",
        "plan_files": plan_files,
        "slices_file": slices_file,
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


def _empty_learning_context(
    repository_identity: str, entity: str, stage: str = "plan"
) -> dict[str, Any]:
    usage = {"schema": "legion.learning-usage.v1", "hint_count": 0, "token_count": 0}
    return {
        "schema": "legion.learning-context.v1",
        "repository_identity": repository_identity,
        "entity": entity,
        "stage": stage,
        "limits": {"max_hints": 20, "max_tokens": 1200},
        "usage": usage,
        "selected_hints": [],
        "excluded_hints": [],
    }


def _learning_context_error(
    payload: Any,
    *,
    repository_identity: str = "",
    entity: str = "",
    stage: str = "",
) -> str:
    """Return a compact validation error for the public typed context contract."""
    if not isinstance(payload, dict):
        return "expected an object"
    required = {
        "schema", "repository_identity", "entity", "stage", "limits", "usage",
        "selected_hints", "excluded_hints",
    }
    if set(payload) != required:
        return "unexpected or missing top-level fields"
    if payload.get("schema") != "legion.learning-context.v1":
        return "invalid schema"
    try:
        serialized_size = len(
            json.dumps(
                payload,
                sort_keys=True,
                separators=(",", ":"),
                ensure_ascii=True,
            ).encode("utf-8")
        )
    except (TypeError, ValueError):
        return "context is not canonically serializable"
    if serialized_size > MAX_LEARNING_CONTEXT_BYTES:
        return "serialized context exceeds the absolute byte limit"
    if not all(isinstance(payload.get(key), str) and payload[key] for key in ("repository_identity", "entity", "stage")):
        return "repository_identity, entity, and stage must be non-empty strings"
    if any(
        len(payload[key]) > MAX_LEARNING_BOUNDARY_CHARS
        for key in ("repository_identity", "entity", "stage")
    ):
        return "context boundary identity exceeds the absolute length limit"
    for key, expected in (
        ("repository_identity", repository_identity),
        ("entity", entity),
        ("stage", stage),
    ):
        if expected and payload.get(key) != expected:
            return f"compiled {key} does not match the requested boundary"
    limits = payload.get("limits")
    usage = payload.get("usage")
    if not isinstance(limits, dict) or set(limits) != {"max_hints", "max_tokens"}:
        return "invalid limits"
    if not isinstance(usage, dict) or set(usage) != {"schema", "hint_count", "token_count"} or usage.get("schema") != "legion.learning-usage.v1":
        return "invalid usage"
    for value in [limits.get("max_hints"), limits.get("max_tokens"), usage.get("hint_count"), usage.get("token_count")]:
        if not isinstance(value, int) or isinstance(value, bool) or value < 0:
            return "limits and usage counts must be non-negative integers"
    if (
        limits["max_hints"] > MAX_LEARNING_HINTS
        or limits["max_tokens"] > MAX_LEARNING_TOKENS
        or usage["hint_count"] > MAX_LEARNING_HINTS
        or usage["token_count"] > MAX_LEARNING_TOKENS
    ):
        return "limits or usage exceed the runner's absolute caps"
    selected = payload.get("selected_hints")
    excluded = payload.get("excluded_hints")
    if not isinstance(selected, list) or not isinstance(excluded, list):
        return "selected_hints and excluded_hints must be arrays"
    if len(excluded) > 200:
        return "excluded hint count exceeds the absolute limit"
    if len(selected) != usage["hint_count"] or len(selected) > limits["max_hints"]:
        return "selected hint count exceeds or disagrees with limits"
    selected_tokens = 0
    for hint in selected:
        if not isinstance(hint, dict) or set(hint) - _LEARNING_SAFE_HINT_FIELDS:
            return "selected hint contains unsafe fields"
        if not all(isinstance(hint.get(key), str) and hint[key] for key in ("id", "scope", "guidance", "selection_reason")):
            return "selected hint is missing safe guidance fields"
        if (
            len(hint["id"]) > MAX_LEARNING_IDENTIFIER_CHARS
            or hint["scope"] not in {"global", "selector", "exact"}
            or hint["selection_reason"] not in {"global", "selector", "exact"}
            or any(
                key in hint
                and (
                    not isinstance(hint[key], str)
                    or not hint[key]
                    or len(hint[key]) > MAX_LEARNING_BOUNDARY_CHARS
                )
                for key in ("entity", "stage")
            )
        ):
            return "selected hint contains invalid bounded metadata"
        tokens = hint.get("token_count")
        if not isinstance(tokens, int) or isinstance(tokens, bool) or tokens < 0:
            return "selected hint token_count must be a non-negative integer"
        measured_tokens = len(hint["guidance"].encode("utf-8"))
        if tokens != measured_tokens:
            return "selected hint token_count does not match measured guidance"
        selected_tokens += tokens
    if selected_tokens != usage["token_count"] or selected_tokens > limits["max_tokens"]:
        return "selected token count exceeds or disagrees with limits"
    for hint in excluded:
        if not isinstance(hint, dict) or set(hint) != {"id", "exclusion_reason"}:
            return "excluded hint contains unsafe fields"
        if not all(isinstance(hint.get(key), str) and hint[key] for key in ("id", "exclusion_reason")):
            return "excluded hint is missing an exclusion reason"
        if (
            len(hint["id"]) > MAX_LEARNING_IDENTIFIER_CHARS
            or len(hint["exclusion_reason"]) > 80
        ):
            return "excluded hint exceeds bounded metadata limits"
    return ""


def _safe_learning_context(payload: dict[str, Any]) -> dict[str, Any]:
    """Copy only the typed executor-safe context fields into run artifacts."""
    return {
        "schema": payload["schema"],
        "repository_identity": payload["repository_identity"],
        "entity": payload["entity"],
        "stage": payload["stage"],
        "limits": {"max_hints": payload["limits"]["max_hints"], "max_tokens": payload["limits"]["max_tokens"]},
        "usage": {
            "schema": payload["usage"]["schema"],
            "hint_count": payload["usage"]["hint_count"],
            "token_count": payload["usage"]["token_count"],
        },
        "selected_hints": [
            {key: hint[key] for key in sorted(hint) if key in _LEARNING_SAFE_HINT_FIELDS}
            for hint in payload["selected_hints"]
        ],
        "excluded_hints": [
            {"id": hint["id"], "exclusion_reason": hint["exclusion_reason"]}
            for hint in payload["excluded_hints"]
        ],
    }


def _learning_revision(context: dict[str, Any]) -> str:
    encoded = json.dumps(context, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest()


def _verify_learning_context_snapshot(
    path: Path,
    revision: str,
    *,
    repository_identity: str,
    entity: str,
    stage: str,
) -> dict[str, Any]:
    """Reauthenticate the exact context bytes before and after every delivery."""
    try:
        if path.is_symlink() or path.stat().st_size > MAX_LEARNING_CONTEXT_BYTES:
            raise ValueError("unsafe learning context path or size")
        raw = path.read_bytes()
        if len(raw) > MAX_LEARNING_CONTEXT_BYTES:
            raise ValueError("oversized learning context")
        payload = json.loads(raw)
    except (OSError, TypeError, UnicodeDecodeError, ValueError) as exc:
        raise LegionRunError(
            f"learning context integrity failure at {stage}: unreadable context",
            1,
        ) from exc
    error = _learning_context_error(
        payload,
        repository_identity=repository_identity,
        entity=entity,
        stage=stage,
    )
    if error:
        raise LegionRunError(
            f"learning context integrity failure at {stage}: {error}",
            1,
        )
    safe = _safe_learning_context(payload)
    if _learning_revision(safe) != revision:
        raise LegionRunError(
            f"learning context integrity failure at {stage}: revision changed",
            1,
        )
    return safe


def _required_guidance(hint: dict[str, Any], mode: str) -> bool:
    return mode == "required" or str(hint.get("guidance") or "").lstrip().lower().startswith("required:")


def _learning_dispositions(context: dict[str, Any], mode: str) -> list[dict[str, str]]:
    dispositions: list[dict[str, str]] = []
    for hint in context["selected_hints"]:
        if mode == "off":
            disposition = "off"
        elif mode == "observe":
            disposition = "observed"
        elif _required_guidance(hint, mode):
            disposition = "required"
        else:
            disposition = "advisory"
        dispositions.append({"id": str(hint["id"]), "disposition": disposition})
    for hint in context["excluded_hints"]:
        dispositions.append({"id": str(hint["id"]), "disposition": str(hint["exclusion_reason"])})
    return sorted(dispositions, key=lambda item: (item["id"], item["disposition"]))


def _delivered_guidance(context: dict[str, Any], mode: str) -> list[str]:
    if mode in {"off", "observe"}:
        return []
    return [str(hint["guidance"]) for hint in context["selected_hints"]]


def _learning_context_descriptor(path: Path, revision: str, mode: str, dispositions: list[dict[str, str]]) -> dict[str, Any]:
    return {
        "path": str(path),
        "revision": revision,
        "mode": mode,
        "dispositions": dispositions,
    }


GUIDANCE_HEADER = "Trusted learning guidance (bounded):"


def _append_guidance(task: str, guidance: list[str]) -> str:
    if not guidance:
        return task
    return f"{task.rstrip()}\n\n{GUIDANCE_HEADER}\n" + "\n".join(f"- {item}" for item in guidance)


def _guidance_present(delivered: Any, guidance: list[str]) -> bool:
    """True when every guidance line survived into the text a stage received.

    Receipts are the audit trail for whether learning actually reached a
    decision boundary, so they are derived from the delivered payload rather
    than from the intent to deliver.

    Match the structure `_append_guidance` writes -- the header, then each line
    as its own bullet -- rather than testing for bare substrings. A guidance
    line is often an ordinary phrase ("tests", "review") that already occurs in
    the task text, so a substring test would attest delivery for a stage whose
    plan artifact never received the guidance at all.
    """
    if not guidance:
        return False
    text = delivered if isinstance(delivered, str) else ""
    if GUIDANCE_HEADER not in text:
        return False
    return all(f"- {item}" in text for item in guidance)


def _write_learning_receipts(
    path: Path,
    *,
    descriptor: dict[str, Any],
    receipts: list[dict[str, Any]],
    descriptors: dict[str, dict[str, Any]] | None = None,
) -> None:
    payload = {
        "schema": "legion.learning-context-receipts.v1",
        "learning_context": descriptor,
        "learning_contexts": descriptors or {"plan": descriptor},
        "receipts": receipts,
    }
    canonical = json.dumps(
        payload, sort_keys=True, separators=(",", ":"), ensure_ascii=True
    ).encode("utf-8")
    payload["receipt_id"] = hashlib.sha256(canonical).hexdigest()
    _write_json(path, payload)
    try:
        persisted = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise LegionRunError("learning receipt persistence failed", 1) from exc
    if not _learning_receipts_valid(persisted):
        raise LegionRunError("learning receipt integrity failure", 1)


def _learning_receipts_valid(payload: Any) -> bool:
    if not isinstance(payload, dict) or not isinstance(payload.get("receipt_id"), str):
        return False
    unsigned = dict(payload)
    receipt_id = unsigned.pop("receipt_id")
    canonical = json.dumps(
        unsigned, sort_keys=True, separators=(",", ":"), ensure_ascii=True
    ).encode("utf-8")
    return bool(
        re.fullmatch(r"[0-9a-f]{64}", receipt_id)
        and hashlib.sha256(canonical).hexdigest() == receipt_id
    )


def _learning_context_acknowledged(
    payload: Any, bundle: dict[str, Any]
) -> bool:
    if not isinstance(payload, dict):
        return False
    ack = payload.get("learning_context_ack")
    return bool(
        isinstance(ack, dict)
        and ack.get("boundary") == bundle["boundary"]
        and ack.get("revision") == bundle["revision"]
    )


def _require_learning_context_ack(
    payload: Any,
    bundle: dict[str, Any],
    guidance: list[str],
    consumer: str,
) -> None:
    if not guidance or _learning_context_acknowledged(payload, bundle):
        return
    raise LegionRunError(
        f"required learning guidance was not acknowledged by {consumer}: "
        f"expected learning_context_ack for {bundle['boundary']} "
        f"revision {bundle['revision']}",
        1,
    )


def run_process(
    argv: list[str],
    env: dict[str, str],
    cwd: Path,
    artifact: Path,
    *,
    shell: bool = False,
    timeout_seconds: int = 1800,
) -> Any:
    """Run one stage and always leave a machine-readable terminal receipt.

    A stage owns its process group.  On timeout we terminate that group rather
    than leaving an executor, its MCP transport, or a shell child behind.
    """
    command: str | list[str] = argv[0] if shell else argv
    proc = subprocess.Popen(
        command,
        shell=shell,
        cwd=str(cwd),
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    try:
        stdout, stderr = proc.communicate(timeout=timeout_seconds)
    except subprocess.TimeoutExpired as exc:
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            stdout, stderr = proc.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            stdout, stderr = proc.communicate()
        payload = {
            "ok": False,
            "status": "timed_out",
            "exit_code": 124,
            "timeout_seconds": timeout_seconds,
            "command": argv,
            "stdout": _short(stdout or exc.stdout or "", 2000),
            "stderr": _short(stderr or exc.stderr or "", 2000),
        }
        _write_json(artifact, payload)
        raise LegionRunError(f"stage timed out ({artifact.name}) after {timeout_seconds}s", 124)
    payload = _json_or_text(stdout)
    if isinstance(payload, dict):
        payload.setdefault("exit_code", proc.returncode)
        if stderr.strip():
            payload.setdefault("stderr", stderr.strip())
    _write_json(artifact, payload)
    if proc.returncode != 0:
        raise LegionRunError(f"stage failed ({artifact.name}): exit {proc.returncode}", 1)
    return payload


def _git_output(
    repo: Path,
    args: list[str],
    *,
    env: dict[str, str] | None = None,
    stdin: str = "",
    timeout_seconds: int = 1800,
    strip: bool = True,
) -> str:
    process = subprocess.Popen(
        ["git", "-C", str(repo), *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        stdin=subprocess.PIPE if stdin else subprocess.DEVNULL,
        env=env,
        start_new_session=True,
    )
    try:
        stdout, stderr = process.communicate(
            input=stdin if stdin else None,
            timeout=timeout_seconds,
        )
    except subprocess.TimeoutExpired as exc:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.communicate(timeout=2)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.communicate()
        raise LegionRunError(
            f"immutable review input timed out after {timeout_seconds}s: git {' '.join(args)}",
            124,
        ) from exc
    if process.returncode != 0:
        detail = _short(stderr or stdout, 1000)
        raise LegionRunError(f"could not create immutable review input: git {' '.join(args)}: {detail}", 1)
    return stdout.strip() if strip else stdout


def require_clean_review_source(repo: Path, *, timeout_seconds: int) -> None:
    dirty = _git_output(
        repo,
        [
            "status",
            "--porcelain",
            "--untracked-files=all",
            "--",
            ".",
            ":(exclude).legion",
            ":(exclude).legion/**",
        ],
        timeout_seconds=timeout_seconds,
    )
    if dirty:
        paths = ", ".join(line[3:] for line in dirty.splitlines()[:8])
        raise LegionRunError(
            "legion-run requires a clean source worktree before fan-out so "
            f"pre-existing local files are not exposed to reviewers: {paths}",
            2,
        )


def create_review_snapshot(
    repo: Path,
    run_dir: Path,
    *,
    timeout_seconds: int,
    learning_context: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Write the current worktree to a detached commit without changing its index.

    Fan-out applies verified patches to the caller's worktree without committing
    them. Reviewers need those exact bytes, but symbolic ``HEAD`` can move and a
    fresh executor worktree otherwise loses dirty/untracked changes. A temporary
    index gives us an immutable, locally-addressable snapshot commit.
    """

    base_sha = _git_output(
        repo, ["rev-parse", "HEAD^{commit}"], timeout_seconds=timeout_seconds
    )
    base_tree = _git_output(
        repo,
        ["rev-parse", f"{base_sha}^{{tree}}"],
        timeout_seconds=timeout_seconds,
    )
    temp_index = run_dir / "review.index"
    snapshot_env = dict(os.environ)
    snapshot_env.update(
        {
            "GIT_INDEX_FILE": str(temp_index),
            "GIT_AUTHOR_NAME": "Legion Review",
            "GIT_AUTHOR_EMAIL": "legion@local",
            "GIT_COMMITTER_NAME": "Legion Review",
            "GIT_COMMITTER_EMAIL": "legion@local",
        }
    )
    try:
        _git_output(
            repo,
            ["read-tree", base_sha],
            env=snapshot_env,
            timeout_seconds=timeout_seconds,
        )
        # Update tracked paths separately, then feed only Git's non-ignored
        # untracked set through a NUL-delimited pathspec. `git add -A` can try
        # to force an ignored `.legion/` runtime tree into the temporary index
        # before a negative pathspec is applied, making otherwise valid review
        # snapshots fail. This also preserves unusual filenames exactly.
        _git_output(
            repo,
            [
                "add",
                "-u",
                "--",
                ".",
                ":(exclude).legion",
                ":(exclude).legion/**",
            ],
            env=snapshot_env,
            timeout_seconds=timeout_seconds,
        )
        untracked = _git_output(
            repo,
            [
                "ls-files",
                "--others",
                "--exclude-standard",
                "-z",
                "--",
                ".",
                ":(exclude).legion",
                ":(exclude).legion/**",
            ],
            env=snapshot_env,
            timeout_seconds=timeout_seconds,
            strip=False,
        )
        if untracked:
            _git_output(
                repo,
                ["add", "--pathspec-from-file=-", "--pathspec-file-nul"],
                env=snapshot_env,
                stdin=untracked,
                timeout_seconds=timeout_seconds,
            )
        tree_sha = _git_output(
            repo, ["write-tree"], env=snapshot_env, timeout_seconds=timeout_seconds
        )
        head_sha = _git_output(
            repo,
            ["commit-tree", tree_sha, "-p", base_sha],
            env=snapshot_env,
            stdin="Legion immutable review snapshot\n",
            timeout_seconds=timeout_seconds,
        )
    finally:
        temp_index.unlink(missing_ok=True)
        Path(f"{temp_index}.lock").unlink(missing_ok=True)

    payload = {
        "schema": "legion.review-input.v1",
        "base_sha": base_sha,
        "head_sha": head_sha,
        "tree_sha": tree_sha,
        "dirty": tree_sha != base_tree,
        "created_at": _iso_utc(),
    }
    if learning_context is not None:
        payload["learning_context"] = learning_context
    _write_json(run_dir / "review-input.json", payload)
    return payload


def hermetic_stage_env(env: dict[str, str]) -> dict[str, str]:
    """Remove executor-role state from deterministic validator/evaluator commands."""

    clean = dict(env)
    for key in (
        "LEGION_ACTIVE",
        "LEGION_EXECUTOR",
        "LEGION_DEPTH",
        "LEGION_FORCE_DELEGATE",
        "LEGION_LOW_CREDIT",
        "LEGION_STATE_ROOT",
        "LEGION_TELEMETRY_DIR",
        "LEGION_REGISTRY_DIR",
        "LEGION_REPOS_FILE",
        "LEGION_BENCH_DIR",
        "LEGION_REPORTS_DIR",
        "LEGION_PROJECT_LEARNING_DIR",
        "LEGION_GLOBAL_LEARNING_DIR",
        "LEGION_PROJECT_ID",
        "LEGION_REPOSITORY_PROJECT_ID",
    ):
        clean.pop(key, None)
    clean.update(
        {
            "CI": clean.get("CI", "1"),
            "GIT_TERMINAL_PROMPT": "0",
            "LEGION_VALIDATION": "1",
        }
    )
    return clean


def _load_json_object(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {}
    return value if isinstance(value, dict) else {}


def _load_json_value(path: Path) -> Any:
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return None


def _int_value(value: Any) -> int:
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        return int(value)
    if isinstance(value, str) and value.strip().isdigit():
        return int(value.strip())
    return 0


def _exit_code(payload: Any) -> int:
    if not isinstance(payload, dict):
        return 0
    return _int_value(payload.get("exit_code"))


def _is_bad_status(value: Any) -> bool:
    return str(value or "").strip().lower() in {
        "fail",
        "failed",
        "failure",
        "error",
        "reject",
        "rejected",
        "request_changes",
        "blocked",
    }


_BLOCKING_REVIEW_SEVERITIES = {"critical", "high", "medium"}
_REVIEW_VERDICTS = {"approve", "request_changes", "comment"}
_REVIEW_FINDING_SEVERITIES = {"critical", "high", "medium", "low"}
_REVIEW_VERDICT_KEYS = {"verdict", "summary", "findings"}
_REVIEW_FINDING_KEYS = {"severity", "title", "file", "line", "detail"}


def _review_verdict_value(payload: dict[str, Any]) -> Any:
    verdict = payload.get("verdict", payload.get("result"))
    if isinstance(verdict, str):
        text = verdict.strip()
        if text.startswith("{") and text.endswith("}"):
            try:
                decoded = json.loads(text)
            except ValueError:
                return verdict
            if isinstance(decoded, dict):
                return decoded
    return verdict


def _blocking_review_findings(verdict: Any) -> list[dict[str, Any]]:
    findings = []
    if isinstance(verdict, dict) and isinstance(verdict.get("findings"), list):
        findings = [item for item in verdict["findings"] if isinstance(item, dict)]
    return [
        item
        for item in findings
        if str(item.get("severity") or "").strip().lower() in _BLOCKING_REVIEW_SEVERITIES
    ]


def _review_verdict_schema_error(verdict: Any) -> str:
    """Validate the public review-verdict schema without an optional dependency."""
    if not isinstance(verdict, dict):
        return "expected a structured verdict object"
    missing = _REVIEW_VERDICT_KEYS - verdict.keys()
    extra = verdict.keys() - _REVIEW_VERDICT_KEYS
    if missing:
        return f"missing required field(s): {', '.join(sorted(missing))}"
    if extra:
        return f"unexpected field(s): {', '.join(sorted(extra))}"
    if (
        not isinstance(verdict["verdict"], str)
        or verdict["verdict"] not in _REVIEW_VERDICTS
    ):
        return "verdict must be approve, request_changes, or comment"
    if not isinstance(verdict["summary"], str):
        return "summary must be a string"
    findings = verdict["findings"]
    if not isinstance(findings, list):
        return "findings must be an array"
    for index, finding in enumerate(findings):
        if not isinstance(finding, dict):
            return f"finding {index} must be an object"
        missing_finding = {"severity", "title"} - finding.keys()
        extra_finding = finding.keys() - _REVIEW_FINDING_KEYS
        if missing_finding:
            return (
                f"finding {index} missing required field(s): "
                f"{', '.join(sorted(missing_finding))}"
            )
        if extra_finding:
            return (
                f"finding {index} has unexpected field(s): "
                f"{', '.join(sorted(extra_finding))}"
            )
        if (
            not isinstance(finding["severity"], str)
            or finding["severity"] not in _REVIEW_FINDING_SEVERITIES
        ):
            return f"finding {index} has an invalid severity"
        if not isinstance(finding["title"], str):
            return f"finding {index} title must be a string"
        for key in ("file", "detail"):
            if key in finding and not isinstance(finding[key], str):
                return f"finding {index} {key} must be a string"
        if "line" in finding and (
            not isinstance(finding["line"], int)
            or isinstance(finding["line"], bool)
        ):
            return f"finding {index} line must be an integer"
    return ""


def _review_failure_reason(payload: dict[str, Any]) -> str:
    if payload.get("ok") is False or _is_bad_status(payload.get("status")):
        return "review command reported failure"
    verdict = _review_verdict_value(payload)
    schema_error = _review_verdict_schema_error(verdict)
    if schema_error:
        return f"invalid terminal verdict: {schema_error}"
    decision = str(verdict["verdict"]).strip().lower()
    if decision != "approve":
        return f"review verdict {decision}"
    blocking = _blocking_review_findings(verdict)
    if blocking:
        first = _short(blocking[0].get("title") or blocking[0].get("detail") or "blocking finding", 160)
        return f"review reported {len(blocking)} blocking finding(s): {first}"
    return ""


def _stage_artifact_path(run_dir: Path, stage: str) -> Path:
    return run_dir / {
        "validate": "validation.json",
        "evaluate": "eval.json",
        "eval": "eval.json",
        "fanout-apply": "fanout.json",
    }.get(stage, f"{stage}.json")


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
    context_files = _as_text_list(plan.get("context_files") or plan.get("plan_sources") or plan.get("plan_source"))
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


def ensure_slices(
    path: Path,
    plan_path: Path,
    plugin: dict[str, Any],
    task: str,
    *,
    allow_generated_slices: bool,
) -> None:
    if has_jsonl_rows(path):
        return
    if not allow_generated_slices:
        raise LegionRunError(
            "plan did not create slices.jsonl; serious workflows must provide explicit slices "
            "(use --allow-generated-slices only for the legacy compatibility path)",
        )
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


def copy_explicit_slices(source_value: str, destination: Path, base_dir: Path) -> None:
    """Copy a direct-mode work queue into the run directory without interpreting it."""
    source = _resolve_plan_source(source_value, base_dir)
    if source == destination:
        return
    shutil.copyfile(source, destination)


def _resolve_plan_source(plan_file: str, base_dir: Path) -> Path:
    source = Path(plan_file).expanduser()
    if not source.is_absolute():
        source = (base_dir / source).resolve()
    if not source.exists():
        raise LegionRunError(f"plan file not found: {source}")
    return source


def _extend_unique(items: list[str], value: Any) -> None:
    for item in _as_text_list(value):
        if item not in items:
            items.append(item)


def write_plan_from_files(
    plan_files: list[str],
    plan_path: Path,
    runner: dict[str, Any],
    task: str,
    base_dir: Path,
    guidance: list[str] | None = None,
) -> dict[str, Any]:
    sources = [_resolve_plan_source(plan_file, base_dir) for plan_file in plan_files]
    if not sources:
        raise LegionRunError("direct heavy-task mode requires --plan-command or --plan-file")

    if len(sources) == 1:
        source = sources[0]
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
        payload.setdefault("plan_source", str(source))
    else:
        sections: list[str] = []
        required_skills: list[str] = []
        quality_gates: list[str] = []
        eval_goals: list[str] = []
        for source in sources:
            text = source.read_text(encoding="utf-8", errors="replace")
            body = text.strip()
            if source.suffix.lower() == ".json":
                try:
                    json_payload = json.loads(text)
                except json.JSONDecodeError as exc:
                    raise LegionRunError(f"invalid plan JSON: {exc}") from exc
                if not isinstance(json_payload, dict):
                    raise LegionRunError("plan JSON must be an object")
                body = _as_text(json_payload.get("planning_instruction"), json.dumps(json_payload, indent=2, sort_keys=True))
                _extend_unique(required_skills, json_payload.get("required_skills") or json_payload.get("legion_code_skills"))
                _extend_unique(quality_gates, json_payload.get("quality_gates"))
                eval_goal = _as_text(json_payload.get("eval_goal"))
                if eval_goal and eval_goal not in eval_goals:
                    eval_goals.append(eval_goal)
            sections.append(f"### {source.name}\n{body}")
        payload = {
            "schema": "legion.heavy-task.plan.v1",
            "mode": "legion-generate-slices",
            "task": task,
            "planning_instruction": "Use these plan files together:\n\n" + "\n\n".join(sections),
            "plan_source": str(sources[0]),
            "plan_sources": [str(source) for source in sources],
        }
        if required_skills:
            payload["required_skills"] = required_skills
        if quality_gates:
            payload["quality_gates"] = quality_gates
        if eval_goals:
            payload["eval_goal"] = " / ".join(eval_goals)

    payload.setdefault("schema", "legion.heavy-task.plan.v1")
    payload.setdefault("mode", "legion-generate-slices")
    payload.setdefault("task", task)
    # Append to whatever task the plan source settled on, so an explicit task
    # inside a JSON plan file is preserved and still carries the guidance.
    # Only a string task is appended to: coercing an authored list or object
    # through str() would silently replace a plan author's structured field
    # with its repr, and only when guidance happened to be active. When the
    # task is not a string the guidance is not delivered here, and the delivery
    # receipt records that truthfully.
    if guidance and isinstance(payload.get("task"), str):
        payload["task"] = _append_guidance(payload["task"], guidance)
    payload["runner"] = runner["name"]
    payload["profile"] = runner["pipeline"]["profile"]
    _write_json(plan_path, payload)
    return payload


def write_plan_from_file(plan_file: str, plan_path: Path, runner: dict[str, Any], task: str, base_dir: Path) -> dict[str, Any]:
    return write_plan_from_files([plan_file], plan_path, runner, task, base_dir)


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
    lifecycle_stages = [
        *PIPELINE_STAGES[:2],
        "learning-context",
        *PIPELINE_STAGES[2:],
    ]
    return [
        {
            "stage": stage,
            "status": "pending",
            "artifacts": PIPELINE_STAGE_ARTIFACTS.get(stage, []),
        }
        for stage in lifecycle_stages
    ]


def _set_stage_status(stages: list[dict[str, Any]], stage: str, status: str, error: str = "") -> None:
    for item in stages:
        if item["stage"] == stage:
            item["status"] = status
            if status == "running":
                item.setdefault("started_at", _iso_utc())
            elif status in {"passed", "failed", "skipped"}:
                item["completed_at"] = _iso_utc()
                item["terminal_status"] = {
                    "passed": "passed",
                    "failed": "failed",
                    "skipped": "not_run",
                }[status]
            if error:
                item["error"] = error
            return


def _skip_pending_stages(stages: list[dict[str, Any]]) -> None:
    for item in stages:
        if item.get("status") == "pending":
            item["status"] = "skipped"
            item["terminal_status"] = "not_run"
            item["completed_at"] = _iso_utc()


def write_stage_status(run_dir: Path, stages: list[dict[str, Any]]) -> None:
    _write_json(run_dir / "stage-status.json", {"schema": "legion.run.stage-status.v1", "stages": stages})


def write_artifact_manifest(run_dir: Path) -> dict[str, Any]:
    names = set(PIPELINE_REQUIRED_ARTIFACTS)
    # Walk the tree, not just the top level. The fanout, validate and review
    # learning bundles live under learning-contexts/, and a manifest that skips
    # them cannot detect a post-run edit to what a stage was told it received.
    for path in sorted(run_dir.rglob("*")):
        if not path.is_file() or path.is_symlink():
            continue
        names.add(path.relative_to(run_dir).as_posix())
    artifacts = []
    for name in sorted(names):
        path = run_dir / name
        exists = path.exists()
        entry = {
            "path": name,
            "exists": exists,
            "size_bytes": path.stat().st_size if exists else 0,
        }
        if exists and name != "artifact-manifest.json":
            entry["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
        artifacts.append(entry)
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


def _feedback_items(payload: Any) -> list[dict[str, Any]]:
    if not isinstance(payload, dict):
        return []
    raw = payload.get("learning_feedback")
    if raw is None:
        raw = payload.get("learning_outcomes")
    if isinstance(raw, dict):
        return [raw]
    if isinstance(raw, list):
        return [item for item in raw if isinstance(item, dict)]
    return []


def _split_entity(value: Any, *, default_type: str, default_name: str) -> tuple[str, str]:
    text = str(value or "").strip()
    if ":" in text:
        target_type, target_name = text.split(":", 1)
        target_type = _short(target_type, 80)
        target_name = _short(target_name, 160)
        if target_type and target_name:
            return target_type, target_name
    return _short(default_type, 80), _short(default_name, 160)


def _runner_learning_target(runner: dict[str, Any]) -> tuple[str, str]:
    """Return the same entity used for context retrieval and feedback storage."""
    return _split_entity(
        runner.get("learning_entity"),
        default_type=str(
            runner.get("target_type") or runner.get("mode") or "runner"
        ),
        default_name=str(runner.get("name") or "runner"),
    )


_CORE_IDENTIFIER = re.compile(r"[A-Za-z0-9._:-]{1,80}")


def _core_identifier(value: Any) -> str:
    """Return a short identifier safe to interpolate into a first-party summary.

    A first-party summary is merged verbatim into trusted executor guidance, so
    only values core itself controls -- stage names, doctor check names -- may
    appear in one. Anything that does not look like a plain identifier is
    replaced rather than passed through, so a hostile value can never become a
    sentence in a prompt.
    """
    text = _as_text(value)
    return text if _CORE_IDENTIFIER.fullmatch(text) else "unnamed"


def _learning_outcome(
    *,
    source: str,
    target_type: str,
    target_name: str,
    severity: str,
    summary: str,
    evidence: str,
    run_id: str,
    source_path: Path,
    metadata: dict[str, Any] | None = None,
    first_party_summary: str = "",
) -> dict[str, Any]:
    """Build one durable outcome record.

    ``summary`` is the human-facing text and may quote third-party detail: a
    doctor message, a slice error, a reviewer finding. It is what reports show.

    ``first_party_summary`` is the separate, core-composed sentence that may be
    merged verbatim into trusted executor guidance. Trust attaches to that
    text, not to the producer, because every producer interpolates something it
    does not control. Leave it empty and the outcome is untrusted, and the
    promotion boundary reduces it to Legion's own fixed guardrail.

    Both markers are top-level fields set only here, never copied from
    caller-supplied ``metadata``, which ``_feedback_outcome`` populates from
    arbitrary extension keys.
    """
    normalized_severity = _short(severity or "medium", 40)
    if normalized_severity not in {"info", "low", "medium", "high", "critical"}:
        normalized_severity = "medium"
    return {
        "schema": "legion.outcome.v1",
        "id": _stable_id([source, target_type, target_name, run_id, summary, evidence]),
        "ts": _iso_utc(),
        "source": _short(source, 120),
        "target_type": _short(target_type, 80),
        "target_name": _short(target_name, 160),
        "severity": normalized_severity,
        "summary": _short(summary, 500),
        "evidence": _short(evidence, 1200),
        "run_id": run_id,
        "source_path": str(source_path),
        "provenance": "first-party" if first_party_summary else "extension",
        "provenance_summary": first_party_summary,
        "metadata": metadata or {},
    }


def _feedback_outcome(
    *,
    item: dict[str, Any],
    stage: str,
    artifact_path: Path,
    runner: dict[str, Any],
    run_id: str,
) -> dict[str, Any] | None:
    summary = _short(item.get("summary") or item.get("lesson") or item.get("message"), 500)
    if not summary:
        return None
    # Stage payloads are untrusted extension output. Core owns trust provenance
    # and scope, so a validator cannot label arbitrary prose as manual feedback
    # or redirect it to another entity that would receive trusted prompts.
    target_type, target_name = _runner_learning_target(runner)
    source = f"legion-run:{stage}"
    severity = _short(item.get("severity") or "medium", 40)
    if severity not in {"info", "low", "medium", "high", "critical"}:
        severity = "medium"
    evidence_raw = item.get("evidence")
    if isinstance(evidence_raw, (dict, list)):
        evidence = json.dumps(evidence_raw, sort_keys=True)
    else:
        evidence = str(evidence_raw or artifact_path)
    metadata: dict[str, Any] = {}
    raw_metadata = item.get("metadata")
    if isinstance(raw_metadata, dict):
        for key in sorted(
            value
            for value in raw_metadata
            if isinstance(value, str)
            and re.fullmatch(r"[A-Za-z0-9_.:-]{1,80}", value)
            and value not in {"stage", "artifact", "feedback_id"}
        )[:32]:
            value = raw_metadata[key]
            try:
                encoded = json.dumps(
                    value,
                    sort_keys=True,
                    separators=(",", ":"),
                    ensure_ascii=True,
                    allow_nan=False,
                )
            except (TypeError, ValueError):
                continue
            if len(encoded.encode("utf-8")) > 1024:
                continue
            candidate = {**metadata, key: value}
            if len(
                json.dumps(
                    candidate,
                    sort_keys=True,
                    separators=(",", ":"),
                    ensure_ascii=True,
                    allow_nan=False,
                ).encode("utf-8")
            ) > 4096:
                break
            metadata = candidate
    metadata = {
        **metadata,
        "stage": stage,
        "artifact": _short(artifact_path.name, 160),
        "feedback_id": _short(item.get("id") or "", 160),
    }
    return _learning_outcome(
        source=source,
        target_type=target_type,
        target_name=target_name,
        severity=severity,
        summary=summary,
        evidence=evidence,
        run_id=run_id,
        source_path=artifact_path,
        metadata=metadata,
    )


def validate_stage_payload(stage: str, payload: Any, artifact_path: Path) -> None:
    """Fail on explicit semantic failure, even when a hook exits zero."""
    if stage == "doctor":
        fail_count = 0
        if isinstance(payload, list):
            fail_count = sum(1 for item in payload if isinstance(item, dict) and str(item.get("severity", "")).lower() == "fail")
        elif isinstance(payload, dict):
            fail_count = _int_value(payload.get("fail") or payload.get("failed") or payload.get("failures"))
            if payload.get("ok") is False:
                fail_count = max(fail_count, 1)
        if fail_count:
            raise LegionRunError(f"stage semantic failure ({artifact_path.name}): doctor reported {fail_count} fail(s)", 1)
        return

    if stage == "fanout-apply" and isinstance(payload, dict):
        failed = _int_value(payload.get("failed") or payload.get("failures"))
        conflicts = _int_value(payload.get("apply_conflicts") or payload.get("conflicts"))
        if payload.get("ok") is False:
            failed = max(failed, 1)
        if failed or conflicts:
            raise LegionRunError(
                f"stage semantic failure ({artifact_path.name}): {failed} failed slice(s), {conflicts} apply conflict(s)",
                1,
            )
        return

    if stage in {"validate", "evaluate"} and isinstance(payload, dict):
        if payload.get("ok") is False or payload.get("passed") is False or _is_bad_status(payload.get("status")):
            raise LegionRunError(f"stage semantic failure ({artifact_path.name}): {stage} reported failure", 1)
        return

    if stage == "review":
        if not isinstance(payload, dict):
            raise LegionRunError(
                f"stage semantic failure ({artifact_path.name}): review gate failed: "
                "invalid terminal verdict: expected a command result object",
                1,
            )
        reason = _review_failure_reason(payload)
        if reason:
            raise LegionRunError(
                f"stage semantic failure ({artifact_path.name}): review gate failed: {reason}",
                1,
            )


def _doctor_learning_outcomes(
    payload: Any,
    *,
    runner: dict[str, Any],
    run_id: str,
    artifact_path: Path,
) -> list[dict[str, Any]]:
    default_type, default_name = _runner_learning_target(runner)
    outcomes: list[dict[str, Any]] = []
    items = payload if isinstance(payload, list) else []
    if isinstance(payload, dict) and (payload.get("ok") is False or _int_value(payload.get("fail"))):
        items = [
            {
                "severity": "fail",
                "entity": payload.get("entity") or f"{default_type}:{default_name}",
                "message": payload.get("message") or payload.get("error") or "legion-doctor reported a failing check.",
                "check": payload.get("check") or "legion-doctor",
            }
        ]
    for item in items:
        if not isinstance(item, dict):
            continue
        severity = str(item.get("severity") or "").lower()
        if severity not in {"fail", "failed", "error", "critical"}:
            continue
        target_type, target_name = _split_entity(
            item.get("entity") or item.get("target"),
            default_type=default_type,
            default_name=default_name,
        )
        # The message interpolates third-party text -- check_mcp folds in a
        # plugin's self-declared name, check_bridges echoes bridge output -- so
        # it stays in the human-facing summary and never becomes guidance.
        summary = _short(
            item.get("message")
            or item.get("summary")
            or item.get("check")
            or "legion-doctor reported a failing check.",
            500,
        )
        outcomes.append(
            _learning_outcome(
                source="legion-run:doctor",
                target_type=target_type,
                target_name=target_name,
                severity="high",
                summary=summary,
                evidence=json.dumps(item, sort_keys=True),
                run_id=run_id,
                source_path=artifact_path,
                metadata={
                    "stage": "doctor",
                    "artifact": artifact_path.name,
                    "doctor_check": item.get("check") or "",
                },
                first_party_summary=(
                    f"legion-doctor check {_core_identifier(item.get('check'))} failed."
                ),
            )
        )
    return outcomes


def _fanout_learning_outcomes(
    payload: Any,
    *,
    runner: dict[str, Any],
    run_id: str,
    artifact_path: Path,
) -> list[dict[str, Any]]:
    if not isinstance(payload, dict):
        return []
    failed = _int_value(payload.get("failed") or payload.get("failures"))
    conflicts = _int_value(payload.get("apply_conflicts") or payload.get("conflicts"))
    if payload.get("ok") is False:
        failed = max(failed, 1)
    if not failed and not conflicts:
        return []
    result_summaries = []
    results = payload.get("results") if isinstance(payload.get("results"), list) else []
    for item in results:
        if not isinstance(item, dict):
            continue
        if item.get("status") in {"failed", "error"} or item.get("error"):
            result_summaries.append(
                " ".join(str(bit) for bit in [item.get("id"), item.get("status"), item.get("error")] if bit)
            )
    details = "; ".join(result_summaries[:4])
    # Slice ids, statuses and error strings are planner- and executor-authored,
    # so they belong in the human-facing summary only. The counters below are
    # core's own and are the sentence allowed to become guidance.
    counters = f"legion-fanout reported {failed} failed slice(s) and {conflicts} apply conflict(s)."
    summary = f"{counters} {details}".strip() if details else counters
    target_type, target_name = _runner_learning_target(runner)
    return [
        _learning_outcome(
            source="legion-run:fanout-apply",
            target_type=target_type,
            target_name=target_name,
            severity="high",
            summary=summary,
            evidence=json.dumps(payload, sort_keys=True),
            run_id=run_id,
            source_path=artifact_path,
            metadata={
                "stage": "fanout-apply",
                "artifact": artifact_path.name,
                "failed": failed,
                "apply_conflicts": conflicts,
            },
            first_party_summary=counters,
        )
    ]


def _review_learning_outcomes(
    payload: Any,
    *,
    runner: dict[str, Any],
    run_id: str,
    artifact_path: Path,
) -> list[dict[str, Any]]:
    if not isinstance(payload, dict):
        return []
    reason = _review_failure_reason(payload)
    if not reason:
        return []
    verdict = _review_verdict_value(payload)
    detail = ""
    if isinstance(verdict, dict):
        summary = _short(verdict.get("summary"), 240)
        blocking = _blocking_review_findings(verdict)
        finding_titles = [
            _short(item.get("title") or item.get("detail") or "blocking finding", 160)
            for item in blocking[:3]
        ]
        detail = " ".join(part for part in [summary, "; ".join(finding_titles)] if part)
    else:
        detail = _short(verdict, 320)
    summary = f"legion review gate failed: {reason}."
    if detail:
        summary = f"{summary} {detail}"
    target_type, target_name = _runner_learning_target(runner)
    return [
        _learning_outcome(
            source="legion-run:review",
            target_type=target_type,
            target_name=target_name,
            severity="high",
            summary=summary,
            evidence=json.dumps(payload, sort_keys=True),
            run_id=run_id,
            source_path=artifact_path,
            metadata={
                "stage": "review",
                "artifact": artifact_path.name,
                "reason": reason,
            },
        )
    ]


def _terminal_failure_outcome(
    *,
    runner: dict[str, Any],
    run_id: str,
    run_dir: Path,
    failed_stage: str,
    message: str,
) -> dict[str, Any]:
    target_type, target_name = _runner_learning_target(runner)
    return _learning_outcome(
        source="legion-run:terminal",
        target_type=target_type,
        target_name=target_name,
        severity="medium",
        # The message is a LegionRunError string; for a review-stage failure it
        # embeds reviewer-model finding titles, so only the stage name is
        # allowed to become guidance.
        summary=f"legion-run failed at {failed_stage}: {message}",
        evidence=str(run_dir),
        run_id=run_id,
        source_path=run_dir / "failure.json",
        metadata={"stage": failed_stage, "artifact": "failure.json"},
        first_party_summary=f"legion-run failed at {_core_identifier(failed_stage)}.",
    )


def _dedupe_learning_outcomes(outcomes: list[dict[str, Any]]) -> list[dict[str, Any]]:
    seen: set[str] = set()
    deduped: list[dict[str, Any]] = []
    for outcome in outcomes:
        oid = str(outcome.get("id") or "")
        if not oid or oid in seen:
            continue
        seen.add(oid)
        deduped.append(outcome)
    return deduped


def collect_learning_outcomes(
    *,
    runner: dict[str, Any],
    run_id: str,
    run_dir: Path,
    stage_payloads: dict[str, Any] | None = None,
    failed_stage: str = "",
    failure_message: str = "",
) -> list[dict[str, Any]]:
    outcomes: list[dict[str, Any]] = []
    payloads = dict(stage_payloads or {})
    for stage in ["validate", "evaluate"]:
        if stage not in payloads:
            payload = _load_json_value(_stage_artifact_path(run_dir, stage))
            if payload is not None:
                payloads[stage] = payload

    for stage, payload in payloads.items():
        artifact_path = _stage_artifact_path(run_dir, stage)
        for item in _feedback_items(payload):
            outcome = _feedback_outcome(
                item=item,
                stage=stage,
                artifact_path=artifact_path,
                runner=runner,
                run_id=run_id,
            )
            if outcome:
                outcomes.append(outcome)

    doctor_payload = _load_json_value(run_dir / "doctor.json")
    if doctor_payload is not None:
        outcomes.extend(
            _doctor_learning_outcomes(
                doctor_payload,
                runner=runner,
                run_id=run_id,
                artifact_path=run_dir / "doctor.json",
            )
        )

    fanout_payload = _load_json_value(run_dir / "fanout.json")
    if fanout_payload is not None:
        outcomes.extend(
            _fanout_learning_outcomes(
                fanout_payload,
                runner=runner,
                run_id=run_id,
                artifact_path=run_dir / "fanout.json",
            )
        )

    review_payload = _load_json_value(run_dir / "review.json")
    if review_payload is not None:
        outcomes.extend(
            _review_learning_outcomes(
                review_payload,
                runner=runner,
                run_id=run_id,
                artifact_path=run_dir / "review.json",
            )
        )

    if failed_stage and failure_message:
        outcomes.append(
            _terminal_failure_outcome(
                runner=runner,
                run_id=run_id,
                run_dir=run_dir,
                failed_stage=failed_stage,
                message=failure_message,
            )
        )
    return _dedupe_learning_outcomes(outcomes)


def record_learning_feedback(
    *,
    runner: dict[str, Any],
    run_id: str,
    run_dir: Path,
    env: dict[str, str],
    stage_payloads: dict[str, Any] | None = None,
    failed_stage: str = "",
    failure_message: str = "",
) -> dict[str, Any]:
    outcomes = collect_learning_outcomes(
        runner=runner,
        run_id=run_id,
        run_dir=run_dir,
        stage_payloads=stage_payloads,
        failed_stage=failed_stage,
        failure_message=failure_message,
    )
    path = Path(env["LEGION_STATE_ROOT"]) / "self-learn" / "outcomes.jsonl"
    for outcome in outcomes:
        _append_jsonl(path, outcome)
    payload = {
        "schema": "legion.run.learning-feedback.v1",
        "recorded": len(outcomes),
        "outcomes_path": str(path),
        "outcomes": outcomes,
    }
    _write_json(run_dir / "learning-feedback.json", payload)
    return payload


def execute(
    runner: dict[str, Any],
    repo: Path,
    task: str,
    json_output: bool,
    *,
    stage_timeout_seconds: int,
    allow_generated_slices: bool,
    learning_context_mode: str,
) -> int:
    os.umask(0o077)
    require_clean_review_source(repo, timeout_seconds=stage_timeout_seconds)
    state = legion_state.resolve_state(str(repo))
    run_id, run_dir = reserve_run_directory(Path(state["state_root"]), runner["name"])
    profile = runner["pipeline"]["profile"]
    stages = _new_stage_records()
    current_stage = ""

    env = dict(os.environ)
    inherited_trace_id = str(env.get("LEGION_TRACE_ID") or "").strip()
    # Nested runs join their parent's trace; top-level runs own a fresh trace.
    # The report must query the same identity downstream stages emit.
    trace_id = inherited_trace_id or run_id
    env.update(
        {
            "LEGION_STATE_ROOT": state["state_root"],
            "LEGION_TELEMETRY_DIR": state["telemetry_dir"],
            "LEGION_REGISTRY_DIR": state["registry_dir"],
            "LEGION_REPOS_FILE": state["repos_file"],
            "LEGION_BENCH_DIR": state["bench_dir"],
            "LEGION_REPORTS_DIR": state["reports_dir"],
            "LEGION_RUN_ID": run_id,
            "LEGION_TRACE_ID": inherited_trace_id or trace_id,
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
            "LEGION_REPOSITORY_IDENTITY": state["repository_identity"],
            "LEGION_LEARNING_CONTEXT_MODE": learning_context_mode,
        }
    )
    learning_entity = str(
        runner.get("learning_entity")
        or f"{runner.get('target_type', 'runner')}:{runner['name']}"
    )
    context_path = run_dir / "learning-context.json"
    usage_path = run_dir / "learning-usage.json"
    context_receipt_path = run_dir / "learning-context-receipt.json"
    receipts_path = run_dir / "learning-receipts.json"
    context_directory = run_dir / "learning-contexts"
    context_directory.mkdir(mode=0o700, exist_ok=True)
    learning_context = _empty_learning_context(
        str(state["repository_identity"]), learning_entity, "plan"
    )
    _write_json(context_path, learning_context)
    _write_json(usage_path, learning_context["usage"])
    learning_revision = _learning_revision(learning_context)
    # learning-context-receipt.json is a hard-required pipeline artifact, but it
    # was only written once compile_learning_context("plan") ran. A doctor or
    # self-learn-hints failure aborts before that, leaving a run directory that
    # is missing a mandatory artifact. Seed it here so every terminal state,
    # including the earliest failures, has a well-formed receipt.
    _write_json(
        context_receipt_path,
        {
            "schema": "legion.learning-context-receipt.v1",
            "status": "pending",
            "path": str(context_path),
            "revision": learning_revision,
            "usage": learning_context["usage"],
        },
    )
    learning_dispositions = _learning_dispositions(learning_context, learning_context_mode)
    learning_descriptor = _learning_context_descriptor(
        context_path, learning_revision, learning_context_mode, learning_dispositions
    )
    learning_bundles: dict[str, dict[str, Any]] = {}
    learning_descriptors: dict[str, dict[str, Any]] = {
        "plan": learning_descriptor
    }
    learning_receipts: list[dict[str, Any]] = []
    _write_learning_receipts(
        receipts_path,
        descriptor=learning_descriptor,
        descriptors=learning_descriptors,
        receipts=learning_receipts,
    )

    def stage_run(
        stage: str,
        argv: list[str],
        artifact: Path,
        *,
        shell: bool = False,
        hermetic: bool = False,
        stage_env: dict[str, str] | None = None,
    ) -> Any:
        nonlocal current_stage
        current_stage = stage
        _set_stage_status(stages, stage, "running")
        write_stage_status(run_dir, stages)
        payload = run_process(
            argv,
            hermetic_stage_env(stage_env or env) if hermetic else (stage_env or env),
            repo,
            artifact,
            shell=shell,
            timeout_seconds=stage_timeout_seconds,
        )
        validate_stage_payload(stage, payload, artifact)
        _set_stage_status(stages, stage, "passed")
        write_stage_status(run_dir, stages)
        return payload

    def compile_learning_context(boundary: str) -> dict[str, Any]:
        """Compile and freeze one context for one lifecycle decision boundary."""
        nonlocal current_stage, learning_context, learning_revision
        nonlocal learning_dispositions, learning_descriptor
        if boundary not in LEARNING_CONTEXT_BOUNDARIES:
            raise LegionRunError(f"unknown learning context boundary: {boundary}")
        if boundary in learning_bundles:
            return learning_bundles[boundary]
        current_stage = {
            "plan": "learning-context",
            "fanout": "plan",
            "validate": "validate",
            "review": "review",
        }[boundary]
        if boundary == "plan":
            _set_stage_status(stages, "learning-context", "running")
            write_stage_status(run_dir, stages)
            bundle_context_path = context_path
            bundle_usage_path = usage_path
            bundle_receipt_path = context_receipt_path
            command_artifact = run_dir / ".learning-context-command.json"
        else:
            bundle_context_path = context_directory / f"{boundary}.json"
            bundle_usage_path = context_directory / f"{boundary}-usage.json"
            bundle_receipt_path = context_directory / f"{boundary}-receipt.json"
            command_artifact = context_directory / f".{boundary}-command.json"
        compiled: Any = _empty_learning_context(
            str(state["repository_identity"]), learning_entity, boundary
        )
        _write_json(bundle_context_path, compiled)
        _write_json(bundle_usage_path, compiled["usage"])
        status = "off"
        if learning_context_mode != "off":
            try:
                compiled = run_process(
                    [
                        _cmd("legion-self-learn"),
                        "compile-context",
                        "--repo",
                        str(repo),
                        "--entity",
                        learning_entity,
                        "--stage",
                        boundary,
                        "--json",
                    ],
                    env,
                    repo,
                    command_artifact,
                    timeout_seconds=stage_timeout_seconds,
                )
            except LegionRunError as exc:
                command_artifact.unlink(missing_ok=True)
                _write_json(
                    bundle_receipt_path,
                    {
                        "schema": "legion.learning-context-receipt.v1",
                        "status": "failed",
                        "path": str(bundle_context_path),
                        "revision": _learning_revision(
                            _empty_learning_context(
                                str(state["repository_identity"]),
                                learning_entity,
                                boundary,
                            )
                        ),
                        "exit_code": exc.code,
                    },
                )
                bundle_context_path.chmod(0o400)
                bundle_usage_path.chmod(0o400)
                raise
            command_artifact.unlink(missing_ok=True)
            if isinstance(compiled, dict):
                compiled = dict(compiled)
                compiled.pop("exit_code", None)
                compiled.pop("stderr", None)
            if compiled == {"ok": True}:
                # An *absent* compiler degrades to no guidance; advisory mode
                # continues, required mode fails. A compiler that crashed,
                # timed out, or returned a context failing its own contract is
                # a different class entirely and always fails the run, so a
                # forged budget or a boundary mismatch cannot pass unnoticed.
                compiled = _empty_learning_context(
                    str(state["repository_identity"]), learning_entity, boundary
                )
                status = "unavailable"
            else:
                status = "compiled"
        error = _learning_context_error(
            compiled,
            repository_identity=str(state["repository_identity"]),
            entity=learning_entity,
            stage=boundary,
        )
        if error:
            _write_json(
                bundle_receipt_path,
                {
                    "schema": "legion.learning-context-receipt.v1",
                    "status": "failed",
                    "path": str(bundle_context_path),
                    "revision": _learning_revision(
                        _empty_learning_context(
                            str(state["repository_identity"]),
                            learning_entity,
                            boundary,
                        )
                    ),
                    "error": error,
                },
            )
            bundle_context_path.chmod(0o400)
            bundle_usage_path.chmod(0o400)
            # A context that fails its own contract -- forged budgets, token
            # accounting that does not add up, a boundary that does not match
            # the one requested -- indicates tampering or a broken toolchain,
            # not an absent compiler. It fails the run in every mode so the
            # operator sees it, rather than silently continuing unguided.
            raise LegionRunError(
                f"stage semantic failure ({bundle_receipt_path.name}): {error}", 1
            )
        safe_context = _safe_learning_context(compiled)
        _write_json(bundle_context_path, safe_context)
        _write_json(bundle_usage_path, safe_context["usage"])
        revision = _learning_revision(safe_context)
        dispositions = _learning_dispositions(
            safe_context, learning_context_mode
        )
        descriptor = _learning_context_descriptor(
            bundle_context_path,
            revision,
            learning_context_mode,
            dispositions,
        )
        _write_json(
            bundle_receipt_path,
            {
                "schema": "legion.learning-context-receipt.v1",
                "status": status,
                "path": str(bundle_context_path),
                "revision": revision,
                "usage": safe_context["usage"],
            },
        )
        bundle_context_path.chmod(0o400)
        bundle_usage_path.chmod(0o400)
        bundle = {
            "boundary": boundary,
            "context": safe_context,
            "path": bundle_context_path,
            "usage_path": bundle_usage_path,
            "receipt_path": bundle_receipt_path,
            "revision": revision,
            "dispositions": dispositions,
            "descriptor": descriptor,
            "status": status,
        }
        learning_bundles[boundary] = bundle
        learning_descriptors[boundary] = descriptor
        if boundary == "plan":
            learning_context = safe_context
            learning_revision = revision
            learning_dispositions = dispositions
            learning_descriptor = descriptor
        _write_learning_receipts(
            receipts_path,
            descriptor=learning_descriptors.get("plan", learning_descriptor),
            descriptors=learning_descriptors,
            receipts=learning_receipts,
        )
        if status == "unavailable" and learning_context_mode == "required":
            raise LegionRunError(
                f"required learning compiler is unavailable at {boundary}", 1
            )
        if boundary == "plan":
            _set_stage_status(stages, "learning-context", "passed")
            write_stage_status(run_dir, stages)
        return bundle

    def activate_learning_context(bundle: dict[str, Any]) -> list[str]:
        verified = _verify_learning_context_snapshot(
            bundle["path"],
            bundle["revision"],
            repository_identity=str(state["repository_identity"]),
            entity=learning_entity,
            stage=bundle["boundary"],
        )
        env.update(
            {
                "LEGION_LEARNING_CONTEXT_PATH": str(bundle["path"]),
                "LEGION_LEARNING_CONTEXT_REVISION": bundle["revision"],
                "LEGION_LEARNING_CONTEXT_BOUNDARY": bundle["boundary"],
                "LEGION_LEARNING_CONTEXT_REQUIRED_ACK": (
                    "1"
                    if learning_context_mode == "required"
                    and bundle["context"]["selected_hints"]
                    else "0"
                ),
            }
        )
        return _delivered_guidance(verified, learning_context_mode)

    def record_learning_receipt(
        bundle: dict[str, Any], boundary: str, kind: str, status: str
    ) -> None:
        _verify_learning_context_snapshot(
            bundle["path"],
            bundle["revision"],
            repository_identity=str(state["repository_identity"]),
            entity=learning_entity,
            stage=bundle["boundary"],
        )
        learning_receipts.append(
            {
                "boundary": boundary,
                "context_boundary": bundle["boundary"],
                "kind": kind,
                "status": status,
                "path": str(bundle["path"]),
                "revision": bundle["revision"],
                "dispositions": bundle["dispositions"],
            }
        )
        _write_learning_receipts(
            receipts_path,
            descriptor=learning_descriptors.get("plan", learning_descriptor),
            descriptors=learning_descriptors,
            receipts=learning_receipts,
        )

    def finalize_self_learning(
        *,
        summary_text: str,
        strict: bool,
        stage_payloads: dict[str, Any] | None = None,
        failed_stage: str = "",
        failure_message: str = "",
    ) -> dict[str, Any]:
        nonlocal current_stage
        current_stage = "self-learn"
        _set_stage_status(stages, "self-learn", "running")
        write_stage_status(run_dir, stages)
        feedback = record_learning_feedback(
            runner=runner,
            run_id=run_id,
            run_dir=run_dir,
            env=env,
            stage_payloads=stage_payloads,
            failed_stage=failed_stage,
            failure_message=failure_message,
        )
        record = best_effort_process(
            [
                _cmd("legion-self-learn"),
                "record",
                "--entity",
                learning_entity,
                "--summary",
                summary_text,
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
        learn = best_effort_process(
            [_cmd("legion-self-learn"), "run", "--repo", str(repo), "--apply-memory", "--json"],
            env,
            repo,
            run_dir / "self-learn-run.json",
        )
        payload = {"learning_feedback": feedback, "record": record, "run": learn}
        _write_json(run_dir / "self-learn.json", payload)
        failed = _exit_code(record) != 0 or _exit_code(learn) != 0
        _set_stage_status(
            stages,
            "self-learn",
            "failed" if failed else "passed",
            "self-learning command failed" if failed else "",
        )
        write_stage_status(run_dir, stages)
        if strict and failed:
            raise LegionRunError("stage failed (self-learn.json): self-learning command failed", 1)
        return payload

    def finalize_success() -> dict[str, Any]:
        try:
            persisted_receipts = json.loads(receipts_path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            raise LegionRunError("learning receipt integrity failure", 1) from exc
        if not _learning_receipts_valid(persisted_receipts):
            raise LegionRunError("learning receipt integrity failure", 1)
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
        receipt_boundary = {
            "plan": ("plan", "plan", "delivery"),
            "route": ("fanout", "fanout-apply", "delivery"),
            "fanout-apply": ("fanout", "fanout-apply", "delivery"),
            "validate": ("validate", "validate", "deterministic-verification"),
            "review": ("review", "final-review", "delivery"),
        }.get(failed_stage)
        if receipt_boundary and not any(
            receipt.get("boundary") == receipt_boundary[1]
            for receipt in learning_receipts
        ):
            bundle = learning_bundles.get(receipt_boundary[0])
            if bundle is not None:
                try:
                    record_learning_receipt(
                        bundle, receipt_boundary[1], receipt_boundary[2], "failed"
                    )
                except LegionRunError:
                    # The original integrity failure is already the terminal
                    # reason; never attest a changed context while finalizing.
                    pass
        _set_stage_status(stages, failed_stage, "failed", str(exc))
        if exc.code == 124:
            for item in stages:
                if item["stage"] == failed_stage:
                    item["terminal_status"] = "timed_out"
                    break
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
            best_effort_process([_cmd("legion-report"), "--trace", trace_id, "--json"], env, repo, run_dir / "legion-report.json")
        if failed_stage != "self-learn":
            finalize_self_learning(
                summary_text=f"legion-run failed at {failed_stage}: {exc}",
                strict=False,
                failed_stage=failed_stage,
                failure_message=str(exc),
            )
        elif not (run_dir / "self-learn.json").exists():
            _write_json(
                run_dir / "self-learn.json",
                {"record": {"ok": False, "error": str(exc)}, "run": {"ok": False, "error": str(exc)}},
            )
        _set_stage_status(stages, "heal-plan", "running")
        write_stage_status(run_dir, stages)
        heal = best_effort_process([_cmd("legion-heal"), "plan", "--repo", str(repo), "--json"], env, repo, run_dir / "heal-plan.json")
        _set_stage_status(
            stages,
            "heal-plan",
            "failed" if _exit_code(heal) != 0 else "passed",
            "heal-plan command failed" if _exit_code(heal) != 0 else "",
        )
        write_stage_status(run_dir, stages)
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
        stage_run("self-learn-hints", [_cmd("legion-self-learn"), "hints", "--entity", learning_entity, "--json"], run_dir / "self-learn-hints.json")
        plan_bundle = compile_learning_context("plan")
        plan_guidance = activate_learning_context(plan_bundle)
        # LEGION_TASK is the planner's task contract. Put bounded guidance in
        # the actual planner input, not merely in an artifact written later.
        env["LEGION_TASK"] = _append_guidance(task, plan_guidance)

        current_stage = "plan"
        _set_stage_status(stages, "plan", "running")
        write_stage_status(run_dir, stages)
        plan_path = run_dir / "plan.json"
        # Track what this process delivered, not what the planner chose to echo
        # back. The plan-command branch hands guidance to the planner through
        # LEGION_TASK; a conforming hook may legitimately emit a refined task or
        # omit the field entirely, so inspecting plan.json would report a
        # delivery failure that did not happen.
        plan_delivered = False
        if runner.get("plan_files"):
            # The plan-file branch assembles plan.json in-process and never
            # reads the environment, so guidance has to be threaded in
            # explicitly. Passing only `task` here silently dropped it while
            # the receipt below still attested delivery.
            written = write_plan_from_files(
                list(runner["plan_files"]),
                plan_path,
                runner,
                task,
                repo,
                guidance=plan_guidance,
            )
            # This branch assembles plan.json itself, so the artifact is the
            # delivery and can be checked directly.
            plan_delivered = _guidance_present(written.get("task"), plan_guidance)
            _write_json(run_dir / "plan-command.json", {"ok": True, "source": "plan-file", "paths": runner["plan_files"]})
        else:
            run_process(
                [runner["commands"]["plan"]],
                env,
                repo,
                run_dir / "plan-command.json",
                shell=True,
                timeout_seconds=stage_timeout_seconds,
            )
            normalize_plan_file(plan_path, runner, task)
            # The planner received the guidance through LEGION_TASK. Whether it
            # echoes that field back into plan.json is its own choice.
            plan_delivered = bool(plan_guidance)
        plan_payload = _load_json_object(plan_path)
        if learning_context_mode == "required":
            _require_learning_context_ack(
                plan_payload, plan_bundle, plan_guidance, "planner"
            )
        plan_payload["learning_context"] = plan_bundle["descriptor"]
        _write_json(plan_path, plan_payload)
        env["LEGION_TASK"] = task
        record_learning_receipt(
            plan_bundle,
            "plan",
            "delivery",
            (
                "acknowledged"
                if plan_delivered and learning_context_mode == "required"
                else "delivered" if plan_delivered
                else "not_delivered" if plan_guidance
                else learning_context_mode
            ),
        )
        fanout_bundle = compile_learning_context("fanout")
        fanout_guidance = activate_learning_context(fanout_bundle)
        slices_path = run_dir / "slices.jsonl"
        if runner.get("slices_file"):
            copy_explicit_slices(str(runner["slices_file"]), slices_path, repo)
        ensure_slices(
            slices_path,
            plan_path,
            runner,
            task,
            allow_generated_slices=allow_generated_slices,
        )
        slices = load_slices(slices_path)
        if fanout_guidance:
            for item in slices:
                item["task"] = _append_guidance(
                    str(item.get("task") or ""), fanout_guidance
                )
            _write_jsonl(slices_path, slices)
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
                timeout_seconds=stage_timeout_seconds,
            )
            routes.append({"slice": item, "route": route})
        _write_json(run_dir / "routes.json", {"routes": routes})
        _set_stage_status(stages, "route", "passed")
        write_stage_status(run_dir, stages)

        # Routing is a separate command boundary. Reauthenticate immediately
        # before the fanout consumer so a same-user replacement cannot survive
        # the interval between context activation and delegated execution.
        activate_learning_context(fanout_bundle)
        fanout_error: LegionRunError | None = None
        try:
            fanout_payload = stage_run("fanout-apply", [_cmd("legion-fanout"), "--slices", str(slices_path), "--repo", str(repo), "--apply", "--json"], run_dir / "fanout.json")
        except LegionRunError as exc:
            fanout_error = exc
            fanout_payload = _load_json_value(run_dir / "fanout.json")
        ledger_source = ""
        if isinstance(fanout_payload, dict):
            ledger_source = str(fanout_payload.get("task_ledger_path") or "")
        if ledger_source and Path(ledger_source).is_file():
            shutil.copyfile(ledger_source, run_dir / "task-ledger.json")
        else:
            _write_json(
                run_dir / "task-ledger.json",
                {
                    "schema": "legion.task-ledger.v1",
                    "status": "unavailable",
                    "reason": "fanout did not return a task ledger",
                },
            )
            if fanout_error is None:
                raise LegionRunError(
                    "stage semantic failure (fanout.json): successful fanout "
                    "did not return a readable task ledger",
                    1,
                )
        if fanout_error is not None:
            raise fanout_error
        record_learning_receipt(
            fanout_bundle,
            "fanout-apply",
            "delivery",
            "delivered" if fanout_guidance else learning_context_mode,
        )
        validation_bundle = compile_learning_context("validate")
        validation_guidance = activate_learning_context(validation_bundle)
        validation_payload = stage_run("validate", [runner["commands"]["validate"]], run_dir / "validation.json", shell=True, hermetic=True)
        if learning_context_mode == "required":
            _require_learning_context_ack(
                validation_payload,
                validation_bundle,
                validation_guidance,
                "validator",
            )
        if isinstance(validation_payload, dict):
            validation_payload["learning_context"] = validation_bundle["descriptor"]
            validation_payload["learning_context_dispositions"] = validation_bundle[
                "dispositions"
            ]
            _write_json(run_dir / "validation.json", validation_payload)
        record_learning_receipt(
            validation_bundle,
            "validate",
            "deterministic-verification",
            (
                "acknowledged"
                if validation_guidance and learning_context_mode == "required"
                else "verified" if validation_guidance else learning_context_mode
            ),
        )
        current_stage = "review"
        _set_stage_status(stages, "review", "running")
        write_stage_status(run_dir, stages)
        review_bundle = compile_learning_context("review")
        review_guidance = activate_learning_context(review_bundle)
        review_input = create_review_snapshot(
            repo,
            run_dir,
            timeout_seconds=stage_timeout_seconds,
            learning_context=review_bundle["descriptor"],
        )
        review_route = run_process(
            [_cmd("legion-route"), "final-review", "--task", "independent final review"],
            env,
            repo,
            run_dir / "review-route.json",
            timeout_seconds=stage_timeout_seconds,
        )
        review_executor = str(review_route.get("executor") if isinstance(review_route, dict) else "")
        review_task = (
            f"Review the immutable repository diff {review_input['base_sha']}...HEAD after "
            "deterministic validation. "
            "Return one JSON object only: {\"verdict\":\"approve|request_changes\","
            "\"summary\":string,\"findings\":[{\"severity\":\"critical|high|medium|low\","
            "\"title\":string,\"detail\":string}]}. Focus on correctness, unnecessary complexity, "
            "and spec adherence."
        )
        review_task = _append_guidance(review_task, review_guidance)
        # Snapshot creation and route resolution are allowed to read repository
        # state but not to substitute the context delivered to the reviewer.
        activate_learning_context(review_bundle)
        if review_executor == "claude":
            stage_run("review", [_cmd("legion-claude"), "run", "--repo", str(repo), "--base", review_input["head_sha"], "--model", str(review_route.get("model") or ""), "--effort", str(review_route.get("reasoning_effort") or "high"), "--sandbox", "read-only", "--no-fallback", "--task", review_task], run_dir / "review.json")
        elif review_executor == "codex":
            stage_run("review", [_cmd("legion-delegate"), "review", "--model", str(review_route.get("model") or ""), "--reasoning-effort", str(review_route.get("reasoning_effort") or "xhigh"), "--repo", str(repo), "--base", review_input["base_sha"], "--head", review_input["head_sha"], "--task", review_task], run_dir / "review.json")
        elif review_executor == "self":
            raise LegionRunError(
                "final-review resolved to executor=self; an independent delegated "
                "reviewer is required",
                1,
            )
        else:
            stage_run("review", [_cmd("legion-delegate"), "run", "--executor", review_executor, "--model", str(review_route.get("model") or ""), "--sandbox", "read-only", "--repo", str(repo), "--base", review_input["head_sha"], "--task", review_task], run_dir / "review.json")
        record_learning_receipt(
            review_bundle,
            "final-review",
            "delivery",
            "delivered" if review_guidance else learning_context_mode,
        )
        eval_payload = stage_run("evaluate", [runner["commands"]["evaluate"]], run_dir / "eval.json", shell=True, hermetic=True)
        stage_run("report", [_cmd("legion-report"), "--trace", trace_id, "--json"], run_dir / "legion-report.json", stage_env=env)
        stage_run("share", [_cmd("legion-share"), "--window", "1d", "--json"], run_dir / "share.json")
        finalize_self_learning(
            summary_text=f"legion-run completed profile {profile}",
            strict=True,
            stage_payloads={"validate": validation_payload, "evaluate": eval_payload},
        )

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
    parser.add_argument("--plan-file", dest="plan_files", action="append", default=[])
    parser.add_argument(
        "--slices-file",
        default="",
        help="repo-relative or absolute JSONL work queue for direct mode",
    )
    parser.add_argument("--validate-command", "--validate", dest="validate_command", default="")
    parser.add_argument("--evaluate-command", "--evaluate", dest="evaluate_command", default="")
    parser.add_argument(
        "--stage-timeout-seconds",
        type=int,
        default=1800,
        help="maximum duration for each external lifecycle stage (default: 1800)",
    )
    parser.add_argument(
        "--allow-generated-slices",
        action="store_true",
        help="enable legacy generic slices when the plan provider does not emit slices.jsonl",
    )
    parser.add_argument(
        "--learning-context-mode",
        choices=sorted(LEARNING_CONTEXT_MODES),
        default=os.environ.get("LEGION_LEARNING_CONTEXT_MODE", "advisory"),
        help="trusted learning compatibility mode: off, observe, advisory, or required (default: advisory)",
    )
    parser.add_argument("--repo", default=os.getcwd())
    parser.add_argument("--task", required=True)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    if args.learning_context_mode not in LEARNING_CONTEXT_MODES:
        parser.error("--learning-context-mode must be one of: off, observe, advisory, required")

    previous_sigterm = signal.getsignal(signal.SIGTERM)
    previous_sigint = signal.getsignal(signal.SIGINT)

    def _cancel(signum: int, _frame: Any) -> None:
        raise LegionRunError(f"run cancelled by {signal.Signals(signum).name}", 130)

    signal.signal(signal.SIGTERM, _cancel)
    signal.signal(signal.SIGINT, _cancel)
    try:
        repo = Path(args.repo).expanduser().resolve()
        if args.plugin or args.plugin_manifest:
            manifest = find_manifest(repo, args.plugin, args.plugin_manifest)
            runner = load_plugin(manifest, args.plugin, args.profile)
            if args.name:
                # A plugin can be reused for many independently learned heavy
                # tasks; an explicit run name scopes that context accordingly.
                runner["learning_entity"] = f"heavy-task:{_slug(args.name)}"
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
        if args.stage_timeout_seconds < 1:
            raise LegionRunError("--stage-timeout-seconds must be at least 1")
        return execute(
            runner,
            repo,
            args.task,
            args.json,
            stage_timeout_seconds=args.stage_timeout_seconds,
            allow_generated_slices=args.allow_generated_slices,
            learning_context_mode=args.learning_context_mode,
        )
    except LegionRunError as exc:
        print(f"legion-run: {exc}", file=sys.stderr)
        return exc.code
    finally:
        signal.signal(signal.SIGTERM, previous_sigterm)
        signal.signal(signal.SIGINT, previous_sigint)


if __name__ == "__main__":
    raise SystemExit(main())
