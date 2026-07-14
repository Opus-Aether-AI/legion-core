import os


ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

ACTIVE_DEFAULT_FILES = [
    "README.md",
    "docs/benchmarking.md",
    "legion-codex-mode/README.md",
    "legion-codex-mode/SKILL.md",
    "legion-observability/README.md",
    "legion-observability/bench/adapters/cursor-agent.sh",
    "legion-observability/bench/adapters/direct-claude.sh",
    "legion-observability/bench/adapters/direct-codex.sh",
    "legion-observability/bench/adapters/legion-cursor.sh",
    "legion-observability/bench/core.json",
    "legion-observability/bench/corpora/README.md",
    "legion-observability/bench/corpora/aider-polyglot-python.json",
    "legion-observability/bench/corpora/heldout-oss-36.json",
    "legion-observability/bench/corpora/heldout-oss-hard.json",
    "legion-observability/bench/corpora/local-smoke.json",
    "legion-observability/bench/stable.json",
    "legion-observability/eval/skill-triggering.yaml",
    "legion-observability/scripts/legion-telemetry.sh",
    "legion-orchestrate/README.md",
    "legion-orchestrate/SKILL.md",
    "legion-orchestrate/scripts/legion-fanout.sh",
    "legion-run/README.md",
    "legion-run/SKILL.md",
    "legion-router/README.md",
    "legion-router/SKILL.md",
    "legion-router/config/routing.toml",
    "legion-router/scripts/delegate.sh",
    "legion-router/scripts/legion-claude.sh",
    "legion-router/scripts/legion-cursor.sh",
    "legion-router/scripts/legion-intake.sh",
    "legion-router/scripts/router.ts",
    "legion-setup/SKILL.md",
    "legion-setup/scripts/legion-codex-setup.sh",
]


def test_active_default_guidance_uses_model_refs():
    needles = [
        "gpt-" + "5.5",
        "gpt-" + "5.4",
        "composer-" + "2.5",
        "claude-haiku-" + "4-5",
        "claude-" + "opus",
        "claude-sonnet-" + "4",
        "sonnet " + "4.6",
        "model = " + '"opus"',
        "model=" + '"opus"',
        "--model " + "opus",
        "CLAUDE_MODEL=" + "opus",
    ]
    offenders = []
    for rel in ACTIVE_DEFAULT_FILES:
        path = os.path.join(ROOT, rel)
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
        for needle in needles:
            if needle in text:
                offenders.append(f"{rel}: {needle}")

    assert offenders == []
