import importlib
import copy
import json
import os
from pathlib import Path
import stat
import sys
import time

import pytest


ROOT = Path(__file__).parents[2]
SCRIPTS = ROOT / "legion-observability" / "scripts"
SCHEMA_PATH = ROOT / "legion-observability" / "schema" / "legion.preflight.v1.schema.json"
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


@pytest.mark.parametrize("payload", ["[]", '"cached"', "null"])
def test_non_object_cache_entries_are_cache_misses(
    tmp_path: Path, payload: str
) -> None:
    cache = tmp_path / "cache.json"
    cache.write_text(payload, encoding="utf-8")

    assert preflight._read_cache(cache, "expected-key") is None


@pytest.mark.parametrize(
    "record",
    [
        {"cache_key": "expected-key", "version_raw": "fixture 1.2.3", "version": []},
        {"cache_key": "expected-key", "version_raw": {}, "version": "1.2.3"},
        {"cache_key": "expected-key", "version_raw": "fixture 1.2.3"},
        {
            "cache_key": "expected-key",
            "version_raw": "fixture 1.2.3",
            "version": "1.2.3",
            "unexpected": True,
        },
    ],
)
def test_noncanonical_matching_cache_records_are_cache_misses(
    tmp_path: Path, record: dict[str, object]
) -> None:
    cache = tmp_path / "cache.json"
    cache.write_text(json.dumps(record), encoding="utf-8")

    assert preflight._read_cache(cache, "expected-key") is None


@pytest.mark.parametrize("version_raw", [None, "fixture 1.2.3"])
@pytest.mark.parametrize("version", [None, "1.2.3"])
def test_canonical_cache_field_types_are_accepted(
    tmp_path: Path, version_raw, version
) -> None:
    cache = tmp_path / "cache.json"
    record = {
        "cache_key": "expected-key",
        "version_raw": version_raw,
        "version": version,
    }
    cache.write_text(json.dumps(record), encoding="utf-8")

    assert preflight._read_cache(cache, "expected-key") == record


def test_cache_fifo_is_a_nonblocking_miss(tmp_path: Path) -> None:
    cache = tmp_path / "cache.fifo"
    os.mkfifo(cache)

    started = time.monotonic()
    assert preflight._read_cache(cache, "expected-key") is None
    assert time.monotonic() - started < 1


def test_cache_symlink_and_oversized_file_are_misses(tmp_path: Path) -> None:
    target = tmp_path / "target.json"
    target.write_text('{"cache_key":"expected-key","version_raw":null,"version":null}')
    linked = tmp_path / "linked.json"
    linked.symlink_to(target)
    oversized = tmp_path / "oversized.json"
    oversized.write_bytes(b" " * (preflight.VERSION_CACHE_BYTES + 1))

    assert preflight._read_cache(linked, "expected-key") is None
    assert preflight._read_cache(oversized, "expected-key") is None


def test_supported_preflight_requires_complete_identity_and_compatibility(tmp_path: Path) -> None:
    incomplete = {
        "schema": "legion.preflight.v1",
        "checked_at": "2026-01-01T00:00:00Z",
        "executor": "fixture",
        "status": "supported",
        "reason": "claimed support",
        "identity": None,
        "cache": {"hit": False, "key": None},
        "compatibility": {},
    }

    with pytest.raises(ValueError):
        preflight.validate_preflight_receipt(
            incomplete, executor="fixture", model="fixture", sandbox="read-only"
        )


