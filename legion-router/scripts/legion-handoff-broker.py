#!/usr/bin/env python3
"""Authenticated, bounded one-hop bridge from a sandboxed harness to Legion.

The provider-facing client is exposed as ``legion-delegate`` through a trusted
PATH entry.  The parent-side server accepts exactly one typed ``run`` request,
executes it in a standalone disposable repository under an equivalent OS write
boundary, and copies only validated canonical telemetry back to the parent.
"""

from __future__ import annotations

import argparse
import base64
import fcntl
import json
import math
import os
import re
import select
import selectors
import secrets
import signal
import socket
import stat
import struct
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any, Optional


MAX_REQUEST_BYTES = 4 * 1024 * 1024
MAX_TASK_BYTES = 16 * 1024
MAX_RESPONSE_BYTES = 32 * 1024 * 1024
MAX_CHILD_OUTPUT_BYTES = 16 * 1024 * 1024
MAX_TELEMETRY_BYTES = 4 * 1024 * 1024
MAX_AUTH_FILE_BYTES = 16 * 1024 * 1024
HEADER = struct.Struct("!I")
EXECUTORS = {"claude", "codex", "cursor", "opencode", "hermes", "pi"}
REASONING_EFFORTS = {"low", "medium", "high", "xhigh", "max"}
SANDBOXES = {"read-only", "workspace-write"}
SAFE_TELEMETRY_NAME = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}\.jsonl$")
SPAN_REQUIRED = {"schema", "ts", "run_id", "executor", "model", "status"}
SPAN_STATUSES = {"ok", "failed", "error", "over_budget", "blocked"}


def _read_exact(connection: socket.socket, size: int) -> bytes:
    chunks: list[bytes] = []
    remaining = size
    while remaining:
        chunk = connection.recv(remaining)
        if not chunk:
            raise ValueError("unexpected end of broker message")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def _recv_json(connection: socket.socket, limit: int) -> dict[str, Any]:
    size = HEADER.unpack(_read_exact(connection, HEADER.size))[0]
    if size > limit:
        raise ValueError("broker message exceeds the size limit")
    payload = json.loads(_read_exact(connection, size))
    if not isinstance(payload, dict):
        raise ValueError("broker message must be a JSON object")
    return payload


def _send_json(connection: socket.socket, payload: dict[str, Any], limit: int) -> None:
    encoded = json.dumps(payload, separators=(",", ":")).encode()
    if len(encoded) > limit:
        raise ValueError("broker response exceeds the size limit")
    connection.sendall(HEADER.pack(len(encoded)) + encoded)


def _client() -> int:
    socket_path = os.environ.get("LEGION_HANDOFF_BROKER_SOCKET", "")
    token = os.environ.get("LEGION_HANDOFF_BROKER_TOKEN", "")
    if not socket_path or not token:
        print("legion-delegate: sandbox handoff broker is unavailable", file=sys.stderr)
        return 2

    stdin = b""
    if not sys.stdin.isatty() and select.select([sys.stdin], [], [], 0)[0]:
        stdin = sys.stdin.buffer.read(MAX_TASK_BYTES + 1)
    if len(stdin) > MAX_TASK_BYTES:
        print("legion-delegate: broker stdin exceeds 16 KiB", file=sys.stderr)
        return 2

    request = {
        "token": token,
        "argv": sys.argv[1:],
        "stdin": base64.b64encode(stdin).decode(),
    }
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.connect(socket_path)
            _send_json(connection, request, MAX_REQUEST_BYTES)
            response = _recv_json(connection, MAX_RESPONSE_BYTES)
        stdout = base64.b64decode(response.get("stdout", ""), validate=True)
        stderr = base64.b64decode(response.get("stderr", ""), validate=True)
        sys.stdout.buffer.write(stdout)
        sys.stderr.buffer.write(stderr)
        return int(response.get("returncode", 2))
    except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as error:
        print(f"legion-delegate: broker request failed: {error}", file=sys.stderr)
        return 2


def _clean_value(flag: str, value: str, *, maximum: int = 4096) -> str:
    if not value or "\x00" in value or len(value.encode()) > maximum:
        raise ValueError(f"sandbox handoff {flag} has an invalid value")
    return value


