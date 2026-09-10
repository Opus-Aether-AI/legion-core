#!/usr/bin/env python3
"""Shared executor capability and family lookup for Legion consumers.

The executor registry is deliberately the one authority for harness identity.
Router, adapters, and telemetry all need to answer the same two questions:
which family owns a variant label, and which capabilities that family exposes.
"""

from __future__ import annotations

import os
import re

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover - py<3.11
    try:
        import tomli as tomllib
    except ModuleNotFoundError:  # pragma: no cover - optional py<3.11 dependency
        tomllib = None


# Keep this intentionally conservative legacy fallback.  It is used only when
# the registry cannot be read or has an invalid shape; a valid primary-only
# registry must still mean that no coding executors are available.
_FALLBACK_CODING_FAMILIES = frozenset({"claude", "codex", "cursor", "opencode"})
DEFAULT_EXECUTORS_FILE = os.path.abspath(
    os.path.join(
        os.path.dirname(__file__), "..", "..", "legion-router", "config", "executors.toml"
    )
)
DEFAULT_MODELS_FILE = os.path.abspath(
    os.path.join(
        os.path.dirname(__file__), "..", "..", "legion-router", "config", "models.toml"
    )
)


class ExecutorRegistryError(ValueError):
    """The executor registry cannot provide a valid executor table."""


_STRING_FIELDS = frozenset(
    {
        "kind", "adapter", "contract", "model_ref", "review", "review_model_ref",
        "binary", "version_regex", "version_policy", "billing_class",
        "usage_reliability", "usage_source", "cost_reliability", "cost_source",
        "cancellation", "sandbox_wrapper_provider_sandbox",
    }
)
_BOOL_FIELDS = frozenset(
    {"acp", "task_file", "effort", "model_chain", "requires_explicit_consent"}
)
_STRING_LIST_FIELDS = frozenset(
    {
        "version_args", "supported_version_patterns", "known_bad_version_patterns",
        "config_fingerprint_env", "config_fingerprint_files", "required_config_env",
        "supported_config_env", "known_bad_config_env", "supported_sandboxes", "supported_read_modes",
        "supported_task_transports", "supported_model_patterns", "supported_efforts",
        "explicit_consent_model_patterns", "supported_sandbox_wrappers", "capabilities",
    }
)
_ENUM_FIELDS = {
    "contract": {"", "native", "diff", "prompt"},
    "review": {"native", "prompt", "none"},
    "version_policy": {"open", "closed"},
    "billing_class": {"free", "local", "metered", "premium_credit", "unknown"},
    "usage_reliability": {"provider_reported", "estimated", "unavailable", "unknown"},
    "cost_reliability": {"provider_reported", "computed", "estimated", "unavailable", "unknown"},
    "cancellation": {"none", "process", "process_group", "process_tree", "provider", "unknown"},
}
_INTEGER_FIELDS = frozenset({"max_runtime_seconds"})
_EXECUTOR_FIELDS = _STRING_FIELDS | _BOOL_FIELDS | _STRING_LIST_FIELDS | _INTEGER_FIELDS
_SANDBOX_WRAPPERS = frozenset({"docker", "podman", "vercel"})
_PROVIDER_SANDBOXES = frozenset({"read-only", "workspace-write", "danger-full-access"})


def _load_toml(path):
    """Parse complete TOML or fail closed on Python versions without a parser."""
    if tomllib is None:
        raise ExecutorRegistryError(
            "TOML parser unavailable; install tomli when running Python earlier than 3.11"
        )
    with open(path, "rb") as fh:
        return tomllib.load(fh)


def _validate_patterns(name, field, values):
    for pattern in values:
        try:
            re.compile(pattern)
        except re.error as exc:
            raise ExecutorRegistryError(
                f"executor '{name}' field '{field}' has invalid regex {pattern!r}: {exc}"
            ) from exc


