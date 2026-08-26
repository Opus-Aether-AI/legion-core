import importlib.util
import json
import os
from itertools import permutations
from pathlib import Path
import subprocess


HERE = os.path.dirname(__file__)
_PATH = os.path.join(
    HERE,
    "..",
    "..",
    "legion-observability",
    "scripts",
    "legion_executor_registry.py",
)
_spec = importlib.util.spec_from_file_location("legion_executor_registry_test", _PATH)
registry = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(registry)

ROUTER_PATH = os.path.join(HERE, "..", "..", "legion-router", "scripts", "legion-route.py")
_router_spec = importlib.util.spec_from_file_location("legion_route_registry_test", ROUTER_PATH)
router = importlib.util.module_from_spec(_router_spec)
_router_spec.loader.exec_module(router)

ROOT = Path(HERE).parents[1]
FIXTURES = ROOT / "tests" / "fixtures" / "symmetric-harness"
MOCK_BIN = ROOT / "tests" / "mocks" / "bin"
ALL_HARNESSES = ("claude", "codex", "cursor", "opencode", "hermes", "pi", "deepseek")


def path_without(binary: str) -> str:
    """PATH with every directory that provides `binary` dropped.

    A test that asserts an adapter refuses to run because a provider CLI is
    missing must not inherit the host PATH: on a machine where that CLI is
    installed the adapter proceeds and launches the real provider, which hangs
    the whole suite instead of failing.
    """
    kept = []
    for entry in os.environ.get("PATH", "").split(os.pathsep):
        if not entry:
            continue
        candidate = os.path.join(entry, binary)
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            continue
        kept.append(entry)
    return os.pathsep.join(kept)


def test_loads_router_supported_top_level_registry(tmp_path):
    path = tmp_path / "executors.toml"
    path.write_text(
        '[aider]\nkind = "coding"\n\n[hermes]\nkind = "primary"\n',
        encoding="utf-8",
    )

    assert registry.load_coding_executor_families(path) == {"aider"}


def test_fallback_parser_accepts_top_level_registry(tmp_path, monkeypatch):
    path = tmp_path / "executors.toml"
    path.write_text('[aider]\nkind = "primary coding"\n', encoding="utf-8")
    monkeypatch.setattr(registry, "tomllib", None)

    assert registry.load_coding_executor_families(path) == {"aider"}


def test_fallback_parser_preserves_nested_executor_kind(tmp_path, monkeypatch):
    path = tmp_path / "executors.toml"
    path.write_text(
        '[executors.codex]\nkind = "coding"\n\n'
        '[executors.codex.capabilities]\nkind = "review"\n',
        encoding="utf-8",
    )
    monkeypatch.setattr(registry, "tomllib", None)

    assert registry.load_coding_executor_families(path) == {"codex"}


def test_fallback_parser_preserves_complete_routing_contract(tmp_path, monkeypatch):
    path = tmp_path / "executors.toml"
    path.write_text(
        '[executors.pi]\n'
        'kind = "primary coding"\n'
        'adapter = "legion-pi"\n'
        'contract = "diff"\n'
        'model_ref = "pi_default"\n',
        encoding="utf-8",
    )
    monkeypatch.setattr(registry, "tomllib", None)

    assert registry.load_executor_registry(path)["pi"] == {
        "kind": "primary coding",
        "adapter": "legion-pi",
        "contract": "diff",
        "model_ref": "pi_default",
    }


def test_fallback_parser_does_not_promote_nested_capability_kind(tmp_path, monkeypatch):
    path = tmp_path / "executors.toml"
    path.write_text(
        '[executors.aider]\nkind = "primary"\n\n'
        '[executors.aider.capabilities]\nkind = "coding"\n',
        encoding="utf-8",
    )
    monkeypatch.setattr(registry, "tomllib", None)

    assert registry.load_coding_executor_families(path) == set()


