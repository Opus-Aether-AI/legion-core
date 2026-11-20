#!/usr/bin/env python3
"""Executor health: which coding executors can take work right now.

The router used to learn that an executor was logged out or out of quota by
sending it work and watching the run fail -- every time. This module keeps one
small machine-wide record per executor so a failure is learned once:

* a run that fails with an authentication or quota error records the executor
  as ``unavailable`` (``logged_out`` / ``no_quota``);
* ``legion-health probe`` (run by ``legion-doctor`` and the daily refresh)
  records the result of a cheap, offline static check: is the CLI installed,
  is it logged in, is the key it needs present;
* every record carries ``recheck_after``. A fresh record is trusted as is; a
  stale ``unavailable`` record is re-probed before the router decides, so a
  re-login is noticed without anyone resetting state.

Routing never probes an executor that has no record, and never treats an
inconclusive probe as an outage: an executor is skipped only on evidence.

Pure stdlib. The record lives at ``$LEGION_HEALTH_FILE`` or
``$LEGION_HOME/health/executors.json`` (``LEGION_HOME`` defaults to ~/.legion).
"""

from __future__ import annotations

import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from typing import Any

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import legion_file_lock  # noqa: E402

SCHEMA = "legion.executor-health.v1"
STATUSES = ("ok", "unavailable", "unknown")
REASONS = (
    "logged_out",
    "no_quota",
    "missing_key",
    "missing_binary",
    "probe_failed",
)
# Seconds a record is trusted before the router looks again. A quota resets on
# its own, so it is rechecked sooner than a login, which needs a person.
DEFAULT_TTL = {
    "ok": 900,
    "no_quota": 3600,
    "logged_out": 6 * 3600,
    "missing_key": 6 * 3600,
    "missing_binary": 6 * 3600,
    "probe_failed": 6 * 3600,
}
DEFAULT_FALLBACK_ORDER = ("claude", "codex", "opencode", "cursor")
PROBE_TIMEOUT_SECONDS = 10

_ROUTER_SCRIPTS = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "..", "legion-router", "scripts")
)
_ROUTE_MODULE = None

# One vocabulary for "the provider could not serve this". Matched against
# stderr and adapter-reported error fields only -- never against an executor's
# result text, which can legitimately quote these words.
_QUOTA = re.compile(
    r"usage limit|rate.?limit|quota|insufficient_quota|\b429\b|too many requests|"
    r"exceeded your|credit balance is too low|out of credits|insufficient credits",
    re.IGNORECASE,
)
_AUTH = re.compile(
    r"unauthori[sz]ed|not authenticated|authentication required|not logged in|"
    r"invalid_api_key|invalid api key|api[_ ]key.{0,40}(unset|missing|required|invalid)|"
    r"please run .{0,40}login|token (?:is |has )?expired|failed to refresh|"
    r"refresh token|login (?:has )?expired|session expired",
    re.IGNORECASE,
)


class HealthError(ValueError):
    """A health command was given an invalid argument."""


def _route():
    """legion-route.py, loaded once, for its config readers."""
    global _ROUTE_MODULE
    if _ROUTE_MODULE is None:
        path = os.path.join(_ROUTER_SCRIPTS, "legion-route.py")
        spec = importlib.util.spec_from_file_location("legion_route_for_health", path)
        module = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        spec.loader.exec_module(module)
        _ROUTE_MODULE = module
    return _ROUTE_MODULE


def _env(env=None):
    return os.environ if env is None else env


def _now(now=None) -> float:
    return time.time() if now is None else float(now)


