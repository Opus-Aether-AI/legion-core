#!/usr/bin/env python3
"""Shared executor capability and family lookup for Legion consumers.

The executor registry is deliberately the one authority for harness identity.
Router, adapters, and telemetry all need to answer the same two questions:
which family owns a variant label, and which capabilities that family exposes.
"""

from __future__ import annotations

import json
import os
import re

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover - py<3.11
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


class ExecutorRegistryError(ValueError):
    """The executor registry cannot provide a valid executor table."""


_STRING_FIELDS = frozenset(
    {
        "kind", "adapter", "contract", "model_ref", "review", "review_model_ref",
        "binary", "version_regex", "version_policy", "billing_class",
        "usage_reliability", "usage_source", "cost_reliability", "cost_source",
        "cancellation",
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
        "explicit_consent_model_patterns",
    }
)
_ENUM_FIELDS = {
    "contract": {"", "native", "diff", "prompt"},
    "version_policy": {"open", "closed"},
    "billing_class": {"free", "local", "metered", "premium_credit", "unknown"},
    "usage_reliability": {"provider_reported", "estimated", "unavailable", "unknown"},
    "cost_reliability": {"provider_reported", "computed", "estimated", "unavailable", "unknown"},
    "cancellation": {"none", "process", "process_group", "process_tree", "provider", "unknown"},
}


def _fallback_table(path):
    """Read the registry fields needed here when tomllib is unavailable."""
    table = {}
    current = table
    section = re.compile(r"\[([A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*)\]")
    with open(path, encoding="utf-8") as fh:
        for raw_line in fh:
            line = raw_line.split("#", 1)[0].strip()
            if line.startswith("[") and line.endswith("]"):
                match = section.fullmatch(line)
                if not match:
                    current = None
                    continue
                current = table
                for part in match.group(1).split("."):
                    child = current.setdefault(part, {})
                    if not isinstance(child, dict):
                        raise ValueError(f"table path conflicts with scalar: {part}")
                    current = child
                continue
            if current is None or "=" not in line:
                continue
            key, value = (part.strip() for part in line.split("=", 1))
            if current is table:
                # A root assignment named `executors` is not an executor table.
                # Preserve that invalid shape for the caller's fallback guard.
                if key == "executors":
                    table["executors"] = None
                continue
            # Executor routing consumes the complete scalar contract, not only
            # ``kind``.  Python 3.9/3.10 therefore must preserve adapter,
            # contract, and model_ref just like tomllib does on 3.11+.
            if len(value) >= 2 and value[0] == value[-1] == '"':
                try:
                    current[key] = json.loads(value)
                except json.JSONDecodeError as exc:
                    raise ValueError(f"invalid quoted TOML value for {key}") from exc
            elif value in ("true", "false"):
                # Capability flags (task_file) are bare booleans. Preserving only
                # quoted strings silently dropped them on 3.9/3.10, so a
                # capability declared in executors.toml simply vanished there and
                # the dispatcher fell back to its pre-capability behaviour.
                current[key] = value == "true"
            elif value.startswith("[") and value.endswith("]"):
                try:
                    parsed = json.loads(value)
                except json.JSONDecodeError as exc:
                    raise ValueError(f"invalid TOML array for {key}") from exc
                current[key] = parsed
            elif re.fullmatch(r"[0-9]+", value):
                current[key] = int(value)
    return table


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
    if tomllib is None:
        table = _fallback_table(registry)
    else:
        with open(registry, "rb") as fh:
            table = tomllib.load(fh)
    if not isinstance(table, dict):
        raise ExecutorRegistryError("executors.toml must contain an executor table")
    executors = table.get("executors", table)
    if not isinstance(executors, dict):
        raise ExecutorRegistryError("executors.toml must contain an [executors] table")
    return validate_executor_registry(executors)


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
