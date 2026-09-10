import importlib.util
import json
from pathlib import Path


ROOT = Path(__file__).parents[2]
SCRIPT = ROOT / "scripts" / "check-license-metadata.py"
SPEC = importlib.util.spec_from_file_location("license_metadata", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def test_repository_license_metadata_is_coherent() -> None:
    assert MODULE.validate(ROOT) == []


def test_conflicting_plugin_license_fails(tmp_path: Path) -> None:
    release = tmp_path / "release"
    plugin = release / "plugin" / ".claude-plugin"
    policy_dir = release / ".claude-plugin"
    plugin.mkdir(parents=True)
    policy_dir.mkdir(parents=True)
    (release / "LICENSE").write_text("owned licence\n", encoding="utf-8")
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
                        "license": "Apache-2.0",
                    }
                ],
            }
        ),
        encoding="utf-8",
    )
    (plugin / "plugin.json").write_text(
        json.dumps({"license": "BUSL-1.1"}), encoding="utf-8"
    )

    errors = MODULE.validate(release)

    assert errors == [
        "marketplace plugin 'plugin' license 'Apache-2.0' != 'BUSL-1.1'"
    ]
