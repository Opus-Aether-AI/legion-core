import importlib
import json
import os
from pathlib import Path
import stat
import sys

import pytest


ROOT = Path(__file__).parents[2]
SCRIPTS = ROOT / "legion-observability" / "scripts"
sys.path.insert(0, str(SCRIPTS))
preflight = importlib.import_module("legion_preflight")
receipts = importlib.import_module("legion_receipts")
registry = importlib.import_module("legion_executor_registry")
FIXTURES = ROOT / "tests" / "fixtures" / "executor-contract"


def test_preflight_is_exposed_by_plugin_and_npm_install_discovery():
    entrypoint = ROOT / "legion-router" / "bin" / "legion-preflight"
    package = json.loads((ROOT / "package.json").read_text(encoding="utf-8"))
    assert entrypoint.is_file() and os.access(entrypoint, os.X_OK)
    assert package["bin"]["legion-preflight"] == "legion-router/bin/legion-preflight"


def test_contract_schemas_are_public_strict_versioned_documents():
    schema_dir = ROOT / "legion-observability" / "schema"
    for name in (
        "legion.preflight.v1",
        "legion.failure.v1",
        "legion.attempt.v1",
        "legion.child-execution-lease.v1",
    ):
        schema = json.loads((schema_dir / f"{name}.schema.json").read_text(encoding="utf-8"))
        assert schema["$schema"] == "https://json-schema.org/draft/2020-12/schema"
        assert schema["title"] == name
        assert schema["additionalProperties"] is False

    registry_schema = json.loads(
        (schema_dir / "legion.executor-registry.v1.schema.json").read_text(encoding="utf-8")
    )
    assert registry_schema["title"] == "legion.executor-registry.v1"
    assert "executors" in registry_schema["required"]
    assert {"cancellation", "max_runtime_seconds"} <= set(
        registry_schema["$defs"]["executor"]["required"]
    )


def executable(path, version="1.2.3"):
    path.write_text(
        "#!/usr/bin/env bash\n"
        "if [[ ${1:-} == --version ]]; then\n"
        f"  echo 'fixture-provider {version}'\n"
        "  exit 0\n"
        "fi\n"
        "printf 'provider-call\\n' >> \"${PROVIDER_CALL_LOG:?}\"\n",
        encoding="utf-8",
    )
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def write_registry(path, binary, *, supported='["^1\\\\.2\\\\.3$"]', known_bad="[]", extra=""):
    path.write_text(
        'schema = "legion.executor-registry.v1"\n[executors.fixture]\n'
        'kind = "coding"\ncontract = "diff"\nadapter = "x"\nmodel_ref = "x"\n'
        f'binary = "{binary}"\nversion_args = ["--version"]\n'
        'version_regex = "fixture-provider (?P<version>[0-9]+\\\\.[0-9]+\\\\.[0-9]+)"\n'
        f'supported_version_patterns = {supported}\nknown_bad_version_patterns = {known_bad}\n'
        'version_policy = "open"\nconfig_fingerprint_env = ["FIXTURE_CONFIG"]\n'
        'supported_sandboxes = ["read-only"]\nsupported_model_patterns = ["^fixture-"]\n'
        'supported_efforts = ["low", "high"]\n'
        + extra,
        encoding="utf-8",
    )


def run_preflight(tmp_path, version="1.2.3", **request):
    binary = tmp_path / "fixture-provider"
    executable(binary, version)
    config = tmp_path / "executors.toml"
    write_registry(config, binary)
    env = {"PATH": os.environ["PATH"], "HOME": str(tmp_path), "PROVIDER_CALL_LOG": str(tmp_path / "calls")}
    result = preflight.preflight("fixture", registry_path=config, cache_dir=tmp_path / "cache", env=env, **request)
    return result, binary, config, env


def test_registry_rejects_declared_field_with_wrong_type(tmp_path):
    path = tmp_path / "bad.toml"
    path.write_text('[executors.bad]\nkind="coding"\nsupported_sandboxes="read-only"\n', encoding="utf-8")
    with pytest.raises(registry.ExecutorRegistryError, match="supported_sandboxes"):
        registry.load_executor_registry(path)


def test_registry_rejects_invalid_regex_and_nonpositive_runtime(tmp_path):
    path = tmp_path / "bad.toml"
    path.write_text('[executors.bad]\nkind="coding"\nsupported_model_patterns=["["]\nmax_runtime_seconds=0\n', encoding="utf-8")
    with pytest.raises(registry.ExecutorRegistryError, match="invalid regex"):
        registry.load_executor_registry(path)


