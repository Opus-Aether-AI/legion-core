import importlib.util
import json
from pathlib import Path

import pytest


ROOT = Path(__file__).parents[2]
SCRIPT = ROOT / "scripts" / "check-license-metadata.py"
SPEC = importlib.util.spec_from_file_location("license_metadata", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


LICENSE_TEXT = """Business Source License 1.1

Change Date:          2030-08-27

Change License:       Apache License, Version 2.0
"""


def write_release(tmp_path: Path) -> Path:
    release = tmp_path / "release"
    plugin = release / "plugin" / ".claude-plugin"
    policy_dir = release / ".claude-plugin"
    plugin.mkdir(parents=True)
    policy_dir.mkdir(parents=True)
    (release / "LICENSE").write_text(LICENSE_TEXT, encoding="utf-8")
    digest = MODULE.hashlib.sha256((release / "LICENSE").read_bytes()).hexdigest()
    (release / "package.json").write_text(
        json.dumps({"license": "BUSL-1.1"}), encoding="utf-8"
    )
    (policy_dir / "license-policy.json").write_text(
        json.dumps(
            {
                "schema": "legion.license-policy.v1",
                "spdx": "BUSL-1.1",
                "license_file": "LICENSE",
                "license_sha256": digest,
                "change_date": "2030-08-27",
                "change_license": "Apache-2.0",
            }
        ),
        encoding="utf-8",
    )
    (policy_dir / "marketplace.json").write_text(
        json.dumps(
            {
                "license": "BUSL-1.1",
                "plugins": [
                    {
                        "name": "plugin",
                        "source": "./plugin",
                        "license": "BUSL-1.1",
                    }
                ],
            }
        ),
        encoding="utf-8",
    )
    (plugin / "plugin.json").write_text(
        json.dumps({"license": "BUSL-1.1"}), encoding="utf-8"
    )
    return release


def test_repository_license_metadata_is_coherent() -> None:
    assert MODULE.validate(ROOT) == []


def test_conflicting_plugin_license_fails(tmp_path: Path) -> None:
    release = write_release(tmp_path)
    marketplace_path = release / ".claude-plugin" / "marketplace.json"
    marketplace = json.loads(marketplace_path.read_text(encoding="utf-8"))
    marketplace["plugins"][0]["license"] = "Apache-2.0"
    marketplace_path.write_text(json.dumps(marketplace), encoding="utf-8")

    errors = MODULE.validate(release)

    assert errors == [
        "marketplace plugin 'plugin' license 'Apache-2.0' != 'BUSL-1.1'"
    ]


@pytest.mark.parametrize(
    ("field", "value", "message"),
    [
        ("change_date", "2031-01-01", "LICENSE Change Date"),
        ("change_license", "MIT", "LICENSE Change License"),
    ],
)
def test_policy_transition_must_match_busl_text(
    tmp_path: Path, field: str, value: str, message: str
) -> None:
    release = write_release(tmp_path)
    policy_path = release / ".claude-plugin" / "license-policy.json"
    policy = json.loads(policy_path.read_text(encoding="utf-8"))
    policy[field] = value
    policy_path.write_text(json.dumps(policy), encoding="utf-8")

    errors = MODULE.validate(release)

    assert len(errors) == 1
    assert message in errors[0]
