#!/usr/bin/env python3
"""legion-route — resolve a task archetype to an executor/model/sandbox/effort.

Reads routing.toml (executor policy) plus models.toml (default model catalog) and
prints the resolved decision as JSON, so legion-delegate / the runners don't
hardcode model choices. Pure stdlib; full routing uses tomllib on Python 3.11+,
while simple model-ref lookups use a tiny parser for shell entrypoint portability.

  legion-route bulk-mechanical-edit
  legion-route --archetype bulk-mechanical-edit
  legion-route implement-feature --task "Build the demo flow"
  legion-route --list
  legion-route --model-ref codex_workhorse
"""
import argparse
import ast
import copy
import json
import os
import sys
from pathlib import Path

sys.path.insert(
    0,
    os.path.abspath(
        os.path.join(os.path.dirname(__file__), "..", "..", "legion-observability", "scripts")
    ),
)
from legion_executor_registry import (  # noqa: E402
    ExecutorRegistryError,
    executor_family as registry_executor_family,
    load_coding_executor_families,
    load_executor_registry,
)

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover - py<3.11
    tomllib = None

_CONFIG_DIR = os.path.join(os.path.dirname(__file__), "..", "config")
_DEFAULT_FILE = os.path.join(_CONFIG_DIR, "routing.toml")
_DEFAULT_MODELS_FILE = os.path.join(_CONFIG_DIR, "models.toml")
_DEFAULT_EXECUTORS_FILE = os.path.join(_CONFIG_DIR, "executors.toml")


class RouteConfigError(ValueError):
    pass


def resolve_primary(env=None):
    """Resolve the operator's PRIMARY harness — the one for which a `self`-routed
    archetype means "do it inline". Legion is harness-symmetric, so this is NOT
    hardcoded to Claude/Opus. Keep in lockstep with lib/primary.sh.
    """
    env = os.environ if env is None else env
    explicit = env.get("LEGION_PRIMARY")
    if explicit:
        return explicit
    if env.get("CLAUDECODE") or env.get("CLAUDE_CODE_ENTRYPOINT"):
        return "claude"
    if env.get("CODEX_SANDBOX") or env.get("CODEX_HOME") or env.get("CODEX_THREAD_ID"):
        return "codex"
    if env.get("OPENCODE") or env.get("OPENCODE_BIN") or env.get("OPENCODE_SERVER"):
        return "opencode"
    if env.get("HERMES_HOME") or env.get("HERMES_SESSION_ID"):
        return "hermes"
    if env.get("CURSOR_AGENT") or env.get("CURSOR_TRACE_ID"):
        return "cursor"
    if str(env.get("AI_AGENT") or "").strip().lower() == "pi" or env.get("PI_CODING_AGENT"):
        return "pi"
    return "claude"


def executor_family(name):
    """Collapse executor variants to the harness family that owns the process."""
    normalized = str(name or "").strip().lower()
    if normalized == "self":
        return "self"
    # Routing may be imported by an embedding process that changes
    # LEGION_EXECUTORS_FILE between calls.  Resolve this lightweight identity
    # lookup from the active registry rather than freezing an allowlist here.
    return registry_executor_family(normalized, load_coding_executor_families()) or normalized


def delegated_worktree_cwd(cwd=None):
    """Whether the physical working directory is a Legion-managed worktree."""
    try:
        path = Path.cwd() if cwd is None else Path(cwd)
        parts = path.resolve().parts
    except (OSError, RuntimeError):
        return False
    return any(
        parts[index:index + 2] == (".legion", "worktrees")
        for index in range(len(parts) - 1)
    )


def delegated_context(env=None, cwd=None):
    """Whether Legion is already running inside a delegated executor."""
    env = os.environ if env is None else env
    if env.get("LEGION_ACTIVE") == "1" or env.get("LEGION_EXECUTOR") == "1":
        return True
    try:
        if int(env.get("LEGION_DEPTH", "0")) > 0:
            return True
    except ValueError:
        pass
    return delegated_worktree_cwd(cwd)


def preflight(route, primary, env=None):
    """Return a recursion-aware route without changing configured policy."""
    out = copy.deepcopy(route)
    target = str(out.get("executor") or "")
    primary_family = executor_family(primary)
    target_family = executor_family(target)
    if target == "self":
        action, reason = "inline", "inline-self-route"
    elif delegated_context(env):
        action, reason = "inline", "delegated-context-route"
    else:
        action, reason = "delegate", "delegated-route"
    out["effective_executor"] = "self" if action == "inline" else target
    out["preflight"] = {
        "action": action,
        "reason": reason,
        "primary": primary_family,
        "target_executor": target,
        "target_family": target_family,
    }
    return out


