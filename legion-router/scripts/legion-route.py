#!/usr/bin/env python3
"""legion-route — resolve a task archetype to an executor/model/sandbox/effort.

Reads routing.toml (the model-selection policy) and prints the resolved decision as
JSON, so legion-delegate / the runners don't hardcode model choices. Pure stdlib;
uses tomllib when available and a small routing.toml-compatible fallback on older
Python runtimes.

  legion-route bulk-mechanical-edit
  legion-route implement-feature --task "Build the demo flow"
  legion-route --list
"""
import argparse
import ast
import copy
import json
import os
import sys

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover - py<3.11
    tomllib = None

_DEFAULT_FILE = os.path.join(os.path.dirname(__file__), "..", "config", "routing.toml")


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


def resolve(table, archetype):
    defaults = copy.deepcopy(table.get("defaults", {}))   # deep so an unresolved result can't alias the table
    arch = (table.get("archetypes") or {}).get(archetype)
    out = defaults
    if arch is None:
        out["archetype"] = archetype
        out["resolved"] = False
        return out
    out.update(copy.deepcopy(arch))   # deepcopy so a caller can't mutate the shared table's nested values
    out["archetype"] = archetype
    out["resolved"] = True
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description="Resolve a routing archetype.")
    ap.add_argument("archetype", nargs="?")
    ap.add_argument("--file", default=os.environ.get("LEGION_ROUTING_FILE", _DEFAULT_FILE))
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--task", default="", help="optional task text hint; accepted for demo/runbook compatibility")
    a = ap.parse_args(argv)
    try:
        table = load_table(a.file)
    except (OSError, RuntimeError) as e:
        sys.stderr.write(f"legion-route: {e}\n")
        return 2
    if a.list:
        print(json.dumps(sorted((table.get("archetypes") or {}).keys())))
        return 0
    if not a.archetype:
        sys.stderr.write("legion-route: archetype required (or --list)\n")
        return 2
    print(json.dumps(resolve(table, a.archetype)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