def _iso(epoch: float) -> str:
    return datetime.fromtimestamp(epoch, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _epoch(value: Any) -> float | None:
    if not isinstance(value, str) or not value:
        return None
    text = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.timestamp()


def legion_home(env=None) -> str:
    env = _env(env)
    home = env.get("HOME") or os.path.expanduser("~")
    return os.path.abspath(os.path.expanduser(env.get("LEGION_HOME") or os.path.join(home, ".legion")))


def health_file(env=None) -> str:
    env = _env(env)
    explicit = env.get("LEGION_HEALTH_FILE")
    if explicit:
        return os.path.abspath(os.path.expanduser(explicit))
    return os.path.join(legion_home(env), "health", "executors.json")


def health_enabled(env=None) -> bool:
    return str(_env(env).get("LEGION_HEALTH", "on")).strip().lower() not in {
        "off", "0", "false", "no",
    }


def _ttl(status: str, reason: str, env=None) -> int:
    env = _env(env)
    key = "ok" if status == "ok" else (reason or "probe_failed")
    override = env.get(f"LEGION_HEALTH_TTL_{key.upper()}_SECONDS")
    if override:
        try:
            return max(0, int(override))
        except ValueError:
            pass
    return DEFAULT_TTL.get(key, DEFAULT_TTL["probe_failed"])


def load(path: str | None = None) -> dict[str, Any]:
    target = path or health_file()
    try:
        with open(target, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return {"schema": SCHEMA, "executors": {}}
    if not isinstance(data, dict) or not isinstance(data.get("executors"), dict):
        return {"schema": SCHEMA, "executors": {}}
    return data


def _write(path: str, data: dict[str, Any]) -> None:
    directory = os.path.dirname(path)
    os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".executors.", suffix=".json", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=2, sort_keys=True)
            fh.write("\n")
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _locked_update(path: str, mutate) -> dict[str, Any]:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    lock_path = path + ".lock"
    fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        with legion_file_lock.exclusive_lock(fd):
            data = load(path)
            mutate(data["executors"])
            data["schema"] = SCHEMA
            _write(path, data)
            return data
    finally:
        os.close(fd)


def record(
    executor: str,
    status: str,
    reason: str = "",
    detail: str = "",
    source: str = "run",
    *,
    ttl: int | None = None,
    path: str | None = None,
    now: float | None = None,
    env=None,
) -> dict[str, Any]:
    """Store one executor's health. Returns the stored entry."""
    if not isinstance(executor, str) or not re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,63}", executor):
        raise HealthError(f"invalid executor name: {executor!r}")
    if status not in ("ok", "unavailable"):
        raise HealthError("status must be ok or unavailable")
    if status == "unavailable" and reason not in REASONS:
        raise HealthError(f"reason must be one of: {', '.join(REASONS)}")
    if status == "ok":
        reason = ""
    stamp = _now(now)
    seconds = _ttl(status, reason, env) if ttl is None else max(0, int(ttl))
    entry = {
        "status": status,
        "reason": reason,
        "detail": str(detail or "")[:400],
        "source": source,
        "checked_at": _iso(stamp),
        "recheck_after": _iso(stamp + seconds),
    }

    def mutate(executors):
        executors[executor] = entry

    _locked_update(path or health_file(env), mutate)
    return entry


def reset(executors: list[str] | None = None, *, path: str | None = None) -> None:
    def mutate(table):
        if not executors:
            table.clear()
        for name in executors or ():
            table.pop(name, None)

    _locked_update(path or health_file(), mutate)


def classify_text(text: str) -> str:
    """Map provider error text to a health reason, or "" when it is not an outage."""
    if not text:
        return ""
    if _QUOTA.search(text):
        return "no_quota"
    if _AUTH.search(text):
        return "logged_out"
    return ""


# ── static probes ──────────────────────────────────────────────────────


def _which(candidate: str, env) -> str:
    if not candidate:
        return ""
    candidate = os.path.expanduser(candidate)
    if os.sep in candidate:
        return candidate if os.path.isfile(candidate) and os.access(candidate, os.X_OK) else ""
    return shutil.which(candidate, path=env.get("PATH")) or ""


