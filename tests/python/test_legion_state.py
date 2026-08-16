import importlib.util
import json
import os
import subprocess
import sys

HERE = os.path.dirname(__file__)
PATH = os.path.join(
    HERE, "..", "..", "legion-observability", "scripts", "legion_state.py"
)
SPEC = importlib.util.spec_from_file_location("legion_state", PATH)
state = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(state)


def _init_committed_repo(repo):
    repo.mkdir()
    subprocess.run(["git", "init", "-q", str(repo)], check=True)
    subprocess.run(
        ["git", "-C", str(repo), "config", "user.email", "test@example.com"],
        check=True,
    )
    subprocess.run(
        ["git", "-C", str(repo), "config", "user.name", "Legion Test"],
        check=True,
    )
    (repo / "tracked.txt").write_text("tracked\n", encoding="utf-8")
    subprocess.run(["git", "-C", str(repo), "add", "tracked.txt"], check=True)
    subprocess.run(
        ["git", "-C", str(repo), "commit", "-qm", "initial"], check=True
    )


def test_resolve_state_defaults_to_global_project_root(tmp_path, monkeypatch):
    home = tmp_path / "home"
    repo = tmp_path / "My App"
    repo.mkdir()
    monkeypatch.setenv("HOME", str(home))
    for key in (
        "LEGION_STATE_ROOT",
        "LEGION_TELEMETRY_DIR",
        "LEGION_REGISTRY_DIR",
        "LEGION_REPOS_FILE",
        "LEGION_BENCH_DIR",
        "LEGION_REPORTS_DIR",
        "LEGION_PROJECT_LEARNING_DIR",
        "LEGION_GLOBAL_LEARNING_DIR",
        "LEGION_CONFIG_FILE",
    ):
        monkeypatch.delenv(key, raising=False)

    resolved = state.resolve_state(str(repo))

    assert resolved["source"] == "auto"
    assert resolved["project_id"] == state.project_id(str(repo))
    assert resolved["state_root"].startswith(str(home / ".legion" / "projects"))
    assert resolved["telemetry_dir"] == os.path.join(resolved["state_root"], "spans")
    assert resolved["registry_dir"] == os.path.join(resolved["state_root"], "registry")
    assert resolved["repos_file"] == os.path.join(resolved["state_root"], "repos.jsonl")
    assert resolved["bench_dir"] == os.path.join(resolved["state_root"], "bench")
    assert resolved["reports_dir"] == os.path.join(resolved["state_root"], "reports")
    assert resolved["project_learning_dir"] == os.path.join(
        resolved["state_root"], "learning"
    )
    assert resolved["global_learning_dir"] == os.path.join(
        str(home / ".legion"), "global", "learning"
    )


def test_linked_worktree_uses_main_checkout_project_id_and_honors_overrides(
    tmp_path,
):
    home = tmp_path / "home"
    main = tmp_path / "main-checkout"
    linked = tmp_path / "linked-worktree"
    _init_committed_repo(main)
    subprocess.run(
        ["git", "-C", str(main), "worktree", "add", "-q", "--detach", str(linked)],
        check=True,
    )

    main_state = state.resolve_state(str(main), {"HOME": str(home)})
    linked_state = state.resolve_state(str(linked), {"HOME": str(home)})

    assert (linked / ".git").is_file()
    assert linked_state["repo"] == str(linked)
    assert linked_state["project_id"] == state.project_id(str(main))
    assert linked_state["project_id"] == main_state["project_id"]
    assert linked_state["state_root"] == main_state["state_root"]

    explicit_root = tmp_path / "explicit-state"
    explicit = state.resolve_state(
        str(linked),
        {"HOME": str(home), "LEGION_STATE_ROOT": str(explicit_root)},
    )
    assert explicit["source"] == "env"
    assert explicit["state_root"] == str(explicit_root)
    assert explicit["project_id"] == state.project_id(str(main))

    config_dir = linked / ".legion"
    config_dir.mkdir()
    (config_dir / "config.toml").write_text(
        '[state]\nroot = ".legion/configured-state"\n', encoding="utf-8"
    )
    configured = state.resolve_state(str(linked), {"HOME": str(home)})
    assert configured["source"] == "config"
    assert configured["state_root"] == str(linked / ".legion/configured-state")
    assert configured["project_id"] == state.project_id(str(main))


def test_plain_clone_keeps_its_own_path_keyed_project_id(tmp_path):
    home = tmp_path / "home"
    repo = tmp_path / "ordinary-clone"
    _init_committed_repo(repo)

    resolved = state.resolve_state(str(repo), {"HOME": str(home)})

    assert state._linked_worktree_main(str(repo)) is None
    assert resolved["project_id"] == state.project_id(str(repo))
    assert resolved["state_root"] == str(
        home / ".legion" / "projects" / state.project_id(str(repo))
    )