def test_fallback_parser_ignores_root_metadata_in_nested_registry(tmp_path, monkeypatch):
    path = tmp_path / "executors.toml"
    path.write_text(
        '[executors.codex]\nkind = "coding"\n\n'
        '[metadata]\nkind = "coding"\n',
        encoding="utf-8",
    )
    monkeypatch.setattr(registry, "tomllib", None)

    assert registry.load_coding_executor_families(path) == {"codex"}


def test_valid_primary_only_registry_stays_empty(tmp_path, monkeypatch):
    path = tmp_path / "executors.toml"
    path.write_text('[hermes]\nkind = "primary"\n', encoding="utf-8")

    assert registry.load_coding_executor_families(path) == set()

    monkeypatch.setattr(registry, "tomllib", None)
    assert registry.load_coding_executor_families(path) == set()


def test_malformed_executor_table_uses_builtin_fallback(tmp_path, monkeypatch):
    path = tmp_path / "executors.toml"
    path.write_text("executors = []\n", encoding="utf-8")

    assert registry.load_coding_executor_families(path) == {
        "claude",
        "codex",
        "cursor",
        "opencode",
    }

    monkeypatch.setattr(registry, "tomllib", None)
    assert registry.load_coding_executor_families(path) == {
        "claude",
        "codex",
        "cursor",
        "opencode",
    }


def test_checked_in_symmetric_registry_declares_roles_capabilities_and_adapters():
    """Every supported harness can be primary and a coding handoff target."""
    executors = router.load_executors(FIXTURES / "executors.toml")
    expected = json.loads((FIXTURES / "executor-contract.json").read_text(encoding="utf-8"))

    assert set(executors) == set(ALL_HARNESSES)
    for name, contract in expected.items():
        assert set(str(executors[name]["kind"]).split()) == set(contract["capabilities"])
        assert executors[name]["adapter"] == contract["adapter"]
        assert executors[name]["contract"] == contract["contract"]
        assert executors[name]["model_ref"] == contract["model_ref"]


def test_live_executor_registry_is_symmetric_without_changing_primary_only_parse_behavior():
    """The production registry, not a test-only copy, is the source of truth."""
    executors = router.load_executors()

    assert set(executors) == set(ALL_HARNESSES)
    assert registry.load_coding_executor_families() == set(ALL_HARNESSES)
    assert all("primary" in str(executors[name]["kind"]).split() for name in ALL_HARNESSES)
    assert all("coding" in str(executors[name]["kind"]).split() for name in ALL_HARNESSES)
    assert all(executors[name]["adapter"] for name in ALL_HARNESSES)
    assert all(executors[name]["contract"] in {"native", "diff", "prompt"} for name in ALL_HARNESSES)


def test_symmetric_pi_and_hermes_are_explicit_targets_not_default_archetypes():
    """Adding coding families must not silently alter routing policy."""
    routing = router.load_table(ROOT / "legion-router" / "config" / "routing.toml")
    archetypes = routing.get("archetypes", {})
    assert all(route.get("executor") not in {"pi", "hermes"} for route in archetypes.values())


def test_primary_detection_recognizes_every_harness_including_pi_markers():
    marker_cases = {
        "claude": {"CLAUDECODE": "1"},
        "codex": {"CODEX_SANDBOX": "workspace-write"},
        "cursor": {"CURSOR_AGENT": "1"},
        "opencode": {"OPENCODE": "1"},
        "hermes": {"HERMES_HOME": "/tmp/hermes"},
        "pi": {"AI_AGENT": "pi"},
    }
    primary_shell = ROOT / "legion-router" / "scripts" / "lib" / "primary.sh"

    for expected, env in marker_cases.items():
        assert router.resolve_primary(env) == expected
        shell_env = {"PATH": os.environ["PATH"], **env}
        result = subprocess.run(
            ["bash", "-c", f'source "{primary_shell}"; legion_primary'],
            env=shell_env,
            check=True,
            capture_output=True,
            text=True,
        )
        assert result.stdout.strip() == expected

    assert router.resolve_primary({"PI_CODING_AGENT": "true"}) == "pi"
    pi_marker = subprocess.run(
        ["bash", "-c", f'source "{primary_shell}"; legion_primary'],
        env={"PATH": os.environ["PATH"], "PI_CODING_AGENT": "true"},
        check=True,
        capture_output=True,
        text=True,
    )
    assert pi_marker.stdout.strip() == "pi"