def load_executors(path=None):
    execs_path = path or os.environ.get("LEGION_EXECUTORS_FILE", _DEFAULT_EXECUTORS_FILE)
    try:
        return load_executor_registry(execs_path)
    except ExecutorRegistryError as exc:
        raise RouteConfigError(str(exc)) from exc


def executor_info(execs, name):
    info = execs.get(name)
    if not isinstance(info, dict):
        raise RouteConfigError(f"unknown executor '{name}'")
    out = dict(info)
    out["name"] = name
    return out


def review_order(table, execs):
    """Ordered reviewer candidates: config order, minus anything that can't review.

    A reviewer is a candidate when it appears in ``[review].order`` and its
    executors.toml entry declares a ``review`` capability other than ``none``.
    Unknown names are dropped rather than raising, so removing an executor from
    the registry cannot wedge review for every caller.
    """
    section = table.get("review") if isinstance(table, dict) else None
    order = section.get("order") if isinstance(section, dict) else None
    if not isinstance(order, (list, tuple)):
        order = ["codex"]
    out = []
    for name in order:
        if not isinstance(name, str):
            continue
        info = execs.get(name)
        if not isinstance(info, dict):
            continue
        kind = info.get("review")
        if not isinstance(kind, str) or kind == "none" or not kind:
            continue
        out.append({"executor": name, "kind": kind,
                    "model_ref": info.get("review_model_ref") or info.get("model_ref") or ""})
    return out


def _strip_inline_comment(line):
    in_string = False
    escaped = False
    out = []
    for ch in line:
        if escaped:
            out.append(ch)
            escaped = False
            continue
        if ch == "\\" and in_string:
            out.append(ch)
            escaped = True
            continue
        if ch == '"':
            in_string = not in_string
            out.append(ch)
            continue
        if ch == "#" and not in_string:
            break
        out.append(ch)
    return "".join(out).strip()


def _parse_value(raw):
    raw = raw.strip()
    if raw == "[]":
        return []
    if raw.startswith('"') and raw.endswith('"'):
        try:
            return ast.literal_eval(raw)
        except (SyntaxError, ValueError):
            return raw[1:-1]
    if raw in {"true", "false"}:
        return raw == "true"
    try:
        return int(raw)
    except ValueError:
        pass
    try:
        return float(raw)
    except ValueError:
        return raw


def _load_routing_toml_fallback(path):
    table = {}
    current = table
    with open(path, encoding="utf-8") as f:
        for raw_line in f:
            line = _strip_inline_comment(raw_line)
            if not line:
                continue
            if line.startswith("[") and line.endswith("]"):
                current = table
                for part in line[1:-1].split("."):
                    current = current.setdefault(part, {})
                continue
            if "=" not in line:
                continue
            key, raw_value = line.split("=", 1)
            current[key.strip()] = _parse_value(raw_value)
    return table


def load_table(path):
    if tomllib is None:
        return _load_routing_toml_fallback(path)
    with open(path, "rb") as f:
        return tomllib.load(f)


def load_simple_models(path):
    models = {}
    in_models = False
    with open(path, encoding="utf-8") as f:
        for raw in f:
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            if line.startswith("[") and line.endswith("]"):
                in_models = line[1:-1].strip() == "models"
                continue
            if not in_models or "=" not in line:
                continue
            key, value = [part.strip() for part in line.split("=", 1)]
            if value.startswith('"') and value.endswith('"') and len(value) >= 2:
                models[key] = value[1:-1]
    return models


def load_models(path=None):
    models_path = path or os.environ.get("LEGION_MODELS_FILE", _DEFAULT_MODELS_FILE)
    if tomllib is None:
        models = load_simple_models(models_path)
        if not models:
            raise RouteConfigError("models.toml must contain a [models] table")
        return models
    table = load_table(models_path)
    models = table.get("models", table)
    if not isinstance(models, dict):
        raise RouteConfigError("models.toml must contain a [models] table")
    return models


def resolve_model_ref(models, ref):
    model = (models or {}).get(ref)
    if not isinstance(model, str) or not model:
        raise RouteConfigError(f"unknown model_ref '{ref}'")
    return model


def _resolve_model_refs(out, models=None):
    needs_models = "model_ref" in out or "fallback_refs" in out
    if needs_models and models is None:
        models = load_models()

    if "model" in out and "model_ref" in out:
        raise RouteConfigError("route may set either model or model_ref, not both")
    if "model_ref" in out:
        out["model"] = resolve_model_ref(models, out["model_ref"])

    if "fallback" in out and "fallback_refs" in out:
        raise RouteConfigError("route may set either fallback or fallback_refs, not both")
    if "fallback_refs" in out:
        refs = out.get("fallback_refs") or []
        if not isinstance(refs, list):
            raise RouteConfigError("fallback_refs must be an array")
        out["fallback"] = [resolve_model_ref(models, ref) for ref in refs]
    return out