def _validated_args(value: Any) -> list[str]:
    """Parse a minimal typed protocol; never forward opaque worker tokens."""

    if not isinstance(value, list) or not value or not all(isinstance(item, str) for item in value):
        raise ValueError("broker argv must be a non-empty string array")
    if value[0] != "run":
        raise ValueError("sandboxed workers may use only legion-delegate run")

    args = ["run"]
    seen: set[str] = set()
    index = 1
    while index < len(value):
        flag = value[index]
        if "\x00" in flag or flag.startswith("--") and "=" in flag:
            raise ValueError(f"sandbox handoff does not accept token {flag!r}")
        if flag in {"--repo", "--base"}:
            if flag in seen or index + 1 >= len(value):
                raise ValueError(f"sandbox handoff {flag} must occur once with a value")
            supplied = _clean_value(flag, value[index + 1])
            allowed = "." if flag == "--repo" else "HEAD"
            if supplied != allowed:
                raise ValueError(f"sandbox handoff permits only {flag} {allowed}")
            seen.add(flag)
            index += 2
            continue
        if flag == "--quiet":
            if flag in seen:
                raise ValueError("sandbox handoff --quiet may occur only once")
            seen.add(flag)
            args.append(flag)
            index += 1
            continue
        if flag not in {"--executor", "--task", "--sandbox", "--reasoning-effort", "--budget-tokens"}:
            raise ValueError(f"sandbox handoff does not permit {flag!r}")
        if flag in seen or index + 1 >= len(value):
            raise ValueError(f"sandbox handoff {flag} must occur once with a value")
        supplied = _clean_value(flag, value[index + 1], maximum=MAX_TASK_BYTES if flag == "--task" else 4096)
        if flag == "--executor" and supplied not in EXECUTORS:
            raise ValueError(f"sandbox handoff executor is not registered: {supplied}")
        if flag == "--sandbox" and supplied not in SANDBOXES:
            raise ValueError(f"sandbox handoff sandbox is invalid: {supplied}")
        if flag == "--reasoning-effort" and supplied not in REASONING_EFFORTS:
            raise ValueError(f"sandbox handoff reasoning effort is invalid: {supplied}")
        if flag == "--budget-tokens":
            if not re.fullmatch(r"[0-9]{1,8}", supplied) or int(supplied) > 10_000_000:
                raise ValueError("sandbox handoff --budget-tokens must be an integer from 0 to 10000000")
            supplied = str(int(supplied))
        seen.add(flag)
        args.extend((flag, supplied))
        index += 2

    if "--executor" not in seen:
        raise ValueError("sandbox handoff requires one explicit --executor")
    return args


def _scheme_escape(value: str) -> str:
    if "\n" in value or "\r" in value:
        raise ValueError("sandbox path contains a newline")
    return value.replace("\\", "\\\\").replace('"', '\\"')


def _reject_json_constant(value: str) -> None:
    raise ValueError(f"non-finite JSON number is forbidden: {value}")


def _valid_optional_string(payload: dict[str, Any], name: str) -> bool:
    return name not in payload or payload[name] is None or isinstance(payload[name], str)


def _valid_nonnegative_number(payload: dict[str, Any], name: str) -> bool:
    if name not in payload:
        return True
    value = payload[name]
    if isinstance(value, bool) or not isinstance(value, (int, float)) or value < 0:
        return False
    return not isinstance(value, float) or math.isfinite(value)


