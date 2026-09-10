#!/usr/bin/env python3
"""Fail when Legion Core release surfaces disagree with the owned licence policy."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path


POLICY_PATH = Path(".claude-plugin/license-policy.json")


def load_json(path: Path) -> dict:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return value


def checked_file(root: Path, relative: Path) -> Path:
    if relative.is_absolute() or ".." in relative.parts:
        raise ValueError(f"path escapes release root: {relative}")
    candidate = root / relative
    current = root
    for part in relative.parts:
        if current.is_symlink():
            raise ValueError(f"release metadata path contains a symlink: {current}")
        current /= part
    if candidate.is_symlink() or not candidate.is_file():
        raise ValueError(f"expected regular release metadata file: {candidate}")
    return candidate


def validate(root: Path) -> list[str]:
    root = root.resolve(strict=True)
    policy = load_json(checked_file(root, POLICY_PATH))
    if policy.get("schema") != "legion.license-policy.v1":
        raise ValueError("license policy must use schema legion.license-policy.v1")
    spdx = policy.get("spdx")
    if not isinstance(spdx, str) or not spdx:
        raise ValueError("license policy must declare a non-empty SPDX identifier")
    declared_digest = policy.get("license_sha256")
    if not isinstance(declared_digest, str) or len(declared_digest) != 64:
        raise ValueError("license policy must declare a SHA-256 digest")

    license_path = checked_file(root, Path(policy.get("license_file", "")))
    actual_digest = hashlib.sha256(license_path.read_bytes()).hexdigest()
    errors: list[str] = []
    if actual_digest != declared_digest:
        errors.append(
            f"{license_path.relative_to(root)} digest {actual_digest} != policy {declared_digest}"
        )

    package = load_json(checked_file(root, Path("package.json")))
    if package.get("license") != spdx:
        errors.append(f"package.json license {package.get('license')!r} != {spdx!r}")

    marketplace = load_json(checked_file(root, Path(".claude-plugin/marketplace.json")))
    if marketplace.get("license") != spdx:
        errors.append(
            f"marketplace license {marketplace.get('license')!r} != {spdx!r}"
        )
    plugins = marketplace.get("plugins")
    if not isinstance(plugins, list):
        raise ValueError("marketplace plugins must be an array")
    for plugin in plugins:
        if not isinstance(plugin, dict):
            errors.append("marketplace contains a non-object plugin entry")
            continue
        name = plugin.get("name", "<unnamed>")
        if plugin.get("license") != spdx:
            errors.append(
                f"marketplace plugin {name!r} license {plugin.get('license')!r} != {spdx!r}"
            )
        source = plugin.get("source")
        if not isinstance(source, str):
            errors.append(f"marketplace plugin {name!r} does not have a local source")
            continue
        manifest_path = Path(source) / ".claude-plugin/plugin.json"
        manifest = load_json(checked_file(root, manifest_path))
        if manifest.get("license") != spdx:
            errors.append(
                f"{manifest_path} license {manifest.get('license')!r} != {spdx!r}"
            )
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path.cwd())
    args = parser.parse_args()
    try:
        errors = validate(args.root)
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as error:
        print(f"license metadata check failed: {error}", file=sys.stderr)
        return 1
    if errors:
        for error in errors:
            print(f"license metadata check failed: {error}", file=sys.stderr)
        return 1
    print("license metadata matches .claude-plugin/license-policy.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
