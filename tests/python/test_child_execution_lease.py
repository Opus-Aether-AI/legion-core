import errno
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

import pytest


ROOT = Path(__file__).parents[2]
SUPERVISOR = ROOT / "legion-router" / "scripts" / "legion-process-supervisor.py"


def test_vanished_proc_entries_do_not_interrupt_descendant_cleanup(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    spec = importlib.util.spec_from_file_location("lease_supervisor_proc_race", SUPERVISOR)
    assert spec is not None and spec.loader is not None
    supervisor = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(supervisor)

    class VanishedProcPath:
        def __init__(self, name: str):
            self.name = name.rsplit("/", 1)[-1]

        def is_dir(self):
            return True

        def iterdir(self):
            return [VanishedProcPath("4242")]

        def __truediv__(self, part):
            return VanishedProcPath(str(part))

        def read_bytes(self):
            raise ProcessLookupError("process vanished between enumeration and read")

        def read_text(self, **_kwargs):
            raise ProcessLookupError("process vanished between enumeration and read")

    monkeypatch.setattr(supervisor.sys, "platform", "linux")
    monkeypatch.setattr(supervisor, "Path", VanishedProcPath)
    assert supervisor._proc_child_pids(1) == set()
    assert supervisor._token_pids("fixture") == set()
    assert supervisor.DescendantTracker._current_parent(4242) is None

    class VanishedHandle:
        closed = False

        def close(self):
            self.closed = True

    handle = VanishedHandle()
    monkeypatch.setattr(supervisor, "_token_pids", lambda _token: {4242})
    monkeypatch.setattr(supervisor.ProcessHandle, "open", lambda _pid: handle)
    tracker = supervisor.DescendantTracker(1, "fixture")
    tracker._capture_token_pids()
    assert handle.closed
    assert tracker._handles == {}


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
    assert receipt["child_exit_code"] == 0
    assert elapsed < 1.5


@pytest.mark.parametrize(
    ("extra", "environment"),
    (
        (["--max-runtime-seconds", "0", "--", "/fixture/provider"], {}),
        (["--max-runtime-seconds", "2"], {}),
        (["--max-runtime-seconds", "2", "--", "/fixture/provider"],
         {"LEGION_CHILD_LEASE_DEADLINE_NS": "invalid"}),
    ),
)
def test_prelaunch_validation_failures_publish_no_child_evidence(
    tmp_path: Path, extra: list[str], environment: dict[str, str]
) -> None:
    status_file = tmp_path / "validation-no-launch.json"
    env = os.environ.copy()
    env.update(environment)
    result = subprocess.run(
        [sys.executable, str(SUPERVISOR), "--cwd", str(tmp_path),
         "--status-file", str(status_file), *extra],
        capture_output=True,
        env=env,
        timeout=4,
    )
    assert result.returncode == 2
    receipt = json.loads(status_file.read_text(encoding="utf-8"))
    assert receipt["status"] == "launch_failed"
    assert receipt["max_runtime_seconds"] >= 1
    assert "child_exit_code" not in receipt


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


def test_inherited_absolute_deadline_clamps_relative_allowance(tmp_path: Path) -> None:
    environment = os.environ.copy()
    environment["LEGION_CHILD_LEASE_DEADLINE_NS"] = str(time.monotonic_ns() + 300_000_000)
    result, receipt, elapsed = run_supervised(
        tmp_path,
        10,
        [sys.executable, "-c", "import time; time.sleep(30)"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        env=environment,
    )
    assert result.returncode == 124
    assert receipt["status"] == "timed_out"
    assert elapsed < 4


@pytest.mark.parametrize("kind", ("symlink", "hardlink", "fifo", "oversized"))
def test_provider_launch_signal_receipt_rejects_unsafe_files_without_blocking(
    tmp_path: Path, kind: str
) -> None:
    spec = importlib.util.spec_from_file_location(f"lease_supervisor_receipt_{kind}", SUPERVISOR)
    assert spec is not None and spec.loader is not None
    supervisor = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(supervisor)
    receipt = tmp_path / "provider-launch.json"
    target = tmp_path / "target"
    target.write_text(
        json.dumps(
            {
                "schema": "legion.provider-launch.v1",
                "status": "started",
                "provider_pid": os.getpid(),
                "auth": "a" * 64,
            }
        ),
        encoding="utf-8",
    )
    if kind == "symlink":
        receipt.symlink_to(target)
    elif kind == "hardlink":
        os.link(target, receipt)
    elif kind == "fifo":
        os.mkfifo(receipt)
    else:
        receipt.write_bytes(b"x" * 4097)

    started = time.monotonic()
    assert supervisor._provider_launch_started(str(receipt)) is False
    assert time.monotonic() - started < 1


def test_provider_launch_signal_receipt_detects_path_replacement(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    spec = importlib.util.spec_from_file_location("lease_supervisor_receipt_replacement", SUPERVISOR)
    assert spec is not None and spec.loader is not None
    supervisor = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(supervisor)
    receipt = tmp_path / "provider-launch.json"
    replacement = tmp_path / "replacement.json"
    payload = json.dumps(
        {
            "schema": "legion.provider-launch.v1",
            "status": "started",
            "provider_pid": os.getpid(),
            "auth": "a" * 64,
        }
    ).encode()
    receipt.write_bytes(payload)
    replacement.write_bytes(payload)
    real_read = os.read
    replaced = False

    def replace_after_read(descriptor: int, size: int) -> bytes:
        nonlocal replaced
        chunk = real_read(descriptor, size)
        if chunk and not replaced:
            os.replace(replacement, receipt)
            replaced = True
        return chunk

    monkeypatch.setattr(supervisor.os, "read", replace_after_read)
    assert supervisor._provider_launch_started(str(receipt)) is False
    assert replaced


def test_descendant_signal_receipt_fifo_does_not_hang_supervisor_cleanup(tmp_path: Path) -> None:
    signal_receipt = tmp_path / "provider-launch.json"
    os.mkfifo(signal_receipt)
    status_file = tmp_path / "lease.json"
    started = time.monotonic()
    result = subprocess.run(
        [
            sys.executable,
            str(SUPERVISOR),
            "--cwd",
            str(tmp_path),
            "--max-runtime-seconds",
            "1",
            "--status-file",
            str(status_file),
            "--descendant-signal-ready-file",
            str(signal_receipt),
            "--",
            sys.executable,
            "-c",
            "import time; time.sleep(30)",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        timeout=8,
    )
    assert result.returncode == 124
    assert json.loads(status_file.read_text(encoding="utf-8"))["status"] == "timed_out"
    assert time.monotonic() - started < 6


def test_expired_inherited_deadline_refuses_before_child_launch(tmp_path: Path) -> None:
    launched = tmp_path / "launched"
    environment = os.environ.copy()
    environment["LEGION_CHILD_LEASE_DEADLINE_NS"] = str(time.monotonic_ns() - 1)
    result, receipt, elapsed = run_supervised(
        tmp_path,
        10,
        [sys.executable, "-c", f"from pathlib import Path; Path({str(launched)!r}).touch()"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        env=environment,
    )
    assert result.returncode == 124
    assert receipt == {
        "schema": "legion.child-execution-lease.v1",
        "status": "launch_failed",
        "reason": "inherited child lease deadline expired before launch",
        "max_runtime_seconds": 10,
    }
    assert not launched.exists()
    assert elapsed < 1


def test_deadline_expiring_during_launch_setup_refuses_immediately_before_popen(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    status_file = tmp_path / "setup-expired.json"
    spec = importlib.util.spec_from_file_location("lease_supervisor_setup_deadline", SUPERVISOR)
    assert spec is not None and spec.loader is not None
    supervisor = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(supervisor)
    clock = iter((50, 101))
    launched = False

    def forbidden_popen(*_args, **_kwargs):
        nonlocal launched
        launched = True
        raise AssertionError("Popen must not run after the absolute deadline")

    monkeypatch.setattr(supervisor.sys, "platform", "darwin")
    monkeypatch.setattr(supervisor.time, "monotonic_ns", lambda: next(clock))
    monkeypatch.setattr(supervisor, "_darwin_inherited_host_sandboxed", lambda: False)
    monkeypatch.setattr(
        supervisor,
        "_darwin_launch_fingerprint",
        lambda command: (command, "/fixture/deny", "/fixture/allow", ""),
    )
    monkeypatch.setattr(supervisor, "_darwin_sandbox_probe", lambda *_args: True)
    monkeypatch.setattr(
        supervisor,
        "_establish_darwin_owner_lease",
        lambda *_args: (-1, "/fixture/owner", "fixture-nonce"),
    )
    monkeypatch.setattr(supervisor.signal, "signal", lambda *_args: None)
    monkeypatch.setattr(supervisor.subprocess, "Popen", forbidden_popen)
    monkeypatch.setenv("LEGION_CHILD_LEASE_DEADLINE_NS", "100")
    for name in (
        "LEGION_ANCESTOR_SUPERVISOR_DENY_CANARY",
        "LEGION_ANCESTOR_SUPERVISOR_ALLOW_CANARY",
        "LEGION_ANCESTOR_SUPERVISOR_OWNER_PATH",
        "LEGION_ANCESTOR_SUPERVISOR_OWNER_NONCE",
        "LEGION_ANCESTOR_SUPERVISOR_OWNER_PID",
    ):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setattr(
        supervisor.sys,
        "argv",
        [
            str(SUPERVISOR),
            "--cwd",
            str(tmp_path),
            "--max-runtime-seconds",
            "30",
            "--status-file",
            str(status_file),
            "--",
            "/fixture/provider",
        ],
    )

    assert supervisor.main() == 124
    assert not launched
    assert json.loads(status_file.read_text(encoding="utf-8")) == {
        "schema": "legion.child-execution-lease.v1",
        "status": "launch_failed",
        "reason": "inherited child lease deadline expired during launch setup",
        "max_runtime_seconds": 30,
    }


@pytest.mark.parametrize(
    ("signum", "expected_returncode"),
    ((signal.SIGTERM, 143), (signal.SIGINT, 130)),
)
def test_signal_after_handlers_before_popen_cancels_without_child_launch(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    signum: int,
    expected_returncode: int,
) -> None:
    status_file = tmp_path / "prelaunch-cancelled.json"
    spec = importlib.util.spec_from_file_location(
        f"lease_supervisor_prelaunch_signal_{signum}", SUPERVISOR
    )
    assert spec is not None and spec.loader is not None
    supervisor = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(supervisor)
    launched = False

    def forbidden_popen(*_args, **_kwargs):
        nonlocal launched
        launched = True
        raise AssertionError("Popen must not run after prelaunch cancellation")

    original_environment_copy = supervisor.os.environ.copy

    def signal_during_prelaunch_setup():
        environment = original_environment_copy()
        os.kill(os.getpid(), signum)
        return environment

    previous_handlers = {
        caught: signal.getsignal(caught)
        for caught in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
    }
    monkeypatch.setattr(supervisor.sys, "platform", "linux")
    monkeypatch.setattr(supervisor.os.environ, "copy", signal_during_prelaunch_setup)
    monkeypatch.setattr(supervisor.subprocess, "Popen", forbidden_popen)
    monkeypatch.setattr(
        supervisor.sys,
        "argv",
        [
            str(SUPERVISOR),
            "--cwd",
            str(tmp_path),
            "--max-runtime-seconds",
            "30",
            "--status-file",
            str(status_file),
            "--",
            "/fixture/provider",
        ],
    )

    try:
        assert supervisor.main() == expected_returncode
    finally:
        for caught, handler in previous_handlers.items():
            signal.signal(caught, handler)

    assert not launched
    assert json.loads(status_file.read_text(encoding="utf-8")) == {
        "schema": "legion.child-execution-lease.v1",
        "status": "launch_failed",
        "reason": f"cancelled by {signal.Signals(signum).name}",
        "max_runtime_seconds": 30,
    }


def test_signal_pending_inside_atomic_launch_region_refuses_before_popen(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    status_file = tmp_path / "atomic-prelaunch-cancelled.json"
    spec = importlib.util.spec_from_file_location("lease_supervisor_atomic_signal", SUPERVISOR)
    assert spec is not None and spec.loader is not None
    supervisor = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(supervisor)
    mask_calls = []

    monkeypatch.setattr(supervisor.sys, "platform", "linux")
    monkeypatch.setattr(supervisor.signal, "signal", lambda *_args: None)
    monkeypatch.setattr(
        supervisor.signal,
        "pthread_sigmask",
        lambda operation, signals: mask_calls.append((operation, set(signals))) or set(),
    )
    monkeypatch.setattr(supervisor.signal, "sigpending", lambda: {signal.SIGTERM})
    monkeypatch.setattr(
        supervisor.subprocess,
        "Popen",
        lambda *_args, **_kwargs: pytest.fail("Popen ran with a launch signal pending"),
    )
    monkeypatch.setattr(
        supervisor.sys,
        "argv",
        [str(SUPERVISOR), "--cwd", str(tmp_path), "--max-runtime-seconds", "30",
         "--status-file", str(status_file), "--", "/fixture/provider"],
    )

    assert supervisor.main() == 143
    assert mask_calls[0][0] == signal.SIG_BLOCK
    assert mask_calls[-1][0] == signal.SIG_SETMASK
    assert json.loads(status_file.read_text(encoding="utf-8")) == {
        "schema": "legion.child-execution-lease.v1",
        "status": "launch_failed",
        "reason": "cancelled by SIGTERM before child launch",
        "max_runtime_seconds": 30,
    }


def test_signal_after_waiting_launcher_starts_cannot_exec_provider(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    status_file = tmp_path / "launcher-cancelled.json"
    marker = tmp_path / "provider-started"
    spec = importlib.util.spec_from_file_location("lease_supervisor_exec_gate", SUPERVISOR)
    assert spec is not None and spec.loader is not None
    supervisor = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(supervisor)
    real_popen = subprocess.Popen

    def signal_after_launcher(*args, **kwargs):
        child = real_popen(*args, **kwargs)
        os.kill(os.getpid(), signal.SIGTERM)
        return child

    class FinishedTracker:
        def __init__(self, *_args):
            pass

        def start(self):
            pass

        def close(self):
            return True

    handlers = {caught: signal.getsignal(caught)
                for caught in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
    monkeypatch.setattr(supervisor.sys, "platform", "linux")
    monkeypatch.setattr(supervisor.subprocess, "Popen", signal_after_launcher)
    monkeypatch.setattr(supervisor, "DescendantTracker", FinishedTracker)
    monkeypatch.setattr(supervisor, "_terminate_tree", lambda *_args: True)
    monkeypatch.setattr(
        supervisor.sys, "argv",
        [str(SUPERVISOR), "--cwd", str(tmp_path), "--max-runtime-seconds", "30",
         "--status-file", str(status_file), "--", sys.executable, "-c",
         f"from pathlib import Path; Path({str(marker)!r}).touch()"],
    )
    try:
        assert supervisor.main() == 143
    finally:
        for caught, handler in handlers.items():
            signal.signal(caught, handler)
    assert json.loads(status_file.read_text(encoding="utf-8"))["status"] == "launch_failed"
    assert not marker.exists()


def test_signal_during_cleanup_cannot_rewrite_an_observed_child_completion(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    status_file = tmp_path / "completed-before-late-signal.json"
    spec = importlib.util.spec_from_file_location("lease_supervisor_late_signal", SUPERVISOR)
    assert spec is not None and spec.loader is not None
    supervisor = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(supervisor)

    class FinishedTracker:
        def __init__(self, *_args):
            pass

        def start(self):
            pass

        def raise_if_error(self):
            pass

        def close(self):
            return True

    def signal_after_observed_exit(*_args):
        os.kill(os.getpid(), signal.SIGTERM)
        return True

    handlers = {
        caught: signal.getsignal(caught)
        for caught in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
    }
    monkeypatch.setattr(supervisor.sys, "platform", "linux")
    monkeypatch.setattr(supervisor, "DescendantTracker", FinishedTracker)
    monkeypatch.setattr(supervisor, "_terminate_tree", signal_after_observed_exit)
    monkeypatch.setattr(
        supervisor.sys,
        "argv",
        [str(SUPERVISOR), "--cwd", str(tmp_path), "--max-runtime-seconds", "30",
         "--status-file", str(status_file), "--", "/usr/bin/true"],
    )
    try:
        assert supervisor.main() == 0
    finally:
        for caught, handler in handlers.items():
            signal.signal(caught, handler)
    receipt = json.loads(status_file.read_text(encoding="utf-8"))
    assert receipt["status"] == "completed"
    assert receipt["child_exit_code"] == 0


def test_signal_between_completed_poll_and_cancel_snapshot_keeps_completion(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    status_file = tmp_path / "completed-at-poll.json"
    spec = importlib.util.spec_from_file_location("lease_supervisor_poll_signal", SUPERVISOR)
    assert spec is not None and spec.loader is not None
    supervisor = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(supervisor)

    real_popen = subprocess.Popen

    class SignalAfterCompletedPoll:
        def __init__(self, *args, **kwargs):
            self.child = real_popen(*args, **kwargs)
            self.signalled = False

        def poll(self):
            result = self.child.poll()
            if result is not None and not self.signalled:
                self.signalled = True
                os.kill(os.getpid(), signal.SIGTERM)
            return result

        def __getattr__(self, name):
            return getattr(self.child, name)

    class FinishedTracker:
        def __init__(self, *_args):
            pass

        def start(self):
            pass

        def raise_if_error(self):
            pass

        def close(self):
            return True

    handlers = {
        caught: signal.getsignal(caught)
        for caught in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
    }
    monkeypatch.setattr(supervisor.sys, "platform", "linux")
    monkeypatch.setattr(supervisor.subprocess, "Popen", SignalAfterCompletedPoll)
    monkeypatch.setattr(supervisor, "DescendantTracker", FinishedTracker)
    monkeypatch.setattr(supervisor, "_terminate_tree", lambda *_args: True)
    monkeypatch.setattr(
        supervisor.sys,
        "argv",
        [str(SUPERVISOR), "--cwd", str(tmp_path), "--max-runtime-seconds", "30",
         "--status-file", str(status_file), "--", "/usr/bin/true"],
    )
    try:
        assert supervisor.main() == 0
    finally:
        for caught, handler in handlers.items():
            signal.signal(caught, handler)
    receipt = json.loads(status_file.read_text(encoding="utf-8"))
    assert receipt["status"] == "completed"
    assert receipt["child_exit_code"] == 0


def test_signal_pending_before_completed_poll_remains_cancellation(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    status_file = tmp_path / "pending-before-poll.json"
    spec = importlib.util.spec_from_file_location("lease_supervisor_pending_poll", SUPERVISOR)
    assert spec is not None and spec.loader is not None
    supervisor = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(supervisor)

    real_popen = subprocess.Popen

    class CompletedChild:
        def __init__(self, *args, **kwargs):
            self.child = real_popen(*args, **kwargs)
            self.pid = self.child.pid

        def poll(self):
            return 0

        def __getattr__(self, name):
            return getattr(self.child, name)

    class FinishedTracker:
        def __init__(self, *_args):
            pass

        def start(self):
            pass

        def raise_if_error(self):
            pass

        def close(self):
            return True

    real_mask = signal.pthread_sigmask
    mask_count = 0

    def pending_at_poll(operation, signals):
        nonlocal mask_count
        previous = real_mask(operation, signals)
        if operation == signal.SIG_BLOCK:
            mask_count += 1
            if mask_count == 2:
                os.kill(os.getpid(), signal.SIGTERM)
        return previous

    handlers = {caught: signal.getsignal(caught)
                for caught in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
    monkeypatch.setattr(supervisor.sys, "platform", "linux")
    monkeypatch.setattr(supervisor.signal, "pthread_sigmask", pending_at_poll)
    monkeypatch.setattr(supervisor.subprocess, "Popen", CompletedChild)
    monkeypatch.setattr(supervisor, "DescendantTracker", FinishedTracker)
    monkeypatch.setattr(supervisor, "_terminate_tree", lambda *_args: True)
    monkeypatch.setattr(
        supervisor.sys, "argv",
        [str(SUPERVISOR), "--cwd", str(tmp_path), "--max-runtime-seconds", "30",
         "--status-file", str(status_file), "--", "/usr/bin/true"],
    )
    try:
        assert supervisor.main() == 143
    finally:
        real_mask(signal.SIG_UNBLOCK, {signal.SIGTERM})
        for caught, handler in handlers.items():
            signal.signal(caught, handler)
    assert json.loads(status_file.read_text(encoding="utf-8"))["status"] == "cancelled"


def test_command_disappearing_before_popen_still_writes_lease_receipt(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    missing = tmp_path / "admitted-but-removed"
    status_file = tmp_path / "launch-race.json"
    spec = importlib.util.spec_from_file_location("lease_supervisor_launch_race", SUPERVISOR)
    assert spec is not None and spec.loader is not None
    supervisor = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(supervisor)

    def disappear(*_args, **_kwargs):
        raise FileNotFoundError(errno.ENOENT, "No such file or directory", str(missing))

    monkeypatch.setattr(supervisor.sys, "platform", "linux")
    monkeypatch.setattr(supervisor.subprocess, "Popen", disappear)
    monkeypatch.setattr(
        supervisor.sys,
        "argv",
        [
            str(SUPERVISOR),
            "--cwd",
            str(tmp_path),
            "--max-runtime-seconds",
            "2",
            "--status-file",
            str(status_file),
            "--",
            str(missing),
        ],
    )

    assert supervisor.main() == 127
    receipt = json.loads(status_file.read_text(encoding="utf-8"))
    assert receipt == {
        "schema": "legion.child-execution-lease.v1",
        "status": "launch_failed",
        "reason": f"child launch failed: command not found: {missing}",
        "max_runtime_seconds": 2,
    }


def test_popen_execution_error_is_typed_as_no_launch(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    status_file = tmp_path / "launch-denied.json"
    spec = importlib.util.spec_from_file_location("lease_supervisor_launch_denied", SUPERVISOR)
    assert spec is not None and spec.loader is not None
    supervisor = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(supervisor)

    def denied(*_args, **_kwargs):
        raise PermissionError(errno.EACCES, "Permission denied", "/fixture/provider")

    monkeypatch.setattr(supervisor.sys, "platform", "linux")
    monkeypatch.setattr(supervisor.subprocess, "Popen", denied)
    monkeypatch.setattr(
        supervisor.sys,
        "argv",
        [
            str(SUPERVISOR),
            "--cwd",
            str(tmp_path),
            "--max-runtime-seconds",
            "2",
            "--status-file",
            str(status_file),
            "--",
            "/fixture/provider",
        ],
    )

    assert supervisor.main() == 126
    receipt = json.loads(status_file.read_text(encoding="utf-8"))
    assert receipt["schema"] == "legion.child-execution-lease.v1"
    assert receipt["status"] == "launch_failed"
    assert receipt["max_runtime_seconds"] == 2
    assert "Permission denied" in receipt["reason"]
    assert "child_exit_code" not in receipt


def test_darwin_host_policy_inspection_failure_is_containment_no_launch(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    status_file = tmp_path / "host-inspection.json"
    spec = importlib.util.spec_from_file_location("lease_supervisor_host_inspection", SUPERVISOR)
    assert spec is not None and spec.loader is not None
    supervisor = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(supervisor)

    def inspection_failed():
        raise supervisor.ProcessInspectionError("fixture inspection failure")

    monkeypatch.setattr(supervisor.sys, "platform", "darwin")
    monkeypatch.setattr(supervisor, "_darwin_inherited_host_sandboxed", inspection_failed)
    monkeypatch.setattr(supervisor.subprocess, "Popen", lambda *_args, **_kwargs: pytest.fail("Popen ran"))
    monkeypatch.setattr(
        supervisor.sys,
        "argv",
        [str(SUPERVISOR), "--cwd", str(tmp_path), "--max-runtime-seconds", "30",
         "--status-file", str(status_file), "--", "/fixture/provider"],
    )

    assert supervisor.main() == 70
    assert json.loads(status_file.read_text(encoding="utf-8")) == {
        "schema": "legion.child-execution-lease.v1",
        "status": "cleanup_failed",
        "reason": "cannot inspect inherited Seatbelt policy: fixture inspection failure",
        "max_runtime_seconds": 30,
        "child_started": False,
    }


def test_darwin_fresh_fingerprint_failure_is_authenticated_no_launch(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    status_file = tmp_path / "fresh-fingerprint.json"
    spec = importlib.util.spec_from_file_location("lease_supervisor_fresh_fingerprint", SUPERVISOR)
    assert spec is not None and spec.loader is not None
    supervisor = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(supervisor)

    monkeypatch.setattr(supervisor.sys, "platform", "darwin")
    monkeypatch.setattr(supervisor, "_darwin_inherited_host_sandboxed", lambda: False)
    monkeypatch.setattr(
        supervisor, "_darwin_launch_fingerprint",
        lambda _command: (_ for _ in ()).throw(OSError("fixture fingerprint failure")),
    )
    monkeypatch.setattr(supervisor.subprocess, "Popen", lambda *_args, **_kwargs: pytest.fail("Popen ran"))
    monkeypatch.setattr(
        supervisor.sys,
        "argv",
        [str(SUPERVISOR), "--cwd", str(tmp_path), "--max-runtime-seconds", "30",
         "--status-file", str(status_file), "--", "/fixture/provider"],
    )

    assert supervisor.main() == 2
    receipt = json.loads(status_file.read_text(encoding="utf-8"))
    assert receipt["status"] == "launch_failed"
    assert "fixture fingerprint failure" in receipt["reason"]
    assert "child_exit_code" not in receipt


@pytest.mark.skipif(sys.platform != "darwin", reason="Seatbelt fingerprints are Darwin-only")
def test_inactive_inherited_fingerprint_cannot_disable_direct_launch(tmp_path: Path) -> None:
    deny_canary = tmp_path / "deny"
    allow_canary = tmp_path / "allow"
    launched = tmp_path / "launched"
    deny_canary.touch()
    allow_canary.touch()
    environment = os.environ.copy()
    environment["LEGION_ANCESTOR_SUPERVISOR_DENY_CANARY"] = str(deny_canary)
    environment["LEGION_ANCESTOR_SUPERVISOR_ALLOW_CANARY"] = str(allow_canary)
    result, receipt, _elapsed = run_supervised(
        tmp_path,
        2,
        [sys.executable, "-c", f"from pathlib import Path; Path({str(launched)!r}).touch()"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        env=environment,
    )
    assert result.returncode == 0
    assert receipt["status"] == "completed"
    assert launched.exists()


@pytest.mark.skipif(sys.platform != "darwin", reason="Seatbelt inheritance is Darwin-only")
def test_existing_seatbelt_host_without_run_unique_canaries_fails_closed(tmp_path: Path) -> None:
    """An arbitrary outer policy cannot safely identify reparented descendants."""

    home_probe = Path.home() / ".ssh"
    launched = tmp_path / "launched"
    status_file = tmp_path / "outer-seatbelt.json"
    profile = (
        '(version 1)(allow default)'
        f'(deny file-read* (subpath "{home_probe}"))'
    )
    environment = os.environ.copy()
    environment.pop("LEGION_ANCESTOR_SUPERVISOR_DENY_CANARY", None)
    environment.pop("LEGION_ANCESTOR_SUPERVISOR_ALLOW_CANARY", None)
    result = subprocess.run(
        [
            "/usr/bin/sandbox-exec",
            "-p",
            profile,
            sys.executable,
            str(SUPERVISOR),
            "--cwd",
            str(tmp_path),
            "--max-runtime-seconds",
            "2",
            "--status-file",
            str(status_file),
            "--",
            sys.executable,
            "-c",
            (
                "import ctypes,os,pathlib,sys;"
                "s=ctypes.CDLL('/usr/lib/libsandbox.1.dylib');"
                "s.sandbox_check.argtypes=(ctypes.c_int,ctypes.c_char_p,ctypes.c_int);"
                "s.sandbox_check.restype=ctypes.c_int;"
                f"assert s.sandbox_check(os.getpid(),b'file-read-data',1,b'{home_probe}')>0;"
                f"pathlib.Path({str(launched)!r}).touch()"
            ),
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        env=environment,
        timeout=8,
    )
    assert result.returncode == 70, result.stderr.decode(errors="replace")
    receipt = json.loads(status_file.read_text(encoding="utf-8"))
    assert receipt["status"] == "cleanup_failed"
    assert receipt["child_started"] is False
    assert "run-unique supervisor fingerprint" in receipt["reason"]
    assert not launched.exists()


@pytest.mark.skipif(sys.platform != "darwin", reason="Seatbelt inheritance is Darwin-only")
def test_network_only_seatbelt_host_without_run_unique_canaries_fails_closed(tmp_path: Path) -> None:
    status_file = tmp_path / "network-seatbelt.json"
    launched = tmp_path / "launched"
    environment = os.environ.copy()
    environment.pop("LEGION_ANCESTOR_SUPERVISOR_DENY_CANARY", None)
    environment.pop("LEGION_ANCESTOR_SUPERVISOR_ALLOW_CANARY", None)
    result = subprocess.run(
        [
            "/usr/bin/sandbox-exec",
            "-p",
            '(version 1)(allow default)(deny network*)',
            sys.executable,
            str(SUPERVISOR),
            "--cwd",
            str(tmp_path),
            "--max-runtime-seconds",
            "2",
            "--status-file",
            str(status_file),
            "--",
            sys.executable,
            "-c",
            f"from pathlib import Path; Path({str(launched)!r}).touch()",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        env=environment,
        timeout=8,
    )
    assert result.returncode == 70, result.stderr.decode(errors="replace")
    receipt = json.loads(status_file.read_text(encoding="utf-8"))
    assert receipt["status"] == "cleanup_failed"
    assert receipt["child_started"] is False
    assert "run-unique supervisor fingerprint" in receipt["reason"]
    assert not launched.exists()


@pytest.mark.skipif(sys.platform != "darwin", reason="Seatbelt inheritance is Darwin-only")
def test_caller_chosen_active_fingerprint_without_supervisor_owner_fails_closed(tmp_path: Path) -> None:
    deny_canary = tmp_path / "deny"
    allow_canary = tmp_path / "allow"
    pid_file = tmp_path / "detached.pid"
    status_file = tmp_path / "inherited-fingerprint.json"
    deny_canary.touch()
    allow_canary.touch()
    profile = (
        '(version 1)(allow default)'
        f'(deny file-read* (literal "{deny_canary}"))'
    )
    environment = os.environ.copy()
    environment["LEGION_ANCESTOR_SUPERVISOR_DENY_CANARY"] = str(deny_canary)
    environment["LEGION_ANCESTOR_SUPERVISOR_ALLOW_CANARY"] = str(allow_canary)
    result = subprocess.run(
        [
            "/usr/bin/sandbox-exec",
            "-p",
            profile,
            sys.executable,
            str(SUPERVISOR),
            "--cwd",
            str(tmp_path),
            "--max-runtime-seconds",
            "2",
            "--status-file",
            str(status_file),
            "--",
            sys.executable,
            "-c",
            """
import os, sys
if os.fork() != 0:
    os._exit(0)
os.setsid()
if os.fork() != 0:
    os._exit(0)
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    stream.write(str(os.getpid()))
null = os.open("/dev/null", os.O_RDWR)
for descriptor in (0, 1, 2):
    os.dup2(null, descriptor)
if null > 2:
    os.close(null)
os.execve("/bin/sleep", ["sleep", "30"], {})
""",
            str(pid_file),
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        env=environment,
        timeout=8,
    )
    assert result.returncode == 70, result.stderr.decode(errors="replace")
    receipt = json.loads(status_file.read_text(encoding="utf-8"))
    assert receipt["status"] == "cleanup_failed"
    assert receipt["child_started"] is False
    assert "active outer Legion supervisor owner" in receipt["reason"]
    assert not pid_file.exists()


@pytest.mark.skipif(sys.platform != "darwin", reason="Seatbelt inheritance is Darwin-only")
def test_stale_forged_owner_receipt_cannot_authorize_nested_launch(tmp_path: Path) -> None:
    fingerprint = tmp_path / "fingerprint"
    fingerprint.mkdir()
    deny_canary = fingerprint / "deny"
    allow_canary = fingerprint / "allow"
    owner_nonce = "a" * 64
    owner_path = fingerprint / f".legion-supervisor-owner-{owner_nonce}"
    launched = tmp_path / "launched"
    status_file = tmp_path / "forged-owner.json"
    deny_canary.touch()
    allow_canary.touch()
    owner_path.write_text(
        json.dumps(
            {
                "schema": "legion.supervisor-owner.v1",
                "pid": os.getpid(),
                "nonce": owner_nonce,
                "deny_canary": str(deny_canary),
                "allow_canary": str(allow_canary),
            },
            separators=(",", ":"),
        )
        + "\n",
        encoding="utf-8",
    )
    owner_path.chmod(0o600)
    profile = (
        '(version 1)(allow default)'
        f'(deny file-read* (literal "{deny_canary}"))'
        f'(deny file-write* (subpath "{fingerprint}"))'
    )
    environment = os.environ.copy()
    environment.update(
        {
            "LEGION_ANCESTOR_SUPERVISOR_DENY_CANARY": str(deny_canary),
            "LEGION_ANCESTOR_SUPERVISOR_ALLOW_CANARY": str(allow_canary),
            "LEGION_ANCESTOR_SUPERVISOR_OWNER_PATH": str(owner_path),
            "LEGION_ANCESTOR_SUPERVISOR_OWNER_NONCE": owner_nonce,
            "LEGION_ANCESTOR_SUPERVISOR_OWNER_PID": str(os.getpid()),
        }
    )
    result = subprocess.run(
        [
            "/usr/bin/sandbox-exec",
            "-p",
            profile,
            sys.executable,
            str(SUPERVISOR),
            "--cwd",
            str(tmp_path),
            "--max-runtime-seconds",
            "2",
            "--status-file",
            str(status_file),
            "--",
            sys.executable,
            "-c",
            f"from pathlib import Path; Path({str(launched)!r}).touch()",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        env=environment,
        timeout=8,
    )
    assert result.returncode == 70, result.stderr.decode(errors="replace")
    receipt = json.loads(status_file.read_text(encoding="utf-8"))
    assert receipt["status"] == "cleanup_failed"
    assert receipt["child_started"] is False
    assert not launched.exists()


@pytest.mark.skipif(sys.platform != "darwin", reason="Seatbelt inheritance is Darwin-only")
def test_nested_supervisor_accepts_live_outer_owner_lease(tmp_path: Path) -> None:
    inner_status = tmp_path / "inner.json"
    launched = tmp_path / "inner-launched"
    result, outer_receipt, _elapsed = run_supervised(
        tmp_path,
        3,
        [
            sys.executable,
            str(SUPERVISOR),
            "--cwd",
            str(tmp_path),
            "--max-runtime-seconds",
            "2",
            "--status-file",
            str(inner_status),
            "--",
            sys.executable,
            "-c",
            f"from pathlib import Path; Path({str(launched)!r}).touch()",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    assert result.returncode == 0, result.stderr.decode(errors="replace")
    assert outer_receipt["status"] == "completed"
    assert json.loads(inner_status.read_text(encoding="utf-8"))["status"] == "completed"
    assert launched.exists()


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


@pytest.mark.skipif(sys.platform != "darwin", reason="Seatbelt fingerprints are Darwin-only")
def test_direct_launch_reaps_rapid_reparent_after_environment_is_shed(tmp_path: Path) -> None:
    """No adapter-supplied canaries are needed for a direct supervised launch."""

    unrelated = subprocess.Popen(["/bin/sleep", "30"])
    try:
        for ordinal in range(5):
            pid_file = tmp_path / f"rapid-{ordinal}.pid"
            program = """
import os, sys
if os.fork() != 0:
    os._exit(0)
os.setsid()
if os.fork() != 0:
    os._exit(0)
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    stream.write(str(os.getpid()))
null = os.open("/dev/null", os.O_RDWR)
for descriptor in (0, 1, 2):
    os.dup2(null, descriptor)
if null > 2:
    os.close(null)
os.execve("/bin/sleep", ["sleep", "30"], {})
"""
            result, receipt, _elapsed = run_supervised(
                tmp_path,
                5,
                [sys.executable, "-c", program, str(pid_file)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
            )
            assert result.returncode == 0, result.stderr.decode(errors="replace")
            assert receipt["status"] == "completed"
            assert pid_file.is_file()
            assert wait_gone(int(pid_file.read_text(encoding="utf-8")))
        assert not process_is_gone(unrelated.pid)
    finally:
        unrelated.terminate()
        unrelated.wait(timeout=2)
