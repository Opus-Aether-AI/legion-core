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


def registry_with_missing_configuration(
    path: Path, binary: Path, *, extra: str = ""
) -> Path:
    registry(path, binary, provider_sandboxes='["read-only", "workspace-write"]')
    text = path.read_text(encoding="utf-8").replace(
        "required_config_env = []\n",
        'required_config_env = ["REQUIRED_TOKEN"]\n',
    )
    if extra.startswith("supported_config_env = "):
        text = text.replace("supported_config_env = []\n", extra)
        extra = ""
    path.write_text(text + extra, encoding="utf-8")
    return path


@pytest.mark.parametrize(
    ("policy", "extra", "requested", "environment", "check"),
    [
        (
            "sandbox",
            "",
            {"sandbox": "danger-full-access"},
            {},
            "sandbox",
        ),
        (
            "effort",
            'supported_efforts = ["low"]\n',
            {"effort": "high"},
            {},
            "effort",
        ),
        (
            "model",
            'supported_model_patterns = ["^fixture-ok$"]\n',
            {"model": "fixture-unsupported"},
            {},
            "model",
        ),
        (
            "billing",
            "requires_explicit_consent = true\n",
            {"model": "fixture-ok", "explicit_consent": False},
            {},
            "billing",
        ),
        (
            "configuration",
            'supported_config_env = ["MODE=^safe$"]\n',
            {},
            {"MODE": "unsafe"},
            "configuration",
        ),
    ],
)
def test_incompatibility_dominates_missing_required_configuration(
    tmp_path: Path,
    policy: str,
    extra: str,
    requested: dict[str, object],
    environment: dict[str, str],
    check: str,
) -> None:
    binary = executable(tmp_path / "fixture")
    config = registry_with_missing_configuration(
        tmp_path / "executors.toml", binary, extra=extra
    )
    env = {
        "HOME": str(tmp_path / "home"),
        "PATH": os.environ["PATH"],
        **environment,
    }

    result = preflight.preflight(
        "fixture",
        registry_path=config,
        cache_dir=tmp_path / "cache",
        env=env,
        **requested,
    )

    assert result["status"] == "incompatible", policy
    assert result["compatibility"][check]["status"] == "incompatible"
    assert "missing required configuration: REQUIRED_TOKEN" in result["reason"]
    assert result["identity"] is None


def test_missing_required_configuration_alone_remains_unavailable(tmp_path: Path) -> None:
    binary = executable(tmp_path / "fixture")
    config = registry_with_missing_configuration(tmp_path / "executors.toml", binary)

    result = preflight.preflight(
        "fixture",
        registry_path=config,
        cache_dir=tmp_path / "cache",
        env={"HOME": str(tmp_path / "home"), "PATH": os.environ["PATH"]},
        sandbox="read-only",
    )

    assert result["status"] == "unavailable"
    assert result["compatibility"]["configuration"]["status"] == "unavailable"


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

    assert result["status"] == "supported"
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

    assert result["status"] == "unavailable"
    assert result["compatibility"] == {}
    assert "is not admitted by supported_sandboxes" in result["reason"]


@pytest.mark.parametrize("field", ["supported_sandbox", "billing_clas"])
def test_misspelled_policy_cannot_downgrade_preflight_to_untested(
    tmp_path: Path, field: str
) -> None:
    binary = executable(tmp_path / "fixture")
    config = registry(
        tmp_path / "executors.toml",
        binary,
        provider_sandboxes='["read-only", "workspace-write"]',
    )
    with config.open("a", encoding="utf-8") as handle:
        handle.write(f'{field} = "misspelled"\n')

    result = preflight.preflight(
        "fixture",
        registry_path=config,
        cache_dir=tmp_path / "cache",
        env={"HOME": str(tmp_path / "home"), "PATH": os.environ["PATH"]},
        sandbox="workspace-write",
    )

    assert result["status"] == "unavailable"
    assert result["compatibility"] == {}
    assert "unknown policy field" in result["reason"]
    assert field in result["reason"]


def test_untested_model_and_version_are_not_admitted(tmp_path: Path) -> None:
    binary = executable(tmp_path / "fixture", version="9.9.9")
    config = registry(
        tmp_path / "executors.toml",
        binary,
        provider_sandboxes='["read-only", "workspace-write"]',
    )
    config.write_text(
        config.read_text(encoding="utf-8").replace(
            'version_policy = "closed"\n', 'version_policy = "open"\n'
        ) + 'supported_model_patterns = ["^fixture-"]\n',
        encoding="utf-8",
    )
    result = preflight.preflight(
        "fixture",
        registry_path=config,
        cache_dir=tmp_path / "cache",
        env={"HOME": str(tmp_path / "home"), "PATH": os.environ["PATH"]},
        model="fixture-model",
    )

    assert result["status"] == "untested"
    assert result["compatibility"]["model"]["status"] == "supported"
    assert result["compatibility"]["version"]["status"] == "untested"

    binary = executable(tmp_path / "fixture", version="1.2.3")
    config.write_text(
        config.read_text(encoding="utf-8").replace(
            'supported_model_patterns = ["^fixture-"]\n', ""
        ),
        encoding="utf-8",
    )
    result = preflight.preflight(
        "fixture",
        registry_path=config,
        cache_dir=tmp_path / "model-cache",
        env={"HOME": str(tmp_path / "home"), "PATH": os.environ["PATH"]},
        model="unconfigured-alias",
    )
    assert result["status"] == "untested"
    assert result["compatibility"]["model"]["status"] == "untested"
    assert result["compatibility"]["version"]["status"] == "supported"


def test_claude_catalog_aliases_are_supported_and_premium_aliases_require_consent(
    tmp_path: Path,
) -> None:
    binary = executable(tmp_path / "claude")
    environment = {"HOME": str(tmp_path / "home"), "PATH": os.environ["PATH"]}
    models = preflight.load_model_catalog()

    ordinary = preflight.preflight(
        "claude",
        binary_override=str(binary),
        cache_dir=tmp_path / "ordinary-cache",
        env=environment,
        model="claude_default",
    )
    assert ordinary["status"] == "supported"
    assert ordinary["compatibility"]["model"]["policy_model"] == models["claude_default"]

    refused = preflight.preflight(
        "claude",
        binary_override=str(binary),
        cache_dir=tmp_path / "refused-cache",
        env=environment,
        model="claude_frontier",
    )
    assert refused["status"] == "incompatible"
    assert refused["identity"] is None
    assert refused["compatibility"]["billing"] == {
        "class": "premium_credit",
        "explicit_consent_required": True,
        "status": "incompatible",
    }

    admitted = preflight.preflight(
        "claude",
        binary_override=str(binary),
        cache_dir=tmp_path / "admitted-cache",
        env=environment,
        model="claude_frontier",
        explicit_consent=True,
    )
    assert admitted["status"] == "supported"
    assert admitted["compatibility"]["model"]["policy_model"] == models["claude_frontier"]
