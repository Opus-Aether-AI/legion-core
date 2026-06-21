#!/usr/bin/env python3
"""legion-codex-bridge — turn Claude-only subagents + slash commands into Codex skills.

Codex CLI has no native subagents and no custom slash commands, but it DOES read
skills from its skills dir. So Legion's agents (`*/agents/*.md`) and commands
(`opus-commands/commands/*.md`) are bridged into skills named `legion-agent-<name>`
and `legion-cmd-<name>` — the capability carries over even though the invocation
differs (the user describes the task; the model's skill-trigger picks it up).

  legion-codex-bridge.py --root <marketplace> --out ~/.codex/skills

Self-pruning + idempotent: every run first removes the skills it previously generated
(the `legion-agent-*` / `legion-cmd-*` prefixes are ours) so removed agents/commands
don't linger. Prints a JSON summary.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys

_FM_RE = re.compile(r"^---\s*\n(.*?)\n---\s*\n?(.*)$", re.DOTALL)
_AGENT_PREFIX = "legion-agent-"
_CMD_PREFIX = "legion-cmd-"
DESCRIPTION_LIMIT = 220


def _split_frontmatter(text: str) -> tuple[dict, str]:
    """Minimal frontmatter parse — we only need `name` and `description`, both of
    which are single-line scalars in these files. Avoids a YAML dependency."""
    m = _FM_RE.match(text)
    if not m:
        return {}, text
    fm_block, body = m.group(1), m.group(2)
    fm: dict[str, str] = {}
    for line in fm_block.splitlines():
        km = re.match(r"^([A-Za-z_][A-Za-z0-9_-]*):\s*(.*)$", line)
        if not km:
            continue
        key, val = km.group(1), km.group(2).strip()
        # Unwrap a quoted scalar; leave lists/objects (tools:) as raw (we ignore them).
        if val and val[0] in "\"'" and val[-1:] == val[0]:
            val = val[1:-1]
        fm[key] = val
    return fm, body


def _yaml_quote(s: str) -> str:
    """Always emit a double-quoted YAML scalar — the marketplace's SKILL.md parser
    (Codex) is strict about unquoted ': ' inside descriptions."""
    s = s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ").strip()
    return f'"{s}"'


def _compact_description(text: str, limit: int = DESCRIPTION_LIMIT) -> str:
    """Keep generated trigger text below Codex's visible skill-description budget."""
    collapsed = re.sub(r"\s+", " ", text).strip()
    if len(collapsed) <= limit:
        return collapsed
    head = collapsed[:limit].rsplit(" ", 1)[0].rstrip(".,;: ")
    if len(head) < 80:
        head = collapsed[:limit].rstrip(".,;: ")
    return head


def _write_skill(out_dir: str, name: str, description: str, body: str) -> None:
    d = os.path.join(out_dir, name)
    os.makedirs(d, exist_ok=True)
    description = _compact_description(description)
    fm = f"---\nname: {name}\ndescription: {_yaml_quote(description)}\n---\n\n"
    with open(os.path.join(d, "SKILL.md"), "w", encoding="utf-8") as fh:
        fh.write(fm + body.lstrip("\n"))


def _prune_generated(out_dir: str) -> int:
    n = 0
    if not os.path.isdir(out_dir):
        return 0
    for entry in os.listdir(out_dir):
        if entry.startswith(_AGENT_PREFIX) or entry.startswith(_CMD_PREFIX):
            p = os.path.join(out_dir, entry)
            if os.path.isdir(p):
                shutil.rmtree(p, ignore_errors=True)
                n += 1
    return n


# Directories that are never marketplace sources: build output, the ephemeral
# delegate worktrees under .legion (which are full repo copies → duplicate matches),
# vendored skills, and the test tree. Pruned in-place so os.walk won't descend.
_PRUNE = {".git", ".legion", "node_modules", "vendored", "tests", ".github"}


def _find(root: str, segment: str) -> list[str]:
    out = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in _PRUNE and not d.startswith(".")]
        if os.path.basename(dirpath) != segment:
            continue
        for f in filenames:
            if f.endswith(".md") and f.lower() != "readme.md":
                out.append(os.path.join(dirpath, f))
    return sorted(out)


def bridge(root: str, out_dir: str) -> dict:
    pruned = _prune_generated(out_dir)
    agents, commands = [], []

    for path in _find(root, "agents"):
        fm, body = _split_frontmatter(open(path, encoding="utf-8").read())
        base = fm.get("name") or os.path.splitext(os.path.basename(path))[0]
        name = _AGENT_PREFIX + base
        desc = fm.get("description") or f"Legion {base} subagent."
        prefix = f"[Legion agent: {base}] "
        note = (f"> Bridged from the Legion **{base}** subagent so it works in Codex CLI "
                f"(which has no native subagents). Apply this role inline.\n\n")
        _write_skill(
            out_dir,
            name,
            prefix + _compact_description(desc, DESCRIPTION_LIMIT - len(prefix)),
            note + body,
        )
        agents.append(name)

    for path in _find(root, "commands"):
        fm, body = _split_frontmatter(open(path, encoding="utf-8").read())
        base = os.path.splitext(os.path.basename(path))[0]
        name = _CMD_PREFIX + base
        desc = fm.get("description") or f"Legion {base} workflow."
        prefix = f"[Legion /{base}] "
        suffix = f" Use when the user asks to '{base}' or describes this workflow."
        desc_budget = max(80, DESCRIPTION_LIMIT - len(prefix) - len(suffix))
        note = (f"> Bridged from the Legion **/{base}** slash command so it works in Codex CLI "
                f"(which has no custom slash commands). Treat the user's message as the command "
                f"arguments (the `$ARGUMENTS` referenced below).\n\n")
        trigger = prefix + _compact_description(desc, desc_budget) + suffix
        _write_skill(out_dir, name, trigger, note + body)
        commands.append(name)

    return {"pruned": pruned, "agents": agents, "commands": commands,
            "count": len(agents) + len(commands), "out": out_dir}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="legion-codex-bridge")
    ap.add_argument("--root", required=True, help="marketplace repo root")
    ap.add_argument("--out", required=True, help="output skills dir (e.g. ~/.codex/skills)")
    args = ap.parse_args(argv)
    root = os.path.abspath(os.path.expanduser(args.root))
    out = os.path.abspath(os.path.expanduser(args.out))
    if not os.path.isdir(root):
        print(json.dumps({"error": f"root not found: {root}"}))
        return 2
    print(json.dumps(bridge(root, out)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
