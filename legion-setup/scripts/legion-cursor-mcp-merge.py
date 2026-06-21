#!/usr/bin/env python3
"""Merge marketplace MCP servers into Cursor's ~/.cursor/mcp.json.

Cursor uses a JSON object with an `mcpServers` key. This helper preserves any
existing user-managed servers and only adds missing Legion marketplace servers
unless --force is passed.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile


def merge(config: dict, servers: dict, force: bool) -> tuple[dict, dict]:
    if not isinstance(config.get("mcpServers"), dict):
        config["mcpServers"] = {}
    current = config["mcpServers"]
    added: list[str] = []
    skipped: list[str] = []
    updated: list[str] = []
    for name in sorted(servers):
        if name in current and not force:
            skipped.append(name)
            continue
        if name in current:
            updated.append(name)
        else:
            added.append(name)
        current[name] = servers[name]
    return config, {"added": added, "skipped": skipped, "updated": updated}


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="legion-cursor-mcp-merge")
    parser.add_argument("--config", required=True, help="path to ~/.cursor/mcp.json")
    parser.add_argument("--force", action="store_true", help="replace existing matching servers")
    parser.add_argument("--dry-run", action="store_true", help="do not write")
    args = parser.parse_args(argv)

    try:
        servers = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        print(json.dumps({"error": f"bad stdin json: {exc}"}))
        return 2
    if not isinstance(servers, dict):
        print(json.dumps({"error": "stdin must be a JSON object of {name: spec}"}))
        return 2

    try:
        with open(args.config, encoding="utf-8") as handle:
            config = json.load(handle)
    except FileNotFoundError:
        config = {}
    except json.JSONDecodeError as exc:
        print(json.dumps({"error": f"bad Cursor MCP config: {exc}"}))
        return 2
    if not isinstance(config, dict):
        print(json.dumps({"error": "Cursor MCP config must be a JSON object"}))
        return 2

    new_config, summary = merge(config, servers, args.force)
    summary["config"] = args.config

    if not args.dry_run and (summary["added"] or summary["updated"]):
        directory = os.path.dirname(os.path.abspath(args.config)) or "."
        os.makedirs(directory, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=directory, prefix=".cursor-mcp-")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                json.dump(new_config, handle, indent=2, sort_keys=True)
                handle.write("\n")
            os.chmod(tmp, 0o600)
            os.replace(tmp, args.config)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise

    print(json.dumps(summary))
    return 0


if __name__ == "__main__":
    sys.exit(main())