def test_live_registry_declares_contract_foundation_without_inventing_transport():
    executors = registry.load_executor_registry()
    required = {
        "binary", "version_args", "version_policy", "supported_version_patterns",
        "known_bad_version_patterns", "config_fingerprint_env", "supported_config_env", "supported_sandboxes",
        "supported_read_modes", "supported_task_transports", "billing_class",
        "usage_reliability", "usage_source", "cost_reliability", "cost_source",
        "cancellation", "max_runtime_seconds",
    }
    assert all(required <= set(config) for config in executors.values())
    assert all(config["max_runtime_seconds"] > 0 for config in executors.values())
    assert all(config["cancellation"] == "process_tree" for config in executors.values())
    assert executors["deepseek"]["task_file"] is False
    assert executors["deepseek"]["supported_task_transports"] == ["argv"]
    assert executors["deepseek"]["supported_sandboxes"] == ["workspace-write"]
    assert executors["deepseek"]["usage_reliability"] == "unavailable"
    assert executors["deepseek"]["cost_reliability"] == "unavailable"
    assert executors["deepseek"]["supported_model_patterns"] == []
    assert "supported_model_patterns" not in executors["claude"]
    assert "supported_model_patterns" not in executors["codex"]
    for name in ("cursor", "hermes", "pi"):
        assert executors[name]["task_file"] is False
        assert executors[name]["supported_task_transports"] == ["argv"]
    for name in ("claude", "codex", "opencode"):
        assert executors[name]["task_file"] is True
        assert executors[name]["supported_task_transports"] == ["stdin"]


def test_preflight_classifies_supported_untested_incompatible_and_unavailable(tmp_path):
    supported, binary, config, env = run_preflight(tmp_path, sandbox="read-only", model="fixture-ok")
    assert supported["status"] == "supported"

    executable(binary, "2.0.0")
    untested = preflight.preflight("fixture", registry_path=config, cache_dir=tmp_path / "cache", env=env)
    assert untested["status"] == "untested"

    incompatible = preflight.preflight(
        "fixture", registry_path=config, cache_dir=tmp_path / "cache", env=env, sandbox="workspace-write"
    )
    assert incompatible["status"] == "incompatible"

    binary.unlink()
    unavailable = preflight.preflight("fixture", registry_path=config, cache_dir=tmp_path / "cache", env=env)
    assert unavailable["status"] == "unavailable"


def test_preflight_cache_invalidates_for_binary_and_configuration(tmp_path):
    first, binary, config, env = run_preflight(tmp_path)
    assert first["cache"]["hit"] is False
    second = preflight.preflight("fixture", registry_path=config, cache_dir=tmp_path / "cache", env=env)
    assert second["cache"]["hit"] is True
    assert second["cache"]["key"] == first["cache"]["key"]

    executable(binary, "1.2.4")
    binary_changed = preflight.preflight("fixture", registry_path=config, cache_dir=tmp_path / "cache", env=env)
    assert binary_changed["cache"]["hit"] is False
    assert binary_changed["cache"]["key"] != first["cache"]["key"]

    env["FIXTURE_CONFIG"] = "new"
    config_changed = preflight.preflight("fixture", registry_path=config, cache_dir=tmp_path / "cache", env=env)
    assert config_changed["cache"]["hit"] is False
    assert config_changed["cache"]["key"] != binary_changed["cache"]["key"]


def test_preflight_cache_invalidates_for_declared_config_file(tmp_path):
    binary = tmp_path / "fixture-provider"
    executable(binary)
    relevant = tmp_path / "provider.conf"
    relevant.write_text("mode=one\n", encoding="utf-8")
    config = tmp_path / "executors.toml"
    write_registry(config, binary, extra=f'config_fingerprint_files = ["{relevant}"]\n')
    env = {"PATH": os.environ["PATH"], "HOME": str(tmp_path), "PROVIDER_CALL_LOG": str(tmp_path / "calls")}
    first = preflight.preflight("fixture", registry_path=config, cache_dir=tmp_path / "cache", env=env)
    relevant.write_text("mode=two\n", encoding="utf-8")
    second = preflight.preflight("fixture", registry_path=config, cache_dir=tmp_path / "cache", env=env)
    assert second["cache"]["hit"] is False
    assert second["cache"]["key"] != first["cache"]["key"]


def test_preflight_binary_override_identifies_the_exact_adapter_binary(tmp_path):
    binary = tmp_path / "custom-provider"
    executable(binary)
    config = tmp_path / "executors.toml"
    write_registry(config, tmp_path / "missing-provider")
    env = {"PATH": os.environ["PATH"], "HOME": str(tmp_path),
           "PROVIDER_CALL_LOG": str(tmp_path / "calls")}
    result = preflight.preflight(
        "fixture", registry_path=config, cache_dir=tmp_path / "cache", env=env,
        binary_override=str(binary), model="fixture-ok",
    )
    assert result["status"] == "supported"
    assert result["identity"]["executable_path"] == str(binary.resolve())
    assert not Path(env["PROVIDER_CALL_LOG"]).exists()


