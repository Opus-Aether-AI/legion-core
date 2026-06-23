import importlib.util
import json
import os
import subprocess
import sys

HERE = os.path.dirname(__file__)
PATH = os.path.join(
    HERE, "..", "..", "legion-observability", "scripts", "legion-context-profile.py"
)
SPEC = importlib.util.spec_from_file_location("legion_context_profile", PATH)
lcp = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = lcp
SPEC.loader.exec_module(lcp)


def _skill(root, name):
    path = root / name
    path.mkdir(parents=True)
    (path / "SKILL.md").write_text("---\nname: x\n---\nbody\n", encoding="utf-8")
    return path


def _profiles(root):
    path = root / "profiles"
    path.mkdir(parents=True)
    (path / "groups.json").write_text(
        json.dumps(
            {
                "schema": "legion.context-groups.v1",
                "groups": {
                    "coding-baseline": {
                        "description": "Common coding skills for most repos.",
                        "skills": [".system", "legion-router"],
                        "plugins": ["legion-router@legion-core"],
                    },
                    "noisy-demo": {
                        "description": "Explicitly noisy surfaces for tests.",
                        "skills": ["unused-skill"],
                        "plugins": ["random@plugin"],
                    },
                    "frontend-web": {
                        "description": "Frontend test group.",
                        "skills": ["webapp-testing"],
                        "plugins": ["webapp-testing@legion"],
                    },
                },
            }
        ),
        encoding="utf-8",
    )
    (path / "project-legion.json").write_text(
        json.dumps(
            {
                "schema": "legion.context-profile.v1",
                "name": "project-legion",
                "description": "Test project profile owned outside legion-core.",
                "strategy": "overlay",
                "include_groups": ["coding-baseline"],
                "disable_groups": ["noisy-demo"],
                "skills": ["zod"],
                "plugins": ["zod@legion"],
            }
        ),
        encoding="utf-8",
    )
    (path / "strict-project.json").write_text(
        json.dumps(
            {
                "schema": "legion.context-profile.v1",
                "name": "strict-project",
                "description": "Strict test profile.",
                "strategy": "strict",
                "include_groups": ["coding-baseline"],
                "skills": ["zod"],
                "plugins": ["zod@legion"],
            }
        ),
        encoding="utf-8",
    )
    return path


def _legion_code_like_profiles(root):
    path = root / "legion-code-context-profiles"
    path.mkdir(parents=True)
    (path / "groups.json").write_text(
        json.dumps(
            {
                "schema": "legion.context-groups.v1",
                "groups": {
                    "coding-baseline": {
                        "description": "Common coding and diagnosis skills.",
                        "skills": [".system", "codebase-design", "diagnose", "tdd"],
                        "plugins": ["codebase-design@legion", "diagnose@legion", "tdd@legion"],
                    },
                    "frontend-web": {
                        "description": "Frontend implementation and browser testing.",
                        "skills": ["browser-patterns", "webapp-testing"],
                        "plugins": ["browser-patterns@legion", "webapp-testing@legion"],
                    },
                    "legion-engine": {
                        "description": "Legion orchestration, routing, observability, and setup.",
                        "skills": [
                            "legion-codex-mode",
                            "legion-observability",
                            "legion-orchestrate",
                            "legion-router",
                            "legion-setup",
                        ],
                        "plugins": [
                            "legion-codex-mode@legion-core",
                            "legion-observability@legion-core",
                            "legion-orchestrate@legion-core",
                            "legion-router@legion-core",
                            "legion-setup@legion-core",
                        ],
                    },
                    "monorepo": {
                        "description": "Workspace-aware monorepo tooling.",
                        "skills": ["opus-monorepo", "turborepo"],
                        "plugins": ["opus-monorepo@legion", "turborepo@legion"],
                    },
                    "vercel-ai": {
                        "description": "Vercel, Next.js, AI SDK, and Chat SDK.",
                        "skills": ["vercel-ai-sdk", "vercel-chat-sdk", "vercel-nextjs"],
                        "plugins": ["vercel-plugin@legion", "vercel-plugin@vercel"],
                    },
                    "documents-and-communication": {
                        "description": "Non-coding document, Slack, Canva, and Linear surfaces.",
                        "skills": ["canva", "documents", "linear", "slack"],
                        "plugins": ["canva@canva", "documents@openai-primary-runtime", "linear@linear", "slack@slack"],
                    },
                },
            }
        ),
        encoding="utf-8",
    )
    (path / "webapp-legion.json").write_text(
        json.dumps(
            {
                "schema": "legion.context-profile.v1",
                "name": "webapp-legion",
                "description": "Web application coding profile with Legion orchestration.",
                "strategy": "overlay",
                "include_groups": [
                    "coding-baseline",
                    "frontend-web",
                    "legion-engine",
                    "monorepo",
                    "vercel-ai",
                ],
                "disable_groups": ["documents-and-communication"],
            }
        ),
        encoding="utf-8",
    )
    return path


