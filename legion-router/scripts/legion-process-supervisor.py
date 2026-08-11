#!/usr/bin/env python3
"""Run one command and terminate its complete descendant tree on exit.

Process groups alone are insufficient because a child may call ``setsid()``.
The supervisor therefore samples descendants for the lifetime of the command,
keeps every observed PID in the termination set, and combines per-PID signals
with the original process-group signal. Linux's PID namespace remains the
outer containment boundary. Production macOS callers additionally provide a
run-unique inherited Seatbelt-policy fingerprint, which remains observable
after a rapid child reparenting sheds every user-space identity channel.
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
QUIET_SECONDS = 0.2


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


def _darwin_all_pids() -> set[int]:
    result: set[int] = set()
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
            if values[index] > 0:
                result.add(int(values[index]))
    except (AttributeError, OSError):
        pass
    return result


def _darwin_sandbox_pids(deny_canary: str, allow_canary: str) -> set[int]:
    """Find processes carrying this supervisor's inherited Seatbelt policy.

    A child can shed its process group, ancestry, environment, and file
    descriptors, but it cannot shed an applied macOS sandbox.  The adjacent
    canaries create a run-unique policy fingerprint: this profile denies one
    exact path and permits the other, while unrelated unsandboxed processes
    permit both and unrelated app sandboxes normally treat both alike.
    """

    result: set[int] = set()
    try:
        sandbox = ctypes.CDLL("/usr/lib/libsandbox.1.dylib", use_errno=True)
        check = sandbox.sandbox_check
        check.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int)
        check.restype = ctypes.c_int
        no_report = ctypes.c_int.in_dll(sandbox, "SANDBOX_CHECK_NO_REPORT").value
        flags = 1 | no_report  # SANDBOX_FILTER_PATH | SANDBOX_CHECK_NO_REPORT
        deny = deny_canary.encode()
        allow = allow_canary.encode()
        for pid in _darwin_all_pids():
            if pid == os.getpid():
                continue
            denied = check(pid, b"file-read-data", flags, ctypes.c_char_p(deny))
            permitted = check(pid, b"file-read-data", flags, ctypes.c_char_p(allow))
            if denied > 0 and permitted == 0:
                result.add(pid)
    except (AttributeError, OSError, ValueError):
        pass
    return result


def _darwin_sandbox_probe(deny_canary: str, allow_canary: str) -> bool:
    """Fail closed when the host cannot query Seatbelt decisions."""

    try:
        sandbox = ctypes.CDLL("/usr/lib/libsandbox.1.dylib", use_errno=True)
        check = sandbox.sandbox_check
        check.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int)
        check.restype = ctypes.c_int
        no_report = ctypes.c_int.in_dll(sandbox, "SANDBOX_CHECK_NO_REPORT").value
        flags = 1 | no_report
        return (
            check(os.getpid(), b"file-read-data", flags, ctypes.c_char_p(deny_canary.encode())) == 0
            and check(os.getpid(), b"file-read-data", flags, ctypes.c_char_p(allow_canary.encode())) == 0
        )
    except (AttributeError, OSError, ValueError):
        return False


def _token_pids(token: str) -> set[int]:
    marker = f"LEGION_SUPERVISOR_TOKEN={token}".encode()
    result: set[int] = set()
    if sys.platform == "darwin":
        # KERN_PROCARGS2 does not reliably expose another process's
        # environment on current macOS. Production sandboxed runs use the
        # unforgeable Seatbelt fingerprint below instead.
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


class _DarwinBSDInfo(ctypes.Structure):
    _fields_ = (
        ("pbi_flags", ctypes.c_uint32),
        ("pbi_status", ctypes.c_uint32),
        ("pbi_xstatus", ctypes.c_uint32),
        ("pbi_pid", ctypes.c_uint32),
        ("pbi_ppid", ctypes.c_uint32),
        ("pbi_uid", ctypes.c_uint32),
        ("pbi_gid", ctypes.c_uint32),
        ("pbi_ruid", ctypes.c_uint32),
        ("pbi_rgid", ctypes.c_uint32),
        ("pbi_svuid", ctypes.c_uint32),
        ("pbi_svgid", ctypes.c_uint32),
        ("rfu_1", ctypes.c_uint32),
        ("pbi_comm", ctypes.c_char * 16),
        ("pbi_name", ctypes.c_char * 32),
        ("pbi_nfiles", ctypes.c_uint32),
        ("pbi_pgid", ctypes.c_uint32),
        ("pbi_pjobc", ctypes.c_uint32),
        ("e_tdev", ctypes.c_uint32),
        ("e_tpgid", ctypes.c_uint32),
        ("pbi_nice", ctypes.c_int32),
        ("pbi_start_tvsec", ctypes.c_uint64),
        ("pbi_start_tvusec", ctypes.c_uint64),
    )


def _pid_identity(pid: int) -> Optional[tuple[int, int]]:
    """Return a kernel process-birth identity that survives exec."""

    if sys.platform == "darwin":
        try:
            libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
            function = libproc.proc_pidinfo
            function.argtypes = (ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int)
            function.restype = ctypes.c_int
            info = _DarwinBSDInfo()
            found = function(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info))  # PROC_PIDTBSDINFO
            if found != ctypes.sizeof(info) or info.pbi_pid != pid:
                return None
            return int(info.pbi_start_tvsec), int(info.pbi_start_tvusec)
        except (AttributeError, OSError):
            return None

    try:
        # starttime is field 22. Split after the final ')' because comm can
        # contain spaces and parentheses; the remaining list begins at field 3.
        fields = (Path("/proc") / str(pid) / "stat").read_text(encoding="utf-8").rsplit(")", 1)[1].split()
        return int(fields[19]), 0
    except (FileNotFoundError, IndexError, PermissionError, ValueError):
        return None


class DescendantTracker:
    """Continuously remember descendants, including those that later reparent."""

    def __init__(self, root_pid: int, token: str, deny_canary: str = "", allow_canary: str = "") -> None:
        self.root_pid = root_pid
        self.token = token
        self.deny_canary = deny_canary
        self.allow_canary = allow_canary
        self._tracked: set[int] = set()
        self._identities: dict[int, tuple[int, int]] = {}
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
            identities = {pid: identity for pid in discovered if (identity := _pid_identity(pid)) is not None}
            with self._lock:
                for pid, identity in identities.items():
                    if pid not in self._tracked:
                        self._tracked.add(pid)
                        self._identities[pid] = identity
        if include_token:
            token_identities = {
                pid: identity
                for pid in _token_pids(self.token) - {os.getpid()}
                if (identity := _pid_identity(pid)) is not None
            }
            with self._lock:
                for pid, identity in token_identities.items():
                    if pid not in self._tracked:
                        self._tracked.add(pid)
                        self._identities[pid] = identity

    def _live_tracked(self) -> set[int]:
        with self._lock:
            identities = dict(self._identities)
        return {pid for pid, identity in identities.items() if _pid_identity(pid) == identity}

    def live_pids(self) -> list[int]:
        use_sandbox_fingerprint = sys.platform == "darwin" and self.deny_canary and self.allow_canary
        self.snapshot(include_token=not use_sandbox_fingerprint)
        if use_sandbox_fingerprint:
            # Re-evaluate the kernel policy immediately before every signal.
            # Returning stale tracked PIDs here could target an unrelated
            # process after PID reuse.
            fingerprinted = _darwin_sandbox_pids(self.deny_canary, self.allow_canary) - {os.getpid()}
            fingerprint_identities = {
                pid: identity
                for pid in fingerprinted
                if (identity := _pid_identity(pid)) is not None
            }
            with self._lock:
                for pid, identity in fingerprint_identities.items():
                    if pid not in self._tracked:
                        self._tracked.add(pid)
                        self._identities[pid] = identity
            return sorted(fingerprinted | self._live_tracked())
        return sorted(self._live_tracked())

    def signal(self, signum: int) -> list[int]:
        # Signal deepest/newest children first so parents cannot immediately
        # replace them while shutdown proceeds.
        live = self.live_pids()
        for pid in sorted(live, reverse=True):
            _signal_pid(pid, signum)
        return live

    def _monitor(self) -> None:
        while not self._stop.wait(POLL_SECONDS):
            self.snapshot()


def _terminate_tree(process: subprocess.Popen[bytes], tracker: DescendantTracker) -> None:
    process_group = process.pid

    def drain(signum: int) -> bool:
        deadline = time.monotonic() + GRACE_SECONDS
        quiet_since: Optional[float] = None
        while time.monotonic() < deadline:
            _signal_group(process_group, signum)
            live = tracker.signal(signum)
            group_live = _group_exists(process_group)
            if process.poll() is not None and not group_live and not live:
                if quiet_since is None:
                    quiet_since = time.monotonic()
                elif time.monotonic() - quiet_since >= QUIET_SECONDS:
                    return True
            else:
                quiet_since = None
            time.sleep(POLL_SECONDS)
        return False

    if drain(signal.SIGTERM):
        return
    drain(signal.SIGKILL)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cwd", required=True)
    parser.add_argument("--darwin-sandbox-deny-canary", default="")
    parser.add_argument("--darwin-sandbox-allow-canary", default="")
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

    deny_canary = arguments.darwin_sandbox_deny_canary
    allow_canary = arguments.darwin_sandbox_allow_canary
    if bool(deny_canary) != bool(allow_canary):
        print("legion-process-supervisor: both Darwin sandbox canaries are required", file=sys.stderr)
        return 2
    if sys.platform == "darwin" and deny_canary:
        try:
            if Path(deny_canary).is_symlink() or Path(allow_canary).is_symlink():
                raise OSError("canary leaf must not be a symbolic link")
            deny_path = Path(deny_canary).resolve(strict=True)
            allow_path = Path(allow_canary).resolve(strict=True)
        except OSError as error:
            print(f"legion-process-supervisor: invalid Darwin sandbox canary: {error}", file=sys.stderr)
            return 2
        if (
            deny_path == allow_path
            or deny_path.parent != allow_path.parent
            or not deny_path.is_file()
            or not allow_path.is_file()
        ):
            print("legion-process-supervisor: Darwin sandbox canaries must be adjacent regular files", file=sys.stderr)
            return 2
        deny_canary = str(deny_path)
        allow_canary = str(allow_path)
        if not _darwin_sandbox_probe(deny_canary, allow_canary):
            print("legion-process-supervisor: Darwin sandbox inspection is unavailable", file=sys.stderr)
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
        tracker = DescendantTracker(process.pid, supervisor_token, deny_canary, allow_canary)
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
