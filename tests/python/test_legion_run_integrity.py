import datetime as dt
import importlib.util
import re
import threading
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
LEGION_RUN_PATH = ROOT / "legion-orchestrate" / "scripts" / "legion-run.py"


def load_legion_run():
    spec = importlib.util.spec_from_file_location("legion_run_integrity", LEGION_RUN_PATH)
    assert spec is not None
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def test_same_second_run_reservations_are_atomic_and_unique(tmp_path):
    legion_run = load_legion_run()
    fixed_now = dt.datetime(2026, 7, 31, 10, 25, 17, tzinfo=dt.timezone.utc)
    callers = 16
    ready = threading.Barrier(callers)

    def reserve():
        ready.wait()
        return legion_run.reserve_run_directory(
            tmp_path,
            "billing-export",
            now=fixed_now,
        )

    with ThreadPoolExecutor(max_workers=callers) as pool:
        reservations = list(pool.map(lambda _index: reserve(), range(callers)))

    run_ids = [run_id for run_id, _run_dir in reservations]
    run_dirs = [run_dir for _run_id, run_dir in reservations]
    legacy_id = "20260731T102517Z-billing-export"

    assert legacy_id in run_ids
    assert len(set(run_ids)) == callers
    assert len(set(run_dirs)) == callers
    assert all(path.is_dir() for path in run_dirs)
    assert all(path.name == run_id for run_id, path in reservations)
    assert all(
        re.fullmatch(
            r"20260731T102517Z-billing-export(?:-(?:[2-9]|[1-9][0-9]+))?",
            run_id,
        )
        for run_id in run_ids
    )
