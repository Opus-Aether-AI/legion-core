#!/usr/bin/env python3
"""Merge Legion marketplace MCP servers into an opencode config.

Reads a Claude-style `mcpServers` object on stdin (as collected by
legion-opencode-setup from every plugin.json) and merges it, translated to
opencode's schema, into the `mcp` table of an opencode.json config — idempotently.

Claude/stdio  {"command": "x", "args": [...], "env": {...}}
  -> opencode  {"type": "local", "command": ["x", ...], "environment": {...}, "enabled": true}
Claude/remote {"url": "https://..."}
  -> opencode  {"type": "remote", "url": "https://...", "enabled": true}

Prints a JSON summary {added, updated, skipped} (or {error}). Existing config keys
are preserved; a server already present and identical is skipped, drifted ones are
updated only with --force.
"""
import argparse
import json
import os
import sys


def _translate(name: str, spec: dict) -> dict:
    if not isinstance(spec, dict):
        raise ValueError(f"server '{name}' is not an object")
    if spec.get("url"):
        out = {"type": "remote", "url": spec["url"], "enabled": True}
        if isinstance(spec.get("headers"), dict):
            out["headers"] = spec["headers"]
        return out
    command = spec.get("command")
    if not command:
        raise ValueError(f"server '{name}' has neither command nor url")
    argv = [command] + list(spec.get("args") or [])
    out = {"type": "local", "command": argv, "enabled": True}
    if isinstance(spec.get("env"), dict) and spec["env"]:
        out["environment"] = spec["env"]
    return out


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    ap.add_argument("--force", action="store_true",
                    help="overwrite a drifted server (otherwise leave it and report it)")
    a = ap.parse_args(argv)

    try:
        incoming = json.load(sys.stdin)
    except ValueError as exc:
        print(json.dumps({"error": f"invalid MCP servers JSON on stdin: {exc}"}))
        return 1
    if not isinstance(incoming, dict):
        print(json.dumps({"error": "expected a JSON object of MCP servers"}))
        return 1

    config = {}
    if os.path.isfile(a.config):
        try:
            with open(a.config, encoding="utf-8") as fh:
                config = json.load(fh)
        except ValueError as exc:
            print(json.dumps({"error": f"existing {a.config} is not valid JSON: {exc}"}))
            return 1
    if not isinstance(config, dict):
        print(json.dumps({"error": f"existing {a.config} is not a JSON object"}))
        return 1

    config.setdefault("$schema", "https://opencode.ai/config.json")
    mcp = config.get("mcp")
    if not isinstance(mcp, dict):
        mcp = {}
    added, updated, skipped = [], [], []
    try:
        for name, spec in incoming.items():
            translated = _translate(name, spec)
            if name not in mcp:
                mcp[name] = translated
                added.append(name)
            elif mcp[name] == translated:
                skipped.append(name)
            elif a.force:
                mcp[name] = translated
                updated.append(name)
            else:
                skipped.append(name)
    except ValueError as exc:
        print(json.dumps({"error": str(exc)}))
        return 1

    config["mcp"] = mcp
    os.makedirs(os.path.dirname(os.path.abspath(a.config)), exist_ok=True)
    tmp = a.config + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(config, fh, indent=2)
        fh.write("\n")
    os.replace(tmp, a.config)
    print(json.dumps({"added": added, "updated": updated, "skipped": skipped}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
