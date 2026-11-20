"""Keep Legion's machine-wide state out of the Python suite.

Executor health and the model-list cache are machine-wide records under
LEGION_HOME. A test that reads them (legion-share's gate consults codex health)
must see a clean record, not whatever the developer's machine last recorded.
"""

import pytest


@pytest.fixture(autouse=True)
def _isolated_legion_machine_state(tmp_path, monkeypatch):
    monkeypatch.setenv("LEGION_HEALTH_FILE", str(tmp_path / "legion-health" / "executors.json"))
    monkeypatch.setenv("LEGION_MODELS_CACHE_DIR", str(tmp_path / "legion-models-cache"))
    for name in (
        "LEGION_HEALTH",
        "LEGION_RUN_BUDGET_USD",
        "LEGION_DAY_BUDGET_USD",
        "LEGION_REVIEW_FIX_MAX_ROUNDS",
    ):
        monkeypatch.delenv(name, raising=False)
