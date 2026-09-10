import importlib
import json
from pathlib import Path
import sys

import pytest


ROOT = Path(__file__).parents[2]
SCRIPTS = ROOT / "legion-observability" / "scripts"
sys.path.insert(0, str(SCRIPTS))
registry = importlib.import_module("legion_executor_registry")


def wrapper_policy(**overrides):
    policy = {
        "kind": "coding",
        "supported_sandboxes": ["read-only", "workspace-write"],
        "supported_sandbox_wrappers": ["docker", "podman", "vercel"],
        "sandbox_wrapper_provider_sandbox": "workspace-write",
    }
    policy.update(overrides)
    return policy


def test_json_schema_closes_the_complete_runtime_policy_surface():
    schema = json.loads(
        (
            ROOT
            / "legion-observability"
            / "schema"
            / "legion.executor-registry.v1.schema.json"
        ).read_text(encoding="utf-8")
    )
    executor = schema["$defs"]["executor"]

    assert schema["additionalProperties"] is False
    assert executor["additionalProperties"] is False
    assert set(executor["properties"]) == registry._EXECUTOR_FIELDS
    assert set(executor["properties"]["supported_sandbox_wrappers"]["items"]["enum"]) == {
        "docker",
        "podman",
        "vercel",
    }
    assert set(executor["properties"]["supported_sandboxes"]["items"]["enum"]) == {
        "read-only",
        "workspace-write",
        "danger-full-access",
    }
    assert executor["dependentRequired"] == {
        "supported_sandbox_wrappers": ["sandbox_wrapper_provider_sandbox"],
        "sandbox_wrapper_provider_sandbox": ["supported_sandbox_wrappers"],
    }


@pytest.mark.parametrize("fallback", [False, True])
def test_live_registry_declares_real_codex_wrapper_policy(
    monkeypatch: pytest.MonkeyPatch, fallback: bool
) -> None:
    if fallback:
        monkeypatch.setattr(registry, "tomllib", None)

    codex = registry.load_executor_registry()["codex"]

    assert codex["supported_sandbox_wrappers"] == ["docker", "podman", "vercel"]
    assert codex["sandbox_wrapper_provider_sandbox"] == "workspace-write"
    assert "workspace-write" in codex["supported_sandboxes"]
    assert not set(codex["supported_sandbox_wrappers"]) & set(codex["supported_sandboxes"])


@pytest.mark.parametrize("field", ["supported_sandbox", "billing_clas"])
def test_runtime_rejects_unknown_executor_policy_fields(field):
    with pytest.raises(registry.ExecutorRegistryError, match="unknown policy field"):
        registry.validate_executor_registry(
            {"fixture": {**wrapper_policy(), field: "misspelled"}}
        )


@pytest.mark.parametrize("fallback", [False, True])
def test_toml_loaders_both_reject_unknown_policy_fields(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, fallback: bool
) -> None:
    config = tmp_path / "executors.toml"
    config.write_text(
        '[executors.fixture]\nkind = "coding"\nbilling_clas = "free"\n',
        encoding="utf-8",
    )
    if fallback:
        monkeypatch.setattr(registry, "tomllib", None)

    with pytest.raises(registry.ExecutorRegistryError, match="billing_clas"):
        registry.load_executor_registry(config)


def test_wrapper_policy_requires_a_separate_admitted_provider_sandbox():
    assert registry.validate_executor_registry({"fixture": wrapper_policy()})

    for invalid in (
        wrapper_policy(sandbox_wrapper_provider_sandbox="danger-full-access"),
        wrapper_policy(supported_sandbox_wrappers=["docker", "workspace-write"]),
        wrapper_policy(supported_sandbox_wrappers=["unknown-wrapper"]),
        wrapper_policy(supported_sandbox_wrappers=["docker", "docker"]),
        wrapper_policy(
            supported_sandboxes=["docker"],
            supported_sandbox_wrappers=["podman"],
            sandbox_wrapper_provider_sandbox="docker",
        ),
    ):
        with pytest.raises(registry.ExecutorRegistryError):
            registry.validate_executor_registry({"fixture": invalid})

    missing_mapping = wrapper_policy()
    del missing_mapping["sandbox_wrapper_provider_sandbox"]
    with pytest.raises(registry.ExecutorRegistryError, match="declare.*together"):
        registry.validate_executor_registry({"fixture": missing_mapping})


@pytest.mark.parametrize(
    "policy",
    [
        {"supported_sandboxes": ["workspace-wirte"]},
        {"billing_class": "premium-credits"},
    ],
)
def test_policy_value_typos_fail_closed(policy):
    with pytest.raises(registry.ExecutorRegistryError):
        registry.validate_executor_registry({"fixture": policy})