def test_state_stays_path_keyed_while_repository_id_is_stable_across_clones(
    tmp_path,
):
    home = tmp_path / "home"
    first = tmp_path / "clone-one"
    second = tmp_path / "clone-two"
    for repo in (first, second):
        repo.mkdir()
        subprocess.run(["git", "init", "-q", str(repo)], check=True)
        subprocess.run(
            [
                "git",
                "-C",
                str(repo),
                "remote",
                "add",
                "origin",
                "https://github.com/Example/Shared.git",
            ],
            check=True,
        )

    first_state = state.resolve_state(str(first), {"HOME": str(home)})
    second_state = state.resolve_state(str(second), {"HOME": str(home)})

    assert first_state["project_id"].startswith("clone-one-")
    assert second_state["project_id"].startswith("clone-two-")
    assert first_state["project_id"] != second_state["project_id"]
    assert first_state["state_root"] == os.path.join(
        str(home / ".legion" / "projects"), first_state["project_id"]
    )
    assert second_state["state_root"] == os.path.join(
        str(home / ".legion" / "projects"), second_state["project_id"]
    )
    assert (
        first_state["repository_project_id"]
        == second_state["repository_project_id"]
    )
    assert first_state["repository_project_id"].startswith("shared-")
    assert first_state["repository_identity"] == "github.com/example/shared"
    shared_learning = os.path.join(
        str(home / ".legion" / "projects"),
        first_state["repository_project_id"],
        "learning",
    )
    assert first_state["project_learning_dir"] == shared_learning
    assert second_state["project_learning_dir"] == shared_learning
    assert first_state["path_project_learning_dir"] == os.path.join(
        first_state["state_root"], "learning"
    )
    assert second_state["path_project_learning_dir"] == os.path.join(
        second_state["state_root"], "learning"
    )


def test_shell_exports_stable_repository_project_id_for_learning(tmp_path):
    repo = tmp_path / "checkout"
    repo.mkdir()
    subprocess.run(["git", "init", "-q", str(repo)], check=True)
    subprocess.run(
        [
            "git",
            "-C",
            str(repo),
            "remote",
            "add",
            "origin",
            "git@github.com:Example/Shared.git",
        ],
        check=True,
    )

    exports = state.shell_exports(
        state.resolve_state(str(repo), {"HOME": str(tmp_path / "home")})
    )

    assert "export LEGION_REPOSITORY_PROJECT_ID=shared-e7ba5b748696" in exports


def test_resolve_state_honors_env_overrides(tmp_path, monkeypatch):
    repo = tmp_path / "repo"
    repo.mkdir()
    root = tmp_path / "state-root"
    telemetry = tmp_path / "custom-spans"
    monkeypatch.setenv("LEGION_STATE_ROOT", str(root))
    monkeypatch.setenv("LEGION_TELEMETRY_DIR", str(telemetry))
    for key in (
        "LEGION_REGISTRY_DIR",
        "LEGION_REPOS_FILE",
        "LEGION_BENCH_DIR",
        "LEGION_REPORTS_DIR",
        "LEGION_PROJECT_LEARNING_DIR",
        "LEGION_GLOBAL_LEARNING_DIR",
        "LEGION_CONFIG_FILE",
    ):
        monkeypatch.delenv(key, raising=False)

    resolved = state.resolve_state(str(repo))

    assert resolved["source"] == "env"
    assert resolved["state_root"] == str(root)
    assert resolved["telemetry_dir"] == str(telemetry)
    assert resolved["registry_dir"] == str(root / "registry")
    assert resolved["project_learning_dir"] == str(root / "learning")


def test_resolve_state_honors_repo_config(tmp_path, monkeypatch):
    home = tmp_path / "home"
    repo = tmp_path / "repo"
    config_dir = repo / ".legion"
    config_dir.mkdir(parents=True)
    (config_dir / "config.toml").write_text(
        '[state]\nroot = ".legion/local-state"\n\n[reports]\nroot = ".legion/local-reports"\n',
        encoding="utf-8",
    )
    monkeypatch.setenv("HOME", str(home))
    for key in (
        "LEGION_STATE_ROOT",
        "LEGION_REPORTS_DIR",
        "LEGION_PROJECT_LEARNING_DIR",
        "LEGION_GLOBAL_LEARNING_DIR",
        "LEGION_CONFIG_FILE",
    ):
        monkeypatch.delenv(key, raising=False)

    resolved = state.resolve_state(str(repo))

    assert resolved["source"] == "config"
    assert resolved["state_root"] == str(repo / ".legion" / "local-state")
    assert resolved["reports_dir"] == str(repo / ".legion" / "local-reports")


def test_git_command_failure_falls_back_to_original_repo_path(tmp_path, monkeypatch):
    repo = tmp_path / "repo"
    repo.mkdir()

    def fail_git(*_args, **_kwargs):
        raise subprocess.TimeoutExpired(cmd="git", timeout=3)

    monkeypatch.setattr(state.subprocess, "run", fail_git)

    resolved = state.resolve_state(str(repo), {"HOME": str(tmp_path / "home")})

    assert resolved["repository_identity"] == str(repo)
    assert resolved["project_id"] == state.project_id(str(repo))


