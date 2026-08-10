#!/usr/bin/env python3
"""legion-cursor-bridge — turn Legion agents/commands/skills into Cursor agents.

Cursor has native subagents in ~/.cursor/agents. This bridge writes focused,
Cursor-native markdown agents for Legion's subagents and slash-command workflows,
plus one skill-loader agent that can apply any mirrored skill from ~/.agents/skills.

Self-pruning + idempotent: every run removes generated legion-agent-*,
legion-cmd-*, and legion-skill-runner files before writing fresh copies.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
import tempfile

_FM_RE = re.compile(r"^---\s*\n(.*?)\n---\s*\n?(.*)$", re.DOTALL)
_AGENT_PREFIX = "legion-agent-"
_CMD_PREFIX = "legion-cmd-"
_SKILL_RUNNER = "legion-skill-runner"
_PRUNE = {".git", ".legion", "node_modules", "vendored", "tests", ".github"}
DESCRIPTION_LIMIT = 220


def _split_frontmatter(text: str) -> tuple[dict[str, str], str]:
    match = _FM_RE.match(text)
    if not match:
        return {}, text
    block, body = match.group(1), match.group(2)
    fm: dict[str, str] = {}
    for line in block.splitlines():
        item = re.match(r"^([A-Za-z_][A-Za-z0-9_-]*):\s*(.*)$", line)
        if not item:
            continue
        key, value = item.group(1), item.group(2).strip()
        if value and value[0] in "\"'" and value[-1:] == value[0]:
            value = value[1:-1]
        fm[key] = value
    return fm, body


def _yaml_quote(text: str) -> str:
    text = text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ").strip()
    return f'"{text}"'


def _compact_description(text: str, limit: int = DESCRIPTION_LIMIT) -> str:
    collapsed = re.sub(r"\s+", " ", text).strip()
    if len(collapsed) <= limit:
        return collapsed
    head = collapsed[:limit].rsplit(" ", 1)[0].rstrip(".,;: ")
    if len(head) < 80:
        head = collapsed[:limit].rstrip(".,;: ")
    return head


def _write_agent(out_dir: str, name: str, description: str, body: str) -> None:
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, f"{name}.md")
    description = _compact_description(description)
    frontmatter = (
        "---\n"
        f"name: {name}\n"
        f"description: {_yaml_quote(description)}\n"
        "model: auto\n"
        "is_background: false\n"
        "---\n\n"
    )
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(frontmatter + body.lstrip("\n"))


def _prune_generated(out_dir: str) -> int:
    if not os.path.isdir(out_dir):
        return 0
    removed = 0
    for entry in os.listdir(out_dir):
        if not entry.endswith(".md"):
            continue
        stem = entry[:-3]
        if (
            stem.startswith(_AGENT_PREFIX)
            or stem.startswith(_CMD_PREFIX)
            or stem == _SKILL_RUNNER
        ):
            try:
                os.unlink(os.path.join(out_dir, entry))
                removed += 1
            except OSError:
                pass
    return removed


def _find(root: str, segment: str) -> list[str]:
    out: list[str] = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in _PRUNE and not d.startswith(".")]
        if os.path.basename(dirpath) != segment:
            continue
        for filename in filenames:
            if filename.endswith(".md") and filename.lower() != "readme.md":
                out.append(os.path.join(dirpath, filename))
    return sorted(out)


def _skill_runner_body(skills_dir: str) -> str:
    return f"""# Legion skill runner

Use this subagent when the user asks Cursor to use a Legion, Claude, or Codex
skill, or when a task clearly maps to a skill mirrored under `{skills_dir}`.

Workflow:

1. Identify the requested skill name or the most relevant skill directory under `{skills_dir}`.
2. Read that skill's `SKILL.md` completely before acting.
3. Follow any referenced local files relative to that `SKILL.md`.
4. Apply the skill inline in the current Cursor task.
5. For Legion harness work, check `legion-self-learn hints` first when available.

