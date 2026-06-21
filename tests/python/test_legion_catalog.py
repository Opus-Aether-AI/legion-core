import importlib.util
import json
import os


HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(
    HERE, "..", "..", "legion-observability", "scripts", "legion-catalog.py"
)
SPEC = importlib.util.spec_from_file_location("legion_catalog", SCRIPT)
catalog = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(catalog)


def _write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def _write_json(path, payload):
    _write(path, json.dumps(payload, indent=2))


def _skill(name, description):
    return (
        "---\n"
        f"name: {name}\n"
        f"description: {description}\n"
        "---\n\n"
        "Body.\n"
    )


def _make_marketplace(tmp_path):
    repo = tmp_path / "repo"
    _write_json(
        repo / ".claude-plugin" / "marketplace.json",
        {
            "plugins": [
                {
                    "name": "plugin-top",
                    "source": "./plugins/plugin-top",
                    "description": "Top-level skill plugin",
                    "version": "0.1.0",
                },
                {
                    "name": "plugin-nested",
                    "source": "./plugins/plugin-nested",
                    "description": "Nested plugin",
                    "version": "0.2.0",
                },
                {
                    "name": "plugin-empty",
                    "source": "./plugins/plugin-empty",
                    "description": "Optional files missing",
                    "version": "0.3.0",
                },
            ]
        },
    )

    top = repo / "plugins" / "plugin-top"
    _write(top / "SKILL.md", _skill("top-skill", "Top skill description"))
    _write_json(
        top / ".claude-plugin" / "plugin.json",
        {"name": "plugin-top", "description": "Top manifest", "version": "1.0.0"},
    )

    nested = repo / "plugins" / "plugin-nested"
    _write_json(
        nested / ".claude-plugin" / "plugin.json",
        {
            "name": "plugin-nested",
            "description": "Nested manifest",
            "version": "2.0.0",
        },
    )
    _write(
        nested / "skills" / "nested-one" / "SKILL.md",
        _skill("nested-one", "First nested skill"),
    )
    _write(
        nested / "skills" / "nested-two" / "SKILL.md",
        _skill("nested-two", "Second nested skill"),
    )
    _write(
        nested / "agents" / "a.md",
        _skill("alpha-agent", "Agent description"),
    )
    _write(
        nested / "commands" / "c.md",
        _skill("alpha-command", "Command description"),
    )
    # Real-world layout: hooks/hooks.json with the event map wrapped under "hooks".
    _write_json(
        nested / "hooks" / "hooks.json",
        {
            "hooks": {
                "PostToolUse": [{"matcher": "Write"}],
                "PreToolUse": [{"matcher": "Read"}],
            }
        },
    )
    _write_json(
        nested / ".mcp.json",
        {"mcpServers": {"alpha-mcp": {"command": "uvx", "args": ["srv"]}}},
    )

    empty = repo / "plugins" / "plugin-empty"
    empty.mkdir(parents=True, exist_ok=True)

    return repo, top, nested, empty


def test_enumerate_plugin_finds_entities_and_frontmatter(tmp_path):
    _, top, nested, _ = _make_marketplace(tmp_path)

    top_entities = catalog.enumerate_plugin(str(top), "plugin-top")
    assert top_entities == [
        {
            "type": "skill",
            "name": "top-skill",
            "plugin": "plugin-top",
            "description": "Top skill description",
            "source_path": os.path.abspath(str(top / "SKILL.md")),
            "detail": {"layout": "top-level"},
        }
    ]

    nested_entities = catalog.enumerate_plugin(str(nested), "plugin-nested")
    keyed = {(entity["type"], entity["name"]): entity for entity in nested_entities}

    assert keyed[("skill", "nested-one")]["description"] == "First nested skill"
    assert keyed[("skill", "nested-two")]["description"] == "Second nested skill"
    assert keyed[("agent", "alpha-agent")]["description"] == "Agent description"
    assert keyed[("command", "alpha-command")]["description"] == "Command description"
    assert ("hook", "PostToolUse") in keyed
    assert ("hook", "PreToolUse") in keyed
    assert ("mcp", "alpha-mcp") in keyed
    assert len(nested_entities) == 7


def test_build_catalog_counts_sorting_and_installed_cross_checks(tmp_path):
    repo, _, _, empty = _make_marketplace(tmp_path)
    homes = {
        "claude_plugins": str(tmp_path / "home" / ".claude" / "plugins"),
        "agents_skills": str(tmp_path / "home" / ".agents" / "skills"),
        "codex_skills": str(tmp_path / "home" / ".codex" / "skills"),
        "agents_bin": str(tmp_path / "home" / ".agents" / "bin"),
    }

    os.makedirs(
        os.path.join(homes["claude_plugins"], "cache", "legion", "plugin-nested"),
        exist_ok=True,
    )
    os.makedirs(os.path.join(homes["agents_skills"], "nested-one"), exist_ok=True)

    result = catalog.build_catalog(str(repo), homes=homes)

    assert result["plugins"] == 3
    assert result["by_type"] == {
        "plugin": 3,
        "skill": 3,
        "agent": 1,
        "command": 1,
        "hook": 2,
        "mcp": 1,
    }

    order = [(entity["type"], entity["plugin"], entity["name"]) for entity in result["entities"]]
    assert order == sorted(order)

    plugin_entities = {
        entity["name"]: entity for entity in result["entities"] if entity["type"] == "plugin"
    }
    assert set(plugin_entities) == {"plugin-top", "plugin-nested", "plugin-empty"}
    assert plugin_entities["plugin-nested"]["installed"] is True
    assert plugin_entities["plugin-empty"]["installed"] is False

    keyed = {
        (entity["type"], entity["name"]): entity for entity in result["entities"] if entity["type"] != "plugin"
    }
    assert keyed[("skill", "nested-one")]["installed"] is True
    assert keyed[("skill", "nested-two")]["installed"] is False
    assert keyed[("command", "alpha-command")]["installed"] is True
    assert keyed[("mcp", "alpha-mcp")]["installed"] is True

    assert catalog.enumerate_plugin(str(empty), "plugin-empty") == []