def _first_binary(env, override: str, *defaults: str) -> str:
    value = env.get(override, "") if override else ""
    if value:
        # An explicit override is authoritative, exactly as the adapters treat it.
        return _which(value, env)
    for candidate in defaults:
        found = _which(candidate, env)
        if found:
            return found
    return ""


def openrouter_key_file(env=None) -> str:
    env = _env(env)
    explicit = env.get("LEGION_OPENROUTER_KEY_FILE")
    if explicit:
        return os.path.abspath(os.path.expanduser(explicit))
    home = env.get("HOME") or os.path.expanduser("~")
    config = env.get("XDG_CONFIG_HOME") or os.path.join(home, ".config")
    return os.path.join(config, "legion", "openrouter.key")


def _opencode_auth(env) -> dict:
    home = env.get("HOME") or os.path.expanduser("~")
    data_home = env.get("XDG_DATA_HOME") or os.path.join(home, ".local", "share")
    try:
        with open(os.path.join(data_home, "opencode", "auth.json"), encoding="utf-8") as fh:
            creds = json.load(fh)
    except (OSError, ValueError):
        return {}
    return creds if isinstance(creds, dict) else {}


def openrouter_key_present(env=None, *, opencode=False) -> bool:
    """Whether an OpenRouter key is configured (presence only; never read out).

    ``opencode`` also accepts a key stored with `opencode auth login`, which
    opencode uses on its own.
    """
    env = _env(env)
    if env.get("OPENROUTER_API_KEY"):
        return True
    path = openrouter_key_file(env)
    try:
        if os.path.isfile(path) and os.path.getsize(path) > 0 and os.access(path, os.R_OK):
            return True
    except OSError:
        pass
    return bool(opencode and isinstance(_opencode_auth(env).get("openrouter"), dict))


def openrouter_key_instructions(env=None) -> str:
    path = openrouter_key_file(env)
    return (
        f"add an OpenRouter API key to {path} (one line, then chmod 600 {path}), "
        "or set LEGION_OPENROUTER_KEY_FILE to a file that holds one"
    )


def _model_for(executor: str, env) -> str:
    override = {
        "opencode": env.get("LEGION_OPENCODE_MODEL") or env.get("OPENCODE_MODEL"),
        "pi": env.get("LEGION_PI_MODEL"),
    }.get(executor)
    if override:
        return override
    try:
        executors = _route().load_executors()
        info = executors.get(executor) or {}
        ref = info.get("model_ref") or ""
        return _route().load_models().get(ref, "") if ref else ""
    except Exception:  # noqa: BLE001 -- a probe must never crash on config
        return ""