def test_router_and_observability_share_executor_family_normalization():
    families = registry.load_coding_executor_families(FIXTURES / "executors.toml")
    assert families == set(ALL_HARNESSES)

    for harness in ALL_HARNESSES:
        for label in (harness, f"{harness}-review", f"{harness}-resume"):
            assert router.executor_family(label) == harness
            assert registry.executor_family(label, families) == harness


def test_cross_harness_preflight_allows_every_different_source_target_pair():
    """Every ordered different-family pair allows one explicit handoff.

    Sized from ALL_HARNESSES rather than hardcoded: this was "the full 6x5
    matrix" until a seventh harness arrived, and a literal count turns adding
    one into an unrelated-looking failure.
    """
    context = ROOT / "legion-router" / "scripts" / "lib" / "executor-context.sh"
    matrix = list(permutations(ALL_HARNESSES, 2))
    assert len(matrix) == len(ALL_HARNESSES) * (len(ALL_HARNESSES) - 1)
    assert {(source, target) for source, target in matrix} == {
        (source, target)
        for source in ALL_HARNESSES
        for target in ALL_HARNESSES
        if source != target
    }
    for source, target in matrix:
        result = subprocess.run(
            [
                "bash",
                "-c",
                f'source "{context}"; legion_cross_harness_handoff_allowed "$1"',
                "bash",
                target,
            ],
            env={
                "PATH": os.environ["PATH"],
                "LEGION_CROSS_HARNESS_HANDOFF": "1",
                "LEGION_EXECUTOR_NAME": source,
                "LEGION_DEPTH": "1",
                "LEGION_MAX_DEPTH": "2",
            },
            text=True,
            capture_output=True,
        )
        assert result.returncode == 0, f"{source} -> {target}: {result.stderr}"


def test_cross_harness_preflight_rejects_same_harness_for_every_family():
    context = ROOT / "legion-router" / "scripts" / "lib" / "executor-context.sh"
    for harness in ALL_HARNESSES:
        result = subprocess.run(
            ["bash", "-c", f'source "{context}"; legion_cross_harness_handoff_allowed "$1"', "bash", harness],
            env={
                "PATH": os.environ["PATH"],
                "LEGION_CROSS_HARNESS_HANDOFF": "1",
                "LEGION_EXECUTOR_NAME": harness,
                "LEGION_DEPTH": "1",
                "LEGION_MAX_DEPTH": "2",
            },
            text=True,
            capture_output=True,
        )
        assert result.returncode != 0


def test_cross_harness_preflight_rejects_depth_overflow_for_every_matrix_row():
    """Every allowed matrix edge fails closed once the inherited depth is full."""
    context = ROOT / "legion-router" / "scripts" / "lib" / "executor-context.sh"
    for source, target in permutations(ALL_HARNESSES, 2):
        result = subprocess.run(
            [
                "bash",
                "-c",
                f'source "{context}"; legion_cross_harness_handoff_allowed "$1"',
                "bash",
                target,
            ],
            env={
                "PATH": os.environ["PATH"],
                "LEGION_CROSS_HARNESS_HANDOFF": "1",
                "LEGION_EXECUTOR_NAME": source,
                "LEGION_DEPTH": "2",
                "LEGION_MAX_DEPTH": "2",
            },
            text=True,
            capture_output=True,
        )
        assert result.returncode != 0, f"depth overflow unexpectedly allowed {source} -> {target}"


