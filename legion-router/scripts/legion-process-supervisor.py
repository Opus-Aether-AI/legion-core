#!/usr/bin/env python3
"""Run one command and terminate its complete descendant tree on exit.

Process groups and bare PIDs are insufficient: a child may call ``setsid()``,
and either identifier can be reused after exit. The supervisor therefore keeps
kernel-bound process identities (Darwin unique IDs plus PID-version tokens, or
Linux pidfds). Production macOS callers additionally provide a random inherited
Seatbelt-policy fingerprint, which remains observable after a rapid child
reparenting sheds every user-space identity channel.
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
DARWIN_ZOMBIE_STATUS = 5


class ProcessInspectionError(RuntimeError):
    """A containment identity or policy could not be inspected safely."""


def _darwin_child_pids(parent: int) -> set[int]:
    try:
        libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
        function = libproc.proc_listchildpids
        function.argtypes = (ctypes.c_int, ctypes.c_void_p, ctypes.c_int)
        function.restype = ctypes.c_int
        required = function(parent, None, 0)
        if required < 0:
            raise ProcessInspectionError(f"proc_listchildpids sizing failed for {parent}")
        if required == 0:
            return set()
        # libproc variants disagree on whether the sizing probe is expressed
        # as bytes or entries; allocating that many pid_t slots is safe for
        # either contract and avoids truncating a busy host's process list.
        count = max(1, required)
        values = (ctypes.c_int * count)()
        found = function(parent, values, ctypes.sizeof(values))
        if found < 0:
            raise ProcessInspectionError(f"proc_listchildpids failed for {parent}")
        if found == 0:
            return set()
        return {int(values[index]) for index in range(min(found, count)) if values[index] > 0}
    except (AttributeError, OSError) as error:
        raise ProcessInspectionError("Darwin child enumeration is unavailable") from error


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
    try:
        libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
        function = libproc.proc_listallpids
        function.argtypes = (ctypes.c_void_p, ctypes.c_int)
        function.restype = ctypes.c_int
        required = function(None, 0)
        if required <= 0:
            raise ProcessInspectionError("proc_listallpids sizing failed")
        count = max(512, required + 256)
        for _attempt in range(4):
            values = (ctypes.c_int * count)()
            found = function(values, ctypes.sizeof(values))
            if found < 0:
                raise ProcessInspectionError("proc_listallpids failed")
            if found < count:
                return {int(values[index]) for index in range(found) if values[index] > 0}
            count *= 2
        raise ProcessInspectionError("proc_listallpids remained truncated")
    except (AttributeError, OSError) as error:
        raise ProcessInspectionError("Darwin process enumeration is unavailable") from error


def _darwin_sandbox_api() -> tuple[object, int]:
    try:
        sandbox = ctypes.CDLL("/usr/lib/libsandbox.1.dylib", use_errno=True)
        check = sandbox.sandbox_check
        check.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int)
        check.restype = ctypes.c_int
        no_report = ctypes.c_int.in_dll(sandbox, "SANDBOX_CHECK_NO_REPORT").value
        return check, 1 | no_report  # SANDBOX_FILTER_PATH | SANDBOX_CHECK_NO_REPORT
    except (AttributeError, OSError, ValueError) as error:
        raise ProcessInspectionError("Darwin sandbox inspection is unavailable") from error


def _darwin_bsd_info(pid: int) -> Optional[_DarwinBSDInfo]:
    try:
        libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
        function = libproc.proc_pidinfo
        function.argtypes = (ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int)
        function.restype = ctypes.c_int
        info = _DarwinBSDInfo()
        found = function(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info))  # PROC_PIDTBSDINFO
        if found == 0:
            return None
        if found != ctypes.sizeof(info) or info.pbi_pid != pid:
            raise ProcessInspectionError(f"proc_pidinfo returned an invalid record for {pid}")
        return info
    except (AttributeError, OSError) as error:
        raise ProcessInspectionError("Darwin process identity inspection is unavailable") from error


def _darwin_sandbox_decision(
    pid: int,
    deny: bytes,
    allow: bytes,
    api: Optional[tuple[object, int]] = None,
) -> Optional[bool]:
    check, flags = api or _darwin_sandbox_api()
    denied = check(pid, b"file-read-data", flags, ctypes.c_char_p(deny))
    permitted = check(pid, b"file-read-data", flags, ctypes.c_char_p(allow))
    if denied < 0 or permitted < 0:
        info = _darwin_bsd_info(pid)
        if info is None or info.pbi_status == DARWIN_ZOMBIE_STATUS:
            return None
        if info.pbi_uid == os.geteuid():
            raise ProcessInspectionError(f"sandbox_check failed for live same-user process {pid}")
        return False
    return denied > 0 and permitted == 0


def _darwin_sandbox_pids(deny_canary: str, allow_canary: str) -> set[int]:
    """Find processes carrying this supervisor's inherited Seatbelt policy.

    A child can shed its process group, ancestry, environment, and file
    descriptors, but it cannot shed an applied macOS sandbox.  The adjacent
    canaries create a run-unique policy fingerprint: this profile denies one
    exact path and permits the other, while unrelated unsandboxed processes
    permit both and unrelated app sandboxes normally treat both alike.
    """

    result: set[int] = set()
    deny = deny_canary.encode()
    allow = allow_canary.encode()
    api = _darwin_sandbox_api()
    for pid in _darwin_all_pids():
        if pid != os.getpid() and _darwin_sandbox_decision(pid, deny, allow, api):
            result.add(pid)
    return result


def _darwin_sandbox_probe(deny_canary: str, allow_canary: str) -> bool:
    """Fail closed when the host cannot query Seatbelt decisions."""

    try:
        check, flags = _darwin_sandbox_api()
        return (
            check(os.getpid(), b"file-read-data", flags, ctypes.c_char_p(deny_canary.encode())) == 0
            and check(os.getpid(), b"file-read-data", flags, ctypes.c_char_p(allow_canary.encode())) == 0
        )
    except ProcessInspectionError:
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


class _AuditToken(ctypes.Structure):
    _fields_ = (("value", ctypes.c_uint32 * 8),)


class _DarwinUniqueInfo(ctypes.Structure):
    _fields_ = (
        ("p_uuid", ctypes.c_uint8 * 16),
        ("p_uniqueid", ctypes.c_uint64),
        ("p_puniqueid", ctypes.c_uint64),
        ("p_idversion", ctypes.c_int32),
        ("p_orig_ppidversion", ctypes.c_int32),
        ("p_reserve2", ctypes.c_uint64),
        ("p_reserve3", ctypes.c_uint64),
    )


def _darwin_unique_info(pid: int) -> Optional[_DarwinUniqueInfo]:
    """Return the kernel unique ID that remains stable across exec."""

    try:
        libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
        function = libproc.proc_pidinfo
        function.argtypes = (ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int)
        function.restype = ctypes.c_int
        info = _DarwinUniqueInfo()
        found = function(pid, 17, 0, ctypes.byref(info), ctypes.sizeof(info))  # PROC_PIDUNIQIDENTIFIERINFO
        if found == 0:
            return None
        if found != ctypes.sizeof(info) or info.p_uniqueid == 0:
            raise ProcessInspectionError(f"proc_pidinfo returned an invalid unique record for {pid}")
        return info
    except (AttributeError, OSError) as error:
        raise ProcessInspectionError("Darwin unique process identity inspection is unavailable") from error


def _darwin_pidversion_token(pid: int, pidversion: int) -> _AuditToken:
    """Build the exact identity fields consumed by XNU's audit-token lookup.

    ``proc_signal_with_audittoken`` resolves only token fields 5 (PID) and 7
    (PID version), then derives credentials from the kernel process record.
    Constructing those fields from one ``PROC_PIDUNIQIDENTIFIERINFO`` record
    avoids ``task_name_for_pid``, which is unavailable inside common harness
    Seatbelt profiles, without falling back to a reusable bare PID.
    """

    token = _AuditToken()
    token.value[5] = pid
    token.value[7] = pidversion & 0xFFFFFFFF
    return token


class ProcessHandle:
    """Kernel-bound process identity safe against PID reuse and exec."""

    def __init__(
        self,
        pid: int,
        *,
        audit_token: Optional[_AuditToken] = None,
        unique_id: int = 0,
        pidfd: int = -1,
    ) -> None:
        self.pid = pid
        self.audit_token = audit_token
        self.unique_id = unique_id
        self.pidfd = pidfd
        self.closed = False

    @classmethod
    def open(cls, pid: int) -> Optional[ProcessHandle]:
        if sys.platform == "darwin":
            info = _darwin_unique_info(pid)
            if info is None:
                return None
            return cls(
                pid,
                audit_token=_darwin_pidversion_token(pid, int(info.p_idversion)),
                unique_id=int(info.p_uniqueid),
            )

        if sys.platform.startswith("linux"):
            if not hasattr(os, "pidfd_open") or not hasattr(signal, "pidfd_send_signal"):
                raise ProcessInspectionError("Linux pidfd APIs are unavailable")
            try:
                return cls(pid, pidfd=os.pidfd_open(pid, 0))
            except ProcessLookupError:
                return None
            except OSError as error:
                raise ProcessInspectionError(f"cannot acquire pidfd for process {pid}: {error}") from error
        raise ProcessInspectionError(f"unsupported supervisor platform: {sys.platform}")

    def _refresh_darwin_identity(self) -> bool:
        if self.audit_token is None:
            raise ProcessInspectionError(f"process {self.pid} has no Darwin audit token")
        info = _darwin_unique_info(self.pid)
        if info is None or int(info.p_uniqueid) != self.unique_id:
            return False
        pidversion = int(info.p_idversion) & 0xFFFFFFFF
        if int(self.audit_token.value[7]) == pidversion:
            return True
        self.audit_token = _darwin_pidversion_token(self.pid, pidversion)
        return True

    def is_live(self) -> bool:
        if self.closed:
            return False
        if sys.platform == "darwin":
            return self._refresh_darwin_identity()
        try:
            signal.pidfd_send_signal(self.pidfd, 0, None, 0)
            return True
        except ProcessLookupError:
            return False
        except OSError as error:
            raise ProcessInspectionError(f"cannot inspect pidfd for process {self.pid}: {error}") from error

    def send_signal(self, signum: int) -> bool:
        if self.closed:
            return False
        if sys.platform == "darwin":
            if self.audit_token is None:
                raise ProcessInspectionError(f"process {self.pid} has no Darwin audit token")
            for _attempt in range(3):
                if not self._refresh_darwin_identity():
                    return False
                try:
                    libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
                    function = libproc.proc_signal_with_audittoken
                    function.argtypes = (ctypes.POINTER(_AuditToken), ctypes.c_int)
                    function.restype = ctypes.c_int
                    result = function(ctypes.byref(self.audit_token), signum)
                except (AttributeError, OSError) as error:
                    raise ProcessInspectionError("Darwin audit-token signaling is unavailable") from error
                if result == 0:
                    return True
                if result != errno.ESRCH:
                    raise ProcessInspectionError(f"audit-token signal {signum} failed for {self.pid}: errno {result}")
            return False
        try:
            signal.pidfd_send_signal(self.pidfd, signum, None, 0)
            return True
        except ProcessLookupError:
            return False
        except OSError as error:
            raise ProcessInspectionError(f"pidfd signal {signum} failed for {self.pid}: {error}") from error

    def close(self) -> None:
        if self.closed:
            return
        self.closed = True
        if self.pidfd >= 0:
            os.close(self.pidfd)


class DescendantTracker:
    """Continuously remember descendants, including those that later reparent."""

    def __init__(self, root_pid: int, token: str, deny_canary: str = "", allow_canary: str = "") -> None:
        self.root_pid = root_pid
        self.token = token
        self.deny_canary = deny_canary
        self.allow_canary = allow_canary
        self._handles: dict[int, ProcessHandle] = {}
        self._error: Optional[ProcessInspectionError] = None
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._monitor, name="legion-descendants", daemon=True)
        self._thread_started = False

    def start(self) -> None:
        root = ProcessHandle.open(self.root_pid)
        if root is not None:
            self._handles[self.root_pid] = root
        self.snapshot()
        self._thread.start()
        self._thread_started = True

    def close(self) -> None:
        self._stop.set()
        if self._thread_started:
            self._thread.join(timeout=1.0)
        with self._lock:
            handles = list(self._handles.values())
            self._handles.clear()
        for handle in handles:
            handle.close()

    def raise_if_error(self) -> None:
        with self._lock:
            error = self._error
        if error is not None:
            raise error

    def _record(self, handle: ProcessHandle) -> bool:
        with self._lock:
            existing = self._handles.get(handle.pid)
            if existing is not None:
                handle.close()
                return existing.is_live()
            self._handles[handle.pid] = handle
            return True

    def _live_parent_pids(self) -> set[int]:
        dead: list[ProcessHandle] = []
        with self._lock:
            for pid, handle in list(self._handles.items()):
                if not handle.is_live():
                    dead.append(self._handles.pop(pid))
            result = set(self._handles)
        for handle in dead:
            handle.close()
        return result

    @staticmethod
    def _current_parent(pid: int) -> Optional[int]:
        if sys.platform == "darwin":
            info = _darwin_bsd_info(pid)
            return None if info is None else int(info.pbi_ppid)
        try:
            fields = (Path("/proc") / str(pid) / "stat").read_text(encoding="utf-8").rsplit(")", 1)[1].split()
            return int(fields[1])
        except (FileNotFoundError, IndexError, PermissionError, ValueError):
            return None

    def _capture_child(self, pid: int, parents: set[int]) -> bool:
        with self._lock:
            if pid in self._handles:
                return True
        handle = ProcessHandle.open(pid)
        if handle is None:
            return False
        parent = self._current_parent(pid)
        with self._lock:
            parent_handle = self._handles.get(parent) if parent is not None else None
        # The integer parent PID may have been reused since ``parents`` was
        # collected. Revalidate the original kernel handle after capturing the
        # child before accepting the relationship.
        if (
            parent not in parents
            or parent_handle is None
            or not parent_handle.is_live()
            or not handle.is_live()
        ):
            handle.close()
            return False
        return self._record(handle)

    def _capture_fingerprinted(self) -> None:
        deny = self.deny_canary.encode()
        allow = self.allow_canary.encode()
        for pid in _darwin_sandbox_pids(self.deny_canary, self.allow_canary) - {os.getpid()}:
            with self._lock:
                existing = self._handles.get(pid)
            if existing is not None and existing.is_live():
                continue
            handle = ProcessHandle.open(pid)
            if handle is None:
                continue
            # Re-check after capturing the kernel unique ID and audit token. If
            # PID reuse happens on either side, handle.is_live() rejects the
            # mismatch and signaling remains bound to the captured PID version.
            matches = _darwin_sandbox_decision(pid, deny, allow)
            if not matches or not handle.is_live():
                handle.close()
                continue
            self._record(handle)

    def _capture_token_pids(self) -> None:
        marker = f"LEGION_SUPERVISOR_TOKEN={self.token}".encode()
        for pid in _token_pids(self.token) - {os.getpid()}:
            handle = ProcessHandle.open(pid)
            if handle is None:
                continue
            try:
                still_owned = marker in (Path("/proc") / str(pid) / "environ").read_bytes().split(b"\0")
            except (FileNotFoundError, PermissionError):
                still_owned = False
            if not still_owned or not handle.is_live():
                handle.close()
                continue
            self._record(handle)

    def snapshot(self, *, include_token: bool = False) -> None:
        self.raise_if_error()
        parents = self._live_parent_pids()
        pending = list(parents)
        visited: set[int] = set()
        while pending:
            parent = pending.pop()
            if parent in visited:
                continue
            visited.add(parent)
            children = _child_pids(parent)
            for child in children:
                if child not in visited and self._capture_child(child, parents | visited):
                    pending.append(child)
        if sys.platform == "darwin" and self.deny_canary and self.allow_canary:
            self._capture_fingerprinted()
        elif include_token:
            self._capture_token_pids()

    def signal(self, signum: int) -> list[int]:
        # Signal deepest/newest children first so parents cannot immediately
        # replace them while shutdown proceeds.
        use_fingerprint = sys.platform == "darwin" and self.deny_canary and self.allow_canary
        self.snapshot(include_token=not use_fingerprint)
        return self.signal_known(signum)

    def signal_known(self, signum: int) -> list[int]:
        """Signal only already captured kernel handles after discovery fails."""

        dead: list[ProcessHandle] = []
        signalled: list[int] = []
        with self._lock:
            for pid, handle in sorted(self._handles.items(), reverse=True):
                if handle.send_signal(signum):
                    signalled.append(pid)
                else:
                    dead.append(handle)
            for handle in dead:
                self._handles.pop(handle.pid, None)
        for handle in dead:
            handle.close()
        return signalled

    def _monitor(self) -> None:
        while not self._stop.wait(POLL_SECONDS):
            try:
                self.snapshot()
            except ProcessInspectionError as error:
                with self._lock:
                    self._error = error
                self._stop.set()
                return


def _terminate_tree(process: subprocess.Popen[bytes], tracker: DescendantTracker) -> bool:
    def signal_unreaped_root(signum: int) -> bool:
        # A direct child cannot have its PID reused until this parent reaps it,
        # so signalling its Popen handle remains safe even when tracker setup or
        # descendant discovery failed before a kernel handle was captured.
        if process.poll() is not None:
            return False
        try:
            process.send_signal(signum)
            return True
        except ProcessLookupError:
            return False

    def drain(signum: int) -> bool:
        deadline = time.monotonic() + GRACE_SECONDS
        quiet_since: Optional[float] = None
        while time.monotonic() < deadline:
            try:
                live = tracker.signal(signum)
            except ProcessInspectionError as error:
                try:
                    tracker.signal_known(signum)
                except ProcessInspectionError:
                    pass
                signal_unreaped_root(signum)
                print(f"legion-process-supervisor: descendant inspection failed: {error}", file=sys.stderr)
                return False
            signal_unreaped_root(signum)
            if process.poll() is not None and not live:
                if quiet_since is None:
                    quiet_since = time.monotonic()
                elif time.monotonic() - quiet_since >= QUIET_SECONDS:
                    return True
            else:
                quiet_since = None
            time.sleep(POLL_SECONDS)
        return False

    if drain(signal.SIGTERM):
        return True
    return drain(signal.SIGKILL)


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
    cleanup_ok = True
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
            tracker.raise_if_error()
        if cancel_requested.is_set():
            cleanup_ok = _terminate_tree(process, tracker) and cleanup_ok
        try:
            returncode = process.wait(timeout=GRACE_SECONDS)
        except subprocess.TimeoutExpired:
            cleanup_ok = _terminate_tree(process, tracker) and cleanup_ok
            try:
                returncode = process.wait(timeout=GRACE_SECONDS)
            except subprocess.TimeoutExpired:
                returncode = -signal.SIGKILL
                cleanup_ok = False
    except ProcessInspectionError as error:
        print(f"legion-process-supervisor: descendant inspection failed: {error}", file=sys.stderr)
        returncode = 70
        cleanup_ok = False
    except OSError as error:
        if error.errno == errno.ENOENT:
            print(f"legion-process-supervisor: command not found: {command[0]}", file=sys.stderr)
            return 127
        raise
    finally:
        if process is not None and tracker is not None:
            cleanup_ok = _terminate_tree(process, tracker) and cleanup_ok
            tracker.close()

    if not cleanup_ok:
        print("legion-process-supervisor: descendant cleanup was incomplete", file=sys.stderr)
        return 70
    if interrupted:
        return 128 + interrupted
    return returncode if returncode >= 0 else 128 - returncode


if __name__ == "__main__":
    raise SystemExit(main())
