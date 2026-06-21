#!/usr/bin/env python3
"""legion-codex-mcp-merge — fold marketplace MCP servers into ~/.codex/config.toml.

Codex CLI reads MCP servers from `[mcp_servers.<name>]` tables in its config.toml,
using the SAME shape Claude Code declares under a plugin's `mcpServers` key
(command / args / env, or url / bearer_token_env_var). This tool renders those
tables and APPENDS only the ones not already present — it never edits or reorders
a block the user (or a prior run) already wrote, so it is safe to re-run.

  echo '{"context7":{"command":"npx","args":["-y","@upstash/context7-mcp@latest"]}}' \
    | legion-codex-mcp-merge.py --config ~/.codex/config.toml

stdin : JSON object  { "<server-name>": { command|args|env | url|bearer_token_env_var } }
stdout: JSON summary  { "added": [...], "skipped": [...], "updated": [...], "config": "<path>" }

--force re-renders servers that already exist (removes the old block, appends fresh).
--dry-run computes the summary + would-be file without writing.
"""
from __future__ import annotations

import argparse
import json
import re
import sys

# Section names we manage are simple identifiers (context7, playwright, …); a bare
# key in TOML matches [A-Za-z0-9_-]+. We deliberately do NOT touch quoted/dotted
# keys — those are out of scope and safer left alone.
_SECTION_RE = re.compile(r"^\[mcp_servers\.([A-Za-z0-9_-]+)\]\s*$", re.MULTILINE)


def _existing_sections(text: str) -> set[str]:
    return set(_SECTION_RE.findall(text))


def _render(name: str, spec: dict) -> str:
    """Render one [mcp_servers.<name>] TOML table. JSON string/array encoding is a
    valid subset of TOML basic-string/array syntax, so json.dumps escapes safely."""
    lines = [f"[mcp_servers.{name}]"]
    if spec.get("url"):
        lines.append(f"url = {json.dumps(spec['url'])}")
        if spec.get("bearer_token_env_var"):
            lines.append(f"bearer_token_env_var = {json.dumps(spec['bearer_token_env_var'])}")
    else:
        lines.append(f"command = {json.dumps(spec.get('command', ''))}")
        args = spec.get("args") or []
        lines.append("args = " + json.dumps(args))
        env = spec.get("env") or {}
        if env:
            pairs = ", ".join(f"{k} = {json.dumps(v)}" for k, v in env.items())
            lines.append("env = { " + pairs + " }")
    return "\n".join(lines) + "\n"


def _strip_section(text: str, name: str) -> str:
    """Remove an existing [mcp_servers.<name>] block: from its header to the next
    top-level [header] or EOF. Used only under --force."""
    header = re.compile(rf"^\[mcp_servers\.{re.escape(name)}\]\s*$", re.MULTILINE)
    m = header.search(text)
    if not m:
        return text
    nxt = re.compile(r"^\[", re.MULTILINE).search(text, m.end())
    end = nxt.start() if nxt else len(text)
    out = text[: m.start()] + text[end:]
    # Collapse the blank-line gap the removal may leave behind.
    return re.sub(r"\n{3,}", "\n\n", out)


def merge(text: str, servers: dict, force: bool) -> tuple[str, dict]:
    existing = _existing_sections(text)
    added, skipped, updated = [], [], []
    appended = []
    for name in sorted(servers):
        if name in existing:
            if force:
                text = _strip_section(text, name)
                updated.append(name)
                appended.append(_render(name, servers[name]))
            else:
                skipped.append(name)
            continue
        added.append(name)
        appended.append(_render(name, servers[name]))
    if appended:
        sep = "" if text.endswith("\n\n") or text == "" else ("\n" if text.endswith("\n") else "\n\n")
        text = text + sep + "\n".join(appended)
    return text, {"added": added, "skipped": skipped, "updated": updated}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="legion-codex-mcp-merge")
    ap.add_argument("--config", required=True, help="path to ~/.codex/config.toml")
    ap.add_argument("--force", action="store_true", help="re-render servers that already exist")
    ap.add_argument("--dry-run", action="store_true", help="don't write; just report")
    args = ap.parse_args(argv)

    try:
        servers = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        print(json.dumps({"error": f"bad stdin json: {exc}"}))
        return 2
    if not isinstance(servers, dict):
        print(json.dumps({"error": "stdin must be a JSON object of {name: spec}"}))
        return 2

    try:
        with open(args.config, encoding="utf-8") as fh:
            text = fh.read()
    except FileNotFoundError:
        text = ""

    new_text, summary = merge(text, servers, args.force)
    summary["config"] = args.config

    if not args.dry_run and (summary["added"] or summary["updated"]):
        # Write atomically-ish: same dir temp + replace, preserving 0600 expectations.
        import os
        import tempfile
        d = os.path.dirname(os.path.abspath(args.config)) or "."
        os.makedirs(d, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=d, prefix=".codex-config-")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                fh.write(new_text)
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
