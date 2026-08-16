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
import subprocess
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
    "LEGION_PROJECT_LEARNING_DIR",
    "LEGION_GLOBAL_LEARNING_DIR",
}


def default_log_root(env: dict[str, str] | None = None) -> str:
    """Harness-neutral GLOBAL log/telemetry root for the cross-repo tools
    (router, console, activity, aggregate).

    Legion began Claude-primary and wrote under ~/.claude/logs/legion — a Claude
    Code directory. To be harness-generic without stranding an existing install's
    history, resolve in this order:
      $LEGION_LOG_ROOT  ->  $XDG_STATE_HOME/legion  ->  an EXISTING
      ~/.claude/logs/legion (back-compat)  ->  $LEGION_HOME/logs (default
      ~/.legion/logs, so a non-Claude primary never writes into ~/.claude).
    """
    env = os.environ if env is None else env
    explicit = env.get("LEGION_LOG_ROOT")
    if explicit:
        return _abs(explicit)
    xdg = env.get("XDG_STATE_HOME")
    if xdg:
        return _abs(os.path.join(xdg, "legion"))
    # Resolve HOME once from the given env (only falling back to the process home
    # when env has no HOME), then build the HOME-derived paths by plain join +
    # abspath — NOT _abs/expanduser, which would re-consult os.environ and make
    # the result depend on the process env instead of the passed `env`.
    home = env.get("HOME") or os.path.expanduser("~")
    legacy = os.path.abspath(os.path.join(home, ".claude", "logs", "legion"))
    if os.path.isdir(legacy):
        return legacy
    legion_home = env.get("LEGION_HOME") or os.path.join(home, ".legion")
    return os.path.abspath(os.path.join(legion_home, "logs"))


def _abs(path: str, base: str | None = None) -> str:
    expanded = os.path.expanduser(os.path.expandvars(path))
    if not os.path.isabs(expanded):
        expanded = os.path.join(base or os.getcwd(), expanded)
    return os.path.abspath(expanded)


