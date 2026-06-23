import importlib.util
import json
import os
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


def test_apply_profile_dry_run_does_not_move_skills_or_write_settings(tmp_path):
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
        lcp.PROFILES["webapp-legion"],
        codex_skills=codex,
        agents_skills=agents,
        claude_settings=settings,
        dry_run=True,
        backup=False,
    )

    assert summary["codex"]["archived"][0]["name"] == "unused-skill"
    assert summary["agents"]["archived"][0]["name"] == "unused-agent-skill"
    assert (codex / "unused-skill").exists()
    assert (agents / "unused-agent-skill").exists()
    data = json.loads(settings.read_text(encoding="utf-8"))
    assert data["enabledPlugins"]["legion-router@legion-core"] is False
    assert data["enabledPlugins"]["random@plugin"] is True


def test_apply_profile_archives_unused_skills_and_trims_claude_plugins(tmp_path):
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
        lcp.PROFILES["webapp-legion"],
        codex_skills=codex,
        agents_skills=agents,
        claude_settings=settings,
        dry_run=False,
        backup=False,
    )

    assert sorted(summary["codex"]["kept"]) == [".system", "legion-router"]
    assert summary["codex"]["archived"][0]["name"] == "unused-skill"
    assert summary["agents"]["archived"][0]["name"] == "unused-agent-skill"
    assert (codex / "legion-router").exists()
    assert not (codex / "unused-skill").exists()
    assert (
        codex.parent / "skills.disabled" / "webapp-legion" / "unused-skill"
    ).exists()
    assert not (agents / "unused-agent-skill").exists()
    assert (
        agents.parent / "skills.disabled" / "webapp-legion" / "unused-agent-skill"
    ).exists()

    data = json.loads(settings.read_text(encoding="utf-8"))
    assert data["enabledPlugins"]["legion-router@legion-core"] is True
    assert data["enabledPlugins"]["zod@legion"] is True
    assert data["enabledPlugins"]["random@plugin"] is False