def validate_executor_registry(executors):
    """Validate declared v1 fields without making them mandatory for legacy files.

    Older registries remain valid because every contract-foundation field is
    optional.  Once a field is declared, however, a typo must fail closed rather
    than silently grant a capability.
    """
    if not isinstance(executors, dict):
        raise ExecutorRegistryError("executors.toml must contain an [executors] table")
    for name, config in executors.items():
        if not isinstance(name, str) or not name or not isinstance(config, dict):
            raise ExecutorRegistryError("every executor must be a named table")
        unknown = sorted(set(config) - _EXECUTOR_FIELDS)
        if unknown:
            raise ExecutorRegistryError(
                f"executor '{name}' has unknown policy field(s): {', '.join(unknown)}"
            )
        for field in _STRING_FIELDS:
            if field in config and not isinstance(config[field], str):
                raise ExecutorRegistryError(f"executor '{name}' field '{field}' must be a string")
        for field in _BOOL_FIELDS:
            if field in config and not isinstance(config[field], bool):
                raise ExecutorRegistryError(f"executor '{name}' field '{field}' must be a boolean")
        for field in _STRING_LIST_FIELDS:
            if field not in config:
                continue
            value = config[field]
            if not isinstance(value, list) or not all(isinstance(item, str) and item for item in value):
                raise ExecutorRegistryError(
                    f"executor '{name}' field '{field}' must be an array of non-empty strings"
                )
            if field.endswith("_patterns"):
                _validate_patterns(name, field, value)
        for field, allowed in _ENUM_FIELDS.items():
            if field in config and config[field] not in allowed:
                raise ExecutorRegistryError(
                    f"executor '{name}' field '{field}' must be one of {sorted(allowed)}"
                )
        provider_sandboxes = config.get("supported_sandboxes")
        if provider_sandboxes is not None:
            unknown_sandboxes = sorted(set(provider_sandboxes) - _PROVIDER_SANDBOXES)
            if unknown_sandboxes:
                raise ExecutorRegistryError(
                    f"executor '{name}' has unsupported provider sandbox(es): "
                    f"{', '.join(unknown_sandboxes)}"
                )
            if len(set(provider_sandboxes)) != len(provider_sandboxes):
                raise ExecutorRegistryError(
                    f"executor '{name}' supported_sandboxes must be unique"
                )
        if config.get("binary") == "":
            raise ExecutorRegistryError(f"executor '{name}' field 'binary' must not be empty")
        if "version_regex" in config:
            _validate_patterns(name, "version_regex", [config["version_regex"]])
        for field in ("config_fingerprint_env", "required_config_env"):
            for env_name in config.get(field, []):
                if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", env_name):
                    raise ExecutorRegistryError(
                        f"executor '{name}' field '{field}' contains invalid environment name {env_name!r}"
                    )
        if "max_runtime_seconds" in config:
            value = config["max_runtime_seconds"]
            if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
                raise ExecutorRegistryError(
                    f"executor '{name}' field 'max_runtime_seconds' must be a positive integer"
                )
        binary = config.get("binary")
        version_args = config.get("version_args")
        if version_args and not binary:
            raise ExecutorRegistryError(
                f"executor '{name}' declares version_args without a binary"
            )
        if config.get("version_policy") == "closed" and not config.get("supported_version_patterns"):
            raise ExecutorRegistryError(
                f"executor '{name}' closed version policy requires supported_version_patterns"
            )
        for predicate_field in ("supported_config_env", "known_bad_config_env"):
            predicates = config.get(predicate_field, [])
            for predicate in predicates:
                env_name, separator, pattern = predicate.partition("=")
                if not separator or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", env_name):
                    raise ExecutorRegistryError(
                        f"executor '{name}' {predicate_field} entries must be NAME=REGEX"
                    )
                _validate_patterns(name, predicate_field, [pattern])
        wrappers = config.get("supported_sandbox_wrappers")
        provider_sandbox = config.get("sandbox_wrapper_provider_sandbox")
        if (wrappers is None) != (provider_sandbox is None):
            raise ExecutorRegistryError(
                f"executor '{name}' must declare supported_sandbox_wrappers and "
                "sandbox_wrapper_provider_sandbox together"
            )
        if wrappers is not None:
            if len(set(wrappers)) != len(wrappers):
                raise ExecutorRegistryError(
                    f"executor '{name}' supported_sandbox_wrappers must be unique"
                )
            unknown_wrappers = sorted(set(wrappers) - _SANDBOX_WRAPPERS)
            if unknown_wrappers:
                raise ExecutorRegistryError(
                    f"executor '{name}' has unsupported sandbox wrapper(s): "
                    f"{', '.join(unknown_wrappers)}"
                )
            if not isinstance(provider_sandboxes, list) or provider_sandbox not in provider_sandboxes:
                raise ExecutorRegistryError(
                    f"executor '{name}' sandbox wrapper provider sandbox "
                    f"{provider_sandbox!r} is not admitted by supported_sandboxes"
                )
            if provider_sandbox in _SANDBOX_WRAPPERS:
                raise ExecutorRegistryError(
                    f"executor '{name}' sandbox wrapper provider sandbox must be a provider mode"
                )
            overlap = sorted(set(wrappers) & set(provider_sandboxes))
            if overlap:
                raise ExecutorRegistryError(
                    f"executor '{name}' sandbox wrapper(s) must not also be provider sandboxes: "
                    f"{', '.join(overlap)}"
                )
    return executors


