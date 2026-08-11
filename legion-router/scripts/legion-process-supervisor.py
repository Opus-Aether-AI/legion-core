#!/usr/bin/env python3
"""Run one command and terminate its complete descendant tree on exit.

Process groups alone are insufficient because a child may call ``setsid()``.
The supervisor therefore samples descendants for the lifetime of the command,
keeps every observed PID in the termination set, and combines per-PID signals
with the original process-group signal.  Linux's PID namespace remains the
outer containment boundary; this tracker closes the equivalent macOS gap.
"""

from __future__ import annotations

import argparse
import ctypes
import errno
import os
import secrets
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Optional


GRACE_SECONDS = 2.0
POLL_SECONDS = 0.02


def _group_exists(process_group: int) -> bool:
    try:
        os.killpg(process_group, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def _signal_group(process_group: int, signum: int) -> None:
    try:
        os.killpg(process_group, signum)
    except ProcessLookupError:
        pass
    except PermissionError:
        # Darwin can report EPERM for a now-empty/reused process group. The
        # per-PID descendant set remains authoritative in that case.
        pass


def _signal_pid(pid: int, signum: int) -> None:
    try:
        os.kill(pid, signum)
    except ProcessLookupError:
        pass
    except PermissionError:
        pass


def _darwin_child_pids(parent: int) -> set[int]:
    try:
        libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
        function = libproc.proc_listchildpids
        function.argtypes = (ctypes.c_int, ctypes.c_void_p, ctypes.c_int)
        function.restype = ctypes.c_int
        required = function(parent, None, 0)
        if required <= 0:
            return set()
        # libproc variants disagree on whether the sizing probe is expressed
        # as bytes or entries; allocating that many pid_t slots is safe for
        # either contract and avoids truncating a busy host's process list.
        count = max(1, required)
        values = (ctypes.c_int * count)()
        found = function(parent, values, ctypes.sizeof(values))
        if found <= 0:
            return set()
        return {int(values[index]) for index in range(min(found, count)) if values[index] > 0}
    except (AttributeError, OSError):
        return set()


def _proc_child_pids(parent: int) -> set[int]:
    children: set[int] = set()
    proc = Path("/proc")
    if not proc.is_dir():
        return children
    for entry in proc.iterdir():
        if not entry.name.isdigit():
            continue
        try:
            # comm may contain spaces and parentheses; the PPID is the second
            # field after the final closing parenthesis.
            fields = (entry / "stat").read_text(encoding="utf-8").rsplit(")", 1)[1].split()
            if len(fields) > 1 and int(fields[1]) == parent:
                children.add(int(entry.name))
        except (FileNotFoundError, IndexError, PermissionError, ValueError):
            continue
    return children


def _child_pids(parent: int) -> set[int]:
    if sys.platform == "darwin":
        return _darwin_child_pids(parent)
    return _proc_child_pids(parent)


def _darwin_process_bytes(pid: int) -> bytes:
    try:
        libc = ctypes.CDLL(None)
        mib = (ctypes.c_int * 3)(1, 49, pid)  # CTL_KERN, KERN_PROCARGS2, pid
        size = ctypes.c_size_t(0)
        if libc.sysctl(mib, 3, None, ctypes.byref(size), None, 0) != 0 or size.value <= 0:
            return b""
        buffer = ctypes.create_string_buffer(size.value)
        if libc.sysctl(mib, 3, buffer, ctypes.byref(size), None, 0) != 0:
            return b""
        return buffer.raw[: size.value]
    except (AttributeError, OSError):
        return b""


def _token_pids(token: str) -> set[int]:
    marker = f"LEGION_SUPERVISOR_TOKEN={token}".encode()
    result: set[int] = set()
    if sys.platform == "darwin":
        try:
            libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
            function = libproc.proc_listallpids
            function.argtypes = (ctypes.c_void_p, ctypes.c_int)
            function.restype = ctypes.c_int
            required = function(None, 0)
            if required <= 0:
                return result
            count = max(1, required)
            values = (ctypes.c_int * count)()
            found = function(values, ctypes.sizeof(values))
            for index in range(min(max(found, 0), count)):
                pid = int(values[index])
                if pid > 0 and marker in _darwin_process_bytes(pid):
                    result.add(pid)
        except (AttributeError, OSError):
            pass
        return result

    proc = Path("/proc")
    if proc.is_dir():
        for entry in proc.iterdir():
            if not entry.name.isdigit():
                continue
            try:
                if marker in (entry / "environ").read_bytes().split(b"\0"):
                    result.add(int(entry.name))
            except (FileNotFoundError, PermissionError):
                continue
    return result


def _pid_exists(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


class DescendantTracker:
    """Continuously remember descendants, including those that later reparent."""

    def __init__(self, root_pid: int, token: str) -> None:
        self.root_pid = root_pid
        self.token = token
        self._tracked: set[int] = set()
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._monitor, name="legion-descendants", daemon=True)

    def start(self) -> None:
        self.snapshot()
        self._thread.start()

    def close(self) -> None:
        self._stop.set()
        self._thread.join(timeout=1.0)

    def snapshot(self, *, include_token: bool = False) -> None:
        with self._lock:
            parents = {self.root_pid, *self._tracked}
        discovered: set[int] = set()
        pending = list(parents)
        visited: set[int] = set()
        while pending:
            parent = pending.pop()
            if parent in visited:
                continue
            visited.add(parent)
            children = _child_pids(parent)
            for child in children:
                if child not in discovered:
                    discovered.add(child)
                    pending.append(child)
        if discovered:
            with self._lock:
                self._tracked.update(discovered)
        if include_token:
            with self._lock:
                self._tracked.update(_token_pids(self.token) - {os.getpid()})

    def live_pids(self) -> list[int]:
        self.snapshot(include_token=True)
        with self._lock:
            return [pid for pid in self._tracked if _pid_exists(pid)]

    def signal(self, signum: int) -> None:
        # Signal deepest/newest children first so parents cannot immediately
        # replace them while shutdown proceeds.
        for pid in sorted(self.live_pids(), reverse=True):
            _signal_pid(pid, signum)

    def _monitor(self) -> None:
        while not self._stop.wait(POLL_SECONDS):
            self.snapshot()


def _terminate_tree(process: subprocess.Popen[bytes], tracker: DescendantTracker) -> None:
    process_group = process.pid
    tracker.snapshot(include_token=True)
    _signal_group(process_group, signal.SIGTERM)
    tracker.signal(signal.SIGTERM)
    deadline = time.monotonic() + GRACE_SECONDS
    while time.monotonic() < deadline:
        if process.poll() is not None and not _group_exists(process_group) and not tracker.live_pids():
            return
        time.sleep(POLL_SECONDS)
    tracker.snapshot(include_token=True)
    _signal_group(process_group, signal.SIGKILL)
    tracker.signal(signal.SIGKILL)
    deadline = time.monotonic() + GRACE_SECONDS
    while time.monotonic() < deadline:
        if process.poll() is not None and not _group_exists(process_group) and not tracker.live_pids():
            return
        time.sleep(POLL_SECONDS)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cwd", required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    return parser


def main() -> int:
    arguments = _parser().parse_args()
    command = arguments.command
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        print("legion-process-supervisor: command is required", file=sys.stderr)
        return 2

    process: Optional[subprocess.Popen[bytes]] = None
    tracker: Optional[DescendantTracker] = None
    interrupted = 0
    cancel_requested = threading.Event()
    returncode = 1
    supervisor_token = secrets.token_hex(24)

    def stop(signum: int, _frame: object) -> None:
        nonlocal interrupted
        interrupted = signum
        cancel_requested.set()

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGHUP, stop)

    try:
        environment = os.environ.copy()
        environment["LEGION_SUPERVISOR_TOKEN"] = supervisor_token
        process = subprocess.Popen(
            command,
            cwd=arguments.cwd,
            stdin=None,
            stdout=None,
            stderr=None,
            env=environment,
            start_new_session=True,
        )
        tracker = DescendantTracker(process.pid, supervisor_token)
        tracker.start()
        while process.poll() is None and not cancel_requested.wait(POLL_SECONDS):
            pass
        if cancel_requested.is_set():
            _terminate_tree(process, tracker)
        try:
            returncode = process.wait(timeout=GRACE_SECONDS)
        except subprocess.TimeoutExpired:
            _terminate_tree(process, tracker)
            try:
                returncode = process.wait(timeout=GRACE_SECONDS)
            except subprocess.TimeoutExpired:
                returncode = -signal.SIGKILL
    except OSError as error:
        if error.errno == errno.ENOENT:
            print(f"legion-process-supervisor: command not found: {command[0]}", file=sys.stderr)
            return 127
        raise
    finally:
        if process is not None and tracker is not None:
            _terminate_tree(process, tracker)
            tracker.close()

    if interrupted:
        return 128 + interrupted
    return returncode if returncode >= 0 else 128 - returncode


if __name__ == "__main__":
    raise SystemExit(main())
