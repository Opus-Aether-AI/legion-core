#!/usr/bin/env python3
"""Shared Legion runtime state resolver.

The public UX is intentionally zero-config: install Legion once, run it from any
repo, and all telemetry/reports/bench/self-learn data lands in a stable global
project state directory. Env vars and optional config files still override that
default for CI and advanced setups.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shlex
from typing import Any

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover - Python < 3.11
    tomllib = None


STATE_KEYS = {
    "LEGION_STATE_ROOT",
    "LEGION_TELEMETRY_DIR",
    "LEGION_REGISTRY_DIR",
    "LEGION_REPOS_FILE",
    "LEGION_BENCH_DIR",
    "LEGION_REPORTS_DIR",
}


def _abs(path: str, base: str | None = None) -> str:
    expanded = os.path.expanduser(os.path.expandvars(path))
    if not os.path.isabs(expanded):
        expanded = os.path.join(base or os.getcwd(), expanded)
    return os.path.abspath(expanded)


def _slug(text: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return slug or "repo"


def project_id(repo: str) -> str:
    repo_abs = os.path.abspath(os.path.expanduser(repo))
    digest = hashlib.sha256(repo_abs.encode("utf-8")).hexdigest()[:12]
    return f"{_slug(os.path.basename(repo_abs))}-{digest}"


def _simple_toml(path: str) -> dict[str, Any]:
    current: str | None = None
    data: dict[str, Any] = {}
    try:
        with open(path, encoding="utf-8") as handle:
            for raw in handle:
                line = raw.split("#", 1)[0].strip()
                if not line:
                    continue
                if line.startswith("[") and line.endswith("]"):
                    current = line[1:-1].strip()
                    data.setdefault(current, {})
                    continue
                if current and "=" in line:
                    key, value = line.split("=", 1)
                    value = value.strip()
                    if (
                        len(value) >= 2
                        and value[0] == value[-1]
                        and value[0] in {"'", '"'}
                    ):
                        value = value[1:-1]
                    data[current][key.strip()] = value
    except OSError:
        return {}
    return data


def _read_config(path: str) -> dict[str, Any]:
    if not path or not os.path.exists(path):
        return {}
    if tomllib:
        try:
            with open(path, "rb") as handle:
                data = tomllib.load(handle)
            return data if isinstance(data, dict) else {}
        except (OSError, ValueError, TypeError):
            return {}
    return _simple_toml(path)


def _config_path(repo: str, env: dict[str, str]) -> str:
    explicit = env.get("LEGION_CONFIG_FILE", "")
    if explicit:
        return _abs(explicit, repo)
    repo_config = os.path.join(repo, ".legion", "config.toml")
    if os.path.exists(repo_config):
        return repo_config
    global_config = os.path.join(
        env.get("XDG_CONFIG_HOME", os.path.join(env.get("HOME", "~"), ".config")),
        "legion",
        "config.toml",
    )
    return _abs(global_config)


def _configured_root(repo: str, config: dict[str, Any]) -> str:
    state = config.get("state") if isinstance(config.get("state"), dict) else {}
    value = state.get("root") if isinstance(state, dict) else ""
    return _abs(str(value), repo) if value else ""


def _configured_reports(repo: str, config: dict[str, Any]) -> str:
    reports = config.get("reports") if isinstance(config.get("reports"), dict) else {}
    value = reports.get("root") if isinstance(reports, dict) else ""
    return _abs(str(value), repo) if value else ""


def resolve_state(repo: str | None = None, env: dict[str, str] | None = None) -> dict[str, str]:
    env = dict(os.environ if env is None else env)
    repo_abs = _abs(repo or os.getcwd())
    config_file = _config_path(repo_abs, env)
    config = _read_config(config_file)

    configured_root = _configured_root(repo_abs, config)
    if env.get("LEGION_STATE_ROOT"):
        state_root = _abs(env["LEGION_STATE_ROOT"], repo_abs)
        source = "env"
    elif configured_root:
        state_root = configured_root
        source = "config"
    else:
        legion_home = _abs(env.get("LEGION_HOME", os.path.join(env.get("HOME", "~"), ".legion")))
        state_root = os.path.join(legion_home, "projects", project_id(repo_abs))
        source = "auto"

    reports_root = (
        _abs(env["LEGION_REPORTS_DIR"], repo_abs)
        if env.get("LEGION_REPORTS_DIR")
        else _configured_reports(repo_abs, config) or os.path.join(state_root, "reports")
    )

    return {
        "repo": repo_abs,
        "project_id": project_id(repo_abs),
        "source": source,
        "config_file": config_file if os.path.exists(config_file) else "",
        "state_root": state_root,
        "telemetry_dir": _abs(env.get("LEGION_TELEMETRY_DIR") or os.path.join(state_root, "spans"), repo_abs),
        "registry_dir": _abs(env.get("LEGION_REGISTRY_DIR") or os.path.join(state_root, "registry"), repo_abs),
        "repos_file": _abs(env.get("LEGION_REPOS_FILE") or os.path.join(state_root, "repos.jsonl"), repo_abs),
        "bench_dir": _abs(env.get("LEGION_BENCH_DIR") or os.path.join(state_root, "bench"), repo_abs),
        "reports_dir": reports_root,
    }


def shell_exports(state: dict[str, str]) -> str:
    mapping = {
        "LEGION_STATE_ROOT": state["state_root"],
        "LEGION_TELEMETRY_DIR": state["telemetry_dir"],
        "LEGION_REGISTRY_DIR": state["registry_dir"],
        "LEGION_REPOS_FILE": state["repos_file"],
        "LEGION_BENCH_DIR": state["bench_dir"],
        "LEGION_REPORTS_DIR": state["reports_dir"],
        "LEGION_PROJECT_ID": state["project_id"],
    }
    return "\n".join(f"export {key}={shlex.quote(value)}" for key, value in mapping.items())


def _restore_default_sigpipe() -> None:
    """Die quietly (not with a BrokenPipeError traceback) when our stdout reader
    goes away — e.g. a shell capture that is abandoned, or `… | head`. Only
    meaningful as a CLI; guarded so importing this module never touches signals."""
    try:
        import signal

        signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    except (AttributeError, ValueError, OSError):  # no SIGPIPE (Windows) / not main thread
        pass


def main(argv: list[str] | None = None) -> int:
    _restore_default_sigpipe()
    parser = argparse.ArgumentParser(prog="legion-state")
    parser.add_argument("--repo", default=os.getcwd())
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--shell", action="store_true")
    parser.add_argument("--field", default="")
    args = parser.parse_args(argv)

    resolved = resolve_state(args.repo)
    if args.shell:
        print(shell_exports(resolved))
    elif args.field:
        print(resolved.get(args.field, ""))
    else:
        print(json.dumps(resolved, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
