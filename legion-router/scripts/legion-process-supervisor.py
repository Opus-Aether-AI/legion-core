#!/usr/bin/env python3
"""Run one command and terminate its complete descendant tree on exit.

Process groups and bare PIDs are insufficient: a child may call ``setsid()``,
and either identifier can be reused after exit. The supervisor therefore keeps
kernel-bound process identities (Darwin unique IDs plus PID-version tokens, or
Linux pidfds). Every macOS launch additionally receives a random inherited
Seatbelt-policy fingerprint, which remains observable after a rapid child
reparenting sheds every user-space identity channel. Callers that already apply
a filesystem sandbox may supply its fingerprint canaries instead. Nested
supervisors inherit and verify the enclosing fingerprint, leaving the outermost
tracker responsible for reparented descendants instead of attempting an
unsupported nested ``sandbox-exec`` application.
"""

from __future__ import annotations

import argparse
import ctypes
import errno
import fcntl
import json
import os
import pwd
import select
import secrets
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
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
        except (FileNotFoundError, ProcessLookupError, IndexError, PermissionError, ValueError):
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


def _darwin_inherited_host_sandboxed() -> bool:
    """Prove that this process already inherits a restrictive Seatbelt policy.

    Some trusted launchers apply Seatbelt before invoking Legion and cannot
    safely expose policy canaries to the child.  Applying ``sandbox-exec`` a
    second time is unsupported. A kernel query that observes any denied
    representative filesystem operation proves inherited containment without
    treating environment claims as trust. Inspection uncertainty fails closed.
    """

    try:
        home = Path(pwd.getpwuid(os.geteuid()).pw_dir).resolve()
    except (KeyError, OSError) as error:
        raise ProcessInspectionError("current account home cannot be resolved") from error
    check, flags = _darwin_sandbox_api()
    probes = (
        (b"file-read-data", Path(__file__).resolve()),
        (b"file-read-data", home),
        (b"file-read-data", home / ".ssh"),
        (b"file-read-data", home / ".aws"),
        (b"file-read-data", home / ".config" / "gh"),
        (b"file-read-data", home / "Library" / "Keychains"),
        (b"file-write-create", home),
        (b"file-write-create", Path("/private/etc")),
    )
    for operation, candidate in probes:
        decision = check(
            os.getpid(), operation, flags, ctypes.c_char_p(str(candidate).encode())
        )
        if decision < 0:
            raise ProcessInspectionError("sandbox_check failed for current process")
        if decision > 0:
            return True
    # Filter-free checks catch policies that constrain non-filesystem
    # capabilities (for example a network-only outer sandbox), where every
    # representative path above may still be allowed.
    no_report = flags & ~1  # remove SANDBOX_FILTER_PATH
    for operation in (
        b"network-outbound",
        b"network-inbound",
        b"process-fork",
        b"process-info-pidinfo",
        b"signal",
        b"system-socket",
        b"mach-lookup",
        b"sandbox-check",
    ):
        decision = check(os.getpid(), operation, no_report)
        if decision < 0:
            raise ProcessInspectionError(
                f"sandbox_check failed for current process operation {operation.decode()}"
            )
        if decision > 0:
            return True
    return False


def _darwin_launch_fingerprint(command: list[str]) -> tuple[list[str], str, str, str]:
    """Apply a unique inherited Seatbelt fingerprint to one direct launch."""

    sandbox_exec = Path("/usr/bin/sandbox-exec")
    if not sandbox_exec.is_file():
        raise ProcessInspectionError("Darwin sandbox-exec is unavailable")
    fingerprint_dir = Path(tempfile.mkdtemp(prefix="legion-supervisor-fingerprint."))
    fingerprint_dir.chmod(0o700)
    deny_canary = fingerprint_dir / "deny"
    allow_canary = fingerprint_dir / "allow"
    deny_canary.touch(mode=0o600)
    allow_canary.touch(mode=0o600)
    deny_path = str(deny_canary.resolve(strict=True))
    allow_path = str(allow_canary.resolve(strict=True))
    # tempfile-generated paths do not contain quotes on Darwin. Still escape
    # both SBPL string metacharacters so a caller-controlled TMPDIR cannot alter
    # the policy that identifies this launch.
    literal = deny_path.replace("\\", "\\\\").replace('"', '\\"')
    protected_dir = (
        str(fingerprint_dir.resolve(strict=True)).replace("\\", "\\\\").replace('"', '\\"')
    )
    profile = (
        f'(version 1)(allow default)(deny file-read* (literal "{literal}"))'
        f'(deny file-write* (subpath "{protected_dir}"))'
    )
    return [str(sandbox_exec), "-p", profile, *command], deny_path, allow_path, str(fingerprint_dir)