def test_pi_and_hermes_adapter_fixtures_have_schema_compatible_terminal_results():
    usage = json.loads((FIXTURES / "adapter-usage.json").read_text(encoding="utf-8"))
    required = {"run_id", "status", "executor", "model", "result", "usage", "cost_usd"}

    for harness in ("pi", "hermes"):
        fixture = FIXTURES / f"{harness}-terminal-result.json"
        result = subprocess.run(
            [str(MOCK_BIN / harness)],
            env={"PATH": os.environ["PATH"], f"MOCK_{harness.upper()}_FIXTURE": str(fixture)},
            check=True,
            capture_output=True,
            text=True,
        )
        terminal = json.loads(result.stdout)
        assert required <= set(terminal)
        assert terminal["executor"] == harness
        assert terminal["status"] == "ok"
        assert terminal["usage"] == usage[harness]
        assert terminal["cost_usd"] >= 0


def test_pi_and_hermes_registered_adapters_are_present_and_ready_for_mocked_runs():
    """Readiness failures must be explicit; no provider binary is ever invoked."""
    executors = router.load_executors()
    for harness in ("pi", "hermes"):
        adapter = ROOT / "legion-router" / "bin" / executors[harness]["adapter"]
        assert adapter.is_file(), f"missing registered adapter for {harness}: {adapter}"
        assert os.access(adapter, os.X_OK)


def test_symmetric_adapter_requires_a_concrete_provider_binary_before_any_worktree(tmp_path):
    repo = tmp_path / "repo"
    repo.mkdir()
    subprocess.run(["git", "init", "-q", str(repo)], check=True)
    subprocess.run(["git", "-C", str(repo), "config", "user.email", "test@example.com"], check=True)
    subprocess.run(["git", "-C", str(repo), "config", "user.name", "test"], check=True)
    (repo / "README.md").write_text("fixture\n", encoding="utf-8")
    subprocess.run(["git", "-C", str(repo), "add", "."], check=True)
    subprocess.run(["git", "-C", str(repo), "commit", "-qm", "fixture"], check=True)

    result = subprocess.run(
        [
            str(ROOT / "legion-router" / "scripts" / "delegate.sh"),
            "run", "--executor", "pi", "--model", "fixture-model",
            "--task", "bounded fixture task", "--repo", str(repo), "--quiet",
        ],
        env={
            "PATH": path_without("pi"),
            "HOME": str(tmp_path / "home"),
            "LEGION_EXECUTORS_FILE": str(FIXTURES / "executors.toml"),
            "LEGION_STATE_ROOT": str(tmp_path / "state"),
            "LEGION_TELEMETRY_DIR": str(tmp_path / "spans"),
        },
        capture_output=True,
        text=True,
        cwd=repo,
        # A regression here launches the real provider; fail fast rather than
        # letting the suite hang indefinitely waiting on it.
        timeout=120,
    )

    assert result.returncode != 0
    assert "pi CLI not found" in result.stderr


def test_fallback_loader_preserves_bare_booleans(tmp_path):
    """Capability flags are bare booleans; the 3.9/3.10 path dropped them.

    Preserving only quoted strings meant a capability declared in
    executors.toml simply vanished on older Pythons, and the dispatcher
    silently fell back to its pre-capability behaviour.
    """
    import legion_executor_registry as registry

    config = tmp_path / "executors.toml"
    config.write_text(
        '[executors.demo]\n'
        'kind = "coding"\n'
        'adapter = "legion-demo"\n'
        'task_file = true\n'
        'review = "prompt"\n'
        'disabled = false\n',
        encoding="utf-8",
    )

    table = registry._fallback_table(str(config))
    demo = table["executors"]["demo"]

    assert demo["task_file"] is True
    assert demo["disabled"] is False
    assert demo["review"] == "prompt"
    assert demo["adapter"] == "legion-demo"
