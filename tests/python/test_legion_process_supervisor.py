from __future__ import annotations

import importlib.util
import signal
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "legion-router" / "scripts" / "legion-process-supervisor.py"
SPEC = importlib.util.spec_from_file_location("legion_process_supervisor", MODULE_PATH)
assert SPEC and SPEC.loader
SUPERVISOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SUPERVISOR)


class _LiveProcess:
    def poll(self) -> None:
        return None


class _PersistentTracker:
    def __init__(self) -> None:
        self.signals: list[int] = []

    def signal(self, signum: int) -> list[int]:
        self.signals.append(signum)
        return [123]


class _FailedDiscoveryTracker:
    def __init__(self) -> None:
        self.known_signals: list[int] = []

    def signal(self, _signum: int) -> list[int]:
        raise SUPERVISOR.ProcessInspectionError("fixture discovery failure")

    def signal_known(self, signum: int) -> list[int]:
        self.known_signals.append(signum)
        return [123]


def test_incomplete_sigkill_drain_is_reported(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(SUPERVISOR, "GRACE_SECONDS", 0.005)
    monkeypatch.setattr(SUPERVISOR, "POLL_SECONDS", 0.0)
    tracker = _PersistentTracker()

    assert SUPERVISOR._terminate_tree(_LiveProcess(), tracker) is False
    assert signal.SIGTERM in tracker.signals
    assert signal.SIGKILL in tracker.signals


def test_inspection_failure_still_signals_captured_kernel_handles(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(SUPERVISOR, "GRACE_SECONDS", 0.005)
    tracker = _FailedDiscoveryTracker()

    assert SUPERVISOR._terminate_tree(_LiveProcess(), tracker) is False
    assert tracker.known_signals == [signal.SIGTERM, signal.SIGKILL]
