from __future__ import annotations

import importlib.util
import os
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "legion-router" / "scripts" / "legion-handoff-broker.py"
SPEC = importlib.util.spec_from_file_location("legion_handoff_broker", MODULE_PATH)
assert SPEC and SPEC.loader
BROKER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BROKER)


def valid_span() -> dict[str, object]:
    return {
        "schema": "legion.span.v1",
        "ts": "2026-08-11T00:00:00Z",
        "run_id": "child-run",
        "trace_id": "trace",
        "parent_id": "parent-run",
        "executor": "cursor",
        "model": "fixture-cursor",
        "status": "ok",
        "duration_ms": 1,
        "cost_usd": 0.0,
        "tokens": {},
        "artifacts": {},
    }


def test_complete_span_validation_rejects_missing_invalid_and_nonfinite_values() -> None:
    assert BROKER._validate_span(valid_span(), "parent-run")["executor"] == "cursor"

    missing = valid_span()
    del missing["model"]
    with pytest.raises(ValueError, match="missing required"):
        BROKER._validate_span(missing, "parent-run")

    invalid_status = valid_span()
    invalid_status["status"] = "definitely-not-valid"
    with pytest.raises(ValueError, match="status"):
        BROKER._validate_span(invalid_status, "parent-run")

    nonfinite = valid_span()
    nonfinite["cost_usd"] = float("nan")
    with pytest.raises(ValueError, match="nonnegative number"):
        BROKER._validate_span(nonfinite, "parent-run")


def test_short_telemetry_append_rolls_back_the_partial_record(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    destination = tmp_path / "spans.jsonl"
    destination.write_bytes(b"existing\n")
    descriptor = os.open(destination, os.O_RDWR | os.O_APPEND)
    real_write = os.write
    called = False

    def short_write(fd: int, value: bytes) -> int:
        nonlocal called
        if fd == descriptor and not called:
            called = True
            return real_write(fd, value[:3])
        return real_write(fd, value)

    monkeypatch.setattr(BROKER.os, "write", short_write)
    try:
        with pytest.raises(OSError, match="short canonical telemetry append"):
            BROKER._write_record_atomic(descriptor, b'{"schema":"legion.span.v1"}\n')
    finally:
        os.close(descriptor)

    assert destination.read_bytes() == b"existing\n"


def test_child_output_is_terminated_while_streaming_past_the_cap(tmp_path: Path) -> None:
    broker = object.__new__(BROKER.Broker)
    broker.stop = threading.Event()
    process = subprocess.Popen(
        [sys.executable, "-c", "import sys; sys.stdout.write('x' * (17 * 1024 * 1024))"],
        cwd=tmp_path,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )

    with pytest.raises(ValueError, match="nested handoff output exceeds 16 MiB"):
        broker._capture_process(process, b"")
    assert process.poll() is not None


def test_unresponsive_descendant_supervisor_fails_closed(tmp_path: Path) -> None:
    process = subprocess.Popen(
        [
            sys.executable,
            "-c",
            (
                "import signal,time;"
                "signal.signal(signal.SIGTERM, signal.SIG_IGN);"
                "print('ready', flush=True);"
                "time.sleep(30)"
            ),
        ],
        cwd=tmp_path,
        stdout=subprocess.PIPE,
        text=True,
        start_new_session=True,
    )
    assert process.stdout is not None
    assert process.stdout.readline().strip() == "ready"

    with pytest.raises(ValueError, match="cleanup deadline"):
        BROKER._terminate_supervisor(process, grace=0.01)
    assert process.poll() is not None


def test_incomplete_descendant_supervisor_exit_fails_closed(tmp_path: Path) -> None:
    process = subprocess.Popen([sys.executable, "-c", "raise SystemExit(70)"], cwd=tmp_path)
    assert process.wait(timeout=2.0) == 70

    with pytest.raises(ValueError, match="incomplete cleanup"):
        BROKER._terminate_supervisor(process)


def test_abandoned_client_preserves_supervisor_exit_70(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    supervisor = tmp_path / "supervisor-exit70"
    supervisor.write_text("#!/bin/sh\nexit 70\n", encoding="utf-8")
    supervisor.chmod(0o700)
    socket_path = Path("/tmp") / f"legion-broker-test-{os.getpid()}-{id(supervisor)}.sock"
    broker = BROKER.Broker(
        socket_path=socket_path,
        token="test-token",
        delegate=Path("/usr/bin/true"),
        source_repo=tmp_path,
        broker_root=tmp_path / "broker-root",
        base_sha="deadbeef",
        sandbox_bin=Path("/usr/bin/true"),
        sandbox_kind="bwrap",
        supervisor=supervisor,
        supervisor_deny_canary=tmp_path / "deny",
        supervisor_allow_canary=tmp_path / "allow",
        telemetry_dir=None,
        expected_parent="parent",
    )
    broker.broker_repo = tmp_path
    monkeypatch.setattr(broker, "_prepare_repository", lambda: None)
    monkeypatch.setattr(broker, "_sandbox_command", lambda command: ["/usr/bin/true"])
    monkeypatch.setattr(broker, "_target_environment", os.environ.copy)

    results: list[int] = []
    errors: list[BaseException] = []

    def serve() -> None:
        try:
            results.append(broker.serve())
        except BaseException as error:
            errors.append(error)

    thread = threading.Thread(target=serve)
    thread.start()
    try:
        deadline = time.monotonic() + 2.0
        while not socket_path.exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        assert socket_path.exists()
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.connect(str(socket_path))
            BROKER._send_json(
                connection,
                {
                    "token": "test-token",
                    "argv": ["run", "--executor", "cursor", "--task", "noop"],
                    "stdin": "",
                },
                BROKER.MAX_REQUEST_BYTES,
            )
            # Deliberately abandon the request before the broker can respond.
        thread.join(timeout=4.0)
        assert not thread.is_alive()
        assert errors == []
        assert results == [70]
        assert broker.cleanup_failure == "descendant supervisor reported incomplete cleanup"
    finally:
        broker.request_stop()
        thread.join(timeout=1.0)
        socket_path.unlink(missing_ok=True)
