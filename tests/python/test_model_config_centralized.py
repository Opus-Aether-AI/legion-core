import os
import re
import subprocess


ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def _tracked_files():
    """Tracked paths only.

    The rule is about what the repo ships, so walking the filesystem is the wrong
    scope: a working tree carries local `.legion/` run records and other ignored
    scratch that legitimately names concrete models, and scanning those turns an
    ordinary local run into a false failure.
    """
    listing = subprocess.run(
        ["git", "-C", ROOT, "ls-files", "-z"],
        capture_output=True,
        text=True,
        check=True,
    )
    return [rel for rel in listing.stdout.split("\0") if rel]

ACTIVE_DEFAULT_FILES = [
    "README.md",
    "docs/benchmarking.md",
    "legion-codex-mode/README.md",
    "legion-codex-mode/SKILL.md",
    "legion-deepseek-mode/README.md",
    "legion-deepseek-mode/SKILL.md",
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
    concrete_model = _concrete_model_pattern()
    offenders = []
    for rel in ACTIVE_DEFAULT_FILES:
        path = os.path.join(ROOT, rel)
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
        if match := concrete_model.search(text):
            offenders.append(f"{rel}: {match.group(0)}")

    assert offenders == []


def _concrete_model_pattern():
    return re.compile(
        r"\b(?:gpt-\d+(?:\.\d+)+(?:[-_][a-z0-9.]+)*"
        r"|claude[-_][a-z0-9.-]*\d[a-z0-9.-]*"
        r"|o\d+(?:[-_][a-z0-9.]+)?"
        r"|(?:cursor[-_])?(?:composer|grok)[-_]?\d[a-z0-9._-]*"
        r"|github-copilot/gpt-\d+(?:\.\d+)*"
        r"|minimax[-_/][a-z0-9.-]*\d[a-z0-9.-]*)\b",
        re.IGNORECASE,
    )


def test_only_model_and_cost_catalogs_contain_concrete_model_ids():
    pattern = _concrete_model_pattern()
    allowed = {
        "legion-router/config/models.toml",
        "legion-router/config/costs.json",
    }
    offenders = []
    for rel in _tracked_files():
        name = os.path.basename(rel)
        if rel == "docs/benchmarks" or rel.startswith("docs/benchmarks/"):
            continue
        if rel in allowed or name.startswith("CHANGELOG") or "lock" in name.lower():
            continue
        try:
            with open(os.path.join(ROOT, rel), encoding="utf-8") as handle:
                text = handle.read()
        except (OSError, UnicodeDecodeError):
            continue
        if match := pattern.search(text):
            offenders.append(f"{rel}: {match.group(0)}")

    assert offenders == []
