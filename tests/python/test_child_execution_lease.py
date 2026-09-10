import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


ROOT = Path(__file__).parents[2]
SUPERVISOR = ROOT / "legion-router" / "scripts" / "legion-process-supervisor.py"


def run_supervised(tmp_path: Path, seconds: int, command: list[str], **kwargs):
    status_file = tmp_path / "lease.json"
    started = time.monotonic()
    result = subprocess.run(
        [
            sys.executable,
            str(SUPERVISOR),
            "--cwd",
            str(tmp_path),
            "--max-runtime-seconds",
            str(seconds),
            "--status-file",
            str(status_file),
            "--",
            *command,
        ],
        timeout=8,
        **kwargs,
    )
    return result, json.loads(status_file.read_text(encoding="utf-8")), time.monotonic() - started


def process_is_gone(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    except PermissionError:
        return False
    return False


def wait_gone(pid: int) -> bool:
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        if process_is_gone(pid):
            return True
        time.sleep(0.02)
    return process_is_gone(pid)


def test_child_finishing_below_lease_succeeds(tmp_path: Path) -> None:
    result, receipt, elapsed = run_supervised(
        tmp_path,
        2,
        [sys.executable, "-c", "import time; time.sleep(0.1)"],
        capture_output=True,
    )
    assert result.returncode == 0
    assert receipt["status"] == "completed"
    assert elapsed < 1.5


def test_silent_setsid_descendant_is_reaped_on_timeout(tmp_path: Path) -> None:
    pid_file = tmp_path / "detached.pid"
    program = """
import os, signal, sys, time
if os.fork() == 0:
    os.setsid()
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    with open(sys.argv[1], "w", encoding="utf-8") as stream:
        stream.write(str(os.getpid()))
        stream.flush()
    while True:
        time.sleep(1)
while True:
    time.sleep(1)
"""
    result, receipt, elapsed = run_supervised(
        tmp_path,
        1,
        [sys.executable, "-c", program, str(pid_file)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    assert result.returncode == 124
    assert receipt == {
        "schema": "legion.child-execution-lease.v1",
        "status": "timed_out",
        "reason": "child execution lease expired after 1 seconds",
        "max_runtime_seconds": 1,
    }
    assert elapsed < 6
    assert wait_gone(int(pid_file.read_text(encoding="utf-8")))


def test_infinite_output_is_bounded_by_same_lease(tmp_path: Path) -> None:
    result, receipt, elapsed = run_supervised(
        tmp_path,
        1,
        [sys.executable, "-c", "import sys; exec('while True: sys.stdout.write(\"x\"); sys.stdout.flush()')"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    assert result.returncode == 124
    assert receipt["status"] == "timed_out"
    assert elapsed < 6


def test_repeated_cancel_at_deadline_writes_one_terminal_outcome(tmp_path: Path) -> None:
    status_file = tmp_path / "race.json"
    process = subprocess.Popen(
        [
            sys.executable,
            str(SUPERVISOR),
            "--cwd",
            str(tmp_path),
            "--max-runtime-seconds",
            "1",
            "--status-file",
            str(status_file),
            "--",
            sys.executable,
            "-c",
            "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    time.sleep(0.98)
    for _ in range(3):
        try:
            process.send_signal(signal.SIGTERM)
        except ProcessLookupError:
            break
    process.wait(timeout=8)
    records = status_file.read_text(encoding="utf-8").splitlines()
    assert len(records) == 1
    receipt = json.loads(records[0])
    assert receipt["status"] in {"cancelled", "timed_out"}
    assert process.returncode in {143, 124}