def supported_receipt(tmp_path: Path) -> dict:
    binary = executable(tmp_path / "fixture")
    config = registry(
        tmp_path / "executors.toml", binary,
        provider_sandboxes='["read-only", "workspace-write"]',
    )
    config.write_text(
        config.read_text(encoding="utf-8")
        + 'supported_read_modes = ["provider-tools"]\n'
        + 'supported_task_transports = ["stdin"]\n'
        + 'supported_efforts = ["high"]\n'
        + 'supported_model_patterns = ["^fixture-model$"]\n',
        encoding="utf-8",
    )
    result = preflight.preflight(
        "fixture", registry_path=config, cache_dir=tmp_path / "cache",
        env={"HOME": str(tmp_path / "home"), "PATH": os.environ["PATH"]},
        model="fixture-model", sandbox="read-only", read_mode="provider-tools",
        task_transport="stdin", effort="high", explicit_consent=False,
    )
    assert result["status"] == "supported"
    return result


@pytest.mark.parametrize("field", ["model", "sandbox", "read_mode", "task_transport", "effort"])
def test_supported_receipt_binds_full_requested_route(tmp_path: Path, field: str) -> None:
    receipt = supported_receipt(tmp_path)
    expected = {
        "executor": "fixture", "model": "fixture-model", "sandbox": "read-only",
        "read_mode": "provider-tools", "task_transport": "stdin", "effort": "high",
        "explicit_consent": False,
    }
    preflight.validate_preflight_receipt(receipt, **expected)
    expected[field] = "different-route"
    with pytest.raises(ValueError, match=f"{field} binding mismatch"):
        preflight.validate_preflight_receipt(receipt, **expected)


@pytest.mark.parametrize("probe_mutation", [
    {"probe_status": "completed", "probe_lease": None},
    {"probe_status": "completed", "probe_lease": {
        "schema": "legion.child-execution-lease.v1", "status": "cleanup_failed",
        "reason": "cleanup failed", "max_runtime_seconds": 5, "child_started": False,
    }},
    {"probe_status": "cached"},
    {"probe_status": "not_requested"},
    {"status": "unavailable"},
])
def test_supported_receipt_rejects_contradictory_version_probe(
    tmp_path: Path, probe_mutation: dict
) -> None:
    receipt = supported_receipt(tmp_path)
    receipt["compatibility"]["version"].update(probe_mutation)
    with pytest.raises(ValueError, match="version probe"):
        preflight.validate_preflight_receipt(receipt)


def test_supported_receipt_rejects_false_cache_hit_for_completed_probe(tmp_path: Path) -> None:
    receipt = supported_receipt(tmp_path)
    receipt["cache"]["hit"] = True
    with pytest.raises(ValueError, match="completed version probe"):
        preflight.validate_preflight_receipt(receipt)


def test_completed_probe_rejects_no_child_lease(tmp_path: Path) -> None:
    receipt = supported_receipt(tmp_path)
    receipt["compatibility"]["version"]["probe_lease"]["child_started"] = False
    with pytest.raises(ValueError, match="completed version probe"):
        preflight.validate_preflight_receipt(receipt)


def test_cached_supported_receipt_requires_and_keeps_cache_hit(tmp_path: Path) -> None:
    completed = supported_receipt(tmp_path)
    cached = copy.deepcopy(completed)
    cached["cache"]["hit"] = True
    cached["compatibility"]["version"].update({
        "probe_status": "cached", "probe_reason": "trusted version probe cache hit",
        "probe_lease": None,
    })
    preflight.validate_preflight_receipt(cached)
    cached["cache"]["hit"] = False
    with pytest.raises(ValueError, match="cached version probe"):
        preflight.validate_preflight_receipt(cached)


def test_supported_receipt_rejects_invalid_model_policy_identity(tmp_path: Path) -> None:
    receipt = supported_receipt(tmp_path)
    receipt["compatibility"]["model"]["policy_model"] = []
    with pytest.raises(ValueError, match="invalid model policy evidence"):
        preflight.validate_preflight_receipt(receipt)


def test_supported_receipt_binds_required_billing_consent(tmp_path: Path) -> None:
    receipt = supported_receipt(tmp_path)
    receipt["compatibility"]["billing"]["explicit_consent_required"] = True
    receipt["compatibility"]["billing"]["class"] = "premium_credit"
    with pytest.raises(ValueError, match="billing consent mismatch"):
        preflight.validate_preflight_receipt(receipt, explicit_consent=False)
    preflight.validate_preflight_receipt(receipt, explicit_consent=True)