def _establish_darwin_owner_lease(
    deny_canary: str, allow_canary: str
) -> tuple[int, str, str]:
    """Create a live, supervisor-held lease for one Seatbelt fingerprint.

    The child receives only the path and nonce. The descriptor and exclusive
    lock remain in this supervisor, so copied environment variables or a stale
    receipt cannot authorize a nested supervisor after the owner exits.
    """

    nonce = secrets.token_hex(32)
    owner_path = Path(deny_canary).parent / f".legion-supervisor-owner-{nonce}"
    flags = os.O_RDWR | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(owner_path, flags, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        payload = json.dumps(
            {
                "schema": "legion.supervisor-owner.v1",
                "pid": os.getpid(),
                "nonce": nonce,
                "deny_canary": deny_canary,
                "allow_canary": allow_canary,
            },
            separators=(",", ":"),
        ).encode()
        os.write(descriptor, payload + b"\n")
        os.fsync(descriptor)
        return descriptor, str(owner_path), nonce
    except BaseException:
        os.close(descriptor)
        owner_path.unlink(missing_ok=True)
        raise


def _verify_darwin_owner_lease(
    owner_path: str,
    owner_nonce: str,
    owner_pid: str,
    deny_canary: str,
    allow_canary: str,
) -> bool:
    """Authenticate that an active outer supervisor owns this fingerprint."""

    if not owner_nonce or not owner_pid.isdigit() or int(owner_pid) < 1:
        return False
    candidate = Path(owner_path)
    try:
        if candidate.is_symlink() or candidate.parent.resolve(strict=True) != Path(deny_canary).parent:
            return False
        check, flags = _darwin_sandbox_api()
        if (
            check(
                os.getpid(),
                b"file-write-data",
                flags,
                ctypes.c_char_p(str(candidate).encode()),
            )
            <= 0
            or check(
                os.getpid(),
                b"file-write-create",
                flags,
                ctypes.c_char_p(str(candidate.parent).encode()),
            )
            <= 0
        ):
            return False
        flags = os.O_RDONLY
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = os.open(candidate, flags)
        try:
            metadata = os.fstat(descriptor)
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid() or metadata.st_mode & 0o077:
                return False
            payload = json.loads(os.read(descriptor, 4097))
            if payload != {
                "schema": "legion.supervisor-owner.v1",
                "pid": int(owner_pid),
                "nonce": owner_nonce,
                "deny_canary": deny_canary,
                "allow_canary": allow_canary,
            }:
                return False
            try:
                fcntl.flock(descriptor, fcntl.LOCK_SH | fcntl.LOCK_NB)
            except BlockingIOError:
                return True
            else:
                fcntl.flock(descriptor, fcntl.LOCK_UN)
                return False
        finally:
            os.close(descriptor)
    except (OSError, ValueError, json.JSONDecodeError):
        return False


def _token_pids(token: str) -> set[int]:
    marker = f"LEGION_SUPERVISOR_TOKEN={token}".encode()
    result: set[int] = set()
    if sys.platform == "darwin":
        # KERN_PROCARGS2 does not reliably expose another process's
        # environment on current macOS. Supervised runs use the inherited
        # Seatbelt fingerprint below instead.
        return result

    proc = Path("/proc")
    if proc.is_dir():
        for entry in proc.iterdir():
            if not entry.name.isdigit():
                continue
            try:
                if marker in (entry / "environ").read_bytes().split(b"\0"):
                    result.add(int(entry.name))
            except (FileNotFoundError, ProcessLookupError, PermissionError):
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
        self._operation_lock = threading.Lock()
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

    def close(self) -> bool:
        self._stop.set()
        if self._thread_started:
            self._thread.join(timeout=1.0)
            # Do not turn the monitor's bounded join into an unbounded lock
            # wait. A daemon still completing its final kernel snapshot owns
            # these handles until process teardown; reporting cleanup failure
            # is safer than blocking the supervisor past its shutdown bound.
            if self._thread.is_alive():
                return False
        with self._operation_lock:
            with self._lock:
                handles = list(self._handles.values())
                self._handles.clear()
            for handle in handles:
                handle.close()
        return True

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

    def _live_parent_handles(self) -> dict[int, ProcessHandle]:
        dead: list[ProcessHandle] = []
        with self._lock:
            for pid, handle in list(self._handles.items()):
                if not handle.is_live():
                    dead.append(self._handles.pop(pid))
            result = dict(self._handles)
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
        except (FileNotFoundError, ProcessLookupError, IndexError, PermissionError, ValueError):
            return None

    def _capture_child(self, pid: int, parents: dict[int, ProcessHandle]) -> bool:
        with self._lock:
            if pid in self._handles:
                return True
        handle = ProcessHandle.open(pid)
        if handle is None:
            return False
        parent = self._current_parent(pid)
        parent_handle = parents.get(parent) if parent is not None else None
        # The integer parent PID may have been reused since ``parents`` was
        # collected. Revalidate the original kernel handle after capturing the
        # child before accepting the relationship. ``_operation_lock`` keeps
        # this exact object owned and its pidfd open throughout the check.
        with self._lock:
            still_owned = parent_handle is not None and self._handles.get(parent) is parent_handle
        if (
            not still_owned
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
            except (FileNotFoundError, ProcessLookupError, PermissionError):
                still_owned = False
            if not still_owned or not handle.is_live():
                handle.close()
                continue
            self._record(handle)

    def _snapshot(self, *, include_token: bool = False) -> None:
        self.raise_if_error()
        parents = self._live_parent_handles()
        pending = list(parents)
        visited: set[int] = set()
        while pending:
            parent = pending.pop()
            if parent in visited:
                continue
            visited.add(parent)
            children = _child_pids(parent)
            for child in children:
                if child not in visited and self._capture_child(child, parents):
                    with self._lock:
                        child_handle = self._handles.get(child)
                    if child_handle is not None:
                        parents[child] = child_handle
                        pending.append(child)
        if sys.platform == "darwin" and self.deny_canary and self.allow_canary:
            self._capture_fingerprinted()
        elif include_token:
            self._capture_token_pids()

    def snapshot(self, *, include_token: bool = False) -> None:
        with self._operation_lock:
            self._snapshot(include_token=include_token)

    def signal(self, signum: int) -> list[int]:
        # Signal deepest/newest children first so parents cannot immediately
        # replace them while shutdown proceeds.
        use_fingerprint = sys.platform == "darwin" and self.deny_canary and self.allow_canary
        with self._operation_lock:
            self._snapshot(include_token=not use_fingerprint)
            return self._signal_known(signum)

    def signal_known(self, signum: int) -> list[int]:
        """Signal only already captured kernel handles after discovery fails."""

        with self._operation_lock:
            return self._signal_known(signum)

    def _signal_known(self, signum: int) -> list[int]:

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


def _read_stable_regular_file(path: str, maximum_bytes: int) -> Optional[bytes]:
    """Read an untrusted path once without following, blocking, or racing it."""

    flags = os.O_RDONLY | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = -1
    try:
        descriptor = os.open(path, flags)
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_nlink != 1
            or opened.st_size > maximum_bytes
        ):
            return None
        path_stat = os.stat(path, follow_symlinks=False)
        if (
            not stat.S_ISREG(path_stat.st_mode)
            or path_stat.st_nlink != 1
            or (path_stat.st_dev, path_stat.st_ino) != (opened.st_dev, opened.st_ino)
        ):
            return None
        chunks: list[bytes] = []
        total = 0
        while total <= maximum_bytes:
            chunk = os.read(descriptor, maximum_bytes + 1 - total)
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
        raw = b"".join(chunks)
        closed = os.fstat(descriptor)
        final_path_stat = os.stat(path, follow_symlinks=False)
        if (
            len(raw) > maximum_bytes
            or not stat.S_ISREG(closed.st_mode)
            or closed.st_nlink != 1
            or closed.st_size > maximum_bytes
            or (closed.st_dev, closed.st_ino) != (opened.st_dev, opened.st_ino)
            or (final_path_stat.st_dev, final_path_stat.st_ino)
            != (opened.st_dev, opened.st_ino)
            or not stat.S_ISREG(final_path_stat.st_mode)
            or final_path_stat.st_nlink != 1
            or closed.st_mtime_ns != opened.st_mtime_ns
            or closed.st_ctime_ns != opened.st_ctime_ns
        ):
            return None
        return raw
    except OSError:
        return None
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def _provider_launch_started(path: str) -> bool:
    if not path:
        return True
    raw = _read_stable_regular_file(path, 4096)
    if raw is None:
        return False
    try:
        value = json.loads(raw)
    except (UnicodeDecodeError, ValueError, TypeError):
        return False
    return (
        isinstance(value, dict)
        and value.get("schema") == "legion.provider-launch.v1"
        and value.get("status") == "started"
        and type(value.get("provider_pid")) is int
        and value["provider_pid"] > 0
        and isinstance(value.get("auth"), str)
        and len(value["auth"]) == 64
    )


def _terminate_tree(
    process: subprocess.Popen[bytes],
    tracker: DescendantTracker,
    descendant_signal_ready_file: str = "",
) -> bool:
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

    if descendant_signal_ready_file and not _provider_launch_started(descendant_signal_ready_file):
        # The direct child is a trusted launcher. Ask it to terminate first,
        # but do not signal its assigned provider until the launcher's durable
        # receipt establishes the paid-attempt boundary. The launcher handler
        # records this signal and forwards it immediately after publication.
        signal_unreaped_root(signal.SIGTERM)
        ready_deadline = time.monotonic() + GRACE_SECONDS
        while time.monotonic() < ready_deadline:
            if _provider_launch_started(descendant_signal_ready_file):
                break
            if process.poll() is not None:
                try:
                    tracker.snapshot()
                    with tracker._lock:
                        live_descendants = any(
                            pid != tracker.root_pid and handle.is_live()
                            for pid, handle in tracker._handles.items()
                        )
                except ProcessInspectionError:
                    live_descendants = True
                if not live_descendants:
                    return True
            time.sleep(POLL_SECONDS)
        if not _provider_launch_started(descendant_signal_ready_file):
            # The trusted launcher failed to publish its boundary. Reap any
            # possible descendant, but force the caller to retain containment
            # evidence instead of treating this as ordinary cancellation.
            drain(signal.SIGTERM)
            drain(signal.SIGKILL)
            return False
    if drain(signal.SIGTERM):
        return True
    return drain(signal.SIGKILL)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cwd", required=True)
    parser.add_argument("--max-runtime-seconds", default=3600, type=int)
    parser.add_argument("--status-file", default="")
    parser.add_argument("--darwin-sandbox-deny-canary", default="")
    parser.add_argument("--darwin-sandbox-allow-canary", default="")
    parser.add_argument("--launch-gate-file", default="")
    parser.add_argument("--launch-gate-token", default="")
    parser.add_argument("--descendant-signal-ready-file", default="")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    return parser


def _write_status(
    path: str,
    status: str,
    reason: str,
    runtime_seconds: int,
    child_exit_code: Optional[int] = None,
    child_started: Optional[bool] = None,
) -> None:
    """Atomically publish the supervisor outcome outside provider-controlled output.

    Exit code 124 alone is ambiguous because a provider can return it itself.  The
    sidecar lets adapters distinguish that ordinary provider failure from a lease
    expiry without parsing stderr or racing a signal handler.
    """

    if not path:
        return
    destination = Path(path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(
        prefix=f".{destination.name}.", suffix=".tmp", dir=destination.parent
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            payload = {
                "schema": "legion.child-execution-lease.v1",
                "status": status,
                "reason": reason,
                "max_runtime_seconds": runtime_seconds,
            }
            if child_exit_code is not None:
                payload["child_exit_code"] = child_exit_code
            if child_started is not None:
                payload["child_started"] = child_started
            json.dump(payload, handle, separators=(",", ":"))
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, destination)
        directory = os.open(destination.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def _write_launch_gate(
    path: str,
    token: str,
    status: str,
    *,
    child_pid: Optional[int] = None,
) -> None:
    destination = Path(path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "schema": "legion.child-launch-gate.v1",
        "status": status,
        "token": token,
        "supervisor_pid": os.getpid(),
    }
    if child_pid is not None:
        payload["child_pid"] = child_pid
    descriptor, temporary = tempfile.mkstemp(
        prefix=f".{destination.name}.", suffix=".tmp", dir=destination.parent
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, separators=(",", ":"))
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, destination)
    finally:
        Path(temporary).unlink(missing_ok=True)


def _read_launch_gate_decision(path: str, token: str) -> tuple[str, int]:
    candidate = Path(path)
    try:
        if candidate.is_symlink() or not candidate.is_file() or candidate.stat().st_size > 4096:
            return "malformed", 0
        value = json.loads(candidate.read_text(encoding="utf-8"))
    except (OSError, ValueError, TypeError):
        return "malformed", 0
    if (
        not isinstance(value, dict)
        or value.get("schema") != "legion.child-launch-gate.v1"
        or value.get("token") != token
        or value.get("supervisor_pid") != os.getpid()
    ):
        return "malformed", 0
    status = value.get("status")
    expected = {"schema", "status", "token", "supervisor_pid"}
    if status == "cancel":
        expected.add("signal")
        signum = value.get("signal")
        if type(signum) is not int or signum not in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
            return "malformed", 0
        if set(value) != expected:
            return "malformed", 0
        return status, signum
    if status in ("ready", "go") and set(value) == expected:
        return status, 0
    return "malformed", 0


def main() -> int:
    arguments = _parser().parse_args()
    if arguments.max_runtime_seconds < 1:
        reason = "--max-runtime-seconds must be at least 1"
        _write_status(arguments.status_file, "launch_failed", reason, 1)
        print(f"legion-process-supervisor: {reason}", file=sys.stderr)
        return 2
    command = arguments.command
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        reason = "command is required"
        _write_status(arguments.status_file, "launch_failed", reason, arguments.max_runtime_seconds)
        print(f"legion-process-supervisor: {reason}", file=sys.stderr)
        return 2
    launch_gate_file = arguments.launch_gate_file
    launch_gate_token = arguments.launch_gate_token
    if bool(launch_gate_file) != bool(launch_gate_token) or (
        launch_gate_token
        and (len(launch_gate_token) != 64 or any(char not in "0123456789abcdef" for char in launch_gate_token))
    ):
        reason = "launch gate requires a path and 64-character lowercase hex token"
        _write_status(arguments.status_file, "launch_failed", reason, arguments.max_runtime_seconds)
        print(f"legion-process-supervisor: {reason}", file=sys.stderr)
        return 2

    absolute_deadline_ns: Optional[int] = None
    inherited_deadline = os.environ.get("LEGION_CHILD_LEASE_DEADLINE_NS", "")
    if inherited_deadline:
        try:
            absolute_deadline_ns = int(inherited_deadline)
            if absolute_deadline_ns < 1:
                raise ValueError
        except ValueError:
            reason = "invalid inherited child lease deadline"
            _write_status(arguments.status_file, "launch_failed", reason, arguments.max_runtime_seconds)
            print(f"legion-process-supervisor: {reason}", file=sys.stderr)
            return 2
        if absolute_deadline_ns <= time.monotonic_ns():
            reason = "inherited child lease deadline expired before launch"
            _write_status(
                arguments.status_file, "launch_failed", reason, arguments.max_runtime_seconds
            )
            print(f"legion-process-supervisor: {reason}", file=sys.stderr)
            return 124

    deny_canary = arguments.darwin_sandbox_deny_canary
    allow_canary = arguments.darwin_sandbox_allow_canary
    fingerprint_dir = ""
    inherited_deny = os.environ.get("LEGION_ANCESTOR_SUPERVISOR_DENY_CANARY", "")
    inherited_allow = os.environ.get("LEGION_ANCESTOR_SUPERVISOR_ALLOW_CANARY", "")
    inherited_owner_path = os.environ.get("LEGION_ANCESTOR_SUPERVISOR_OWNER_PATH", "")
    inherited_owner_nonce = os.environ.get("LEGION_ANCESTOR_SUPERVISOR_OWNER_NONCE", "")
    inherited_owner_pid = os.environ.get("LEGION_ANCESTOR_SUPERVISOR_OWNER_PID", "")
    inherited_fingerprint_active = False
    using_inherited = False
    if bool(inherited_deny) != bool(inherited_allow):
        reason = "incomplete inherited supervisor fingerprint"
        _write_status(arguments.status_file, "launch_failed", reason, arguments.max_runtime_seconds)
        print(f"legion-process-supervisor: {reason}", file=sys.stderr)
        return 2
    if len(
        [value for value in (inherited_owner_path, inherited_owner_nonce, inherited_owner_pid) if value]
    ) not in (0, 3):
        reason = "incomplete inherited supervisor ownership lease"
        _write_status(arguments.status_file, "launch_failed", reason, arguments.max_runtime_seconds)
        print(f"legion-process-supervisor: {reason}", file=sys.stderr)
        return 2
    if sys.platform == "darwin" and inherited_deny:
        try:
            inherited_fingerprint_active = bool(
                _darwin_sandbox_decision(
                    os.getpid(), inherited_deny.encode(), inherited_allow.encode()
                )
            )
        except ProcessInspectionError as error:
            reason = f"cannot inspect inherited supervisor fingerprint: {error}"
            _write_status(
                arguments.status_file, "cleanup_failed", reason,
                arguments.max_runtime_seconds, child_started=False
            )
            print(f"legion-process-supervisor: {reason}", file=sys.stderr)
            return 70
        # Test shims and stale caller environments may carry a well-formed pair
        # without actually running under that policy. Such a pair grants no
        # trust: fall through to a fresh direct-launch fingerprint instead.
        # An active inherited pair is the outer supervisor's run-unique process
        # identity. Verify and propagate it rather than nesting sandbox-exec.
        # The outer supervisor remains responsible for fingerprint-wide
        # discovery: this nested process is deliberately denied the host-wide
        # process listing that such discovery requires.
        if inherited_fingerprint_active and not deny_canary:
            deny_canary = inherited_deny
            allow_canary = inherited_allow
    if bool(deny_canary) != bool(allow_canary):
        reason = "both Darwin sandbox canaries are required"
        _write_status(arguments.status_file, "launch_failed", reason, arguments.max_runtime_seconds)
        print(f"legion-process-supervisor: {reason}", file=sys.stderr)
        return 2
    if sys.platform == "darwin" and deny_canary:
        using_inherited = inherited_fingerprint_active and deny_canary == inherited_deny
        try:
            if using_inherited:
                # The defining policy intentionally makes the deny leaf
                # unstatable. Canonicalize the shared parent and retain the two
                # leaf names; the kernel deny/allow decision below is the
                # authoritative proof for the inherited pair.
                deny_input = Path(deny_canary)
                allow_input = Path(allow_canary)
                deny_parent = deny_input.parent.resolve(strict=True)
                allow_parent = allow_input.parent.resolve(strict=True)
                deny_path = deny_parent / deny_input.name
                allow_path = allow_parent / allow_input.name
            else:
                if Path(deny_canary).is_symlink() or Path(allow_canary).is_symlink():
                    raise OSError("canary leaf must not be a symbolic link")
                deny_path = Path(deny_canary).resolve(strict=True)
                allow_path = Path(allow_canary).resolve(strict=True)
        except OSError as error:
            reason = f"invalid Darwin sandbox canary: {error}"
            _write_status(arguments.status_file, "launch_failed", reason, arguments.max_runtime_seconds)
            print(f"legion-process-supervisor: {reason}", file=sys.stderr)
            return 2
        if deny_path == allow_path or deny_path.parent != allow_path.parent or (
            not using_inherited and (not deny_path.is_file() or not allow_path.is_file())
        ):
            reason = "Darwin sandbox canaries must be adjacent regular files"
            _write_status(arguments.status_file, "launch_failed", reason, arguments.max_runtime_seconds)
            print(f"legion-process-supervisor: {reason}", file=sys.stderr)
            return 2
        deny_canary = str(deny_path)
        allow_canary = str(allow_path)
        if using_inherited:
            try:
                if not _darwin_sandbox_decision(
                    os.getpid(), deny_canary.encode(), allow_canary.encode()
                ):
                    raise ProcessInspectionError("inherited fingerprint is inactive")
                if not _verify_darwin_owner_lease(
                    inherited_owner_path,
                    inherited_owner_nonce,
                    inherited_owner_pid,
                    deny_canary,
                    allow_canary,
                ):
                    raise ProcessInspectionError(
                        "inherited fingerprint has no active outer Legion supervisor owner"
                    )
            except ProcessInspectionError as error:
                reason = f"invalid inherited supervisor fingerprint: {error}"
                _write_status(
                    arguments.status_file, "cleanup_failed", reason,
                    arguments.max_runtime_seconds, child_started=False
                )
                print(f"legion-process-supervisor: {reason}", file=sys.stderr)
                return 70
        elif not _darwin_sandbox_probe(deny_canary, allow_canary):
            reason = "Darwin sandbox inspection is unavailable"
            _write_status(arguments.status_file, "launch_failed", reason, arguments.max_runtime_seconds)
            print(f"legion-process-supervisor: {reason}", file=sys.stderr)
            return 2

    if sys.platform == "darwin" and not deny_canary:
        try:
            host_sandboxed = _darwin_inherited_host_sandboxed()
        except ProcessInspectionError as error:
            reason = f"cannot inspect inherited Seatbelt policy: {error}"
            _write_status(
                arguments.status_file, "cleanup_failed", reason,
                arguments.max_runtime_seconds, child_started=False
            )
            print(f"legion-process-supervisor: {reason}", file=sys.stderr)
            return 70
        if host_sandboxed:
            reason = (
                "inherited Seatbelt policy has no verified run-unique supervisor fingerprint"
            )
            _write_status(
                arguments.status_file, "cleanup_failed", reason,
                arguments.max_runtime_seconds, child_started=False
            )
            print(f"legion-process-supervisor: {reason}", file=sys.stderr)
            return 70
        try:
            command, deny_canary, allow_canary, fingerprint_dir = _darwin_launch_fingerprint(command)
            if not _darwin_sandbox_probe(deny_canary, allow_canary):
                raise ProcessInspectionError("Darwin sandbox inspection is unavailable")
        except (OSError, ProcessInspectionError) as error:
            if fingerprint_dir:
                shutil.rmtree(fingerprint_dir, ignore_errors=True)
            reason = f"cannot establish Darwin process fingerprint: {error}"
            _write_status(arguments.status_file, "launch_failed", reason, arguments.max_runtime_seconds)
            print(f"legion-process-supervisor: {reason}", file=sys.stderr)
            return 2

    owner_descriptor = -1
    owner_path = inherited_owner_path
    owner_nonce = inherited_owner_nonce
    if sys.platform == "darwin" and deny_canary and not using_inherited:
        try:
            owner_descriptor, owner_path, owner_nonce = _establish_darwin_owner_lease(
                deny_canary, allow_canary
            )
        except (OSError, ValueError) as error:
            reason = f"cannot establish active supervisor ownership lease: {error}"
            _write_status(
                arguments.status_file, "cleanup_failed", reason,
                arguments.max_runtime_seconds, child_started=False
            )
            if fingerprint_dir:
                shutil.rmtree(fingerprint_dir, ignore_errors=True)
            print(f"legion-process-supervisor: {reason}", file=sys.stderr)
            return 70

    process: Optional[subprocess.Popen[bytes]] = None
    tracker: Optional[DescendantTracker] = None
    interrupted = 0
    cancel_requested = False
    returncode = 1
    cleanup_ok = True
    cleanup_attempted = False
    timed_out = False
    completed_before_cleanup = False
    supervisor_token = secrets.token_hex(24)
    authorization_fd = -1

    def stop(signum: int, _frame: object) -> None:
        nonlocal cancel_requested, interrupted, authorization_fd
        interrupted = signum
        # Python handlers can be re-entered by repeated delivery of the same
        # signal. threading.Event.set() takes a non-reentrant condition lock,
        # so a second TERM at the wrong bytecode boundary can deadlock the
        # supervisor forever. A plain assignment is re-entrant; the main loop
        # observes it within POLL_SECONDS.
        cancel_requested = True
        # The exec-side gate is still holding the provider before process
        # creation. Closing the authorization writer is the cancellation
        # decision; a later write cannot accidentally launch it.
        if authorization_fd >= 0:
            try:
                os.close(authorization_fd)
            except OSError:
                pass
            authorization_fd = -1

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGHUP, stop)

    try:
        if launch_gate_file:
            try:
                _write_launch_gate(launch_gate_file, launch_gate_token, "ready")
            except OSError as error:
                reason = f"cannot publish pre-launch supervisor readiness: {error}"
                _write_status(
                    arguments.status_file, "cleanup_failed", reason,
                    arguments.max_runtime_seconds, child_started=False
                )
                return 70
            gate_deadline = time.monotonic() + min(10, arguments.max_runtime_seconds)
            while True:
                if cancel_requested:
                    reason = f"cancelled by {signal.Signals(interrupted).name} before child launch"
                    _write_status(
                        arguments.status_file, "launch_failed", reason,
                        arguments.max_runtime_seconds
                    )
                    return 128 + interrupted
                decision, gate_signal = _read_launch_gate_decision(
                    launch_gate_file, launch_gate_token
                )
                if decision == "go":
                    break
                if decision == "cancel":
                    reason = (
                        f"cancelled by {signal.Signals(gate_signal).name} "
                        "at final pre-launch gate"
                    )
                    _write_status(
                        arguments.status_file, "launch_failed", reason,
                        arguments.max_runtime_seconds
                    )
                    return 128 + gate_signal
                if decision != "ready":
                    reason = "pre-launch supervisor gate was malformed"
                    _write_status(
                        arguments.status_file, "cleanup_failed", reason,
                        arguments.max_runtime_seconds, child_started=False
                    )
                    return 70
                if time.monotonic() >= gate_deadline:
                    reason = "pre-launch supervisor gate timed out before launch authorization"
                    _write_status(
                        arguments.status_file, "launch_failed", reason,
                        arguments.max_runtime_seconds
                    )
                    return 124
                time.sleep(POLL_SECONDS)
        environment = os.environ.copy()
        environment["LEGION_SUPERVISOR_TOKEN"] = supervisor_token
        if sys.platform == "darwin" and deny_canary:
            environment["LEGION_ANCESTOR_SUPERVISOR_DENY_CANARY"] = deny_canary
            environment["LEGION_ANCESTOR_SUPERVISOR_ALLOW_CANARY"] = allow_canary
            environment["LEGION_ANCESTOR_SUPERVISOR_OWNER_PATH"] = owner_path
            environment["LEGION_ANCESTOR_SUPERVISOR_OWNER_NONCE"] = owner_nonce
            environment["LEGION_ANCESTOR_SUPERVISOR_OWNER_PID"] = (
                inherited_owner_pid if using_inherited else str(os.getpid())
            )
        # Darwin fingerprint and owner establishment can perform several process
        # inspections. An inherited/lowered absolute lease may expire during
        # that setup, so recheck at the last possible point before any child can
        # launch. The surrounding finally block releases all setup resources.
        launch_signals = {signal.SIGINT, signal.SIGTERM, signal.SIGHUP}
        gate_read = error_read = error_write = -1
        previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, launch_signals)
        try:
            # Blocking the handled signals makes the final cancellation check
            # and Popen one linearized region. A signal pending before the mask
            # is observed here; one arriving after it is restored only after
            # `process` names the real child, so it cannot resume into Popen
            # from a pre-launch handler and accidentally spend.
            if absolute_deadline_ns is not None and absolute_deadline_ns <= time.monotonic_ns():
                reason = "inherited child lease deadline expired during launch setup"
                _write_status(
                    arguments.status_file, "launch_failed", reason, arguments.max_runtime_seconds
                )
                print(f"legion-process-supervisor: {reason}", file=sys.stderr)
                return 124
            if cancel_requested:
                reason = f"cancelled by {signal.Signals(interrupted).name}"
                _write_status(
                    arguments.status_file, "launch_failed", reason, arguments.max_runtime_seconds
                )
                return 128 + interrupted
            pending_launch_signals = signal.sigpending() & launch_signals
            if pending_launch_signals:
                interrupted = min(pending_launch_signals)
                reason = f"cancelled by {signal.Signals(interrupted).name} before child launch"
                _write_status(
                    arguments.status_file, "launch_failed", reason,
                    arguments.max_runtime_seconds
                )
                return 128 + interrupted
            try:
                gate_read, authorization_fd = os.pipe()
                error_read, error_write = os.pipe()
                process = subprocess.Popen(
                    [sys.executable, str(Path(__file__).parent / "lib/child-exec-gate.py"),
                     str(gate_read), str(error_write), *command],
                    cwd=arguments.cwd,
                    stdin=None,
                    stdout=None,
                    stderr=None,
                    env=environment,
                    start_new_session=True,
                    pass_fds=(gate_read, error_write),
                    # The parent keeps termination signals blocked across its
                    # last cancellation check and process creation. Restore the
                    # caller's mask in the forked child before exec so the new
                    # process cannot inherit an indefinitely blocked TERM/HUP.
                    preexec_fn=lambda: signal.pthread_sigmask(
                        signal.SIG_SETMASK, previous_mask
                    ),
                )
            except OSError as error:
                # Admission and launch are separated by an unavoidable filesystem
                # race. Authenticate that no provider process was created with a
                # dedicated lease outcome; "completed" would make adapters account
                # for a provider attempt that never happened.
                if error.errno == errno.ENOENT:
                    reason = f"child launch failed: command not found: {command[0]}"
                    exit_code = 127
                else:
                    reason = f"child launch failed: {error}"
                    exit_code = 126
                _write_status(
                    arguments.status_file,
                    "launch_failed",
                    reason,
                    arguments.max_runtime_seconds,
                )
                print(f"legion-process-supervisor: {reason}", file=sys.stderr)
                return exit_code
            finally:
                for descriptor in (gate_read, error_write):
                    if descriptor >= 0:
                        os.close(descriptor)
                gate_read = error_write = -1
                if process is None:
                    for descriptor in (authorization_fd, error_read):
                        if descriptor >= 0:
                            os.close(descriptor)
                    authorization_fd = error_read = -1
        except OSError as error:
            reason = f"cannot establish atomic child launch signal mask: {error}"
            _write_status(
                arguments.status_file, "cleanup_failed", reason,
                arguments.max_runtime_seconds, child_started=False
            )
            return 70
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
        tracker = DescendantTracker(
            process.pid,
            supervisor_token,
            "" if using_inherited else deny_canary,
            "" if using_inherited else allow_canary,
        )
        tracker.start()
        # Popen above starts only a trusted waiting launcher. Unmask first so
        # any cancellation pending before or during that Popen closes the
        # authorization writer. A successful one-byte write is the atomic
        # launch decision; the launcher cannot exec a provider before it.
        if cancel_requested or authorization_fd < 0:
            if authorization_fd >= 0:
                os.close(authorization_fd)
                authorization_fd = -1
            if error_read >= 0:
                os.close(error_read)
            try:
                process.wait(timeout=GRACE_SECONDS)
            except subprocess.TimeoutExpired:
                cleanup_ok = _terminate_tree(process, tracker,
                                             arguments.descendant_signal_ready_file)
                cleanup_attempted = True
                _write_status(arguments.status_file, "cleanup_failed",
                              "pre-launch cancellation could not reap the waiting launcher",
                              arguments.max_runtime_seconds, child_started=False)
                return 70
            reason = f"cancelled by {signal.Signals(interrupted).name} before child launch"
            _write_status(arguments.status_file, "launch_failed", reason,
                          arguments.max_runtime_seconds)
            return 128 + interrupted
        try:
            os.write(authorization_fd, b"G")
        except OSError:
            if error_read >= 0:
                os.close(error_read)
            try:
                process.wait(timeout=GRACE_SECONDS)
            except subprocess.TimeoutExpired:
                cleanup_ok = _terminate_tree(process, tracker,
                                             arguments.descendant_signal_ready_file)
                cleanup_attempted = True
                _write_status(arguments.status_file, "cleanup_failed",
                              "authorization failure could not reap the waiting launcher",
                              arguments.max_runtime_seconds, child_started=False)
                return 70
            if cancel_requested:
                reason = f"cancelled by {signal.Signals(interrupted).name} before child launch"
                _write_status(arguments.status_file, "launch_failed", reason,
                              arguments.max_runtime_seconds)
                return 128 + interrupted
            _write_status(arguments.status_file, "cleanup_failed",
                          "cannot authorize child launch", arguments.max_runtime_seconds,
                          child_started=False)
            return 70
        finally:
            if authorization_fd >= 0:
                os.close(authorization_fd)
                authorization_fd = -1
        try:
            if not select.select([error_read], [], [], GRACE_SECONDS)[0]:
                cleanup_ok = _terminate_tree(process, tracker,
                                             arguments.descendant_signal_ready_file)
                cleanup_attempted = True
                _write_status(arguments.status_file, "cleanup_failed",
                              "child exec gate did not confirm launch",
                              arguments.max_runtime_seconds)
                return 70
            launch_error = os.read(error_read, 4097)
        finally:
            os.close(error_read)
        if launch_error:
            try:
                detail = json.loads(launch_error)
                launch_errno = int(detail["errno"])
                reason = f"child launch failed: {detail['reason']}"
            except (ValueError, TypeError, KeyError):
                launch_errno = 1
                reason = "child launch failed with malformed exec evidence"
            process.wait(timeout=GRACE_SECONDS)
            _write_status(arguments.status_file, "launch_failed", reason,
                          arguments.max_runtime_seconds)
            return 127 if launch_errno == errno.ENOENT else 126
        if launch_gate_file:
            try:
                _write_launch_gate(
                    launch_gate_file, launch_gate_token, "started", child_pid=process.pid
                )
            except OSError as error:
                cleanup_ok = _terminate_tree(
                    process, tracker, arguments.descendant_signal_ready_file
                )
                cleanup_attempted = True
                reason = f"cannot publish authenticated child launch: {error}"
                _write_status(
                    arguments.status_file, "cleanup_failed", reason,
                    arguments.max_runtime_seconds
                )
                return 70
        deadline = time.monotonic() + arguments.max_runtime_seconds
        if absolute_deadline_ns is not None:
            deadline = min(deadline, absolute_deadline_ns / 1_000_000_000)

        def child_completed_before_cancel() -> bool:
            nonlocal completed_before_cleanup
            # Python may dispatch a signal handler between poll() returning a
            # completed child and the next bytecode reading cancel_requested.
            # Freeze that flag until the observed outcome is recorded.
            observed_mask = signal.pthread_sigmask(signal.SIG_BLOCK, launch_signals)
            try:
                # A blocked signal has not run the Python handler yet. Count
                # it as cancellation when already pending before this poll;
                # a signal first delivered by poll() after observing exit is
                # later and must not rewrite a completed child.
                cancellation_before_poll = cancel_requested or bool(
                    signal.sigpending() & launch_signals
                )
                completed = process.poll() is not None
                if completed:
                    completed_before_cleanup = not cancellation_before_poll
                return completed
            finally:
                signal.pthread_sigmask(signal.SIG_SETMASK, observed_mask)

        while True:
            if child_completed_before_cancel():
                # A cancellation already received before this observation is
                # still the cause of a signalled child exit. Only a signal
                # arriving *after* observed completion is ignored.
                break
            tracker.raise_if_error()
            now = time.monotonic()
            # The monotonic deadline wins a simultaneous timeout/cancel race.
            # A child already observed complete wins instead, including one that
            # finishes immediately below the lease boundary.
            if now >= deadline:
                if child_completed_before_cancel():
                    break
                timed_out = True
                break
            if cancel_requested:
                break
            time.sleep(min(POLL_SECONDS, deadline - now))
        # One descendant drain owns the entire TERM/KILL cleanup budget. The
        # old lifecycle could spend that budget here, another wait budget, and
        # then a second complete drain in finally (roughly ten seconds under
        # contention). _terminate_tree polls/reaps the direct child itself, so
        # a second blocking wait or drain adds no containment guarantee.
        cleanup_ok = _terminate_tree(
            process, tracker, arguments.descendant_signal_ready_file
        ) and cleanup_ok
        cleanup_attempted = True
        observed_returncode = process.poll()
        if observed_returncode is None:
            returncode = -signal.SIGKILL
            cleanup_ok = False
        else:
            returncode = observed_returncode
    except ProcessInspectionError as error:
        print(f"legion-process-supervisor: descendant inspection failed: {error}", file=sys.stderr)
        returncode = 70
        cleanup_ok = False
    finally:
        if process is not None and tracker is not None:
            if not cleanup_attempted:
                cleanup_ok = _terminate_tree(
                    process, tracker, arguments.descendant_signal_ready_file
                ) and cleanup_ok
            cleanup_ok = tracker.close() and cleanup_ok
        if fingerprint_dir:
            shutil.rmtree(fingerprint_dir, ignore_errors=True)
        if owner_descriptor >= 0:
            os.close(owner_descriptor)
            Path(owner_path).unlink(missing_ok=True)

    if not cleanup_ok:
        _write_status(
            arguments.status_file,
            "cleanup_failed",
            "descendant cleanup was incomplete",
            arguments.max_runtime_seconds,
        )
        print("legion-process-supervisor: descendant cleanup was incomplete", file=sys.stderr)
        return 70
    if timed_out:
        reason = f"child execution lease expired after {arguments.max_runtime_seconds} seconds"
        _write_status(arguments.status_file, "timed_out", reason, arguments.max_runtime_seconds)
        print(f"legion-process-supervisor: {reason}", file=sys.stderr)
        return 124
    # A handler may run while descendant cleanup and status publication are in
    # progress. Once the loop observed the direct child exit, that late signal
    # cannot retroactively turn the completed provider call into a cancellation.
    if interrupted and not completed_before_cleanup:
        _write_status(
            arguments.status_file,
            "cancelled",
            f"cancelled by {signal.Signals(interrupted).name}",
            arguments.max_runtime_seconds,
        )
        return 128 + interrupted
    _write_status(
        arguments.status_file,
        "completed",
        "child completed",
        arguments.max_runtime_seconds,
        returncode if returncode >= 0 else 128 - returncode,
    )
    return returncode if returncode >= 0 else 128 - returncode


if __name__ == "__main__":
    raise SystemExit(main())
