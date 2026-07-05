import importlib.util
import os


HERE = os.path.dirname(__file__)
PATH = os.path.join(
    HERE, "..", "..", "legion-observability", "scripts", "legion_state.py"
)
SPEC = importlib.util.spec_from_file_location("legion_state", PATH)
state = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(state)


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
        "LEGION_CONFIG_FILE",
    ):
        monkeypatch.delenv(key, raising=False)

    resolved = state.resolve_state(str(repo))

    assert resolved["source"] == "auto"
    assert resolved["project_id"].startswith("my-app-")
    assert resolved["state_root"].startswith(str(home / ".legion" / "projects"))
    assert resolved["telemetry_dir"] == os.path.join(resolved["state_root"], "spans")
    assert resolved["registry_dir"] == os.path.join(resolved["state_root"], "registry")
    assert resolved["repos_file"] == os.path.join(resolved["state_root"], "repos.jsonl")
    assert resolved["bench_dir"] == os.path.join(resolved["state_root"], "bench")
    assert resolved["reports_dir"] == os.path.join(resolved["state_root"], "reports")


def test_resolve_state_honors_env_overrides(tmp_path, monkeypatch):
    repo = tmp_path / "repo"
    repo.mkdir()
    root = tmp_path / "state-root"
    telemetry = tmp_path / "custom-spans"
    monkeypatch.setenv("LEGION_STATE_ROOT", str(root))
    monkeypatch.setenv("LEGION_TELEMETRY_DIR", str(telemetry))

    resolved = state.resolve_state(str(repo))

    assert resolved["source"] == "env"
    assert resolved["state_root"] == str(root)
    assert resolved["telemetry_dir"] == str(telemetry)
    assert resolved["registry_dir"] == str(root / "registry")


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
    for key in ("LEGION_STATE_ROOT", "LEGION_REPORTS_DIR", "LEGION_CONFIG_FILE"):
        monkeypatch.delenv(key, raising=False)

    resolved = state.resolve_state(str(repo))

    assert resolved["source"] == "config"
    assert resolved["state_root"] == str(repo / ".legion" / "local-state")
    assert resolved["reports_dir"] == str(repo / ".legion" / "local-reports")
