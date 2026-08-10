import importlib.util
import os


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
