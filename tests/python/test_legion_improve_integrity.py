import importlib.util
import json
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
IMPROVE_PATH = ROOT / "legion-observability" / "scripts" / "legion-improve.py"


def load_improve():
    spec = importlib.util.spec_from_file_location("legion_improve_integrity", IMPROVE_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_bounded_process_times_out_after_child_closes_output_streams(tmp_path):
    improve = load_improve()
    sleeper = tmp_path / "close-and-sleep.py"
    sleeper.write_text(
        "import os, time\nos.close(1)\nos.close(2)\ntime.sleep(30)\n",
        encoding="utf-8",
    )
    started = time.monotonic()

    result = improve._bounded_process(
        ["python3", str(sleeper)], timeout=1, output_limit=1024
    )

    assert result.returncode == 124
    assert "timed out" in result.stderr
    assert time.monotonic() - started < 4


def test_error_payload_matches_the_dedicated_error_contract():
    improve = load_improve()
    payload = improve.error_payload("queue", "queue_bounds_out_of_range")

    assert payload == {
        "schema": "legion.improvement-error.v1",
        "command": "queue",
        "status": "error",
        "reason": "queue_bounds_out_of_range",
    }
    schema = json.loads(
        (ROOT / "legion-observability" / "schema" / "legion.improvement-error.v1.schema.json").read_text(
            encoding="utf-8"
        )
    )
    assert schema["required"] == ["schema", "command", "status", "reason"]
