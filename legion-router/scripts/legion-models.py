#!/usr/bin/env python3
"""legion-models — keep models.toml current against each provider's model list.

  legion-models check [--fetch | --offline] [--json] [--models-file F]

Every role in models.toml names a concrete model id. A provider retires ids, and
nothing in Legion noticed until a delegated run failed on one. `check` compares
each id with the provider's published list:

  anthropic, openai, deepseek, xai   models.dev (https://models.dev/api.json)
  openrouter/<vendor>/<model>        OpenRouter (https://openrouter.ai/api/v1/models)
  cursor ids                         no published list: reported "unverifiable"

`--fetch` downloads the lists (public, no credentials) into
$LEGION_HOME/models-cache/ and checks against them; the default `--offline`
uses that cache only, so legion-doctor never touches the network. The daily
refresh runs `--fetch`. Exit 1 when a configured id is missing from its
provider's list, 0 otherwise.

Overrides (tests, mirrors): LEGION_MODELS_DEV_URL, LEGION_OPENROUTER_MODELS_URL,
LEGION_MODELS_CACHE_DIR.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import sys
import tempfile
import time
import urllib.request
from datetime import datetime, timezone

_HERE = os.path.dirname(os.path.abspath(__file__))
MODELS_DEV_URL = "https://models.dev/api.json"
OPENROUTER_URL = "https://openrouter.ai/api/v1/models"
FETCH_TIMEOUT_SECONDS = 30
STALE_AFTER_DAYS = 7
# models.dev provider keys for the vendors whose ids the catalog uses directly.
MODELS_DEV_PROVIDERS = ("anthropic", "openai", "deepseek", "xai")
UNVERIFIABLE = ("cursor",)


def _route():
    path = os.path.join(_HERE, "legion-route.py")
    spec = importlib.util.spec_from_file_location("legion_route_for_models", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _age_days(stamp) -> float | None:
    if not isinstance(stamp, str):
        return None
    try:
        parsed = datetime.fromisoformat(stamp.replace("Z", "+00:00"))
    except ValueError:
        return None
    return (datetime.now(timezone.utc) - parsed).total_seconds() / 86400


def cache_dir(env=None) -> str:
    env = os.environ if env is None else env
    if env.get("LEGION_MODELS_CACHE_DIR"):
        return os.path.abspath(os.path.expanduser(env["LEGION_MODELS_CACHE_DIR"]))
    home = env.get("HOME") or os.path.expanduser("~")
    legion_home = env.get("LEGION_HOME") or os.path.join(home, ".legion")
    return os.path.join(os.path.abspath(os.path.expanduser(legion_home)), "models-cache")


def provider_of(model_id: str) -> tuple[str, str]:
    """(provider, id as that provider lists it) for one catalog id."""
    if model_id.startswith("openrouter/"):
        return "openrouter", model_id[len("openrouter/"):]
    if "/" in model_id:
        vendor, rest = model_id.split("/", 1)
        return vendor, rest
    if model_id.startswith("claude-"):
        return "anthropic", model_id
    if re.match(r"(?:gpt-|o\d)", model_id):
        return "openai", model_id
    if model_id.startswith("deepseek-"):
        return "deepseek", model_id
    if model_id.startswith("grok-"):
        return "xai", model_id
    if model_id.startswith(("cursor-", "composer-")):
        return "cursor", model_id
    return "unknown", model_id


def _fetch_json(url: str, user_agent: str = ""):
    # The two edges filter User-Agents differently: models.dev refuses urllib's
    # default one and OpenRouter refuses unfamiliar ones, so each source passes
    # what it accepts ("" keeps urllib's default).
    headers = {"Accept": "application/json"}
    if user_agent:
        headers["User-Agent"] = user_agent
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=FETCH_TIMEOUT_SECONDS) as response:  # noqa: S310 - fixed public URLs or explicit override
        return json.loads(response.read().decode("utf-8"))


def _write_cache(directory: str, name: str, payload: dict) -> None:
    os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=f".{name}.", suffix=".json", dir=directory)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, sort_keys=True)
    os.replace(tmp, os.path.join(directory, f"{name}.json"))


def _read_cache(directory: str, name: str) -> dict | None:
    try:
        with open(os.path.join(directory, f"{name}.json"), encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def fetch(directory: str, env=None) -> dict:
    """Refresh both provider lists. Returns {source: error-or-""}."""
    env = os.environ if env is None else env
    errors = {}
    url = env.get("LEGION_MODELS_DEV_URL") or MODELS_DEV_URL
    try:
        raw = _fetch_json(url, "legion-models/1.0")
        providers = {}
        for key in MODELS_DEV_PROVIDERS + ("openrouter",):
            models = (raw.get(key) or {}).get("models") if isinstance(raw, dict) else None
            if isinstance(models, dict):
                providers[key] = sorted(models)
        if not providers:
            raise ValueError("no provider lists in the response")
        _write_cache(directory, "models-dev", {"url": url, "fetched_at": _now_iso(), "providers": providers})
        errors["models-dev"] = ""
    except Exception as exc:  # noqa: BLE001 - one source failing must not stop the other
        errors["models-dev"] = f"{type(exc).__name__}: {exc}"
    url = env.get("LEGION_OPENROUTER_MODELS_URL") or OPENROUTER_URL
    try:
        raw = _fetch_json(url)
        ids = sorted(item["id"] for item in raw.get("data", []) if isinstance(item, dict) and isinstance(item.get("id"), str))
        if not ids:
            raise ValueError("no model ids in the response")
        _write_cache(directory, "openrouter", {"url": url, "fetched_at": _now_iso(), "ids": ids})
        errors["openrouter"] = ""
    except Exception as exc:  # noqa: BLE001
        errors["openrouter"] = f"{type(exc).__name__}: {exc}"
    return errors


def check(models: dict, directory: str, fetch_errors: dict | None = None) -> dict:
    models_dev = _read_cache(directory, "models-dev") or {}
    openrouter = _read_cache(directory, "openrouter") or {}
    lists: dict[str, set] = {}
    for key, ids in (models_dev.get("providers") or {}).items():
        if isinstance(ids, list):
            lists[key] = set(ids)
    if isinstance(openrouter.get("ids"), list):
        # OpenRouter's own catalogue is authoritative for openrouter/ ids.
        lists["openrouter"] = set(openrouter["ids"])
    roles = []
    for role, model in sorted(models.items()):
        if not isinstance(model, str) or not model:
            continue
        provider, listed = provider_of(model)
        if provider in UNVERIFIABLE or provider == "unknown":
            status = "unverifiable"
        elif provider not in lists:
            status = "unchecked"
        else:
            status = "current" if listed in lists[provider] else "missing"
        roles.append({"role": role, "model": model, "provider": provider, "status": status})
    sources = {
        "models-dev": {"fetched_at": models_dev.get("fetched_at"), "url": models_dev.get("url")},
        "openrouter": {"fetched_at": openrouter.get("fetched_at"), "url": openrouter.get("url")},
    }
    for name, info in sources.items():
        age = _age_days(info["fetched_at"])
        info["age_days"] = None if age is None else round(age, 2)
        info["stale"] = age is None or age > STALE_AFTER_DAYS
        if fetch_errors and fetch_errors.get(name):
            info["fetch_error"] = fetch_errors[name]
    counts = {}
    for row in roles:
        counts[row["status"]] = counts.get(row["status"], 0) + 1
    return {
        "schema": "legion.model-currency.v1",
        "checked_at": _now_iso(),
        "cache_dir": directory,
        "sources": sources,
        "counts": counts,
        "missing": [row for row in roles if row["status"] == "missing"],
        "roles": roles,
    }


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="legion-models", description="Check models.toml ids against provider lists.")
    sub = parser.add_subparsers(dest="cmd", required=True)
    p_check = sub.add_parser("check", help="compare every configured id with its provider's list")
    mode = p_check.add_mutually_exclusive_group()
    mode.add_argument("--fetch", action="store_true", help="download the provider lists first")
    mode.add_argument("--offline", action="store_true", help="use the cached lists only (default)")
    p_check.add_argument("--json", action="store_true")
    p_check.add_argument("--models-file", default=None)
    args = parser.parse_args(argv)

    directory = cache_dir()
    fetch_errors = fetch(directory) if args.fetch else None
    try:
        models = _route().load_models(args.models_file)
    except Exception as exc:  # noqa: BLE001
        print(f"legion-models: cannot read models.toml: {exc}", file=sys.stderr)
        return 2
    report = check(models, directory, fetch_errors)
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        for name, info in report["sources"].items():
            when = info["fetched_at"] or "never fetched"
            note = f" (fetch failed: {info['fetch_error']})" if info.get("fetch_error") else ""
            print(f"source {name}: {when}{note}")
        for row in report["roles"]:
            if row["status"] != "current":
                print(f"{row['status']:<12} {row['role']} = {row['model']} ({row['provider']})")
        summary = ", ".join(f"{n} {k}" for k, n in sorted(report["counts"].items()))
        print(f"legion-models: {summary}")
    return 1 if report["missing"] else 0


if __name__ == "__main__":
    sys.exit(main())
