#!/usr/bin/env python3
"""Read-only Legion catalog indexer for marketplace inventory surfaces."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone
from typing import Any


ENTITY_TYPES = ("plugin", "skill", "agent", "command", "hook", "mcp")
_FRONTMATTER_RE = re.compile(
    r"^\ufeff?---[ \t]*\r?\n(.*?)\r?\n---(?:[ \t]*\r?\n|[ \t]*$)",
    re.DOTALL,
)


def _frontmatter(md_text: str) -> dict[str, str]:
    """Parse a leading YAML-ish frontmatter block for name/description only."""
    if not isinstance(md_text, str):
        return {}
    match = _FRONTMATTER_RE.match(md_text)
    if not match:
        return {}

    parsed: dict[str, str] = {}
    for raw_line in match.group(1).splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or ":" not in line:
            continue
        key, value = line.split(":", 1)
        key = key.strip().lower()
        if key not in {"name", "description"}:
            continue
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
            value = value[1:-1]
        if value:
            parsed[key] = value
    return parsed


def _text(value: Any) -> str:
    return value.strip() if isinstance(value, str) else ""


def _json_file(path: str) -> dict[str, Any]:
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError, TypeError):
        return {}
    return data if isinstance(data, dict) else {}


def _text_file(path: str) -> str:
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read()
    except OSError:
        return ""


def _entity(
    entity_type: str,
    name: str,
    plugin: str,
    description: str,
    source_path: str,
    detail: Any,
) -> dict[str, Any]:
    return {
        "type": entity_type,
        "name": name,
        "plugin": plugin,
        "description": description,
        "source_path": os.path.abspath(source_path),
        "detail": detail,
    }


def _iter_markdown_entities(
    directory: str,
    entity_type: str,
    plugin_name: str,
) -> list[dict[str, Any]]:
    entities: list[dict[str, Any]] = []
    if not os.path.isdir(directory):
        return entities

    try:
        entries = sorted(os.scandir(directory), key=lambda entry: entry.name)
    except OSError:
        return entities

    for entry in entries:
        if not entry.is_file() or not entry.name.endswith(".md"):
            continue
        frontmatter = _frontmatter(_text_file(entry.path))
        name = frontmatter.get("name") or os.path.splitext(entry.name)[0]
        entities.append(
            _entity(
                entity_type,
                name,
                plugin_name,
                frontmatter.get("description", ""),
                entry.path,
                {},
            )
        )
    return entities


def _iter_nested_skills(skills_dir: str, plugin_name: str) -> list[dict[str, Any]]:
    entities: list[dict[str, Any]] = []
    if not os.path.isdir(skills_dir):
        return entities

    for root, dirs, files in os.walk(skills_dir):
        dirs.sort()
        files.sort()
        if "SKILL.md" not in files:
            continue
        skill_path = os.path.join(root, "SKILL.md")
        frontmatter = _frontmatter(_text_file(skill_path))
        default_name = os.path.basename(root)
        entities.append(
            _entity(
                "skill",
                frontmatter.get("name") or default_name,
                plugin_name,
                frontmatter.get("description", ""),
                skill_path,
                {"layout": "nested"},
            )
        )
    return entities


def _mcp_entities(
    plugin_dir: str,
    plugin_name: str,
    plugin_manifest: dict[str, Any],
) -> list[dict[str, Any]]:
    servers: dict[str, tuple[Any, str]] = {}

    manifest_servers = plugin_manifest.get("mcpServers")
    if isinstance(manifest_servers, dict):
        manifest_path = os.path.join(plugin_dir, ".claude-plugin", "plugin.json")
        for name, detail in manifest_servers.items():
            if isinstance(name, str) and name:
                servers[name] = (detail, manifest_path)

    mcp_path = os.path.join(plugin_dir, ".mcp.json")
    mcp_json = _json_file(mcp_path)
    file_servers = mcp_json.get("mcpServers")
    if isinstance(file_servers, dict):
        for name, detail in file_servers.items():
            if isinstance(name, str) and name:
                servers[name] = (detail, mcp_path)

    entities: list[dict[str, Any]] = []
    for name in sorted(servers):
        detail, source_path = servers[name]
        entities.append(_entity("mcp", name, plugin_name, "", source_path, detail))
    return entities


def enumerate_plugin(plugin_dir: str, plugin_name: str) -> list[dict[str, Any]]:
    """Enumerate all non-plugin entities contributed by one plugin directory."""
    plugin_dir = os.path.abspath(plugin_dir)
    manifest = _json_file(os.path.join(plugin_dir, ".claude-plugin", "plugin.json"))
    entities: list[dict[str, Any]] = []

    top_skill = os.path.join(plugin_dir, "SKILL.md")
    if os.path.isfile(top_skill):
        frontmatter = _frontmatter(_text_file(top_skill))
        entities.append(
            _entity(
                "skill",
                frontmatter.get("name") or plugin_name,
                plugin_name,
                frontmatter.get("description")
                or _text(manifest.get("description")),
                top_skill,
                {"layout": "top-level"},
            )
        )

    entities.extend(_iter_nested_skills(os.path.join(plugin_dir, "skills"), plugin_name))
    entities.extend(_iter_markdown_entities(os.path.join(plugin_dir, "agents"), "agent", plugin_name))
    entities.extend(
        _iter_markdown_entities(os.path.join(plugin_dir, "commands"), "command", plugin_name)
    )

    # Hooks: Claude Code plugins put hooks.json either at the plugin root or under
    # hooks/, and the event map is usually wrapped under a top-level "hooks" key
    # ({"hooks": {PreToolUse: [...]}}) — handle both layouts + both shapes.
    hooks_path = next(
        (p for p in (os.path.join(plugin_dir, "hooks.json"),
                     os.path.join(plugin_dir, "hooks", "hooks.json"))
         if os.path.isfile(p)),
        os.path.join(plugin_dir, "hooks.json"),
    )
    hooks = _json_file(hooks_path)
    if isinstance(hooks.get("hooks"), dict):
        hooks = hooks["hooks"]
    for name in sorted(k for k in hooks if isinstance(k, str)):
        entities.append(_entity("hook", name, plugin_name, "", hooks_path, hooks[name]))

    entities.extend(_mcp_entities(plugin_dir, plugin_name, manifest))
    return entities


def _default_homes() -> dict[str, str]:
    return {
        "claude_plugins": os.path.expanduser("~/.claude/plugins"),
        "agents_skills": os.path.expanduser("~/.agents/skills"),
        "codex_skills": os.path.expanduser("~/.codex/skills"),
        "agents_bin": os.path.expanduser("~/.agents/bin"),
    }


def _plugin_installed(plugin_name: str, homes: dict[str, str]) -> bool:
    return os.path.lexists(
        os.path.join(homes["claude_plugins"], "cache", "legion", plugin_name)
    )


def _entity_installed(
    entity: dict[str, Any],
    plugin_installed: bool,
    homes: dict[str, str],
) -> bool:
    if entity.get("type") == "plugin":
        return plugin_installed
    if entity.get("type") == "skill":
        name = _text(entity.get("name"))
        if not name:
            return False
        return os.path.lexists(os.path.join(homes["agents_skills"], name)) or os.path.lexists(
            os.path.join(homes["codex_skills"], name)
        )
    return plugin_installed


def _plugin_dir(repo: str, source: Any, plugin_name: str) -> str:
    if isinstance(source, str) and source.strip():
        return os.path.abspath(os.path.join(repo, source))
    return os.path.abspath(os.path.join(repo, plugin_name))


def build_catalog(repo: str, *, homes: dict[str, str] | None = None) -> dict[str, Any]:
    """Build a full marketplace catalog with installed-state cross-checks."""
    repo = os.path.abspath(repo)
    homes_map = _default_homes()
    if homes:
        homes_map.update({key: str(value) for key, value in homes.items()})

    by_type = {entity_type: 0 for entity_type in ENTITY_TYPES}
    installed_counts = {entity_type: 0 for entity_type in ENTITY_TYPES}
    entities: list[dict[str, Any]] = []

    marketplace = _json_file(os.path.join(repo, ".claude-plugin", "marketplace.json"))
    plugins = marketplace.get("plugins")
    if not isinstance(plugins, list):
        plugins = []

    plugin_count = 0
    for plugin in plugins:
        if not isinstance(plugin, dict):
            continue
        name = _text(plugin.get("name"))
        if not name:
            continue
        plugin_count += 1
        plugin_dir = _plugin_dir(repo, plugin.get("source"), name)
        manifest = _json_file(os.path.join(plugin_dir, ".claude-plugin", "plugin.json"))
        plugin_entity = _entity(
            "plugin",
            name,
            name,
            _text(manifest.get("description")) or _text(plugin.get("description")),
            plugin_dir,
            {
                "source": plugin.get("source"),
                "version": _text(manifest.get("version")) or _text(plugin.get("version")),
            },
        )
        plugin_entity["installed"] = _plugin_installed(name, homes_map)
        entities.append(plugin_entity)
        by_type["plugin"] += 1
        installed_counts["plugin"] += int(plugin_entity["installed"])

        for child in enumerate_plugin(plugin_dir, name):
            child["installed"] = _entity_installed(child, plugin_entity["installed"], homes_map)
            entities.append(child)
            child_type = child["type"]
            by_type[child_type] += 1
            installed_counts[child_type] += int(child["installed"])

    entities.sort(key=lambda entity: (entity["type"], entity["plugin"], entity["name"]))
    return {
        "repo": repo,
        "generated_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "plugins": plugin_count,
        "by_type": by_type,
        "installed": installed_counts,
        "entities": entities,
    }


def _short_description(text: str, limit: int = 72) -> str:
    collapsed = " ".join(_text(text).split())
    if len(collapsed) <= limit:
        return collapsed
    return collapsed[: limit - 3].rstrip() + "..."


def _render_table(catalog: dict[str, Any], entity_type: str | None, installed_only: bool) -> str:
    entities = catalog.get("entities", [])
    if not isinstance(entities, list):
        entities = []

    filtered = [
        entity
        for entity in entities
        if (entity_type is None or entity.get("type") == entity_type)
        and (not installed_only or entity.get("installed"))
    ]
    if not filtered:
        return "No matching entities."

    name_width = max(len("name"), max(len(_text(entity.get("name"))) for entity in filtered))
    plugin_width = max(
        len("plugin"), max(len(_text(entity.get("plugin"))) for entity in filtered)
    )

    lines: list[str] = []
    for current_type in ENTITY_TYPES:
        group = [entity for entity in filtered if entity.get("type") == current_type]
        if not group:
            continue
        lines.append(current_type)
        lines.append(
            f"{'type':<7}  {'name':<{name_width}}  "
            f"{'plugin':<{plugin_width}}  {'installed':<9}  description"
        )
        for entity in group:
            lines.append(
                f"{entity['type']:<7}  {entity['name']:<{name_width}}  "
                f"{entity['plugin']:<{plugin_width}}  "
                f"{('yes' if entity.get('installed') else ''):<9}  "
                f"{_short_description(_text(entity.get('description')))}"
            )
        lines.append("")
    return "\n".join(lines).rstrip()


def main(argv: list[str] | None = None) -> int:
    """CLI entrypoint."""
    here = os.path.dirname(os.path.abspath(__file__))
    default_repo = os.path.abspath(os.path.join(here, "..", ".."))

    parser = argparse.ArgumentParser(prog="legion-catalog")
    parser.add_argument("--repo", default=default_repo)
    parser.add_argument("--type", choices=ENTITY_TYPES)
    parser.add_argument("--installed", action="store_true")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)

    catalog = build_catalog(args.repo)
    if args.json:
        print(json.dumps(catalog, indent=2, sort_keys=False))
        return 0

    print(_render_table(catalog, args.type, args.installed))
    return 0


if __name__ == "__main__":
    sys.exit(main())