def _run_context_profile(*args):
    return subprocess.run(
        [sys.executable, PATH, *args],
        check=True,
        capture_output=True,
        text=True,
    )


def test_overlay_profile_only_archives_explicitly_disabled_skills(tmp_path):
    profiles = lcp.load_profiles(home=tmp_path, explicit_paths=[_profiles(tmp_path)])
    codex = tmp_path / ".codex" / "skills"
    agents = tmp_path / ".agents" / "skills"
    settings = tmp_path / ".claude" / "settings.json"
    _skill(codex, "legion-router")
    _skill(codex, "unused-skill")
    _skill(agents, "zod")
    _skill(agents, "unused-agent-skill")
    settings.parent.mkdir(parents=True)
    settings.write_text(
        json.dumps(
            {
                "enabledPlugins": {
                    "legion-router@legion-core": False,
                    "random@plugin": True,
                    "zod@legion": True,
                }
            }
        ),
        encoding="utf-8",
    )

    summary = lcp.apply_profile(
        profiles["project-legion"],
        codex_skills=codex,
        agents_skills=agents,
        claude_settings=settings,
        dry_run=True,
        backup=False,
    )

    assert summary["codex"]["archived"][0]["name"] == "unused-skill"
    assert summary["agents"]["archived"] == []
    assert (codex / "unused-skill").exists()
    assert (agents / "unused-agent-skill").exists()
    data = json.loads(settings.read_text(encoding="utf-8"))
    assert data["enabledPlugins"]["legion-router@legion-core"] is False
    assert data["enabledPlugins"]["random@plugin"] is True


def test_overlay_profile_enables_selected_plugins_and_disables_explicit_noise(tmp_path):
    profiles = lcp.load_profiles(home=tmp_path, explicit_paths=[_profiles(tmp_path)])
    codex = tmp_path / ".codex" / "skills"
    agents = tmp_path / ".agents" / "skills"
    settings = tmp_path / ".claude" / "settings.json"
    _skill(codex, ".system")
    _skill(codex, "legion-router")
    _skill(codex, "unused-skill")
    _skill(agents, "zod")
    _skill(agents, "unused-agent-skill")
    settings.parent.mkdir(parents=True)
    settings.write_text(
        json.dumps(
            {
                "enabledPlugins": {
                    "legion-router@legion-core": False,
                    "random@plugin": True,
                    "zod@legion": True,
                }
            }
        ),
        encoding="utf-8",
    )

    summary = lcp.apply_profile(
        profiles["project-legion"],
        codex_skills=codex,
        agents_skills=agents,
        claude_settings=settings,
        dry_run=False,
        backup=False,
    )

    assert summary["strategy"] == "overlay"
    assert sorted(summary["codex"]["kept"]) == [".system", "legion-router"]
    assert summary["codex"]["archived"][0]["name"] == "unused-skill"
    assert summary["agents"]["archived"] == []
    assert (codex / "legion-router").exists()
    assert not (codex / "unused-skill").exists()
    assert (
        codex.parent / "skills.disabled" / "project-legion" / "unused-skill"
    ).exists()
    assert (agents / "unused-agent-skill").exists()

    data = json.loads(settings.read_text(encoding="utf-8"))
    assert data["enabledPlugins"]["legion-router@legion-core"] is True
    assert data["enabledPlugins"]["zod@legion"] is True
    assert data["enabledPlugins"]["random@plugin"] is False