def _slug(text: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return slug or "repo"


def _normalize_remote(remote: str) -> str:
    """Return a credential-free, clone-independent repository identity."""
    value = remote.strip()
    if not value:
        return ""
    value = re.sub(r"^[a-z][a-z0-9+.-]*://", "", value, flags=re.IGNORECASE)
    value = re.sub(r"^[^/@]+@", "", value)
    if re.match(r"^[^/:]+:[^/].*", value):
        value = value.replace(":", "/", 1)
    value = value.split("?", 1)[0].split("#", 1)[0]
    value = value.rstrip("/")
    if value.lower().endswith(".git"):
        value = value[:-4]
    return value.lower()


def repository_identity(repo: str) -> str:
    repo_abs = os.path.abspath(os.path.expanduser(repo))
    try:
        result = subprocess.run(
            ["git", "-C", repo_abs, "config", "--get", "remote.origin.url"],
            check=False,
            capture_output=True,
            text=True,
            timeout=3,
        )
        identity = _normalize_remote(result.stdout) if result.returncode == 0 else ""
        if identity:
            return identity
    except (OSError, subprocess.SubprocessError, UnicodeError):
        pass
    return repo_abs


def project_id(repo: str) -> str:
    repo_abs = os.path.abspath(os.path.expanduser(repo))
    digest = hashlib.sha256(repo_abs.encode("utf-8")).hexdigest()[:12]
    return f"{_slug(os.path.basename(repo_abs))}-{digest}"


def _linked_worktree_main(repo: str) -> str | None:
    """Return the owning checkout for a linked Git worktree, if detectable.

    State resolution is on every Legion command's hot path, so Git discovery is
    deliberately best-effort. Unsupported Git versions, unreadable repositories,
    malformed output, timeouts, and non-Git directories all preserve the legacy
    path-keyed behavior.
    """
    repo_abs = os.path.abspath(os.path.expanduser(repo))
    try:
        result = subprocess.run(
            [
                "git",
                "-C",
                repo_abs,
                "rev-parse",
                "--path-format=absolute",
                "--git-dir",
                "--git-common-dir",
            ],
            check=False,
            capture_output=True,
            text=True,
            timeout=3,
        )
    except (OSError, subprocess.SubprocessError, UnicodeError):
        return None

    if result.returncode != 0 or not isinstance(result.stdout, str):
        return None
    paths = result.stdout.splitlines()
    if len(paths) != 2 or not all(os.path.isabs(path) for path in paths):
        return None
    git_dir, common_dir = (os.path.normpath(path) for path in paths)
    if git_dir == common_dir:
        return None
    return os.path.dirname(common_dir)


def repository_project_id(repo: str, identity: str | None = None) -> str:
    """Return a clone-independent project ID for cross-repository learning."""
    repo_abs = os.path.abspath(os.path.expanduser(repo))
    stable_identity = identity or repository_identity(repo_abs)
    digest = hashlib.sha256(stable_identity.encode("utf-8")).hexdigest()[:12]
    name = stable_identity.rstrip("/").rsplit("/", 1)[-1] if stable_identity else ""
    return f"{_slug(name or os.path.basename(repo_abs))}-{digest}"


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
    identity = repository_identity(repo_abs)
    # Linked worktrees are transient children of one physical checkout. Keep
    # runtime state path-keyed, but key those children to their owning checkout
    # so their spans and registries survive worktree cleanup.
    path_project_id = project_id(_linked_worktree_main(repo_abs) or repo_abs)
    stable_repository_project_id = repository_project_id(repo_abs, identity)
    config_file = _config_path(repo_abs, env)
    config = _read_config(config_file)
    legion_home = _abs(env.get("LEGION_HOME", os.path.join(env.get("HOME", "~"), ".legion")))

    configured_root = _configured_root(repo_abs, config)
    if env.get("LEGION_STATE_ROOT"):
        state_root = _abs(env["LEGION_STATE_ROOT"], repo_abs)
        source = "env"
    elif configured_root:
        state_root = configured_root
        source = "config"
    else:
        state_root = os.path.join(legion_home, "projects", path_project_id)
        source = "auto"

    reports_root = (
        _abs(env["LEGION_REPORTS_DIR"], repo_abs)
        if env.get("LEGION_REPORTS_DIR")
        else _configured_reports(repo_abs, config) or os.path.join(state_root, "reports")
    )
    path_project_learning_dir = os.path.join(state_root, "learning")
    # Runtime artifacts remain checkout-local because worktrees, run registries,
    # and spans describe one physical checkout. Learned guidance is different:
    # it is keyed by repository identity so the installer/source clone and every
    # user checkout of the same remote consume one shared project memory.
    # Explicit/configured state roots retain their historical all-in-one layout.
    default_project_learning_dir = (
        os.path.join(legion_home, "projects", stable_repository_project_id, "learning")
        if source == "auto"
        else path_project_learning_dir
    )

    return {
        "repo": repo_abs,
        "repository_identity": identity,
        "repository_project_id": stable_repository_project_id,
        "project_id": path_project_id,
        "source": source,
        "config_file": config_file if os.path.exists(config_file) else "",
        "state_root": state_root,
        "telemetry_dir": _abs(env.get("LEGION_TELEMETRY_DIR") or os.path.join(state_root, "spans"), repo_abs),
        "registry_dir": _abs(env.get("LEGION_REGISTRY_DIR") or os.path.join(state_root, "registry"), repo_abs),
        "repos_file": _abs(env.get("LEGION_REPOS_FILE") or os.path.join(state_root, "repos.jsonl"), repo_abs),
        "bench_dir": _abs(env.get("LEGION_BENCH_DIR") or os.path.join(state_root, "bench"), repo_abs),
        "reports_dir": reports_root,
        "project_learning_dir": _abs(
            env.get("LEGION_PROJECT_LEARNING_DIR") or default_project_learning_dir,
            repo_abs,
        ),
        # Read-only compatibility source for typed hints written before project
        # learning became clone-independent. New writes use project_learning_dir.
        "path_project_learning_dir": _abs(path_project_learning_dir, repo_abs),
        "global_learning_dir": _abs(
            env.get("LEGION_GLOBAL_LEARNING_DIR")
            or os.path.join(legion_home, "global", "learning"),
            repo_abs,
        ),
    }


def _recorded_repo_paths(project_dir: str) -> list[str]:
    """Read repository roots recorded in one project state directory."""
    paths: list[str] = []
    seen: set[str] = set()

    def add(value: Any) -> None:
        if isinstance(value, str) and value and value not in seen:
            seen.add(value)
            paths.append(value)

    repos_file = os.path.join(project_dir, "repos.jsonl")
    try:
        with open(repos_file, encoding="utf-8") as handle:
            for line in handle:
                try:
                    add(json.loads(line).get("repo_root"))
                except (json.JSONDecodeError, AttributeError):
                    continue
    except (OSError, UnicodeError):
        pass

    # Older and interrupted runs may have a registry record without ever
    # appending repos.jsonl. Use that metadata only when the canonical record is
    # absent, keeping this opt-in scan bounded on mature stores.
    if paths:
        return paths
    registry_dir = os.path.join(project_dir, "registry")
    try:
        with os.scandir(registry_dir) as iterator:
            entries = sorted(iterator, key=lambda entry: entry.name)
    except OSError:
        return paths
    for entry in entries:
        try:
            if not entry.is_file(follow_symlinks=False) or not entry.name.endswith(".json"):
                continue
            with open(entry.path, encoding="utf-8") as handle:
                add(json.load(handle).get("repo_root"))
        except (OSError, UnicodeError, json.JSONDecodeError, AttributeError):
            continue
    return paths


def _path_exists(path: str) -> bool | None:
    """Return None rather than misclassifying an unreadable path as missing."""
    try:
        os.stat(path)
        return True
    except (FileNotFoundError, NotADirectoryError):
        return False
    except OSError:
        return None


def _ephemeral_worktree_reason(path: str, *, inspect_git: bool) -> str | None:
    normalized = path.replace("\\", "/").rstrip("/") + "/"
    if "/.legion/worktrees/" in normalized or "/improve/worktrees/" in normalized:
        return "ephemeral_worktree_path"
    if inspect_git and _linked_worktree_main(path):
        return "linked_git_worktree"
    return None


def _directory_size(path: str) -> int:
    """Return the apparent size of files below path without following links."""
    total = 0
    pending = [path]
    while pending:
        current = pending.pop()
        try:
            entries = os.scandir(current)
        except OSError:
            continue
        with entries:
            for entry in entries:
                try:
                    if entry.is_dir(follow_symlinks=False):
                        pending.append(entry.path)
                    else:
                        total += entry.stat(follow_symlinks=False).st_size
                except OSError:
                    continue
    return total


def orphaned_project_report(env: dict[str, str] | None = None) -> dict[str, Any]:
    """Describe orphaned/per-worktree auto state without modifying it."""
    env = dict(os.environ if env is None else env)
    legion_home = _abs(
        env.get("LEGION_HOME", os.path.join(env.get("HOME", "~"), ".legion"))
    )
    projects_dir = os.path.join(legion_home, "projects")
    projects: list[dict[str, Any]] = []
    try:
        with os.scandir(projects_dir) as iterator:
            entries = sorted(iterator, key=lambda entry: entry.name)
    except OSError:
        entries = []

    for entry in entries:
        try:
            if not entry.is_dir(follow_symlinks=False):
                continue
        except OSError:
            continue
        repo_paths = _recorded_repo_paths(entry.path)
        statuses = {path: _path_exists(path) for path in repo_paths}
        missing_paths = [path for path, exists in statuses.items() if exists is False]
        ephemeral_paths: list[str] = []
        ephemeral_reasons: set[str] = set()
        for path, exists in statuses.items():
            reason = _ephemeral_worktree_reason(path, inspect_git=exists is True)
            if reason:
                ephemeral_paths.append(path)
                ephemeral_reasons.add(reason)

        reasons = sorted(ephemeral_reasons)
        if statuses and all(exists is False for exists in statuses.values()):
            reasons.insert(0, "recorded_repo_missing")
        if not reasons:
            continue

        projects.append(
            {
                "project_id": entry.name,
                "path": entry.path,
                "recorded_repo_paths": repo_paths,
                "missing_repo_paths": missing_paths,
                "ephemeral_repo_paths": ephemeral_paths,
                "reasons": reasons,
                "size_bytes": _directory_size(entry.path),
            }
        )

    return {
        "projects_dir": projects_dir,
        "orphan_count": len(projects),
        "total_size_bytes": sum(project["size_bytes"] for project in projects),
        "projects": projects,
        "read_only": True,
    }


def _human_size(size: int) -> str:
    value = float(size)
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if value < 1024 or unit == "TiB":
            return f"{int(value)} {unit}" if unit == "B" else f"{value:.1f} {unit}"
        value /= 1024
    return f"{size} B"  # pragma: no cover - loop always returns


def render_orphaned_project_report(report: dict[str, Any]) -> str:
    lines = [f"Orphaned per-worktree project state under {report['projects_dir']}:"]
    projects = report["projects"]
    if not projects:
        lines.append("  none found")
    for project in projects:
        lines.append(
            f"- {project['path']} ({_human_size(project['size_bytes'])}, "
            f"{project['size_bytes']} bytes)"
        )
        lines.append(f"  reason: {', '.join(project['reasons'])}")
        for repo_path in project["recorded_repo_paths"]:
            lines.append(f"  repo: {repo_path}")
    noun = "directory" if report["orphan_count"] == 1 else "directories"
    lines.append(
        f"Found {report['orphan_count']} {noun} totaling "
        f"{_human_size(report['total_size_bytes'])} "
        f"({report['total_size_bytes']} bytes)."
    )
    lines.append("Read-only report: no files were deleted, merged, or moved.")
    return "\n".join(lines)


def shell_exports(state: dict[str, str]) -> str:
    mapping = {
        "LEGION_STATE_ROOT": state["state_root"],
        "LEGION_TELEMETRY_DIR": state["telemetry_dir"],
        "LEGION_REGISTRY_DIR": state["registry_dir"],
        "LEGION_REPOS_FILE": state["repos_file"],
        "LEGION_BENCH_DIR": state["bench_dir"],
        "LEGION_REPORTS_DIR": state["reports_dir"],
        "LEGION_PROJECT_LEARNING_DIR": state["project_learning_dir"],
        "LEGION_GLOBAL_LEARNING_DIR": state["global_learning_dir"],
        "LEGION_PROJECT_ID": state["project_id"],
        "LEGION_REPOSITORY_PROJECT_ID": state["repository_project_id"],
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
    parser.add_argument("--log-root", action="store_true",
                        help="print the harness-neutral global log root and exit")
    parser.add_argument(
        "--report-orphans",
        action="store_true",
        help=(
            "report orphaned/per-worktree state under $LEGION_HOME/projects "
            "(default ~/.legion/projects) and its total size; never modify it"
        ),
    )
    args = parser.parse_args(argv)

    if args.log_root:
        print(default_log_root())
        return 0
    if args.report_orphans:
        report = orphaned_project_report()
        print(
            json.dumps(report, indent=2, sort_keys=True)
            if args.json
            else render_orphaned_project_report(report)
        )
        return 0

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
