import importlib.util
import os
import sys
from pathlib import Path

import pytest

HERE = os.path.dirname(__file__)
_SPEC = importlib.util.spec_from_file_location(
    "legion_run_hooks",
    os.path.join(HERE, "..", "..", "legion-orchestrate", "scripts", "legion-run.py"),
)
lr = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(lr)

_BASE = """[plugin]
name = "demo"
kind = "domain-plugin"
[pipeline]
profile = "legion.heavy_task.v1"
entrypoint = "legion-run"
[commands]
plan = "demo-plan"
validate = "demo-validate"
evaluate = "demo-eval"
"""


def _manifest(tmp_path, extra=""):
    path = tmp_path / "legion-plugin.toml"
    path.write_text(_BASE + extra, encoding="utf-8")
    return path


def test_optional_hooks_are_resolved_when_declared(tmp_path):
    path = _manifest(tmp_path, 'review = "demo-review"\nheal = "demo-heal"\n')
    plugin = lr.load_plugin(path)
    assert plugin["commands"]["review"] == "demo-review"
    assert plugin["commands"]["heal"] == "demo-heal"
    assert plugin["hooks"] == {
        "review": True, "telemetry_sink": False, "doctor_checks": False, "heal": True,
    }


def test_a_manifest_written_before_the_hooks_existed_still_loads(tmp_path):
    """Absent means "use the built-in" — which is what every old manifest means."""
    plugin = lr.load_plugin(_manifest(tmp_path))
    assert plugin["commands"]["plan"] == "demo-plan"
    assert not any(plugin["hooks"].values())


def test_a_misspelled_hook_is_refused_not_ignored(tmp_path):
    # Silently dropping a typo'd hook looks identical to a hook that ran and did
    # nothing, and the point of a seam is knowing which side handled the work.
    path = _manifest(tmp_path, 'reveiw = "demo-review"\n')
    with pytest.raises(lr.LegionRunError) as excinfo:
        lr.load_plugin(path)
    assert "reveiw" in str(excinfo.value)


def test_required_commands_are_still_required(tmp_path):
    path = tmp_path / "legion-plugin.toml"
    path.write_text(_BASE.replace('validate = "demo-validate"\n', ""), encoding="utf-8")
    with pytest.raises(lr.LegionRunError):
        lr.load_plugin(path)
