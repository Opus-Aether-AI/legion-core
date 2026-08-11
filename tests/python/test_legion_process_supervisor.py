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
    def __init__(self) -> None:
        self.signals: list[int] = []

    def poll(self) -> None:
        return None

    def send_signal(self, signum: int) -> None:
        self.signals.append(signum)


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
    process = _LiveProcess()

    assert SUPERVISOR._terminate_tree(process, tracker) is False
    assert tracker.known_signals == [signal.SIGTERM, signal.SIGKILL]
    assert process.signals == [signal.SIGTERM, signal.SIGKILL]


def test_darwin_handle_uses_proc_identity_without_a_task_port(monkeypatch: pytest.MonkeyPatch) -> None:
    info = SUPERVISOR._DarwinUniqueInfo()
    info.p_uniqueid = 987654321
    info.p_idversion = 12345
    monkeypatch.setattr(SUPERVISOR.sys, "platform", "darwin")
    monkeypatch.setattr(SUPERVISOR, "_darwin_unique_info", lambda pid: info if pid == 4321 else None)

    handle = SUPERVISOR.ProcessHandle.open(4321)

    assert handle is not None
    assert handle.unique_id == 987654321
    assert handle.audit_token is not None
    assert int(handle.audit_token.value[5]) == 4321
    assert int(handle.audit_token.value[7]) == 12345


def test_child_capture_revalidates_the_kernel_bound_parent(monkeypatch: pytest.MonkeyPatch) -> None:
    class FakeHandle:
        def __init__(self, pid: int, live: bool) -> None:
            self.pid = pid
            self.live = live
            self.closed = False

        def is_live(self) -> bool:
            return self.live

        def close(self) -> None:
            self.closed = True

    tracker = SUPERVISOR.DescendantTracker(10, "token")
    original_parent = FakeHandle(10, True)
    replacement_parent = FakeHandle(10, True)
    child = FakeHandle(20, True)
    tracker._handles[10] = replacement_parent
    monkeypatch.setattr(SUPERVISOR.ProcessHandle, "open", lambda pid: child if pid == 20 else None)
    monkeypatch.setattr(tracker, "_current_parent", lambda pid: 10 if pid == 20 else None)

    assert tracker._capture_child(20, {10: original_parent}) is False
    assert child.closed is True
    assert 20 not in tracker._handles


def test_tracker_close_is_safe_before_monitor_thread_starts() -> None:
    class FakeHandle:
        def __init__(self) -> None:
            self.closed = False

        def close(self) -> None:
            self.closed = True

    tracker = SUPERVISOR.DescendantTracker(10, "token")
    handle = FakeHandle()
    tracker._handles[10] = handle

    tracker.close()

    assert handle.closed is True