def _validate_span(payload: Any, expected_parent: str) -> dict[str, Any]:
    """Validate the complete in-repository legion.span.v1 schema contract."""

    if not isinstance(payload, dict) or not SPAN_REQUIRED.issubset(payload):
        raise ValueError("nested handoff telemetry is missing required span fields")
    if payload.get("schema") != "legion.span.v1" or payload.get("parent_id") != expected_parent:
        raise ValueError("nested handoff emitted invalid telemetry attribution")
    for name in ("ts", "run_id", "executor", "model"):
        if not isinstance(payload.get(name), str):
            raise ValueError(f"nested handoff telemetry {name} must be a string")
    if payload.get("status") not in SPAN_STATUSES:
        raise ValueError("nested handoff telemetry status is invalid")
    if not all(_valid_optional_string(payload, name) for name in ("trace_id", "parent_id", "archetype", "target_type", "target_name")):
        raise ValueError("nested handoff telemetry has an invalid optional string")
    if "task" in payload and not isinstance(payload["task"], str):
        raise ValueError("nested handoff telemetry task must be a string")
    if not _valid_nonnegative_number(payload, "duration_ms") or not _valid_nonnegative_number(payload, "cost_usd"):
        raise ValueError("nested handoff telemetry has an invalid nonnegative number")
    if "tokens" in payload and not isinstance(payload["tokens"], dict):
        raise ValueError("nested handoff telemetry tokens must be an object")
    if "artifacts" in payload and not isinstance(payload["artifacts"], dict):
        raise ValueError("nested handoff telemetry artifacts must be an object")
    return payload


def _write_record_atomic(descriptor: int, encoded: bytes) -> None:
    """Append one record, rolling back a short/failed write while locked."""

    fcntl.flock(descriptor, fcntl.LOCK_EX)
    original_size = os.fstat(descriptor).st_size
    try:
        written = os.write(descriptor, encoded)
        if written != len(encoded):
            os.ftruncate(descriptor, original_size)
            raise OSError("short canonical telemetry append")
    except BaseException:
        try:
            os.ftruncate(descriptor, original_size)
        except OSError:
            pass
        raise
    finally:
        fcntl.flock(descriptor, fcntl.LOCK_UN)


def _host_control_directories(home: Path) -> list[Path]:
    candidates = (
        Path("/run"),
        Path("/var/run"),
        home / ".docker" / "run",
        home / ".docker" / "desktop",
        home / ".local" / "share" / "containers",
        home / ".colima",
        home / ".orbstack",
        home / "Library" / "Containers" / "com.docker.docker",
        home / "Library" / "Group Containers" / "group.com.docker",
    )
    result: list[Path] = []
    seen: set[str] = set()
    for candidate in candidates:
        key = str(candidate)
        if key not in seen:
            seen.add(key)
            result.append(candidate)
    return result


def _terminate_supervisor(process: subprocess.Popen[bytes], grace: float = 6.0) -> None:
    """Let the descendant-aware supervisor drain or fail the broker closed."""

    try:
        process.send_signal(signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=grace)
        return
    except subprocess.TimeoutExpired as error:
        # This PID is still our unreaped direct child, so it cannot be reused
        # before Popen.kill() checks and signals it. Re-signalling the original
        # process group would not have that guarantee after its leader exits.
        process.kill()
        try:
            process.wait(timeout=2.0)
        except subprocess.TimeoutExpired:
            pass
        raise ValueError("descendant supervisor exceeded its cleanup deadline") from error