def _registry_path(path=None):
    return os.path.expanduser(
        str(path or os.environ.get("LEGION_EXECUTORS_FILE") or DEFAULT_EXECUTORS_FILE)
    )


def load_executor_registry(path=None):
    """Load and validate the executor table used by every Legion consumer.

    Both ``[executors.codex]`` and legacy top-level ``[codex]`` shapes are
    accepted.  Callers that need a safe telemetry fallback should use
    :func:`load_executor_families`; routing callers receive a typed failure.
    """
    registry = _registry_path(path)
    table = _load_toml(registry)
    if not isinstance(table, dict):
        raise ExecutorRegistryError("executors.toml must contain an executor table")
    if "executors" in table:
        if "schema" in table and table["schema"] != "legion.executor-registry.v1":
            raise ExecutorRegistryError("executors.toml has an unsupported schema")
    executors = table.get("executors", table)
    if not isinstance(executors, dict):
        raise ExecutorRegistryError("executors.toml must contain an [executors] table")
    return validate_executor_registry(executors)


def load_model_catalog(path=None):
    """Load the trusted semantic-model catalog used for no-spend admission."""
    catalog_path = os.path.expanduser(
        str(path or os.environ.get("LEGION_MODELS_FILE") or DEFAULT_MODELS_FILE)
    )
    table = _load_toml(catalog_path)
    models = table.get("models", table) if isinstance(table, dict) else None
    if not isinstance(models, dict) or not models:
        raise ExecutorRegistryError("models.toml must contain a non-empty [models] table")
    if not all(
        isinstance(role, str) and role
        and isinstance(model, str) and model
        for role, model in models.items()
    ):
        raise ExecutorRegistryError("models.toml must map non-empty roles to non-empty model IDs")
    return models


def executor_capabilities(config):
    """Return the typed capability set for one backwards-compatible entry."""
    if not isinstance(config, dict):
        return frozenset()
    capabilities = config.get("capabilities")
    if isinstance(capabilities, (list, tuple)) and all(
        isinstance(capability, str) and capability for capability in capabilities
    ):
        return frozenset(capabilities)
    kind = config.get("kind")
    if not isinstance(kind, str):
        return frozenset()
    return frozenset(part for part in kind.split() if part)


def has_executor_capability(config, capability):
    """Whether an executor entry declares one capability."""
    return isinstance(capability, str) and capability in executor_capabilities(config)


def load_executor_families(capability, path=None):
    """Return families declaring ``capability`` from the shared registry.

    Only the historical coding fallback is defined for malformed registries.
    Other capability lookups fail closed, which prevents an invalid table from
    silently granting primary or nesting authority.
    """
    try:
        executors = load_executor_registry(path)
    except (OSError, ValueError):
        return _FALLBACK_CODING_FAMILIES if capability == "coding" else frozenset()
    return frozenset(
        name
        for name, config in executors.items()
        if isinstance(name, str) and has_executor_capability(config, capability)
    )


def load_coding_executor_families(path=None):
    """Return registry executors that accept scoped coding work."""
    return load_executor_families("coding", path)


CODING_EXECUTOR_FAMILIES = load_coding_executor_families()


def executor_family(executor, families=CODING_EXECUTOR_FAMILIES):
    """Map mode labels such as codex-review/resume to their registry family."""
    if not isinstance(executor, str) or not executor.strip():
        return None
    normalized = executor.strip().lower()
    if normalized in families:
        return normalized
    family = normalized.split("-", 1)[0]
    return family if family in families else None


def is_delegated_executor(executor):
    return executor_family(executor) is not None


def _main(argv=None):
    """Small shell bridge; keeps shell nesting checks registry-driven."""
    import argparse

    parser = argparse.ArgumentParser(description="Query Legion executor capabilities.")
    parser.add_argument("--family", metavar="EXECUTOR")
    parser.add_argument("--capability", metavar="NAME", default="coding")
    parser.add_argument("--executors-file")
    args = parser.parse_args(argv)
    if args.family:
        family = executor_family(
            args.family, load_executor_families(args.capability, args.executors_file)
        )
        if family is None:
            return 1
        print(family)
        return 0
    for family in sorted(load_executor_families(args.capability, args.executors_file)):
        print(family)
    return 0


if __name__ == "__main__":  # pragma: no cover - exercised by shell consumers
    raise SystemExit(_main())