def test_strict_profile_archives_anything_outside_resolved_groups(tmp_path):
    profiles = lcp.load_profiles(home=tmp_path, explicit_paths=[_profiles(tmp_path)])
    codex = tmp_path / ".codex" / "skills"
    agents = tmp_path / ".agents" / "skills"
    settings = tmp_path / ".claude" / "settings.json"
    _skill(codex, ".system")
    _skill(codex, "legion-router")
    _skill(codex, "unused-skill")
    _skill(agents, "zod")
    _skill(agents, "unused-agent-skill")
    settings.parent.mkdir(parents=True)
    settings.write_text(
        json.dumps(
            {
                "enabledPlugins": {
                    "legion-router@legion-core": False,
                    "random@plugin": True,
                    "zod@legion": True,
                }
            }
        ),
        encoding="utf-8",
    )

    summary = lcp.apply_profile(
        profiles["strict-project"],
        codex_skills=codex,
        agents_skills=agents,
        claude_settings=settings,
        dry_run=False,
        backup=False,
    )

    assert summary["strategy"] == "strict"
    assert summary["codex"]["archived"][0]["name"] == "unused-skill"
    assert summary["agents"]["archived"][0]["name"] == "unused-agent-skill"
    data = json.loads(settings.read_text(encoding="utf-8"))
    assert data["enabledPlugins"]["random@plugin"] is False


def test_profile_loader_discovers_repo_profile_from_standard_location(tmp_path):
    repo = tmp_path / "repo"
    profile_dir = repo / ".legion" / "context-profiles"
    profile_dir.mkdir(parents=True)
    (profile_dir / "repo.json").write_text(
        json.dumps(
            {
                "schema": "legion.context-profile.v1",
                "name": "repo-profile",
                "description": "Repo-owned context profile.",
                "strategy": "overlay",
                "skills": ["legion-orchestrate"],
                "plugins": ["legion-orchestrate@legion-core"],
            }
        ),
        encoding="utf-8",
    )

    profiles = lcp.load_profiles(home=tmp_path, cwd=repo)

    assert profiles["repo-profile"].skills == frozenset({"legion-orchestrate"})
    assert profiles["repo-profile"].source_path == profile_dir / "repo.json"


def test_cli_group_overrides_expand_profile_like_a_query_region(tmp_path):
    context = lcp.load_context(home=tmp_path, explicit_paths=[_profiles(tmp_path)])

    profile = lcp.with_group_overrides(
        context.profiles["project-legion"],
        context.groups,
        include_groups=["frontend-web"],
    )

    assert "frontend-web" in profile.include_groups
    assert "webapp-testing" in profile.skills
    assert "webapp-testing@legion" in profile.plugins


def test_suggest_groups_ranks_nearby_skill_regions(tmp_path):
    context = lcp.load_context(home=tmp_path, explicit_paths=[_profiles(tmp_path)])

    suggestions = lcp.suggest_groups("debug a frontend webapp test", context.groups)

    assert suggestions[0]["group"] == "frontend-web"
    assert "webapp-testing" in suggestions[0]["skills"]


def test_coverage_reports_missing_skills_and_plugins(tmp_path):
    profiles_dir = _profiles(tmp_path)
    skills = tmp_path / "skills"
    _skill(skills, "legion-router")
    _skill(skills, "missing-skill")
    marketplace = tmp_path / "marketplace.json"
    marketplace.write_text(
        json.dumps(
            {
                "plugins": [
                    {"name": "legion-router"},
                    {"name": "missing-plugin"},
                ]
            }
        ),
        encoding="utf-8",
    )
    context = lcp.load_context(home=tmp_path, explicit_paths=[profiles_dir])

    report = lcp.coverage_report(
        context.groups,
        skills_roots=[skills],
        marketplaces=[marketplace],
        plugin_suffix="@legion-core",
    )

    assert report["ok"] is False
    assert report["missing_skills"] == ["missing-skill"]
    assert report["missing_plugins"] == ["missing-plugin@legion-core"]


def test_coverage_passes_when_expected_surface_is_grouped(tmp_path):
    profiles_dir = _profiles(tmp_path)
    skills = tmp_path / "skills"
    _skill(skills, "legion-router")
    marketplace = tmp_path / "marketplace.json"
    marketplace.write_text(
        json.dumps({"plugins": [{"name": "legion-router"}]}),
        encoding="utf-8",
    )
    context = lcp.load_context(home=tmp_path, explicit_paths=[profiles_dir])

    report = lcp.coverage_report(
        context.groups,
        skills_roots=[skills],
        marketplaces=[marketplace],
        plugin_suffix="@legion-core",
    )

    assert report["ok"] is True
    assert report["missing_skills"] == []
    assert report["missing_plugins"] == []