class Broker:
    def __init__(
        self,
        *,
        socket_path: Path,
        token: str,
        delegate: Path,
        source_repo: Path,
        broker_root: Path,
        base_sha: str,
        sandbox_bin: Path,
        sandbox_kind: str,
        supervisor: Path,
        supervisor_deny_canary: Path,
        supervisor_allow_canary: Path,
        telemetry_dir: Optional[Path],
        expected_parent: str,
    ) -> None:
        self.socket_path = socket_path
        self.token = token
        self.delegate = delegate
        self.source_repo = source_repo
        self.broker_root = broker_root
        self.broker_repo = broker_root / "repo"
        self.base_sha = base_sha
        self.sandbox_bin = sandbox_bin
        self.sandbox_kind = sandbox_kind
        self.supervisor = supervisor
        self.supervisor_deny_canary = supervisor_deny_canary
        self.supervisor_allow_canary = supervisor_allow_canary
        self.telemetry_dir = telemetry_dir
        self.expected_parent = expected_parent
        self.stop = threading.Event()
        self.use_lock = threading.Lock()
        self.used = False
        self.repository_lock = threading.Lock()
        self.repository_ready = False
        self.process_lock = threading.Lock()
        self.active_process: Optional[subprocess.Popen[bytes]] = None
        self.control_empty = broker_root.parent / "control-empty"

    def _git(self, *args: str, cwd: Optional[Path] = None) -> bytes:
        environment = os.environ.copy()
        environment.update({"GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull})
        return subprocess.check_output(
            ["git", *args], cwd=str(cwd) if cwd else None, env=environment, stdin=subprocess.DEVNULL
        )

    def _prepare_repository(self) -> None:
        with self.repository_lock:
            if self.repository_ready:
                return
            self.broker_root.mkdir(parents=True, exist_ok=False)
            if self.control_empty.exists() or self.control_empty.is_symlink():
                control_stat = self.control_empty.lstat()
                if not stat.S_ISDIR(control_stat.st_mode) or self.control_empty.is_symlink():
                    raise ValueError("broker control-socket mask is not a trusted directory")
            else:
                self.control_empty.mkdir(mode=0o555)
            self.control_empty.chmod(0o555)
            object_format = self._git("-C", str(self.source_repo), "rev-parse", "--show-object-format").decode().strip()
            if object_format not in {"sha1", "sha256"}:
                raise ValueError(f"unsupported Git object format: {object_format}")
            common = self._git("-C", str(self.source_repo), "rev-parse", "--git-common-dir").decode().strip()
            common_path = Path(common)
            if not common_path.is_absolute():
                common_path = self.source_repo / common_path
            objects = common_path.resolve(strict=True) / "objects"
            init = ["init", "-q"]
            if object_format == "sha256":
                init.append("--object-format=sha256")
            init.append(str(self.broker_repo))
            self._git(*init)
            alternates = self.broker_repo / ".git" / "objects" / "info" / "alternates"
            alternates.write_text(f"{objects}\n", encoding="utf-8")
            self._git("-C", str(self.broker_repo), "update-ref", "refs/heads/legion-broker", self.base_sha)
            self._git("-C", str(self.broker_repo), "symbolic-ref", "HEAD", "refs/heads/legion-broker")
            self._git("-C", str(self.broker_repo), "reset", "--hard", "-q", "HEAD")
            self._prepare_private_runtime()
            self.repository_ready = True

    def _copy_auth_file(self, source: Path, destination: Path) -> bool:
        flags = os.O_RDONLY
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        try:
            source_descriptor = os.open(source, flags)
        except (FileNotFoundError, OSError):
            return False
        source_stat = os.fstat(source_descriptor)
        if not stat.S_ISREG(source_stat.st_mode) or source_stat.st_size > MAX_AUTH_FILE_BYTES:
            os.close(source_descriptor)
            return False
        try:
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination_flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
            if hasattr(os, "O_NOFOLLOW"):
                destination_flags |= os.O_NOFOLLOW
            destination_descriptor = os.open(destination, destination_flags, 0o600)
            try:
                copied = 0
                while True:
                    chunk = os.read(source_descriptor, min(1024 * 1024, MAX_AUTH_FILE_BYTES - copied + 1))
                    if not chunk:
                        break
                    copied += len(chunk)
                    if copied > MAX_AUTH_FILE_BYTES:
                        raise ValueError("harness authentication file exceeds 16 MiB")
                    view = memoryview(chunk)
                    while view:
                        written = os.write(destination_descriptor, view)
                        if written <= 0:
                            raise OSError("short harness authentication file write")
                        view = view[written:]
            except BaseException:
                os.close(destination_descriptor)
                destination.unlink(missing_ok=True)
                raise
            else:
                os.close(destination_descriptor)
        finally:
            os.close(source_descriptor)
        return True

    def _prepare_private_runtime(self) -> None:
        home = Path(os.environ.get("HOME", ""))
        runtime = self.broker_root / "runtime"
        runtime.mkdir(mode=0o700)

        codex_source = Path(os.environ.get("CODEX_HOME", str(home / ".codex")))
        self._copy_auth_file(codex_source / "auth.json", runtime / "codex" / "auth.json")

        pi_source = Path(os.environ.get("PI_CODING_AGENT_DIR", str(home / ".pi" / "agent")))
        for name in ("auth.json", "settings.json", "models.json", "keybindings.json"):
            self._copy_auth_file(pi_source / name, runtime / "pi" / name)

        hermes_source = Path(os.environ.get("HERMES_HOME", str(home / ".hermes")))
        for name in (".env", "auth.json"):
            self._copy_auth_file(hermes_source / name, runtime / "hermes" / name)

        claude_source = Path(os.environ.get("CLAUDE_CONFIG_DIR", str(home / ".claude")))
        self._copy_auth_file(claude_source / ".credentials.json", runtime / "claude" / ".credentials.json")

        xdg_data = Path(os.environ.get("XDG_DATA_HOME", str(home / ".local" / "share")))
        self._copy_auth_file(xdg_data / "opencode" / "auth.json", runtime / "xdg-data" / "opencode" / "auth.json")

        cursor_config = Path(os.environ.get("XDG_CONFIG_HOME", str(home / ".config"))) / "cursor"
        cursor_data = Path(os.environ.get("CURSOR_DATA_DIR", str(home / ".cursor")))
        cursor_auth_destination = runtime / "xdg-config" / "cursor" / "auth.json"
        if not self._copy_auth_file(cursor_config / "auth.json", cursor_auth_destination):
            self._copy_auth_file(cursor_data / "auth.json", cursor_auth_destination)
        for name in ("auth.json", "credentials.json"):
            self._copy_auth_file(cursor_data / name, runtime / "cursor-data" / name)

        for name in ("tmp", "cache", "state", "xdg-config", "xdg-cache", "xdg-state", "xdg-data", "cursor-data"):
            (runtime / name).mkdir(parents=True, exist_ok=True)

    def _sandbox_command(self, command: list[str]) -> list[str]:
        if self.sandbox_kind == "sandbox-exec":
            profile = self.broker_root / "target.sb"
            escaped_root = _scheme_escape(str(self.broker_root))
            escaped_supervisor_deny = _scheme_escape(str(self.supervisor_deny_canary))
            profile.write_text(
                "\n".join(
                    (
                        "(version 1)",
                        "(allow default)",
                        "(deny file-write*)",
                        "(deny signal)",
                        "(allow signal (target same-sandbox))",
                        "(deny process-info*)",
                        "(allow process-info* (target same-sandbox))",
                        f'(deny file-read* (literal "{escaped_supervisor_deny}"))',
                        "(deny network-outbound (remote unix-socket))",
                        '(allow network-outbound (remote unix-socket (path-literal "/private/var/run/mDNSResponder")))',
                        f'(allow file-write* (literal "/dev/null") (literal "/dev/tty") (subpath "{escaped_root}"))',
                        "",
                    )
                ),
                encoding="utf-8",
            )
            return [str(self.sandbox_bin), "-f", str(profile), *command]
        if self.sandbox_kind == "bwrap":
            sandboxed = [
                str(self.sandbox_bin),
                "--die-with-parent",
                "--new-session",
                "--unshare-pid",
                "--ro-bind",
                "/",
                "/",
                "--bind",
                str(self.broker_root),
                str(self.broker_root),
            ]
            sandboxed.extend(("--tmpfs", "/run"))
            home = Path(os.environ.get("HOME", ""))
            for directory in _host_control_directories(home):
                if directory == Path("/run") or directory.is_symlink() or not directory.is_dir():
                    continue
                sandboxed.extend(("--ro-bind", str(self.control_empty), str(directory)))
            sandboxed.extend(
                [
                "--proc",
                "/proc",
                "--chdir",
                str(self.broker_repo),
                "--",
                *command,
                ]
            )
            return sandboxed
        raise ValueError(f"unsupported broker sandbox kind: {self.sandbox_kind}")

    def _target_environment(self) -> dict[str, str]:
        environment = os.environ.copy()
        runtime = self.broker_root / "runtime"
        environment.update(
            {
                "TMPDIR": str(runtime / "tmp"),
                "TMP": str(runtime / "tmp"),
                "TEMP": str(runtime / "tmp"),
                "XDG_CONFIG_HOME": str(runtime / "xdg-config"),
                "XDG_CACHE_HOME": str(runtime / "xdg-cache"),
                "XDG_STATE_HOME": str(runtime / "xdg-state"),
                "XDG_DATA_HOME": str(runtime / "xdg-data"),
                "CURSOR_DATA_DIR": str(runtime / "cursor-data"),
                "CODEX_HOME": str(runtime / "codex"),
                "PI_CODING_AGENT_DIR": str(runtime / "pi"),
                "HERMES_HOME": str(runtime / "hermes"),
                "CLAUDE_CONFIG_DIR": str(runtime / "claude"),
                "LEGION_STATE_ROOT": str(runtime / "state"),
                "LEGION_TELEMETRY_DIR": str(runtime / "state" / "spans"),
                "LEGION_REGISTRY_DIR": str(runtime / "state" / "registry"),
                "LEGION_REPOS_FILE": str(runtime / "state" / "repos.jsonl"),
                "PYTHONDONTWRITEBYTECODE": "1",
            }
        )
        for name in (
            "DOCKER_HOST",
            "CONTAINER_HOST",
            "BUILDKIT_HOST",
            "SSH_AUTH_SOCK",
            "KUBECONFIG",
            "CONTAINERD_ADDRESS",
        ):
            environment.pop(name, None)
        return environment

    def _copy_telemetry(self) -> None:
        if self.telemetry_dir is None:
            return
        directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
        if hasattr(os, "O_NOFOLLOW"):
            directory_flags |= os.O_NOFOLLOW
        descriptors: list[int] = []
        try:
            current = os.open(self.broker_root, directory_flags)
            descriptors.append(current)
            for component in ("runtime", "state", "spans"):
                current = os.open(component, directory_flags, dir_fd=current)
                descriptors.append(current)
        except FileNotFoundError:
            for descriptor in reversed(descriptors):
                os.close(descriptor)
            return
        except OSError as error:
            for descriptor in reversed(descriptors):
                os.close(descriptor)
            raise ValueError("nested handoff telemetry path is not a trusted directory chain") from error

        source_descriptor = descriptors[-1]
        copied = 0
        pending: dict[str, list[bytes]] = {}
        try:
            for name in sorted(os.listdir(source_descriptor)):
                if not SAFE_TELEMETRY_NAME.fullmatch(name):
                    continue
                flags = os.O_RDONLY
                if hasattr(os, "O_NOFOLLOW"):
                    flags |= os.O_NOFOLLOW
                try:
                    descriptor = os.open(name, flags, dir_fd=source_descriptor)
                except OSError as error:
                    raise ValueError("nested handoff telemetry file is not safely readable") from error
                try:
                    source_stat = os.fstat(descriptor)
                    remaining = MAX_TELEMETRY_BYTES - copied
                    if not stat.S_ISREG(source_stat.st_mode) or source_stat.st_size > remaining:
                        raise ValueError("nested handoff telemetry exceeds 4 MiB or is not regular")
                    chunks: list[bytes] = []
                    file_size = 0
                    while True:
                        chunk = os.read(descriptor, min(64 * 1024, remaining - file_size + 1))
                        if not chunk:
                            break
                        file_size += len(chunk)
                        if file_size > remaining:
                            raise ValueError("nested handoff telemetry exceeds 4 MiB")
                        chunks.append(chunk)
                    copied += file_size
                finally:
                    os.close(descriptor)
                lines: list[bytes] = []
                for raw_line in b"".join(chunks).splitlines():
                    payload = json.loads(raw_line, parse_constant=_reject_json_constant)
                    validated = _validate_span(payload, self.expected_parent)
                    lines.append(json.dumps(validated, separators=(",", ":"), allow_nan=False).encode() + b"\n")
                pending[name] = lines
        finally:
            for descriptor in reversed(descriptors):
                os.close(descriptor)

        self.telemetry_dir.mkdir(parents=True, exist_ok=True)
        destination_directory = os.open(self.telemetry_dir, directory_flags)
        try:
            for name, lines in pending.items():
                flags = os.O_WRONLY | os.O_CREAT | os.O_APPEND
                if hasattr(os, "O_NOFOLLOW"):
                    flags |= os.O_NOFOLLOW
                descriptor = os.open(name, flags, 0o600, dir_fd=destination_directory)
                try:
                    if not stat.S_ISREG(os.fstat(descriptor).st_mode):
                        raise ValueError("canonical telemetry destination is not a regular file")
                    for encoded in lines:
                        _write_record_atomic(descriptor, encoded)
                finally:
                    os.close(descriptor)
        finally:
            os.close(destination_directory)

    def _response(self, returncode: int, stdout: bytes = b"", stderr: bytes = b"") -> dict[str, Any]:
        return {
            "returncode": returncode,
            "stdout": base64.b64encode(stdout).decode(),
            "stderr": base64.b64encode(stderr).decode(),
        }

    def terminate_active(self) -> None:
        with self.process_lock:
            process = self.active_process
        if process is not None:
            _terminate_supervisor(process)

    def _capture_process(self, process: subprocess.Popen[bytes], stdin: bytes) -> tuple[bytes, bytes]:
        if process.stdin is None or process.stdout is None or process.stderr is None:
            raise ValueError("broker target pipes are unavailable")
        try:
            process.stdin.write(stdin)
            process.stdin.close()
        except BrokenPipeError:
            pass

        stdout_fd = process.stdout.fileno()
        stderr_fd = process.stderr.fileno()
        captured = {stdout_fd: bytearray(), stderr_fd: bytearray()}
        selector = selectors.DefaultSelector()
        for stream in (process.stdout, process.stderr):
            os.set_blocking(stream.fileno(), False)
            selector.register(stream, selectors.EVENT_READ, stream.fileno())
        total = 0
        try:
            while selector.get_map():
                if self.stop.is_set():
                    _terminate_supervisor(process)
                for key, _events in selector.select(timeout=0.1):
                    descriptor = key.data
                    try:
                        chunk = os.read(descriptor, 64 * 1024)
                    except BlockingIOError:
                        continue
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    total += len(chunk)
                    if total > MAX_CHILD_OUTPUT_BYTES:
                        _terminate_supervisor(process)
                        raise ValueError("nested handoff output exceeds 16 MiB")
                    captured[descriptor].extend(chunk)
            process.wait(timeout=4.0)
        except subprocess.TimeoutExpired as error:
            _terminate_supervisor(process)
            raise ValueError("nested handoff target did not terminate") from error
        finally:
            selector.close()
            process.stdout.close()
            process.stderr.close()
        return bytes(captured[stdout_fd]), bytes(captured[stderr_fd])

    def request_stop(self) -> None:
        self.stop.set()

    def _handle(self, connection: socket.socket) -> None:
        try:
            request = _recv_json(connection, MAX_REQUEST_BYTES)
            supplied_token = request.get("token", "")
            if not isinstance(supplied_token, str) or not secrets.compare_digest(supplied_token, self.token):
                raise ValueError("broker authentication failed")
            args = _validated_args(request.get("argv"))
            try:
                stdin = base64.b64decode(request.get("stdin", ""), validate=True)
            except (TypeError, ValueError) as error:
                raise ValueError("broker stdin is not valid base64") from error
            if len(stdin) > MAX_TASK_BYTES:
                raise ValueError("broker stdin exceeds 16 KiB")

            with self.use_lock:
                if self.used:
                    raise ValueError("sandboxed workers may make only one cross-harness handoff")
                self.used = True

            self._prepare_repository()
            command = [
                str(self.delegate),
                *args,
                "--repo",
                str(self.broker_repo),
                "--base",
                "HEAD",
                "--no-dirty-warn",
            ]
            sandboxed = self._sandbox_command(command)
            supervised = [
                str(self.supervisor),
                "--cwd",
                str(self.broker_repo),
            ]
            if self.sandbox_kind == "sandbox-exec":
                supervised.extend(
                    (
                        "--darwin-sandbox-deny-canary",
                        str(self.supervisor_deny_canary),
                        "--darwin-sandbox-allow-canary",
                        str(self.supervisor_allow_canary),
                    )
                )
            supervised.extend(("--", *sandboxed))
            process = subprocess.Popen(
                supervised,
                cwd=self.broker_repo,
                env=self._target_environment(),
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                start_new_session=True,
            )
            with self.process_lock:
                self.active_process = process
            try:
                stdout, stderr = self._capture_process(process, stdin)
            finally:
                _terminate_supervisor(process)
                with self.process_lock:
                    self.active_process = None
            self._copy_telemetry()
            _send_json(connection, self._response(process.returncode, stdout, stderr), MAX_RESPONSE_BYTES)
        except (OSError, UnicodeError, ValueError, json.JSONDecodeError, subprocess.SubprocessError) as error:
            try:
                _send_json(connection, self._response(2, stderr=f"legion-delegate: {error}\n".encode()), MAX_RESPONSE_BYTES)
            except (OSError, ValueError):
                pass
        finally:
            connection.close()

    def serve(self) -> int:
        self.socket_path.parent.mkdir(parents=True, exist_ok=True)
        if self.socket_path.exists() or self.socket_path.is_symlink():
            raise ValueError(f"broker socket already exists: {self.socket_path}")
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            server.bind(str(self.socket_path))
            os.chmod(self.socket_path, 0o600)
            server.listen(1)
            server.settimeout(0.25)
            while not self.stop.is_set():
                try:
                    connection, _ = server.accept()
                except (TimeoutError, socket.timeout):
                    continue
                self._handle(connection)
            return 0
        finally:
            self.terminate_active()
            server.close()
            try:
                self.socket_path.unlink()
            except FileNotFoundError:
                pass


def _server(arguments: argparse.Namespace) -> int:
    telemetry = Path(arguments.telemetry_dir).resolve() if arguments.telemetry_dir else None
    deny_argument = Path(arguments.supervisor_deny_canary)
    allow_argument = Path(arguments.supervisor_allow_canary)
    if deny_argument.is_symlink() or allow_argument.is_symlink():
        raise ValueError("supervisor canary leaf must not be a symbolic link")
    supervisor_deny_canary = deny_argument.resolve(strict=True)
    supervisor_allow_canary = allow_argument.resolve(strict=True)
    if (
        supervisor_deny_canary == supervisor_allow_canary
        or supervisor_deny_canary.parent != supervisor_allow_canary.parent
        or not stat.S_ISREG(supervisor_deny_canary.stat().st_mode)
        or not stat.S_ISREG(supervisor_allow_canary.stat().st_mode)
    ):
        raise ValueError("supervisor canaries must be adjacent regular files")
    broker = Broker(
        socket_path=Path(arguments.socket),
        token=arguments.token,
        delegate=Path(arguments.delegate).resolve(strict=True),
        source_repo=Path(arguments.source_repo).resolve(strict=True),
        broker_root=Path(arguments.broker_root),
        base_sha=arguments.base_sha,
        sandbox_bin=Path(arguments.sandbox_bin).resolve(strict=True),
        sandbox_kind=arguments.sandbox_kind,
        supervisor=Path(arguments.supervisor).resolve(strict=True),
        supervisor_deny_canary=supervisor_deny_canary,
        supervisor_allow_canary=supervisor_allow_canary,
        telemetry_dir=telemetry,
        expected_parent=arguments.expected_parent,
    )

    def stop(_signum: int, _frame: Any) -> None:
        broker.request_stop()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGHUP, stop)
    return broker.serve()


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    serve = subparsers.add_parser("serve")
    serve.add_argument("--socket", required=True)
    serve.add_argument("--token", required=True)
    serve.add_argument("--delegate", required=True)
    serve.add_argument("--source-repo", required=True)
    serve.add_argument("--broker-root", required=True)
    serve.add_argument("--base-sha", required=True)
    serve.add_argument("--sandbox-bin", required=True)
    serve.add_argument("--sandbox-kind", choices=("sandbox-exec", "bwrap"), required=True)
    serve.add_argument("--supervisor", required=True)
    serve.add_argument("--supervisor-deny-canary", required=True)
    serve.add_argument("--supervisor-allow-canary", required=True)
    serve.add_argument("--telemetry-dir", default="")
    serve.add_argument("--expected-parent", required=True)
    return parser


def main() -> int:
    if Path(sys.argv[0]).name == "legion-delegate":
        return _client()
    arguments = _parser().parse_args()
    if arguments.command == "serve":
        return _server(arguments)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
