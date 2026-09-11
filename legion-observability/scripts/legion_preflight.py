#!/usr/bin/env python3
"""No-spend executor admission and binary/config identity cache."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import select
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone

from legion_executor_registry import (
    ExecutorRegistryError,
    load_executor_registry,
    load_model_catalog,
)


SCHEMA = "legion.preflight.v1"
PASSING_STATES = frozenset({"supported"})
VERSION_DISCOVERY_SECONDS = 5
VERSION_OUTPUT_BYTES = 4096
VERSION_CACHE_CONTRACT = "legion.supervised-version.v1"
PROCESS_SUPERVISOR = (
    Path(__file__).resolve().parents[2]
    / "legion-router"
    / "scripts"
    / "legion-process-supervisor.py"
)


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
    if not isinstance(value, dict):
        return None
    if set(value) != {"cache_key", "version_raw", "version"}:
        return None
    if value.get("cache_key") != key:
        return None
    if any(
        field is not None and not isinstance(field, str)
        for field in (value.get("version_raw"), value.get("version"))
    ):
        return None
    return value


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


def _version_deadline_ns(env):
    own_deadline = time.monotonic_ns() + VERSION_DISCOVERY_SECONDS * 1_000_000_000
    inherited = env.get("LEGION_CHILD_LEASE_DEADLINE_NS")
    if inherited is None or inherited == "":
        return own_deadline
    try:
        inherited_deadline = int(inherited)
    except (TypeError, ValueError) as exc:
        raise ValueError("invalid inherited child lease deadline") from exc
    if inherited_deadline < 1:
        raise ValueError("invalid inherited child lease deadline")
    return min(own_deadline, inherited_deadline)


def _supervised_version_output(executable, args, env):
    """Run one version probe under the canonical descendant-aware lease."""

    environment = dict(env)
    environment["LEGION_CHILD_LEASE_DEADLINE_NS"] = str(_version_deadline_ns(environment))
    captured = bytearray()

    with tempfile.TemporaryDirectory(prefix="legion-preflight-version-") as temporary:
        lease_path = Path(temporary) / "lease.json"
        process = subprocess.Popen(
            [
                os.path.realpath(sys.executable),
                "-I",
                str(PROCESS_SUPERVISOR),
                "--cwd",
                temporary,
                "--max-runtime-seconds",
                str(VERSION_DISCOVERY_SECONDS),
                "--status-file",
                str(lease_path),
                "--",
                executable,
                *args,
            ],
            cwd=temporary,
            env=environment,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            bufsize=0,
        )
        assert process.stdout is not None
        output_fd = process.stdout.fileno()
        supervisor_exited_at = None
        output_closed = False
        try:
            while not output_closed:
                readable, _writable, _exceptional = select.select(
                    [output_fd], [], [], 0.1
                )
                if readable:
                    chunk = os.read(output_fd, 64 * 1024)
                    if not chunk:
                        output_closed = True
                    else:
                        remaining = VERSION_OUTPUT_BYTES - len(captured)
                        if remaining > 0:
                            captured.extend(chunk[:remaining])
                if process.poll() is not None:
                    supervisor_exited_at = supervisor_exited_at or time.monotonic()
                    if not output_closed and time.monotonic() - supervisor_exited_at >= 1.0:
                        # An EOF holder survived the supervisor. Do not block,
                        # cache, or trust the partial identity.
                        return None, {
                            "status": "invalid",
                            "reason": "version probe supervisor exited without closing output",
                            "lease": None,
                        }
            process.wait()
        finally:
            process.stdout.close()
        try:
            lease = json.loads(lease_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return None, {
                "status": "invalid",
                "reason": "version probe supervisor did not publish a valid lease receipt",
                "lease": None,
            }
        allowed = {
            "schema", "status", "reason", "max_runtime_seconds",
            "child_started", "child_exit_code",
        }
        lease_status = lease.get("status") if isinstance(lease, dict) else None
        lease_valid = (
            isinstance(lease, dict)
            and set(lease).issubset(allowed)
            and lease.get("schema") == "legion.child-execution-lease.v1"
            and lease_status in {
                "completed", "cancelled", "timed_out", "cleanup_failed", "launch_failed"
            }
            and isinstance(lease.get("reason"), str)
            and bool(lease["reason"])
            and type(lease.get("max_runtime_seconds")) is int
            and lease["max_runtime_seconds"] >= 1
            and (
                "child_started" not in lease
                or lease.get("child_started") is False
            )
            and (
                "child_exit_code" not in lease
                or (
                    type(lease.get("child_exit_code")) is int
                    and 0 <= lease["child_exit_code"] <= 255
                )
            )
        )
        completed = (
            lease_valid
            and lease_status == "completed"
            and process.returncode is not None
            and process.returncode >= 0
            and lease.get("child_exit_code") == process.returncode
        )
        if not lease_valid or (lease_status == "completed" and not completed):
            return None, {
                "status": "invalid",
                "reason": "version probe supervisor published malformed lease evidence",
                "lease": None,
            }
        probe_status = lease_status
        if lease_status == "launch_failed" and process.returncode == 124 \
                and "deadline" in lease["reason"].lower():
            # The supervisor correctly records that Popen never happened, but
            # callers still need the causal timeout to terminate the lease.
            probe_status = "timed_out"

    raw = bytes(captured).decode("utf-8", errors="replace").strip()
    return (raw or None if completed else None), {
        "status": probe_status,
        "reason": lease["reason"],
        "lease": lease,
    }


def _discover_version(executable, config, cache_dir, binary_digest, config_digest, env):
    key = _canonical_digest(
        {
            "contract": VERSION_CACHE_CONTRACT,
            "executable_path": executable,
            "binary_sha256": binary_digest,
            "config_sha256": config_digest,
        }
    )
    cache_path = Path(cache_dir) / f"{key}.json"
    cached = _read_cache(cache_path, key)
    if cached is not None:
        return cached.get("version_raw"), cached.get("version"), True, key, {
            "status": "cached", "reason": "trusted version probe cache hit", "lease": None,
        }

    args = config.get("version_args", ["--version"])
    raw = None
    version = None
    probe = {"status": "not_requested", "reason": None, "lease": None}
    if args:
        try:
            raw, probe = _supervised_version_output(executable, args, env)
        except (OSError, ValueError, subprocess.SubprocessError) as exc:
            raw = None
            probe = {
                "status": "invalid",
                "reason": f"version probe supervisor could not start: {exc}",
                "lease": None,
            }
        if probe["status"] == "completed":
            try:
                current_digest = _sha256_file(executable)
                executable_still_valid = os.path.isfile(executable) \
                    and os.access(executable, os.X_OK)
            except OSError:
                current_digest = None
                executable_still_valid = False
            if not executable_still_valid or current_digest != binary_digest:
                # Darwin's Seatbelt launcher can itself start successfully and
                # report the missing nested executable as its exit code. Bind
                # admission to the same executable bytes checked before the
                # probe so that wrapper completion cannot masquerade as an
                # ordinary unparseable version.
                raw = None
                probe = {
                    "status": "launch_failed",
                    "reason": "executor binary disappeared or changed during version probe",
                    "lease": probe["lease"],
                }
    if raw:
        pattern = config.get("version_regex") or r"(?P<version>[0-9]+(?:\.[0-9A-Za-z_-]+)+)"
        matched = re.search(pattern, raw)
        if matched:
            version = matched.groupdict().get("version") or matched.group(0)
    record = {"cache_key": key, "version_raw": raw, "version": version}
    if probe["status"] in {"completed", "not_requested"}:
        _write_cache(cache_path, record)
    return raw, version, False, key, probe


def _matches_any(value, patterns):
    return value is not None and any(re.search(pattern, value) for pattern in patterns)


def _trusted_model_policy(executor, requested_model, models):
    """Resolve only catalog roles owned by this executor family."""
    prefix = f"{executor}_"
    owned = {
        role: model
        for role, model in models.items()
        if isinstance(role, str) and role.startswith(prefix)
    }
    if requested_model in owned:
        return owned[requested_model], requested_model
    if requested_model in owned.values():
        roles = sorted(role for role, model in owned.items() if model == requested_model)
        return requested_model, roles[0] if roles else None
    return requested_model, None


def _compatibility(executor, config, request, env, models):
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
    policy_model = model
    model_ref = None
    if model is not None:
        policy_model, model_ref = _trusted_model_policy(executor, model, models)
        if model_patterns is None:
            model_state = "supported" if model_ref is not None else "untested"
        else:
            model_state = "supported" if _matches_any(policy_model, model_patterns) else "incompatible"
        if model_state == "incompatible":
            failures.append(f"unsupported model '{model}'")
    checks["model"] = {
        "requested": model,
        "policy_model": policy_model,
        "model_ref": model_ref,
        "status": model_state,
    }

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
    consent_required = bool(config.get("requires_explicit_consent")) or _matches_any(
        policy_model, consent_patterns
    )
    consent_ok = not consent_required or bool(request.get("explicit_consent"))
    checks["billing"] = {
        "class": "premium_credit" if _matches_any(policy_model, consent_patterns) else config.get("billing_class", "unknown"),
        "explicit_consent_required": consent_required,
        "status": "supported" if consent_ok else "incompatible",
    }
    if not consent_ok:
        failures.append("explicit billing consent required")
    return checks, failures


def preflight(executor, *, registry_path=None, models_path=None, cache_dir=None, env=None,
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
    try:
        models = load_model_catalog(models_path)
    except (OSError, ExecutorRegistryError, ValueError) as exc:
        return {"schema": SCHEMA, "checked_at": checked_at, "executor": executor,
                "status": "unavailable", "reason": f"invalid model catalog: {exc}",
                "identity": None, "cache": {"hit": False, "key": None}, "compatibility": {}}
    checks, failures = _compatibility(executor, config, request, env, models)
    missing_config = checks.get("configuration", {}).get("status") == "unavailable"
    incompatible = any(
        isinstance(check, dict) and check.get("status") == "incompatible"
        for check in checks.values()
    )
    if failures:
        return {"schema": SCHEMA, "checked_at": checked_at, "executor": executor,
                # Policy incompatibility is terminal even when the same
                # executor is also unavailable. Callers may fall through on a
                # typed unavailable result, so allowing missing credentials to
                # mask an unsupported model/sandbox/effort/billing/configuration
                # request could spend through a different provider.
                "status": "incompatible" if incompatible else (
                    "unavailable" if missing_config else "incompatible"
                ),
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
    raw, version, cache_hit, cache_key, version_probe = _discover_version(
        executable, config, cache_dir, binary_digest, config_digest, env
    )
    if version_probe["status"] not in {"completed", "cached", "not_requested"}:
        checks["version"] = {
            "discovered": None,
            "status": "unavailable",
            "probe_status": version_probe["status"],
            "probe_reason": version_probe["reason"],
            "probe_lease": version_probe["lease"],
        }
        return {
            "schema": SCHEMA, "checked_at": checked_at, "executor": executor,
            "status": "unavailable",
            "reason": f"executor version probe {version_probe['status']}: "
                      f"{version_probe['reason']}",
            "identity": None,
            "cache": {"hit": False, "key": cache_key},
            "compatibility": checks,
        }
    known_bad_version = _matches_any(version, config.get("known_bad_version_patterns", []))
    version_patterns = config.get("supported_version_patterns", [])
    supported_version = _matches_any(version, version_patterns)
    open_version = (
        config.get("version_policy") == "open"
        and not version_patterns
        and version is not None
    )
    if known_bad_version:
        failures.append(f"known-bad executor version '{version}'")
    elif config.get("version_policy", "open") == "closed" and not supported_version:
        failures.append(f"unsupported executor version '{version or 'unknown'}'")
    checks["version"] = {
        "discovered": version,
        "status": "supported" if supported_version or open_version else "untested",
        "probe_status": version_probe["status"],
        "probe_reason": version_probe["reason"],
        "probe_lease": version_probe["lease"],
    }

    untested_checks = sorted(
        name
        for name, check in checks.items()
        if isinstance(check, dict) and check.get("status") == "untested"
    )
    if failures:
        status = "incompatible"
    elif not untested_checks:
        status = "supported"
    else:
        status = "untested"
    reason = "; ".join(failures) if failures else (
        "declared capabilities and version are supported" if status == "supported"
        else "executor is available but policy is untested for: " + ", ".join(untested_checks)
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
    parser.add_argument("--models-file")
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
        args.executor, registry_path=args.executors_file, models_path=args.models_file,
        cache_dir=args.cache_dir,
        sandbox=args.sandbox, read_mode=args.read_mode, task_transport=args.task_transport,
        model=args.model, effort=args.effort, explicit_consent=args.explicit_consent,
        binary_override=args.binary,
    )
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if result["status"] in PASSING_STATES else 1


if __name__ == "__main__":
    raise SystemExit(main())