def test_cli_suggest_routes_orchestration_to_legion_engine_from_external_catalog(tmp_path):
    profiles_dir = _legion_code_like_profiles(tmp_path)

    result = _run_context_profile(
        "suggest",
        "--home",
        str(tmp_path),
        "--profile-path",
        str(profiles_dir),
        "--query",
        "orchestrate codex router fanout multi model delegation",
        "--limit",
        "3",
    )

    data = json.loads(result.stdout)
    assert data["groups"][0]["group"] == "legion-engine"
    assert "legion-orchestrate" in data["groups"][0]["skills"]
    assert "legion-orchestrate@legion-core" in data["groups"][0]["plugins"]


def test_cli_coverage_accepts_legion_code_style_catalog(tmp_path):
    profiles_dir = _legion_code_like_profiles(tmp_path)
    skills = tmp_path / "skills"
    for name in [
        ".system",
        "browser-patterns",
        "codebase-design",
        "documents",
        "legion-orchestrate",
        "legion-router",
        "opus-monorepo",
        "turborepo",
        "vercel-nextjs",
        "webapp-testing",
    ]:
        _skill(skills, name)
    marketplace = tmp_path / "marketplace.json"
    marketplace.write_text(
        json.dumps(
            {
                "plugins": [
                    {"name": "browser-patterns"},
                    {"name": "codebase-design"},
                    {"name": "opus-monorepo"},
                    {"name": "turborepo"},
                    {"name": "webapp-testing"},
                ]
            }
        ),
        encoding="utf-8",
    )

    result = _run_context_profile(
        "coverage",
        "--home",
        str(tmp_path),
        "--profile-path",
        str(profiles_dir),
        "--skills-root",
        str(skills),
        "--marketplace",
        str(marketplace),
        "--plugin-suffix",
        "@legion",
    )

    data = json.loads(result.stdout)
    assert data["ok"] is True
    assert data["missing_skills"] == []
    assert data["missing_plugins"] == []


def test_cli_apply_keeps_legion_orchestration_active_with_legion_code_profile(tmp_path):
    profiles_dir = _legion_code_like_profiles(tmp_path)
    codex = tmp_path / ".codex" / "skills"
    agents = tmp_path / ".agents" / "skills"
    settings = tmp_path / ".claude" / "settings.json"
    for name in [
        ".system",
        "documents",
        "legion-orchestrate",
        "legion-router",
        "slack",
        "unused-local",
        "webapp-testing",
    ]:
        _skill(codex, name)
    for name in ["documents", "legion-orchestrate", "unused-agent"]:
        _skill(agents, name)
    settings.parent.mkdir(parents=True)
    settings.write_text(
        json.dumps(
            {
                "enabledPlugins": {
                    "browser-patterns@legion": False,
                    "canva@canva": True,
                    "legion-orchestrate@legion-core": False,
                    "random@plugin": True,
                    "slack@slack": True,
                }
            }
        ),
        encoding="utf-8",
    )

    result = _run_context_profile(
        "apply",
        "--home",
        str(tmp_path),
        "--profile",
        "webapp-legion",
        "--profile-path",
        str(profiles_dir),
        "--codex-skills",
        str(codex),
        "--agents-skills",
        str(agents),
        "--claude-settings",
        str(settings),
        "--no-backup",
    )

    summary = json.loads(result.stdout)
    assert summary["strategy"] == "overlay"
    assert {".system", "legion-orchestrate", "legion-router", "webapp-testing"} <= set(
        summary["codex"]["kept"]
    )
    assert {item["name"] for item in summary["codex"]["archived"]} == {
        "documents",
        "slack",
    }
    assert {item["name"] for item in summary["agents"]["archived"]} == {"documents"}
    assert (codex / "legion-orchestrate").exists()
    assert (codex / "legion-router").exists()
    assert (codex / "unused-local").exists()
    assert not (codex / "documents").exists()
    assert not (codex / "slack").exists()
    assert (agents / "legion-orchestrate").exists()
    assert (agents / "unused-agent").exists()
    assert not (agents / "documents").exists()
    data = json.loads(settings.read_text(encoding="utf-8"))
    assert data["enabledPlugins"]["legion-orchestrate@legion-core"] is True
    assert data["enabledPlugins"]["browser-patterns@legion"] is True
    assert data["enabledPlugins"]["canva@canva"] is False
    assert data["enabledPlugins"]["slack@slack"] is False
    assert data["enabledPlugins"]["random@plugin"] is True
