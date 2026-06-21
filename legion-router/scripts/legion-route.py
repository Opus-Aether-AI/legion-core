#!/usr/bin/env python3
"""legion-route — resolve a task archetype to an executor/model/sandbox/effort.

Reads routing.toml (the model-selection policy) and prints the resolved decision as
JSON, so legion-delegate / the runners don't hardcode model choices. Pure stdlib
(tomllib, 3.11+). Importable for tests.

  legion-route bulk-mechanical-edit
  legion-route --list
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

_DEFAULT_FILE = os.path.join(os.path.dirname(__file__), "..", "config", "routing.toml")


def load_table(path):
    if tomllib is None:
        raise RuntimeError("tomllib unavailable (need Python 3.11+)")
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
