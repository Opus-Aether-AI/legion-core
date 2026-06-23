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
import shutil
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


WEBAPP_LEGION_SKILLS = frozenset(
    {
        ".system",
        "browser-patterns",
        "codebase-design",
        "diagnose",
        "domain-modeling",
        "impeccable",
        "implement",
        "legion-cmd-bugfix",
        "legion-cmd-feature",
        "legion-cmd-performance-pass",
        "legion-cmd-plan-with-team",
        "legion-cmd-refactor",
        "legion-cmd-review-gate",
        "legion-cmd-test-hardening",
        "legion-cmd-ultra-review",
        "legion-codex-mode",
        "legion-observability",
        "legion-orchestrate",
        "legion-router",
        "legion-setup",
        "opus-commands",
        "opus-monorepo",
        "playwright-cli",
        "refactor-plan",
        "tdd",
        "turborepo",
        "vercel-ai-sdk",
        "vercel-chat-sdk",
        "vercel-cli",
        "vercel-nextjs",
        "vercel-react-best-practices",
        "webapp-testing",
        "zod",
    }
)

WEBAPP_LEGION_PLUGINS = frozenset(
    {
        "browser-patterns@legion",
        "codebase-design@legion",
        "context7@claude-plugins-official",
        "diagnose@legion",
        "domain-modeling@legion",
        "impeccable@legion",
        "implement@legion",
        "legion-codex-mode@legion-core",
        "legion-observability@legion-core",
        "legion-orchestrate@legion-core",
        "legion-router@legion-core",
        "legion-setup@legion-core",
        "opus-codebase-memory@legion",
        "opus-commands@legion",
        "opus-core@legion",
        "opus-monorepo@legion",
        "playwright-cli@legion",
        "refactor-plan@legion",
        "tdd@legion",
        "turborepo@legion",
        "vercel-plugin@vercel",
        "webapp-testing@legion",
        "zod@legion",
    }
)


@dataclass(frozen=True)
class Profile:
    name: str
    description: str
    skills: frozenset[str]
    plugins: frozenset[str]


PROFILES = {
    "webapp-legion": Profile(
        name="webapp-legion",
        description=(
            "Aether Wealth webapp profile: Legion orchestration, routing, "
            "observability, webapp testing, design, monorepo, and Vercel skills."
        ),
        skills=WEBAPP_LEGION_SKILLS,
        plugins=WEBAPP_LEGION_PLUGINS,
    )
}


def _resolve(path: str | Path) -> Path:
    return Path(path).expanduser()


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
    dry_run: bool = False,
) -> dict[str, Any]:
    skills_dir = _resolve(skills_dir)
    disabled_dir = skills_dir.parent / "skills.disabled" / profile_name
    summary: dict[str, Any] = {
        "skills_dir": str(skills_dir),
        "disabled_dir": str(disabled_dir),
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
    for child in children:
        if child.name in keep:
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
    dry_run: bool = False,
    backup: bool = True,
) -> dict[str, Any]:
    settings_path = _resolve(settings_path)
    summary: dict[str, Any] = {
        "settings": str(settings_path),
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
    for name in sorted(plugins):
        desired = name in keep
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
        "dry_run": dry_run,
        "codex": archive_skills(codex_skills, profile.skills, profile.name, dry_run=dry_run),
        "agents": archive_skills(agents_skills, profile.skills, profile.name, dry_run=dry_run),
        "claude": trim_claude_plugins(
            claude_settings,
            profile.plugins,
            dry_run=dry_run,
            backup=backup,
        ),
    }


def _profile_or_exit(name: str) -> Profile:
    try:
        return PROFILES[name]
    except KeyError:
        known = ", ".join(sorted(PROFILES))
        raise SystemExit(f"unknown profile '{name}'. Known profiles: {known}") from None


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

    apply_p = sub.add_parser("apply", help="apply a reversible context profile")
    apply_p.add_argument("--profile", default="webapp-legion", help="profile name")
    apply_p.add_argument("--home", default="~", help="home directory for default paths")
    apply_p.add_argument("--codex-skills", default=None, help="Codex skills directory")
    apply_p.add_argument("--agents-skills", default=None, help=".agents skills directory")
    apply_p.add_argument("--claude-settings", default=None, help="Claude settings.json path")
    apply_p.add_argument("--dry-run", action="store_true", help="report changes without writing")
    apply_p.add_argument("--no-backup", action="store_true", help="do not backup Claude settings")

    args = parser.parse_args(argv)

    if args.cmd == "list":
        if args.profile:
            profile = _profile_or_exit(args.profile)
            out = {
                "profile": profile.name,
                "description": profile.description,
                "skills": sorted(profile.skills),
                "plugins": sorted(profile.plugins),
            }
        else:
            out = {
                name: {
                    "description": profile.description,
                    "skills": len(profile.skills),
                    "plugins": len(profile.plugins),
                }
                for name, profile in sorted(PROFILES.items())
            }
        print(json.dumps(out, indent=2, sort_keys=True))
        return 0

    profile = _profile_or_exit(args.profile)
    defaults = _default_paths(_resolve(args.home))
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