def test_bare_repo_falls_back_without_crashing(tmp_path):
    repo = tmp_path / "bare.git"
    subprocess.run(["git", "init", "--bare", "-q", str(repo)], check=True)

    resolved = state.resolve_state(str(repo), {"HOME": str(tmp_path / "home")})

    assert resolved["project_id"] == state.project_id(str(repo))


def test_orphan_report_is_read_only_and_includes_total_size(tmp_path):
    home = tmp_path / "home"
    projects = home / ".legion" / "projects"
    missing_repo = tmp_path / "removed-repo"
    live_repo = tmp_path / "live-repo"
    live_repo.mkdir()
    ephemeral_repo = live_repo / ".legion" / "worktrees" / "heal-pr-42"
    ephemeral_repo.mkdir(parents=True)

    def write_project(name, repo_path, *, registry_only=False):
        project = projects / name
        project.mkdir(parents=True)
        record = json.dumps({"repo_root": str(repo_path)}) + "\n"
        if registry_only:
            registry = project / "registry"
            registry.mkdir()
            (registry / "run.json").write_text(record, encoding="utf-8")
        else:
            (project / "repos.jsonl").write_text(record, encoding="utf-8")
        (project / "payload.bin").write_bytes(b"telemetry")
        return project

    missing_project = write_project("missing-111111111111", missing_repo)
    registry_project = write_project(
        "registry-222222222222", tmp_path / "removed-registry-repo", registry_only=True
    )
    ephemeral_project = write_project(
        "heal-pr-42-333333333333", ephemeral_repo
    )
    write_project("live-444444444444", live_repo)
    unrecorded = projects / "shared-learning-555555555555"
    unrecorded.mkdir()
    (unrecorded / "learning.json").write_text("{}\n", encoding="utf-8")

    before = {
        path: path.read_bytes()
        for path in (
            missing_project / "payload.bin",
            registry_project / "payload.bin",
            ephemeral_project / "payload.bin",
        )
    }
    report = state.orphaned_project_report({"HOME": str(home)})

    by_id = {project["project_id"]: project for project in report["projects"]}
    assert report["read_only"] is True
    assert report["orphan_count"] == 3
    assert set(by_id) == {
        "missing-111111111111",
        "registry-222222222222",
        "heal-pr-42-333333333333",
    }
    assert by_id["missing-111111111111"]["reasons"] == [
        "recorded_repo_missing"
    ]
    assert by_id["registry-222222222222"]["reasons"] == [
        "recorded_repo_missing"
    ]
    assert by_id["heal-pr-42-333333333333"]["reasons"] == [
        "ephemeral_worktree_path"
    ]
    assert report["total_size_bytes"] == sum(
        project["size_bytes"] for project in report["projects"]
    )
    assert all(path.read_bytes() == content for path, content in before.items())

    cli_env = os.environ.copy()
    cli_env["HOME"] = str(home)
    cli_env.pop("LEGION_HOME", None)
    result = subprocess.run(
        [sys.executable, os.path.abspath(PATH), "--report-orphans"],
        check=True,
        capture_output=True,
        text=True,
        env=cli_env,
    )
    assert "Found 3 directories totaling" in result.stdout
    assert "Read-only report: no files were deleted, merged, or moved." in result.stdout

    help_result = subprocess.run(
        [sys.executable, os.path.abspath(PATH), "--help"],
        check=True,
        capture_output=True,
        text=True,
    )
    assert "--report-orphans" in help_result.stdout
    assert "never modify it" in help_result.stdout


def test_default_log_root_resolution_order(tmp_path):
    home = tmp_path / "home"
    home.mkdir()
    base = {"HOME": str(home)}

    # 1. explicit LEGION_LOG_ROOT wins
    assert state.default_log_root({**base, "LEGION_LOG_ROOT": str(tmp_path / "explicit")}) == str(tmp_path / "explicit")
    # 2. XDG_STATE_HOME/legion next
    assert state.default_log_root({**base, "XDG_STATE_HOME": str(tmp_path / "xdg")}) == str(tmp_path / "xdg" / "legion")
    # 3. fresh install (no ~/.claude/logs/legion) -> neutral ~/.legion/logs
    assert state.default_log_root(base) == str(home / ".legion" / "logs")
    # 4. LEGION_HOME override
    assert state.default_log_root({**base, "LEGION_HOME": str(tmp_path / "lh")}) == str(tmp_path / "lh" / "logs")
    # 5. an EXISTING ~/.claude/logs/legion is kept (back-compat)
    legacy = home / ".claude" / "logs" / "legion"
    legacy.mkdir(parents=True)
    assert state.default_log_root(base) == str(legacy)


def test_default_log_root_is_hermetic_wrt_passed_env(tmp_path, monkeypatch):
    # A passed env must drive the result, not the process HOME (regression guard:
    # os.path.expanduser used to re-consult os.environ for HOME-derived paths).
    monkeypatch.setenv("HOME", str(tmp_path / "process-home"))
    fake = tmp_path / "fakehome"
    fake.mkdir()
    got = state.default_log_root({"HOME": str(fake)})
    assert got == str(fake / ".legion" / "logs")
    assert "process-home" not in got
