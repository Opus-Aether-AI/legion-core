#!/usr/bin/env python3
"""No-spend executor admission and binary/config identity cache."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
from datetime import datetime, timezone

from legion_executor_registry import ExecutorRegistryError, load_executor_registry


SCHEMA = "legion.preflight.v1"
PASSING_STATES = frozenset({"supported", "untested"})


def _sha256_bytes(value):
    return hashlib.sha256(value).hexdigest()


def _sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _canonical_digest(value):
    return _sha256_bytes(
        json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()
    )


def _utc_now():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _resolve_binary(binary, env):
    if not binary:
        return None
    expanded = os.path.expanduser(os.path.expandvars(binary))
    if os.path.sep in expanded:
        path = os.path.realpath(expanded)
        return path if os.path.isfile(path) and os.access(path, os.X_OK) else None
    found = shutil.which(expanded, path=env.get("PATH"))
    return os.path.realpath(found) if found else None


def _expand_path(value, env):
    expanded = value
    for name, replacement in env.items():
        expanded = expanded.replace("${" + name + "}", replacement).replace("$" + name, replacement)
    if expanded.startswith("~/"):
        expanded = os.path.join(env.get("HOME") or os.path.expanduser("~"), expanded[2:])
    return os.path.realpath(expanded)


def _config_identity(config, env):
    env_names = set(config.get("config_fingerprint_env", []))
    env_names.update(config.get("required_config_env", []))
    env_names.update(item.partition("=")[0] for item in config.get("supported_config_env", []))
    env_names.update(item.partition("=")[0] for item in config.get("known_bad_config_env", []))
    env_values = {name: env.get(name) for name in sorted(env_names)}
    files = []
    for raw_path in config.get("config_fingerprint_files", []):
        path = _expand_path(raw_path, env)
        try:
            digest = _sha256_file(path) if os.path.isfile(path) else None
        except OSError:
            digest = "unreadable"
        files.append({"path": path, "sha256": digest})
    # The declaration itself is relevant configuration: changing compatibility
    # or discovery policy must not reuse an older probe.
    material = {"contract": config, "environment": env_values, "files": files}
    return _canonical_digest(material)


def _read_cache(path, key):
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return value if value.get("cache_key") == key else None


def _write_cache(path, value):
    temporary = None
    try:
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        fd, temporary = tempfile.mkstemp(prefix=".preflight-", dir=str(path.parent))
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, sort_keys=True, separators=(",", ":"))
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    except OSError:
        # Admission is a no-spend probe; an optional cache must never turn an
        # otherwise valid executor into an unavailable one. This is expected
        # under read-only HOME/XDG mounts and hardened CI containers.
        return False
    finally:
        if temporary is not None:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass
    return True


def _discover_version(executable, config, cache_dir, binary_digest, config_digest, env):
    key = _canonical_digest(
        {"executable_path": executable, "binary_sha256": binary_digest, "config_sha256": config_digest}
    )
    cache_path = Path(cache_dir) / f"{key}.json"
    cached = _read_cache(cache_path, key)
    if cached is not None:
        return cached.get("version_raw"), cached.get("version"), True, key

    args = config.get("version_args", ["--version"])
    raw = None
    version = None
    if args:
        try:
            completed = subprocess.run(
                [executable, *args], capture_output=True, text=True, timeout=5,
                check=False, env=dict(env), stdin=subprocess.DEVNULL,
            )
            combined = "\n".join(part.strip() for part in (completed.stdout, completed.stderr) if part.strip())
            raw = combined[:4096] if combined else None
        except (OSError, subprocess.SubprocessError):
            raw = None
    if raw:
        pattern = config.get("version_regex") or r"(?P<version>[0-9]+(?:\.[0-9A-Za-z_-]+)+)"
        matched = re.search(pattern, raw)
        if matched:
            version = matched.groupdict().get("version") or matched.group(0)
    record = {"cache_key": key, "version_raw": raw, "version": version}
    _write_cache(cache_path, record)
    return raw, version, False, key


def _matches_any(value, patterns):
    return value is not None and any(re.search(pattern, value) for pattern in patterns)


def _compatibility(config, request, env):
    checks = {}
    failures = []
    for request_name, registry_name in (
        ("sandbox", "supported_sandboxes"),
        ("read_mode", "supported_read_modes"),
        ("task_transport", "supported_task_transports"),
        ("effort", "supported_efforts"),
    ):
        requested = request.get(request_name)
        supported = config.get(registry_name)
        state = "not_requested"
        if requested is not None:
            admitted = requested
            wrapper = None
            declared_wrappers = config.get("supported_sandbox_wrappers", [])
            if request_name == "sandbox" \
                    and isinstance(declared_wrappers, (list, tuple)) \
                    and requested in declared_wrappers:
                wrapper = requested
                admitted = config.get("sandbox_wrapper_provider_sandbox")
            if wrapper is not None and (not isinstance(admitted, str) or not admitted):
                state = "incompatible"
            else:
                state = "untested" if supported is None else (
                    "supported" if admitted in supported else "incompatible"
                )
            if state == "incompatible":
                if wrapper is not None:
                    failures.append(
                        f"sandbox wrapper '{wrapper}' requires unsupported provider sandbox "
                        f"'{admitted}'"
                    )
                else:
                    failures.append(f"unsupported {request_name} '{requested}'")
        checks[request_name] = {"requested": requested, "status": state}
        if request_name == "sandbox" and requested is not None:
            checks[request_name]["provider_sandbox"] = admitted
            checks[request_name]["wrapper"] = wrapper

    model = request.get("model")
    model_patterns = config.get("supported_model_patterns")
    model_state = "not_requested"
    if model is not None:
        model_state = "untested" if model_patterns is None else (
            "supported" if _matches_any(model, model_patterns) else "incompatible"
        )
        if model_state == "incompatible":
            failures.append(f"unsupported model '{model}'")
    checks["model"] = {"requested": model, "status": model_state}

    missing = [name for name in config.get("required_config_env", []) if not env.get(name)]
    checks["configuration"] = {"missing": missing, "status": "unavailable" if missing else "supported"}
    if missing:
        failures.append("missing required configuration: " + ", ".join(missing))
    for predicate in config.get("supported_config_env", []):
        name, _, pattern = predicate.partition("=")
        if env.get(name) is not None and not re.search(pattern, env[name]):
            checks["configuration"] = {"missing": missing, "status": "incompatible"}
            failures.append(f"unsupported configuration in {name}")
    for predicate in config.get("known_bad_config_env", []):
        name, _, pattern = predicate.partition("=")
        if env.get(name) is not None and re.search(pattern, env[name]):
            checks["configuration"] = {"missing": missing, "status": "incompatible"}
            failures.append(f"known-bad configuration in {name}")

    consent_patterns = config.get("explicit_consent_model_patterns", [])
    consent_required = bool(config.get("requires_explicit_consent")) or _matches_any(model, consent_patterns)
    consent_ok = not consent_required or bool(request.get("explicit_consent"))
    checks["billing"] = {
        "class": "premium_credit" if _matches_any(model, consent_patterns) else config.get("billing_class", "unknown"),
        "explicit_consent_required": consent_required,
        "status": "supported" if consent_ok else "incompatible",
    }
    if not consent_ok:
        failures.append("explicit billing consent required")
    return checks, failures


def preflight(executor, *, registry_path=None, cache_dir=None, env=None,
              binary_override=None, **request):
    env = dict(os.environ if env is None else env)
    checked_at = _utc_now()
    try:
        executors = load_executor_registry(registry_path)
    except (OSError, ExecutorRegistryError, ValueError) as exc:
        return {"schema": SCHEMA, "checked_at": checked_at, "executor": executor,
                "status": "unavailable", "reason": f"invalid executor registry: {exc}",
                "identity": None, "cache": {"hit": False, "key": None}, "compatibility": {}}
    config = executors.get(executor)
    if not isinstance(config, dict):
        return {"schema": SCHEMA, "checked_at": checked_at, "executor": executor,
                "status": "unavailable", "reason": f"executor '{executor}' is not registered",
                "identity": None, "cache": {"hit": False, "key": None}, "compatibility": {}}
    # Adapter-specific binary overrides (for example CODEX_BIN=/opt/codex) are
    # part of the executable identity.  Copy the registry row so a caller can
    # preflight the exact binary it will launch without mutating shared state.
    config = dict(config)
    if binary_override:
        config["binary"] = binary_override
    checks, failures = _compatibility(config, request, env)
    missing_config = checks.get("configuration", {}).get("status") == "unavailable"
    if failures:
        return {"schema": SCHEMA, "checked_at": checked_at, "executor": executor,
                "status": "unavailable" if missing_config else "incompatible",
                "reason": "; ".join(failures), "identity": None,
                "cache": {"hit": False, "key": None}, "compatibility": checks}
    executable = _resolve_binary(config.get("binary") or executor, env)
    if executable is None:
        return {"schema": SCHEMA, "checked_at": checked_at, "executor": executor,
                "status": "unavailable", "reason": f"executor binary not found: {config.get('binary') or executor}",
                "identity": None, "cache": {"hit": False, "key": None}, "compatibility": {}}
    try:
        binary_digest = _sha256_file(executable)
    except OSError as exc:
        return {"schema": SCHEMA, "checked_at": checked_at, "executor": executor,
                "status": "unavailable", "reason": f"executor binary is unreadable: {exc}",
                "identity": None, "cache": {"hit": False, "key": None}, "compatibility": {}}
    config_digest = _config_identity(config, env)
    if cache_dir is None:
        default_home = env.get("HOME") or os.path.expanduser("~")
        cache_dir = env.get("LEGION_PREFLIGHT_CACHE_DIR") or os.path.join(
            env.get("XDG_CACHE_HOME") or os.path.join(default_home, ".cache"),
            "legion", "preflight",
        )
    raw, version, cache_hit, cache_key = _discover_version(
        executable, config, cache_dir, binary_digest, config_digest, env
    )
    known_bad_version = _matches_any(version, config.get("known_bad_version_patterns", []))
    supported_version = _matches_any(version, config.get("supported_version_patterns", []))
    if known_bad_version:
        failures.append(f"known-bad executor version '{version}'")
    elif config.get("version_policy", "open") == "closed" and not supported_version:
        failures.append(f"unsupported executor version '{version or 'unknown'}'")

    if failures:
        status = "incompatible"
    elif supported_version and not any(
        isinstance(check, dict) and check.get("status") == "untested"
        for check in checks.values()
    ):
        status = "supported"
    else:
        status = "untested"
    reason = "; ".join(failures) if failures else (
        "declared capabilities and version are supported" if status == "supported"
        else "executor is available but its version is not declared tested"
    )
    return {
        "schema": SCHEMA, "checked_at": checked_at, "executor": executor,
        "status": status, "reason": reason,
        "identity": {"executable_path": executable, "binary_sha256": binary_digest,
                     "config_sha256": config_digest, "version": version, "version_raw": raw},
        "cache": {"hit": cache_hit, "key": cache_key}, "compatibility": checks,
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description="No-spend Legion executor preflight")
    parser.add_argument("--json", action="store_true", required=True)
    parser.add_argument("--executor", required=True)
    parser.add_argument("--executors-file")
    parser.add_argument("--cache-dir")
    parser.add_argument("--sandbox")
    parser.add_argument("--read-mode")
    parser.add_argument("--task-transport")
    parser.add_argument("--model")
    parser.add_argument("--effort")
    parser.add_argument("--explicit-consent", action="store_true")
    parser.add_argument("--binary")
    args = parser.parse_args(argv)
    result = preflight(
        args.executor, registry_path=args.executors_file, cache_dir=args.cache_dir,
        sandbox=args.sandbox, read_mode=args.read_mode, task_transport=args.task_transport,
        model=args.model, effort=args.effort, explicit_consent=args.explicit_consent,
        binary_override=args.binary,
    )
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if result["status"] in PASSING_STATES else 1


if __name__ == "__main__":
    raise SystemExit(main())