def test_unavailable_receipt_rejects_all_supported_compatibility(tmp_path: Path) -> None:
    receipt = supported_receipt(tmp_path)
    receipt["status"] = "unavailable"
    receipt["identity"] = None
    receipt["cache"]["hit"] = False
    with pytest.raises(ValueError, match="unavailable preflight lacks matching"):
        preflight.validate_preflight_receipt(receipt)


def test_missing_binary_unavailable_receipt_requires_exact_no_identity_shape() -> None:
    receipt = {
        "schema": "legion.preflight.v1", "checked_at": "now", "executor": "fixture",
        "status": "unavailable", "reason": "executor binary not found: fixture",
        "identity": None, "cache": {"hit": False, "key": None}, "compatibility": {},
    }
    preflight.validate_preflight_receipt(receipt, executor="fixture", model="fixture")
    forged = copy.deepcopy(receipt)
    forged["reason"] = "arbitrary unavailable"
    with pytest.raises(ValueError, match="exact no-executable evidence"):
        preflight.validate_preflight_receipt(forged)


def test_early_no_spend_version_failure_need_not_invent_later_route_checks() -> None:
    receipt = {
        "schema": "legion.preflight.v1", "checked_at": "2026-09-12T00:00:00Z",
        "executor": "claude", "status": "unavailable",
        "reason": "version probe deadline expired", "identity": None,
        "cache": {"hit": False, "key": None},
        "compatibility": {"version": {
            "discovered": None, "status": "unavailable", "probe_status": "timed_out",
            "probe_reason": "inherited child lease deadline expired during launch setup",
            "probe_lease": {
                "schema": "legion.child-execution-lease.v1", "status": "launch_failed",
                "reason": "inherited child lease deadline expired during launch setup",
                "max_runtime_seconds": 30,
            },
        }},
    }
    preflight.validate_preflight_receipt(
        receipt, executor="claude", model="model-b", sandbox="workspace-write",
        read_mode="provider-tools", task_transport="stdin", effort=None,
        explicit_consent=False,
    )
    receipt["status"] = "supported"
    with pytest.raises(ValueError, match="compatibility is incomplete"):
        preflight.validate_preflight_receipt(receipt, executor="claude")


def test_preflight_schema_defines_complete_compatibility_surface() -> None:
    schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
    compatibility = schema["properties"]["compatibility"]
    assert compatibility["additionalProperties"] is False
    assert set(compatibility["properties"]) == {
        "sandbox", "read_mode", "task_transport", "effort", "model",
        "configuration", "billing", "version",
    }


def test_draft202012_preflight_schema_rejects_unknown_and_invalid_checks(tmp_path: Path) -> None:
    jsonschema = pytest.importorskip("jsonschema")
    schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
    validator = jsonschema.Draft202012Validator(schema)
    validator.check_schema(schema)
    receipt = supported_receipt(tmp_path)
    validator.validate(receipt)

    mutations = [
        lambda value: value["compatibility"].update({"foreign": {"status": "supported"}}),
        lambda value: value["compatibility"].pop("read_mode"),
        lambda value: value["compatibility"]["read_mode"].update({"requested": []}),
        lambda value: value["compatibility"]["read_mode"].update({"status": "not_requested"}),
        lambda value: value["compatibility"]["task_transport"].update({"extra": True}),
        lambda value: value["compatibility"]["effort"].update({"status": "fabricated"}),
        lambda value: value["compatibility"]["model"].update({"policy_model": []}),
        lambda value: value["compatibility"]["billing"].update({"explicit_consent_required": 1}),
        lambda value: value["compatibility"]["configuration"].update({"missing": [""]}),
        lambda value: value["compatibility"]["sandbox"].update({"wrapper": []}),
    ]
    for mutate in mutations:
        contradictory = copy.deepcopy(receipt)
        mutate(contradictory)
        assert list(validator.iter_errors(contradictory))


