#!/usr/bin/env python3
"""legion-route — resolve a task archetype to an executor/model/sandbox/effort.

Reads routing.toml (executor policy) plus models.toml (default model catalog) and
prints the resolved decision as JSON, so legion-delegate / the runners don't
hardcode model choices. Pure stdlib; full routing uses tomllib on Python 3.11+,
while simple model-ref lookups use a tiny parser for shell entrypoint portability.

  legion-route bulk-mechanical-edit
  legion-route --list
  legion-route --model-ref codex_workhorse
"""
import argparse
import copy
import json
import os
import sys

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover - py<3.11
    tomllib = None

_CONFIG_DIR = os.path.join(os.path.dirname(__file__), "..", "config")
_DEFAULT_FILE = os.path.join(_CONFIG_DIR, "routing.toml")
_DEFAULT_MODELS_FILE = os.path.join(_CONFIG_DIR, "models.toml")


class RouteConfigError(ValueError):
    pass


def load_table(path):
    if tomllib is None:
        raise RuntimeError("tomllib unavailable (need Python 3.11+)")
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


def main(argv=None):
    ap = argparse.ArgumentParser(description="Resolve a routing archetype.")
    ap.add_argument("archetype", nargs="?")
    ap.add_argument("--file", default=os.environ.get("LEGION_ROUTING_FILE", _DEFAULT_FILE))
    ap.add_argument("--models-file", default=os.environ.get("LEGION_MODELS_FILE", _DEFAULT_MODELS_FILE))
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--list-models", action="store_true")
    ap.add_argument("--model-ref")
    a = ap.parse_args(argv)
    try:
        models = load_models(a.models_file)
        if a.model_ref:
            print(resolve_model_ref(models, a.model_ref))
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
    if not a.archetype:
        sys.stderr.write("legion-route: archetype required (or --list)\n")
        return 2
    try:
        print(json.dumps(resolve(table, a.archetype, models)))
    except RouteConfigError as e:
        sys.stderr.write(f"legion-route: {e}\n")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