def resolve(table, archetype, models=None):
    defaults = copy.deepcopy(table.get("defaults", {}))   # deep so an unresolved result can't alias the table
    arch = (table.get("archetypes") or {}).get(archetype)
    out = defaults
    if arch is None:
        out["archetype"] = archetype
        out["resolved"] = False
        return _resolve_model_refs(out, models)
    arch = copy.deepcopy(arch)   # deepcopy so a caller can't mutate the shared table's nested values
    if "model" in arch:
        out.pop("model_ref", None)
    if "model_ref" in arch:
        out.pop("model", None)
    if "fallback" in arch:
        out.pop("fallback_refs", None)
    if "fallback_refs" in arch:
        out.pop("fallback", None)
    out.update(arch)
    out["archetype"] = archetype
    out["resolved"] = True
    return _resolve_model_refs(out, models)


def _restore_default_sigpipe():
    """Die quietly instead of raising BrokenPipeError when our stdout reader goes
    away (abandoned shell capture, `… | head`). Guarded so an import is a no-op."""
    try:
        import signal

        signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    except (AttributeError, ValueError, OSError):
        pass


def main(argv=None):
    _restore_default_sigpipe()
    ap = argparse.ArgumentParser(description="Resolve a routing archetype.")
    ap.add_argument("archetype", nargs="?", metavar="ARCHETYPE")
    ap.add_argument("--archetype", dest="flag_archetype", metavar="ARCHETYPE",
                    help="routing archetype (equivalent to positional ARCHETYPE)")
    ap.add_argument("--file", default=os.environ.get("LEGION_ROUTING_FILE", _DEFAULT_FILE))
    ap.add_argument("--models-file", default=os.environ.get("LEGION_MODELS_FILE", _DEFAULT_MODELS_FILE))
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--task", default="", help="optional task text hint; accepted for demo/runbook compatibility")
    ap.add_argument("--list-models", action="store_true")
    ap.add_argument(
        "--models-json",
        action="store_true",
        help="print the whole model catalog as a JSON object (role -> model id)",
    )
    ap.add_argument("--model-ref")
    ap.add_argument("--primary", action="store_true", help="print the resolved primary harness and exit")
    ap.add_argument(
        "--preflight",
        action="store_true",
        help="add caller-aware effective_executor/preflight fields",
    )
    ap.add_argument("--executors-file", default=os.environ.get("LEGION_EXECUTORS_FILE", _DEFAULT_EXECUTORS_FILE))
    ap.add_argument("--executor-info", metavar="NAME", help="print the registry entry for one executor as JSON")
    ap.add_argument("--list-executors", action="store_true")
    ap.add_argument(
        "--review-order",
        action="store_true",
        help="print the review fallback order, filtered to executors that can review",
    )
    a = ap.parse_args(argv)
    if a.archetype and a.flag_archetype and a.archetype != a.flag_archetype:
        ap.error(f"positional archetype {a.archetype!r} conflicts with --archetype {a.flag_archetype!r}")
    archetype = a.flag_archetype or a.archetype
    if a.primary:
        print(resolve_primary())
        return 0
    try:
        if a.review_order:
            print(json.dumps(review_order(load_table(a.file), load_executors(a.executors_file))))
            return 0
        if a.list_executors or a.executor_info:
            execs = load_executors(a.executors_file)
            if a.list_executors:
                print(json.dumps(sorted(execs.keys())))
                return 0
            print(json.dumps(executor_info(execs, a.executor_info)))
            return 0
        models = load_models(a.models_file)
        if a.model_ref:
            print(resolve_model_ref(models, a.model_ref))
            return 0
        if a.models_json:
            print(json.dumps(models, sort_keys=True))
            return 0
        if a.list_models:
            print(json.dumps(sorted(models.keys())))
            return 0
        table = load_table(a.file)
    except (OSError, RuntimeError, RouteConfigError) as e:
        sys.stderr.write(f"legion-route: {e}\n")
        return 2
    if a.list:
        print(json.dumps(sorted((table.get("archetypes") or {}).keys())))
        return 0
    if not archetype:
        sys.stderr.write("legion-route: archetype required (or --list)\n")
        return 2
    try:
        route = resolve(table, archetype, models)
        if a.preflight:
            route = preflight(route, resolve_primary())
        print(json.dumps(route))
    except RouteConfigError as e:
        sys.stderr.write(f"legion-route: {e}\n")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