def test_known_bad_version_is_incompatible(tmp_path):
    binary = tmp_path / "fixture-provider"
    executable(binary, "0.9.0")
    config = tmp_path / "executors.toml"
    write_registry(config, binary, known_bad='["^0\\\\."]')
    env = {"PATH": os.environ["PATH"], "HOME": str(tmp_path), "PROVIDER_CALL_LOG": str(tmp_path / "calls")}
    result = preflight.preflight("fixture", registry_path=config, cache_dir=tmp_path / "cache", env=env)
    assert result["status"] == "incompatible"
    assert "known-bad executor version" in result["reason"]


def test_preflight_never_makes_a_provider_call(tmp_path):
    result, _binary, _config, env = run_preflight(tmp_path, model="fixture-ok", effort="high")
    assert result["status"] == "supported"
    assert not Path(env["PROVIDER_CALL_LOG"]).exists()


def test_unknown_cost_and_usage_are_nullable_not_zero_and_lineage_is_retained():
    known = json.loads((FIXTURES / "known-attempt.json").read_text(encoding="utf-8"))
    unknown = json.loads((FIXTURES / "unknown-attempt.json").read_text(encoding="utf-8"))
    receipts.validate_attempt(known)
    receipts.validate_attempt(unknown)
    aggregate = receipts.reconcile_attempts([known, unknown])
    assert aggregate["cost_status"] == "partial"
    assert aggregate["cost_usd"] is None
    assert aggregate["known_cost_usd"] == 0.25
    assert aggregate["usage_status"] == "partial"
    assert aggregate["usage"] is None
    assert aggregate["known_usage"] == {"input_tokens": 10, "output_tokens": 3}
    assert unknown["cache_lineage"]["previous_attempt_id"] == known["attempt_id"]


def test_parent_attempt_reconciles_exactly_from_children():
    children = [json.loads((FIXTURES / name).read_text(encoding="utf-8"))
                for name in ("known-attempt.json", "unknown-attempt.json")]
    parent = receipts.aggregate_attempt_receipt(
        child_attempts=children, run_id="run-1", ordinal=1, executor="router",
        attempt_id="parent-1",
        provider="aggregate", config_identity="config-sha256", requested_model=None,
        effective_model=None, requested_effort=None, effective_effort=None,
        sandbox="workspace-write", terminal_status="succeeded",
        started_at="2026-09-10T00:00:00Z", ended_at="2026-09-10T00:00:02Z",
        duration_ms=2000, parent_attempt_id=None,
    )
    assert parent["attempt_kind"] == "aggregate"
    assert parent["child_attempt_ids"] == ["attempt-1", "attempt-2"]
    assert parent["cost_usd"] is None
    assert parent["reconciliation"]["known_cost_usd"] == 0.25
    assert parent["reconciliation"]["attempt_count"] == 2
    receipts.validate_attempt(parent)
    receipts.validate_aggregate_reconciliation(parent, children)

    nested = receipts.reconcile_attempts([parent])
    assert nested["cost_status"] == "partial"
    assert nested["cost_usd"] is None
    assert nested["known_cost_usd"] == 0.25
    assert nested["known_cost_attempts"] == 1
    assert nested["attempt_count"] == 2

    parent["reconciliation"]["known_cost_usd"] = 0
    with pytest.raises(ValueError, match="does not reconcile"):
        receipts.validate_aggregate_reconciliation(parent, children)


def test_receipt_helpers_reject_schema_and_provenance_mismatches():
    invalid = json.loads((FIXTURES / "invalid-attempt.json").read_text(encoding="utf-8"))
    with pytest.raises(ValueError, match="missing or unknown"):
        receipts.validate_attempt(invalid)
    with pytest.raises(ValueError, match="must be null"):
        receipts.attempt_receipt(
            run_id="run", ordinal=1, executor="x", provider="x", config_identity="sha",
            requested_model=None, effective_model=None, requested_effort=None,
            effective_effort=None, sandbox="read-only", terminal_status="succeeded",
            started_at="a", ended_at="b", duration_ms=1, cost_usd=0,
            cost_status="unknown", cost_source=None,
        )


def test_failure_receipt_binds_attempt_output_and_retry_classification():
    failure = receipts.failure_receipt(
        run_id="run", attempt_id="attempt", failure_class="quota", provider_code="429",
        retryable=True, output_started=False, message="quota exhausted",
    )
    attempt = receipts.attempt_receipt(
        run_id="run", attempt_id="attempt", ordinal=2, executor="x", provider="p",
        config_identity="sha", requested_model="m", effective_model="m",
        requested_effort="high", effective_effort="high", sandbox="read-only",
        terminal_status="failed", started_at="a", ended_at="b", duration_ms=1,
        failure=failure, output_started=False,
    )
    assert attempt["failure"]["class"] == "quota"
    assert attempt["failure"]["retryable"] is True
