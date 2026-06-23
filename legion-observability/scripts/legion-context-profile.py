#!/usr/bin/env python3
"""Apply reversible Legion context profiles across Codex, Claude, and .agents.

The goal is to keep high-signal skills/plugins active for a repo while moving
rarely used surfaces out of the default prompt budget. Nothing is deleted:
inactive skill directories are moved under `skills.disabled/<profile>/`, and
Claude plugin entries are toggled in settings.json only when they already exist.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

PROFILE_SCHEMA = "legion.context-profile.v1"
GROUP_SCHEMA = "legion.context-groups.v1"
PLUGIN_ROOT = Path(__file__).resolve().parents[1]
STOPWORDS = {
    "a",
    "and",
    "for",
    "in",
    "of",
    "on",
    "or",
    "the",
    "to",
    "with",
    "legion",
}


@dataclass(frozen=True)
class ContextGroup:
    name: str
    description: str
    skills: frozenset[str]
    plugins: frozenset[str]
    source_path: Path | None = None


@dataclass(frozen=True)
class Profile:
    name: str
    description: str
    strategy: str
    include_groups: tuple[str, ...]
    disable_groups: tuple[str, ...]
    skills: frozenset[str]
    plugins: frozenset[str]
    disable_skills: frozenset[str]
    disable_plugins: frozenset[str]
    source_path: Path | None = None


@dataclass(frozen=True)
class ContextCatalog:
    groups: dict[str, ContextGroup]
    profiles: dict[str, Profile]


def _resolve(path: str | Path) -> Path:
    return Path(path).expanduser()


def _tokens(text: str) -> set[str]:
    import re

    return {
        item
        for item in re.split(r"[^a-z0-9]+", text.lower())
        if len(item) > 1 and item not in STOPWORDS
    }


def _string_set(value: Any, *, path: Path, key: str) -> frozenset[str]:
    if value is None:
        return frozenset()
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise ValueError(f"{path}: '{key}' must be an array of strings")
    return frozenset(value)


def _string_tuple(value: Any, *, path: Path, key: str) -> tuple[str, ...]:
    return tuple(sorted(_string_set(value, path=path, key=key)))


def _merge_groups(
    names: tuple[str, ...],
    groups: dict[str, ContextGroup],
    *,
    path: Path,
) -> tuple[frozenset[str], frozenset[str]]:
    skills: set[str] = set()
    plugins: set[str] = set()
    missing = [name for name in names if name not in groups]
    if missing:
        known = ", ".join(sorted(groups)) or "(none loaded)"
        raise ValueError(f"{path}: unknown context group(s): {', '.join(missing)}. Known: {known}")
    for name in names:
        group = groups[name]
        skills.update(group.skills)
        plugins.update(group.plugins)
    return frozenset(skills), frozenset(plugins)


def group_catalog_from_json(path: Path, data: dict[str, Any]) -> dict[str, ContextGroup]:
    raw_groups = data.get("groups")
    if not isinstance(raw_groups, dict):
        raise ValueError(f"{path}: 'groups' must be an object")
    groups: dict[str, ContextGroup] = {}
    for name, raw in raw_groups.items():
        if not isinstance(name, str) or not name.strip():
            raise ValueError(f"{path}: group names must be non-empty strings")
        if not isinstance(raw, dict):
            raise ValueError(f"{path}: group '{name}' must be an object")
        description = raw.get("description", "")
        if not isinstance(description, str):
            raise ValueError(f"{path}: group '{name}' description must be a string")
        groups[name] = ContextGroup(
            name=name,
            description=description,
            skills=_string_set(raw.get("skills"), path=path, key=f"groups.{name}.skills"),
            plugins=_string_set(raw.get("plugins"), path=path, key=f"groups.{name}.plugins"),
            source_path=path,
        )
    return groups


def profile_from_json(path: Path, data: dict[str, Any], groups: dict[str, ContextGroup]) -> Profile:
    schema = data.get("schema")
    if schema not in (None, PROFILE_SCHEMA):
        raise ValueError(f"{path}: unsupported schema '{schema}'")
    name = data.get("name")
    description = data.get("description")
    if not isinstance(name, str) or not name.strip():
        raise ValueError(f"{path}: 'name' must be a non-empty string")
    if not isinstance(description, str) or not description.strip():
        raise ValueError(f"{path}: 'description' must be a non-empty string")
    strategy = data.get("strategy", "overlay")
    if strategy not in {"overlay", "strict"}:
        raise ValueError(f"{path}: 'strategy' must be 'overlay' or 'strict'")
    include_groups = _string_tuple(data.get("include_groups"), path=path, key="include_groups")
    disable_groups = _string_tuple(data.get("disable_groups"), path=path, key="disable_groups")
    group_skills, group_plugins = _merge_groups(include_groups, groups, path=path)
    disabled_group_skills, disabled_group_plugins = _merge_groups(disable_groups, groups, path=path)
    return Profile(
        name=name,
        description=description,
        strategy=strategy,
        include_groups=include_groups,
        disable_groups=disable_groups,
        skills=frozenset(group_skills | _string_set(data.get("skills"), path=path, key="skills")),
        plugins=frozenset(group_plugins | _string_set(data.get("plugins"), path=path, key="plugins")),
        disable_skills=frozenset(
            disabled_group_skills | _string_set(data.get("disable_skills"), path=path, key="disable_skills")
        ),
        disable_plugins=frozenset(
            disabled_group_plugins
            | _string_set(data.get("disable_plugins"), path=path, key="disable_plugins")
        ),
        source_path=path,
    )


def _split_profile_paths(value: str | None) -> list[Path]:
    if not value:
        return []
    return [_resolve(item) for item in value.split(os.pathsep) if item.strip()]


def _iter_profile_files(path: Path) -> list[Path]:
    path = _resolve(path)
    if path.is_file() and path.suffix == ".json":
        return [path]
    if path.is_dir():
        return sorted(item for item in path.glob("*.json") if item.is_file())
    return []


def profile_search_paths(
    *,
    home: Path | None = None,
    cwd: Path | None = None,
    explicit_paths: list[str | Path] | None = None,
) -> list[Path]:
    home = _resolve(home or Path.home())
    cwd = _resolve(cwd or Path.cwd())
    roots: list[Path] = []
    roots.extend(_split_profile_paths(os.environ.get("LEGION_CONTEXT_PROFILE_PATH")))
    roots.extend(_resolve(path) for path in (explicit_paths or []))
    roots.extend(
        [
            cwd / ".legion" / "context-profiles",
            cwd / "context-profiles",
            home / ".config" / "legion" / "context-profiles",
            PLUGIN_ROOT / "context-profiles",
        ]
    )
    sources_root = home / ".agents" / "sources"
    if sources_root.exists():
        roots.extend(sorted(sources_root.glob("*/context-profiles")))
    seen: set[Path] = set()
    unique: list[Path] = []
    for root in roots:
        try:
            resolved = root.resolve()
        except OSError:
            resolved = root
        if resolved in seen:
            continue
        seen.add(resolved)
        unique.append(root)
    return unique


def load_context(
    *,
    home: Path | None = None,
    cwd: Path | None = None,
    explicit_paths: list[str | Path] | None = None,
) -> ContextCatalog:
    files: list[Path] = []
    groups: dict[str, ContextGroup] = {}
    profiles: dict[str, Profile] = {}
    for root in profile_search_paths(home=home, cwd=cwd, explicit_paths=explicit_paths):
        for path in _iter_profile_files(root):
            files.append(path)
    payloads: dict[Path, dict[str, Any]] = {}
    for path in files:
        payload = _load_json_object(path)
        payloads[path] = payload
        schema = payload.get("schema")
        if schema == GROUP_SCHEMA or (schema is None and "groups" in payload and "name" not in payload):
            for name, group in group_catalog_from_json(path, payload).items():
                groups.setdefault(name, group)
    for path in files:
        payload = payloads[path]
        schema = payload.get("schema")
        if schema == GROUP_SCHEMA or (schema is None and "groups" in payload and "name" not in payload):
            continue
        if schema not in (None, PROFILE_SCHEMA):
            continue
        profile = profile_from_json(path, payload, groups)
        profiles.setdefault(profile.name, profile)
    return ContextCatalog(groups=groups, profiles=profiles)


def load_profiles(
    *,
    home: Path | None = None,
    cwd: Path | None = None,
    explicit_paths: list[str | Path] | None = None,
) -> dict[str, Profile]:
    return load_context(home=home, cwd=cwd, explicit_paths=explicit_paths).profiles


def with_group_overrides(
    profile: Profile,
    groups: dict[str, ContextGroup],
    *,
    include_groups: list[str] | tuple[str, ...] | None = None,
    disable_groups: list[str] | tuple[str, ...] | None = None,
) -> Profile:
    extra_include = tuple(include_groups or ())
    extra_disable = tuple(disable_groups or ())
    include_skills, include_plugins = _merge_groups(extra_include, groups, path=profile.source_path or Path("<cli>"))
    disable_skills, disable_plugins = _merge_groups(extra_disable, groups, path=profile.source_path or Path("<cli>"))
    merged_include = tuple(sorted(set(profile.include_groups) | set(extra_include)))
    merged_disable = tuple(sorted(set(profile.disable_groups) | set(extra_disable)))
    return Profile(
        name=profile.name,
        description=profile.description,
        strategy=profile.strategy,
        include_groups=merged_include,
        disable_groups=merged_disable,
        skills=frozenset(profile.skills | include_skills),
        plugins=frozenset(profile.plugins | include_plugins),
        disable_skills=frozenset(profile.disable_skills | disable_skills),
        disable_plugins=frozenset(profile.disable_plugins | disable_plugins),
        source_path=profile.source_path,
    )


def suggest_groups(query: str, groups: dict[str, ContextGroup], *, limit: int = 8) -> list[dict[str, Any]]:
    query_tokens = _tokens(query)
    ranked: list[dict[str, Any]] = []
    if not query_tokens:
        return ranked
    for group in groups.values():
        haystack = " ".join(
            [group.name, group.description, *sorted(group.skills), *sorted(group.plugins)]
        )
        group_tokens = _tokens(haystack)
        matched = sorted(query_tokens & group_tokens)
        if not matched:
            continue
        ranked.append(
            {
                "group": group.name,
                "score": len(matched),
                "matched": matched,
                "description": group.description,
                "skills": sorted(group.skills),
                "plugins": sorted(group.plugins),
            }
        )
    ranked.sort(key=lambda item: (-int(item["score"]), str(item["group"])))
    return ranked[: max(1, limit)]


def _group_union(groups: dict[str, ContextGroup]) -> tuple[set[str], set[str]]:
    skills: set[str] = set()
    plugins: set[str] = set()
    for group in groups.values():
        skills.update(group.skills)
        plugins.update(group.plugins)
    return skills, plugins


def _frontmatter_name(path: Path) -> str | None:
    try:
        text = path.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return None
    if not text.startswith("---"):
        return None
    for line in text.splitlines()[1:80]:
        if line.strip() == "---":
            return None
        if line.startswith("name:"):
            value = line.split(":", 1)[1].strip().strip("\"'")
            return value or None
    return None


def _expected_skill_entries(root: Path) -> list[tuple[str, set[str]]]:
    root = _resolve(root)
    if not root.exists():
        return []
    entries: list[tuple[str, set[str]]] = []
    for skill_file in sorted(root.rglob("SKILL.md")):
        if any(part in {".git", ".legion", "__pycache__", ".pytest_cache"} for part in skill_file.parts):
            continue
        if "tests" in skill_file.parts:
            continue
        options = {skill_file.parent.name}
        frontmatter = _frontmatter_name(skill_file)
        if frontmatter:
            options.add(frontmatter)
        entries.append((str(skill_file), options))
    return entries


def _expected_marketplace_plugins(path: Path, suffix: str) -> set[str]:
    path = _resolve(path)
    if not path.exists():
        return set()
    data = _load_json_object(path)
    plugins = data.get("plugins", [])
    if not isinstance(plugins, list):
        raise ValueError(f"{path}: 'plugins' must be an array")
    out: set[str] = set()
    for item in plugins:
        if not isinstance(item, dict):
            continue
        name = item.get("name")
        if isinstance(name, str) and name.strip():
            out.add(f"{name}{suffix}")
    return out


def coverage_report(
    groups: dict[str, ContextGroup],
    *,
    skills_roots: list[str | Path] | None = None,
    marketplaces: list[str | Path] | None = None,
    plugin_suffix: str = "@legion",
) -> dict[str, Any]:
    covered_skills, covered_plugins = _group_union(groups)
    expected_skill_entries: dict[str, set[str]] = {}
    for root in skills_roots or []:
        for source_path, options in _expected_skill_entries(_resolve(root)):
            expected_skill_entries.setdefault(source_path, set()).update(options)
    expected_plugins: set[str] = set()
    for marketplace in marketplaces or []:
        expected_plugins.update(_expected_marketplace_plugins(_resolve(marketplace), plugin_suffix))
    missing_skills = sorted(
        sorted(options)[0]
        for options in expected_skill_entries.values()
        if not (options & covered_skills)
    )
    expected_skill_names = set().union(*expected_skill_entries.values()) if expected_skill_entries else set()
    missing_plugins = sorted(expected_plugins - covered_plugins)
    extra_skills = sorted(covered_skills - expected_skill_names) if expected_skill_names else []
    extra_plugins = sorted(covered_plugins - expected_plugins) if expected_plugins else []
    return {
        "ok": not missing_skills and not missing_plugins,
        "expected_skills": len(expected_skill_entries),
        "covered_skills": len(covered_skills),
        "missing_skills": missing_skills,
        "extra_skills": extra_skills,
        "expected_plugins": len(expected_plugins),
        "covered_plugins": len(covered_plugins),
        "missing_plugins": missing_plugins,
        "extra_plugins": extra_plugins,
    }


def _unique_destination(path: Path) -> Path:
    if not path.exists() and not path.is_symlink():
        return path
    for i in range(1, 1000):
        candidate = path.with_name(f"{path.name}.{i}")
        if not candidate.exists() and not candidate.is_symlink():
            return candidate
    raise RuntimeError(f"could not find an unused archive path for {path}")


def archive_skills(
    skills_dir: Path,
    keep: set[str] | frozenset[str],
    profile_name: str,
    *,
    disable: set[str] | frozenset[str] | None = None,
    strategy: str = "strict",
    dry_run: bool = False,
) -> dict[str, Any]:
    skills_dir = _resolve(skills_dir)
    disabled_dir = skills_dir.parent / "skills.disabled" / profile_name
    summary: dict[str, Any] = {
        "skills_dir": str(skills_dir),
        "disabled_dir": str(disabled_dir),
        "strategy": strategy,
        "present": skills_dir.exists(),
        "active_before": 0,
        "active_after": 0,
        "kept": [],
        "archived": [],
        "skipped": [],
    }
    if not skills_dir.exists():
        return summary

    children = sorted(skills_dir.iterdir(), key=lambda p: p.name)
    summary["active_before"] = len(children)
    disabled = set(disable or ())
    for child in children:
        if strategy == "overlay" and child.name not in disabled:
            summary["kept"].append(child.name)
            continue
        if strategy == "strict" and child.name in keep:
            summary["kept"].append(child.name)
            continue
        if not child.is_dir() and not child.is_symlink():
            summary["skipped"].append({"name": child.name, "reason": "not a skill directory"})
            continue
        dest = _unique_destination(disabled_dir / child.name)
        summary["archived"].append({"name": child.name, "to": str(dest)})
        if not dry_run:
            disabled_dir.mkdir(parents=True, exist_ok=True)
            shutil.move(str(child), str(dest))

    if dry_run:
        summary["active_after"] = summary["active_before"] - len(summary["archived"])
    else:
        summary["active_after"] = len(list(skills_dir.iterdir()))
    return summary


def _load_json_object(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return data


def trim_claude_plugins(
    settings_path: Path,
    keep: set[str] | frozenset[str],
    *,
    disable: set[str] | frozenset[str] | None = None,
    strategy: str = "strict",
    dry_run: bool = False,
    backup: bool = True,
) -> dict[str, Any]:
    settings_path = _resolve(settings_path)
    summary: dict[str, Any] = {
        "settings": str(settings_path),
        "strategy": strategy,
        "present": settings_path.exists(),
        "enabled": [],
        "disabled": [],
        "unchanged_count": 0,
        "backup": None,
    }
    if not settings_path.exists():
        return summary

    data = _load_json_object(settings_path)
    plugins = data.get("enabledPlugins")
    if not isinstance(plugins, dict):
        summary["reason"] = "settings has no enabledPlugins object"
        return summary

    changed = False
    disabled = set(disable or ())
    for name in sorted(plugins):
        if name in disabled:
            desired = False
        elif name in keep:
            desired = True
        elif strategy == "strict":
            desired = False
        else:
            summary["unchanged_count"] += 1
            continue
        current = bool(plugins[name])
        if current == desired:
            summary["unchanged_count"] += 1
            continue
        changed = True
        plugins[name] = desired
        if desired:
            summary["enabled"].append(name)
        else:
            summary["disabled"].append(name)

    if changed and not dry_run:
        if backup:
            stamp = datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S")
            backup_path = settings_path.with_name(f"{settings_path.name}.context-profile-backup.{stamp}")
            shutil.copy2(settings_path, backup_path)
            summary["backup"] = str(backup_path)
        settings_path.parent.mkdir(parents=True, exist_ok=True)
        with settings_path.open("w", encoding="utf-8") as handle:
            json.dump(data, handle, indent=2, sort_keys=True)
            handle.write("\n")
    return summary


def apply_profile(
    profile: Profile,
    *,
    codex_skills: Path,
    agents_skills: Path,
    claude_settings: Path,
    dry_run: bool = False,
    backup: bool = True,
) -> dict[str, Any]:
    return {
        "profile": profile.name,
        "description": profile.description,
        "strategy": profile.strategy,
        "include_groups": list(profile.include_groups),
        "disable_groups": list(profile.disable_groups),
        "dry_run": dry_run,
        "codex": archive_skills(
            codex_skills,
            profile.skills,
            profile.name,
            disable=profile.disable_skills,
            strategy=profile.strategy,
            dry_run=dry_run,
        ),
        "agents": archive_skills(
            agents_skills,
            profile.skills,
            profile.name,
            disable=profile.disable_skills,
            strategy=profile.strategy,
            dry_run=dry_run,
        ),
        "claude": trim_claude_plugins(
            claude_settings,
            profile.plugins,
            disable=profile.disable_plugins,
            strategy=profile.strategy,
            dry_run=dry_run,
            backup=backup,
        ),
    }


def _select_profile(name: str | None, profiles: dict[str, Profile]) -> Profile:
    if name:
        try:
            return profiles[name]
        except KeyError:
            known = ", ".join(sorted(profiles)) or "(none discovered)"
            raise SystemExit(f"unknown profile '{name}'. Known profiles: {known}") from None
    if len(profiles) == 1:
        return next(iter(profiles.values()))
    known = ", ".join(sorted(profiles)) or "(none discovered)"
    raise SystemExit(f"--profile is required when discovered profiles != 1. Known profiles: {known}")


def _default_paths(home: Path) -> dict[str, Path]:
    return {
        "codex_skills": home / ".codex" / "skills",
        "agents_skills": home / ".agents" / "skills",
        "claude_settings": home / ".claude" / "settings.json",
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="legion-context-profile")
    sub = parser.add_subparsers(dest="cmd", required=True)

    list_p = sub.add_parser("list", help="print available profiles")
    list_p.add_argument("--profile", default=None, help="show one profile")
    list_p.add_argument("--home", default="~", help="home directory for profile discovery")
    list_p.add_argument(
        "--profile-path",
        action="append",
        default=[],
        help="additional profile file or directory; may be repeated",
    )

    groups_p = sub.add_parser("groups", help="print available context groups")
    groups_p.add_argument("--home", default="~", help="home directory for group discovery")
    groups_p.add_argument(
        "--profile-path",
        action="append",
        default=[],
        help="additional profile/group file or directory; may be repeated",
    )

    suggest_p = sub.add_parser("suggest", help="rank context groups for a task/query")
    suggest_p.add_argument("--query", required=True, help="task text to match against context groups")
    suggest_p.add_argument("--limit", type=int, default=8, help="maximum groups to return")
    suggest_p.add_argument("--home", default="~", help="home directory for group discovery")
    suggest_p.add_argument(
        "--profile-path",
        action="append",
        default=[],
        help="additional profile/group file or directory; may be repeated",
    )

    coverage_p = sub.add_parser("coverage", help="verify groups cover expected skills/plugins")
    coverage_p.add_argument("--home", default="~", help="home directory for group discovery")
    coverage_p.add_argument(
        "--profile-path",
        action="append",
        default=[],
        help="additional profile/group file or directory; may be repeated",
    )
    coverage_p.add_argument(
        "--skills-root",
        action="append",
        default=[],
        help="directory whose child skill directories should be covered; may be repeated",
    )
    coverage_p.add_argument(
        "--marketplace",
        action="append",
        default=[],
        help="marketplace.json whose plugin names should be covered; may be repeated",
    )
    coverage_p.add_argument(
        "--plugin-suffix",
        default="@legion",
        help="suffix used to form enabled plugin ids from marketplace plugin names",
    )

    apply_p = sub.add_parser("apply", help="apply a reversible context profile")
    apply_p.add_argument("--profile", default=None, help="profile name")
    apply_p.add_argument(
        "--profile-path",
        action="append",
        default=[],
        help="additional profile file or directory; may be repeated",
    )
    apply_p.add_argument(
        "--include-group",
        action="append",
        default=[],
        help="temporarily include a context group; may be repeated",
    )
    apply_p.add_argument(
        "--disable-group",
        action="append",
        default=[],
        help="temporarily disable/archive a context group; may be repeated",
    )
    apply_p.add_argument("--home", default="~", help="home directory for default paths")
    apply_p.add_argument("--codex-skills", default=None, help="Codex skills directory")
    apply_p.add_argument("--agents-skills", default=None, help=".agents skills directory")
    apply_p.add_argument("--claude-settings", default=None, help="Claude settings.json path")
    apply_p.add_argument("--dry-run", action="store_true", help="report changes without writing")
    apply_p.add_argument("--no-backup", action="store_true", help="do not backup Claude settings")

    args = parser.parse_args(argv)

    home = _resolve(getattr(args, "home", "~"))
    context = load_context(home=home, explicit_paths=list(getattr(args, "profile_path", []) or []))
    profiles = context.profiles

    if args.cmd == "list":
        if args.profile:
            profile = _select_profile(args.profile, profiles)
            out = {
                "profile": profile.name,
                "description": profile.description,
                "strategy": profile.strategy,
                "include_groups": list(profile.include_groups),
                "disable_groups": list(profile.disable_groups),
                "skills": sorted(profile.skills),
                "plugins": sorted(profile.plugins),
                "disable_skills": sorted(profile.disable_skills),
                "disable_plugins": sorted(profile.disable_plugins),
                "source": str(profile.source_path) if profile.source_path else None,
            }
        else:
            out = {
                name: {
                    "description": profile.description,
                    "strategy": profile.strategy,
                    "include_groups": list(profile.include_groups),
                    "disable_groups": list(profile.disable_groups),
                    "skills": len(profile.skills),
                    "plugins": len(profile.plugins),
                    "disable_skills": len(profile.disable_skills),
                    "disable_plugins": len(profile.disable_plugins),
                    "source": str(profile.source_path) if profile.source_path else None,
                }
                for name, profile in sorted(profiles.items())
            }
        print(json.dumps(out, indent=2, sort_keys=True))
        return 0

    if args.cmd == "groups":
        out = {
            name: {
                "description": group.description,
                "skills": sorted(group.skills),
                "plugins": sorted(group.plugins),
                "source": str(group.source_path) if group.source_path else None,
            }
            for name, group in sorted(context.groups.items())
        }
        print(json.dumps(out, indent=2, sort_keys=True))
        return 0

    if args.cmd == "suggest":
        out = {
            "query": args.query,
            "groups": suggest_groups(args.query, context.groups, limit=max(1, args.limit)),
        }
        print(json.dumps(out, indent=2, sort_keys=True))
        return 0

    if args.cmd == "coverage":
        out = coverage_report(
            context.groups,
            skills_roots=list(args.skills_root or []),
            marketplaces=list(args.marketplace or []),
            plugin_suffix=args.plugin_suffix,
        )
        print(json.dumps(out, indent=2, sort_keys=True))
        return 0 if out["ok"] else 1

    profile = with_group_overrides(
        _select_profile(args.profile, profiles),
        context.groups,
        include_groups=list(args.include_group or []),
        disable_groups=list(args.disable_group or []),
    )
    defaults = _default_paths(home)
    summary = apply_profile(
        profile,
        codex_skills=_resolve(args.codex_skills or defaults["codex_skills"]),
        agents_skills=_resolve(args.agents_skills or defaults["agents_skills"]),
        claude_settings=_resolve(args.claude_settings or defaults["claude_settings"]),
        dry_run=bool(args.dry_run),
        backup=not bool(args.no_backup),
    )
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError) as exc:
        print(json.dumps({"error": str(exc)}))
        raise SystemExit(1)
