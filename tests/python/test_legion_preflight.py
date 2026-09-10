import importlib
import os
from pathlib import Path
import stat
import sys

import pytest


ROOT = Path(__file__).parents[2]
SCRIPTS = ROOT / "legion-observability" / "scripts"
sys.path.insert(0, str(SCRIPTS))
preflight = importlib.import_module("legion_preflight")


def executable(path: Path, version: str = "1.2.3") -> Path:
    path.write_text(
        "#!/usr/bin/env bash\n"
        f"printf 'fixture-provider {version}\\n'\n",
        encoding="utf-8",
    )
    path.chmod(path.stat().st_mode | stat.S_IXUSR)
    return path


def registry(path: Path, binary: Path, *, provider_sandboxes: str) -> Path:
    path.write_text(
        '[executors.fixture]\nkind = "coding"\ncontract = "diff"\n'
        'adapter = "fixture"\nmodel_ref = "fixture"\n'
        f'binary = "{binary}"\nversion_args = ["--version"]\n'
        'version_regex = "fixture-provider (?P<version>[0-9]+\\\\.[0-9]+\\\\.[0-9]+)"\n'
        'version_policy = "closed"\nsupported_version_patterns = ["^1\\\\.2\\\\.3$"]\n'
        'known_bad_version_patterns = []\nconfig_fingerprint_env = []\n'
        'config_fingerprint_files = []\nrequired_config_env = []\n'
        'supported_config_env = []\nknown_bad_config_env = []\n'
        f'supported_sandboxes = {provider_sandboxes}\n'
        'supported_sandbox_wrappers = ["docker", "podman", "vercel"]\n'
        'sandbox_wrapper_provider_sandbox = "workspace-write"\n'
        'cancellation = "process_tree"\nmax_runtime_seconds = 60\n',
        encoding="utf-8",
    )
    return path


def test_preflight_succeeds_when_read_only_home_prevents_cache_write(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    binary = executable(tmp_path / "fixture")
    config = registry(
        tmp_path / "executors.toml",
        binary,
        provider_sandboxes='["read-only", "workspace-write"]',
    )
    home = tmp_path / "read-only-home"
    cache_dir = home / ".cache" / "legion" / "preflight"
    cache_dir.mkdir(parents=True)
    real_mkstemp = preflight.tempfile.mkstemp

    def deny_cache_file(*args, **kwargs):
        if kwargs.get("dir") == str(cache_dir):
            raise PermissionError("read-only HOME")
        return real_mkstemp(*args, **kwargs)

    monkeypatch.setattr(preflight.tempfile, "mkstemp", deny_cache_file)
    result = preflight.preflight(
        "fixture",
        registry_path=config,
        env={"HOME": str(home), "PATH": os.environ["PATH"]},
        sandbox="workspace-write",
    )

    assert result["status"] == "supported"
    assert result["identity"]["version"] == "1.2.3"
    assert result["cache"]["hit"] is False
    assert result["cache"]["key"]
    assert not list(cache_dir.glob("*.json"))


@pytest.mark.parametrize("wrapper", ["docker", "podman", "vercel"])
def test_live_codex_registry_normalizes_sandcastle_wrapper_to_provider_sandbox(
    tmp_path: Path, wrapper: str
) -> None:
    binary = executable(tmp_path / "codex")
    result = preflight.preflight(
        "codex",
        binary_override=str(binary),
        cache_dir=tmp_path / "cache",
        env={"HOME": str(tmp_path / "home"), "PATH": os.environ["PATH"]},
        sandbox=wrapper,
    )

    assert result["status"] == "untested"
    assert result["compatibility"]["sandbox"] == {
        "requested": wrapper,
        "provider_sandbox": "workspace-write",
        "wrapper": wrapper,
        "status": "supported",
    }


def test_sandcastle_wrapper_cannot_bypass_provider_sandbox_admission(tmp_path: Path) -> None:
    binary = executable(tmp_path / "fixture")
    config = registry(
        tmp_path / "executors.toml",
        binary,
        provider_sandboxes='["read-only"]',
    )
    result = preflight.preflight(
        "fixture",
        registry_path=config,
        cache_dir=tmp_path / "cache",
        env={"HOME": str(tmp_path / "home"), "PATH": os.environ["PATH"]},
        sandbox="docker",
    )

    assert result["status"] == "incompatible"
    assert result["compatibility"]["sandbox"] == {
        "requested": "docker",
        "provider_sandbox": "workspace-write",
        "wrapper": "docker",
        "status": "incompatible",
    }
    assert "requires unsupported provider sandbox 'workspace-write'" in result["reason"]