def _run(argv: list[str], env) -> tuple[int, str]:
    try:
        done = subprocess.run(
            argv,
            capture_output=True,
            text=True,
            timeout=PROBE_TIMEOUT_SECONDS,
            env=dict(env),
            stdin=subprocess.DEVNULL,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return 127, str(exc)
    return done.returncode, (done.stdout or "") + (done.stderr or "")


def probe(executor: str, env=None) -> dict[str, str]:
    """Cheap offline check of one executor. Never raises.

    Returns {"status": ok|unavailable|unknown, "reason": ..., "detail": ...}.
    "unknown" means the check could not tell; callers treat it as available.
    """
    env = dict(_env(env))
    try:
        return _probe(executor, env)
    except Exception as exc:  # noqa: BLE001
        return {"status": "unknown", "reason": "", "detail": f"probe error: {exc}"}


def _missing(binary: str, hint: str) -> dict[str, str]:
    return {"status": "unavailable", "reason": "missing_binary", "detail": f"{binary} CLI not found{hint}"}


def _probe(executor: str, env) -> dict[str, str]:
    home = env.get("HOME") or os.path.expanduser("~")
    if executor == "claude":
        binary = _first_binary(env, "CLAUDE_BIN", "claude")
        if not binary:
            return _missing("claude", " (set CLAUDE_BIN)")
        return {"status": "ok", "reason": "", "detail": "claude CLI present (login is checked by its first run)"}
    if executor == "codex":
        binary = _first_binary(env, "CODEX_BIN", "codex")
        if not binary:
            return _missing("codex", " (set CODEX_BIN)")
        if env.get("OPENAI_API_KEY") or env.get("CODEX_API_KEY"):
            return {"status": "ok", "reason": "", "detail": "codex present with an API key in the environment"}
        rc, out = _run([binary, "login", "status"], env)
        lowered = out.lower()
        if "not logged in" in lowered:
            return {"status": "unavailable", "reason": "logged_out", "detail": "codex login status: Not logged in -- run 'codex login'"}
        if rc == 0 and "logged in" in lowered:
            return {"status": "ok", "reason": "", "detail": out.strip().splitlines()[0][:200] if out.strip() else "logged in"}
        return {"status": "unknown", "reason": "", "detail": "codex login status was inconclusive"}
    if executor == "cursor":
        binary = _first_binary(env, "CURSOR_AGENT_BIN", "agent", "cursor-agent")
        if not binary:
            return _missing("cursor agent", " (set CURSOR_AGENT_BIN)")
        if env.get("CURSOR_API_KEY"):
            return {"status": "ok", "reason": "", "detail": "cursor present with CURSOR_API_KEY"}
        return {"status": "unavailable", "reason": "missing_key", "detail": "headless cursor needs CURSOR_API_KEY; an interactive login does not grant -p access"}
    if executor == "opencode":
        binary = _first_binary(env, "OPENCODE_BIN", os.path.join(home, ".opencode", "bin", "opencode"), "opencode")
        if not binary:
            return _missing("opencode", " (set OPENCODE_BIN)")
        model = _model_for("opencode", env)
        provider = model.split("/", 1)[0] if "/" in model else ""
        if provider == "openrouter":
            if openrouter_key_present(env, opencode=True):
                return {"status": "ok", "reason": "", "detail": f"opencode present; OpenRouter key found for {model}"}
            return {"status": "unavailable", "reason": "missing_key", "detail": f"{model} needs an OpenRouter key: {openrouter_key_instructions(env)}"}
        data_home = env.get("XDG_DATA_HOME") or os.path.join(home, ".local", "share")
        auth = os.path.join(data_home, "opencode", "auth.json")
        try:
            with open(auth, encoding="utf-8") as fh:
                creds = json.load(fh)
        except (OSError, ValueError):
            return {"status": "unavailable", "reason": "logged_out", "detail": f"no opencode credentials at {auth} -- run 'opencode auth login'"}
        entry = creds.get(provider) if isinstance(creds, dict) and provider else None
        if provider and not isinstance(entry, dict):
            return {"status": "unavailable", "reason": "logged_out", "detail": f"opencode has no '{provider}' credentials -- run 'opencode auth login'"}
        expires = entry.get("expires") if isinstance(entry, dict) else None
        if isinstance(expires, (int, float)) and expires < time.time() * 1000:
            return {"status": "unavailable", "reason": "logged_out", "detail": f"opencode '{provider}' credentials expired -- run 'opencode auth login'"}
        return {"status": "ok", "reason": "", "detail": "opencode present with credentials on disk"}
    if executor == "deepseek":
        binary = _first_binary(env, "DSH_BIN", "dsh")
        if not binary:
            return _missing("dsh", " (set DSH_BIN)")
        if not env.get("DEEPSEEK_API_KEY"):
            return {"status": "unavailable", "reason": "missing_key", "detail": "DEEPSEEK_API_KEY is unset"}
        return {"status": "ok", "reason": "", "detail": "dsh present with DEEPSEEK_API_KEY"}
    if executor in ("pi", "hermes"):
        override = "PI_BIN" if executor == "pi" else "HERMES_BIN"
        binary = _first_binary(env, override, executor)
        if not binary:
            return _missing(executor, f" (set {override})")
        model = _model_for(executor, env)
        if model.startswith("openrouter/") and not openrouter_key_present(env):
            return {"status": "unavailable", "reason": "missing_key", "detail": f"{model} needs an OpenRouter key: {openrouter_key_instructions(env)}"}
        return {"status": "ok", "reason": "", "detail": f"{executor} CLI present (login is checked by its first run)"}
    return {"status": "unknown", "reason": "", "detail": "no static probe for this executor"}


# ── evaluation ─────────────────────────────────────────────────────────


def evaluate(
    executor: str,
    *,
    probe_stale: bool = True,
    force_probe: bool = False,
    probe_missing: bool = False,
    path: str | None = None,
    env=None,
    now: float | None = None,
) -> dict[str, Any]:
    """Decide whether ``executor`` may take work now.

    The result always has ``available`` (bool). Order of evidence:
    a forced probe; a fresh record; a re-probe of a stale ``unavailable``
    record (or of a missing one, with ``probe_missing``); otherwise available
    (no evidence of an outage).
    """
    env = _env(env)
    target = path or health_file(env)
    stamp = _now(now)
    base = {"executor": executor, "status": "unknown", "reason": "", "detail": "", "source": "none",
            "checked_at": None, "recheck_after": None, "fresh": False}
    if not health_enabled(env):
        return {**base, "available": True, "detail": "health routing disabled (LEGION_HEALTH=off)"}

    if not force_probe:
        entry = load(target)["executors"].get(executor)
        if isinstance(entry, dict) and entry.get("status") in ("ok", "unavailable"):
            recheck = _epoch(entry.get("recheck_after"))
            fresh = recheck is not None and stamp < recheck
            merged = {**base, **{k: entry.get(k) for k in ("status", "reason", "detail", "source", "checked_at", "recheck_after")}}
            merged["fresh"] = fresh
            if fresh:
                merged["available"] = entry.get("status") != "unavailable"
                return merged
            if entry.get("status") != "unavailable" or not probe_stale:
                # A stale ok, or a stale outage we may not re-probe: not evidence.
                merged["available"] = True
                return merged
        elif not probe_missing:
            return {**base, "available": True}

    result = probe(executor, env)
    out = {**base, "status": result["status"], "reason": result["reason"],
           "detail": result["detail"], "source": "probe", "checked_at": _iso(stamp)}
    if result["status"] != "unavailable":
        # A static probe cannot see a spent quota, and for some executors not
        # an expired login either, so "probe passed" never clears an outage a
        # RUN recorded while that record is still fresh. A probe that finds an
        # outage always wins: it is the stronger evidence.
        entry = load(target)["executors"].get(executor)
        recheck = _epoch(entry.get("recheck_after")) if isinstance(entry, dict) else None
        if (
            isinstance(entry, dict)
            and entry.get("status") == "unavailable"
            and entry.get("source") == "run"
            and recheck is not None
            and stamp < recheck
        ):
            kept = {**base, **{k: entry.get(k) for k in ("status", "reason", "detail", "source", "checked_at", "recheck_after")}}
            kept["fresh"] = True
            kept["available"] = False
            kept["detail"] = (
                f"{entry.get('detail') or 'recorded by a failed run'} (learned from a run; "
                f"rechecked after {entry.get('recheck_after')}, or clear it with "
                f"'legion-health reset {executor}')"
            )
            return kept
    if result["status"] in ("ok", "unavailable"):
        stored = record(executor, result["status"], result["reason"], result["detail"],
                        "probe", path=target, now=stamp, env=env)
        out.update(stored)
        out["fresh"] = True
    out["available"] = result["status"] != "unavailable"
    return out


def coding_executors(env=None) -> list[str]:
    try:
        executors = _route().load_executors()
    except Exception:  # noqa: BLE001
        return list(DEFAULT_FALLBACK_ORDER)
    out = []
    for name, info in executors.items():
        if isinstance(info, dict) and "coding" in str(info.get("kind", "")).split():
            out.append(name)
    return out


def _as_list(value: Any) -> list[str]:
    if isinstance(value, (list, tuple)):
        return [str(item) for item in value if isinstance(item, str) and item]
    if isinstance(value, str) and value.strip().startswith("["):
        import ast

        try:
            parsed = ast.literal_eval(value.strip())
        except (SyntaxError, ValueError):
            return []
        return _as_list(parsed)
    return []


def fallback_order(routing: str | None = None, env=None) -> list[str]:
    env = _env(env)
    explicit = env.get("LEGION_HEALTH_FALLBACK_ORDER")
    if explicit:
        return [part.strip() for part in explicit.split(",") if part.strip()]
    route = _route()
    path = routing or env.get("LEGION_ROUTING_FILE") or route._DEFAULT_FILE
    try:
        table = route.load_table(path)
    except (OSError, ValueError):
        return list(DEFAULT_FALLBACK_ORDER)
    section = table.get("health") if isinstance(table, dict) else None
    order = _as_list(section.get("fallback_order")) if isinstance(section, dict) else []
    return order or list(DEFAULT_FALLBACK_ORDER)


def _model_ref_resolves(executor: str) -> bool:
    """Whether the active models file can run this executor at all.

    A repository that pins a Claude-only models file has no Codex roles; the
    fallback must not route work to an executor that file leaves out.
    """
    route = _route()
    try:
        info = route.load_executors().get(executor)
        if not isinstance(info, dict):
            return False
        if "coding" not in str(info.get("kind", "")).split() or not info.get("adapter"):
            return False
        ref = info.get("model_ref") or ""
        return bool(ref) and bool(route.load_models().get(ref))
    except Exception:  # noqa: BLE001
        return False


def pick(
    exclude: list[str] | tuple[str, ...] = (),
    *,
    order: list[str] | None = None,
    routing: str | None = None,
    path: str | None = None,
    env=None,
    now: float | None = None,
) -> dict[str, Any]:
    """First healthy executor in the fallback order, skipping ``exclude``.

    Returns {"executor": name-or-"", "skipped": [{executor, reason}]}.
    """
    skipped = []
    for name in order or fallback_order(routing, env):
        if name in exclude or name == "self":
            continue
        if not _model_ref_resolves(name):
            skipped.append({"executor": name, "reason": "no_model_role"})
            continue
        verdict = evaluate(name, path=path, env=env, now=now)
        if verdict["available"]:
            return {"executor": name, "skipped": skipped}
        skipped.append({"executor": name, "reason": verdict.get("reason") or "unavailable"})
    return {"executor": "", "skipped": skipped}


def observe(
    executor: str,
    run_status: str,
    *,
    reason_hint: str = "",
    texts: list[str] | None = None,
    default_reason: str = "",
    path: str | None = None,
    env=None,
) -> dict[str, Any] | None:
    """Fold one finished run into the health record.

    A usable run marks the executor ok. A failure marks it unavailable only when
    the adapter named the cause (``reason_hint``) or its error text matches the
    outage vocabulary; any other failure is the task's problem, not the
    executor's, and leaves the record alone -- unless the caller already knows
    the executor could not be reached (``default_reason``).
    """
    if not health_enabled(env):
        return None
    family = executor.split("-", 1)[0]
    if run_status in ("ok", "over_budget"):
        return record(family, "ok", source="run", path=path, env=env)
    reason = reason_hint if reason_hint in REASONS else ""
    if not reason:
        for text in texts or ():
            reason = classify_text(text)
            if reason:
                break
    if not reason and default_reason in REASONS:
        reason = default_reason
    if not reason:
        return None
    detail = ""
    for text in texts or ():
        for line in str(text).splitlines():
            if classify_text(line):
                detail = line.strip()[:300]
                break
        if detail:
            break
    return record(family, "unavailable", reason, detail or f"run ended {run_status}", "run", path=path, env=env)