Do not invent skill behavior from memory. The filesystem copy is authoritative.
"""


def _selected_roots(root: str, plugin_names: set[str] | None) -> list[str]:
    if plugin_names is None:
        return [root]
    manifest_path = os.path.join(root, ".claude-plugin", "marketplace.json")
    if not os.path.isfile(manifest_path):
        raise FileNotFoundError(
            f"selected-profile bridge requires marketplace manifest: {manifest_path}"
        )
    with open(manifest_path, encoding="utf-8") as handle:
        marketplace = json.load(handle)
    root_real = os.path.realpath(root)
    selected: list[str] = []
    for plugin in marketplace.get("plugins", []):
        if plugin.get("name") not in plugin_names:
            continue
        source = plugin.get("source")
        if not isinstance(source, str) or not source.startswith("./"):
            continue
        candidate = os.path.realpath(os.path.join(root, source[2:]))
        if os.path.commonpath([root_real, candidate]) != root_real:
            raise ValueError(
                f"selected plugin source escapes marketplace root: {source}"
            )
        if os.path.isdir(candidate):
            selected.append(candidate)
    return selected


def bridge(
    root: str,
    out_dir: str,
    skills_dir: str,
    plugin_names: set[str] | None = None,
) -> dict[str, object]:
    agents: list[str] = []
    commands: list[str] = []
    # Resolve and validate the selected marketplace before changing the live
    # Cursor directory. Generation also happens off to the side so malformed
    # source files cannot destroy the last known-good bridge.
    search_roots = _selected_roots(root, plugin_names)
    parent = os.path.dirname(out_dir) or "."
    os.makedirs(parent, exist_ok=True)
    stage = tempfile.mkdtemp(prefix=".legion-cursor-agents-", dir=parent)
    try:
        for path in sorted(path for search_root in search_roots for path in _find(search_root, "agents")):
            fm, body = _split_frontmatter(open(path, encoding="utf-8").read())
            base = fm.get("name") or os.path.splitext(os.path.basename(path))[0]
            name = _AGENT_PREFIX + base
            desc = fm.get("description") or f"Legion {base} subagent."
            prefix = f"[Legion agent: {base}] "
            note = (
                f"> Bridged from Legion subagent `{base}` so it works as a Cursor "
                "subagent. Apply this role inline and keep changes scoped.\n\n"
            )
            _write_agent(
                stage,
                name,
                prefix + _compact_description(desc, DESCRIPTION_LIMIT - len(prefix)),
                note + body,
            )
            agents.append(name)

        for path in sorted(path for search_root in search_roots for path in _find(search_root, "commands")):
            fm, body = _split_frontmatter(open(path, encoding="utf-8").read())
            base = os.path.splitext(os.path.basename(path))[0]
            name = _CMD_PREFIX + base
            desc = fm.get("description") or f"Legion {base} workflow."
            prefix = f"[Legion /{base}] "
            suffix = f" Use when the user asks to '{base}' or describes this workflow."
            desc_budget = max(80, DESCRIPTION_LIMIT - len(prefix) - len(suffix))
            note = (
                f"> Bridged from Legion slash command `/{base}` so it works as a Cursor "
                "subagent. Treat the user's message as the command arguments.\n\n"
            )
            trigger = prefix + _compact_description(desc, desc_budget) + suffix
            _write_agent(stage, name, trigger, note + body)
            commands.append(name)

        _write_agent(
            stage,
            _SKILL_RUNNER,
            "[Legion skills] Load and apply mirrored Legion/Claude/Codex skills from ~/.agents/skills.",
            _skill_runner_body(skills_dir),
        )
        pruned = _prune_generated(out_dir)
        os.makedirs(out_dir, exist_ok=True)
        for entry in os.listdir(stage):
            os.replace(os.path.join(stage, entry), os.path.join(out_dir, entry))
    finally:
        shutil.rmtree(stage, ignore_errors=True)

    return {
        "pruned": pruned,
        "agents": agents,
        "commands": commands,
        "skill_runner": _SKILL_RUNNER,
        "count": len(agents) + len(commands) + 1,
        "out": out_dir,
        "selected_plugins": sorted(plugin_names) if plugin_names is not None else None,
    }


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="legion-cursor-bridge")
    parser.add_argument("--root", required=True, help="marketplace repo root")
    parser.add_argument("--out", required=True, help="Cursor agents dir, e.g. ~/.cursor/agents")
    parser.add_argument(
        "--skills-dir",
        default=os.path.expanduser("~/.agents/skills"),
        help="mirrored skill directory the skill-runner should read",
    )
    parser.add_argument(
        "--plugins-file",
        help="optional newline-delimited marketplace plugin allowlist",
    )
    args = parser.parse_args(argv)

    root = os.path.abspath(os.path.expanduser(args.root))
    out = os.path.abspath(os.path.expanduser(args.out))
    skills_dir = os.path.abspath(os.path.expanduser(args.skills_dir))
    plugin_names = None
    if args.plugins_file:
        plugins_file = os.path.abspath(os.path.expanduser(args.plugins_file))
        if not os.path.isfile(plugins_file):
            print(json.dumps({"error": f"plugins file not found: {plugins_file}"}))
            return 2
        with open(plugins_file, encoding="utf-8") as handle:
            plugin_names = {line.strip() for line in handle if line.strip()}
    if not os.path.isdir(root):
        print(json.dumps({"error": f"root not found: {root}"}))
        return 2
    print(json.dumps(bridge(root, out, skills_dir, plugin_names)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