def test_preflight_receipt_file_rejects_symlink(tmp_path: Path) -> None:
    target = tmp_path / "receipt.json"
    target.write_text("{}", encoding="utf-8")
    linked = tmp_path / "receipt-link.json"
    linked.symlink_to(target)

    with pytest.raises(OSError):
        preflight.validate_preflight_receipt_file(linked)


@pytest.mark.parametrize("lease_kind", ["symlink", "fifo", "oversized"])
def test_supervised_version_probe_rejects_unsafe_lease_leaf_without_blocking(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, lease_kind: str
) -> None:
    target = tmp_path / "untrusted-target.json"
    target.write_text('{"status":"completed"}', encoding="utf-8")

    class FinishedSupervisor:
        returncode = 0

        def __init__(self, command, **_kwargs):
            lease_path = Path(command[command.index("--status-file") + 1])
            if lease_kind == "symlink":
                lease_path.symlink_to(target)
            elif lease_kind == "fifo":
                os.mkfifo(lease_path)
            else:
                lease_path.write_bytes(b" " * 65537)
            read_fd, write_fd = os.pipe()
            os.close(write_fd)
            self.stdout = os.fdopen(read_fd, "rb", buffering=0)

        def poll(self):
            return self.returncode

        def wait(self):
            return self.returncode

    monkeypatch.setattr(preflight.subprocess, "Popen", FinishedSupervisor)
    started = time.monotonic()
    version, probe = preflight._supervised_version_output(
        "/usr/bin/true", ["--version"], {"PATH": os.environ["PATH"]},
        preflight._sha256_file("/usr/bin/true"),
    )
    assert time.monotonic() - started < 1
    assert version is None
    assert probe["status"] == "invalid"
    assert probe["lease"] is None
    assert target.read_text(encoding="utf-8") == '{"status":"completed"}'


def test_malformed_matching_cache_reprobes_without_crashing(tmp_path: Path) -> None:
    binary = executable(tmp_path / "fixture")
    config = registry(
        tmp_path / "executors.toml",
        binary,
        provider_sandboxes='["read-only", "workspace-write"]',
    )
    cache_dir = tmp_path / "cache"
    environment = {"HOME": str(tmp_path / "home"), "PATH": os.environ["PATH"]}
    first = preflight.preflight(
        "fixture", registry_path=config, cache_dir=cache_dir, env=environment
    )
    cache_file = next(cache_dir.glob("*.json"))
    malformed = json.loads(cache_file.read_text(encoding="utf-8"))
    malformed["version"] = []
    cache_file.write_text(json.dumps(malformed), encoding="utf-8")

    second = preflight.preflight(
        "fixture", registry_path=config, cache_dir=cache_dir, env=environment
    )

    assert first["status"] == second["status"] == "supported"
    assert second["cache"]["hit"] is False
    assert second["identity"]["version"] == "1.2.3"


def test_version_probe_refuses_binary_replaced_after_admission(tmp_path: Path) -> None:
    binary = executable(tmp_path / "fixture")
    admitted_digest = preflight._sha256_file(binary)
    marker = tmp_path / "unadmitted-ran"
    replacement = tmp_path / "replacement"
    replacement.write_text(
        f"#!/bin/sh\nprintf replaced > {marker}\nprintf 'fixture-provider 1.2.3\\n'\n",
        encoding="utf-8",
    )
    replacement.chmod(0o700)
    os.replace(replacement, binary)

    raw, probe = preflight._supervised_version_output(
        str(binary), ["--version"], {"PATH": os.environ["PATH"]}, admitted_digest,
    )

    assert raw is None
    assert probe["status"] == "launch_failed"
    assert not marker.exists()


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
