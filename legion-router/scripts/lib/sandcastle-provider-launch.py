#!/usr/bin/env python3
"""Authenticate Sandcastle provider launch across the real exec boundary."""

import errno
import hashlib
import hmac
import json
import os
import select
import signal
import stat
import subprocess
import sys
import tempfile
import time


def marker_write(path, token, status, pid=None):
    directory = os.path.dirname(path)
    descriptor, temporary = tempfile.mkstemp(prefix=".sandcastle-provider.", dir=directory)
    try:
        payload = {"schema": "legion.sandcastle-provider-launch.v2", "status": status}
        if pid is not None:
            payload["provider_pid"] = pid
        encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
        payload["auth"] = hmac.new(token.encode(), encoded, hashlib.sha256).hexdigest()
        with os.fdopen(descriptor, "w", encoding="utf-8") as destination:
            json.dump(payload, destination, separators=(",", ":"))
            destination.write("\n")
            destination.flush()
            os.fsync(destination.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
        directory_fd = os.open(directory, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def verify_marker(path, token):
    try:
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    except FileNotFoundError:
        return "absent"
    except OSError:
        return "malformed"
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_size > 4096:
            return "malformed"
        payload = json.loads(os.read(descriptor, 4097))
        if not isinstance(payload, dict):
            return "malformed"
        provided = payload.pop("auth", None)
        status = payload.get("status")
        expected_fields = {"schema", "status"}
        if status == "started":
            expected_fields.add("provider_pid")
            if type(payload.get("provider_pid")) is not int or payload["provider_pid"] < 1:
                return "malformed"
        elif status not in {"pending", "not-started"}:
            return "malformed"
        if (set(payload) != expected_fields or payload.get("schema") != "legion.sandcastle-provider-launch.v2"
                or not isinstance(provided, str) or len(provided) != 64):
            return "malformed"
        encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
        expected = hmac.new(token.encode(), encoded, hashlib.sha256).hexdigest()
        return status if hmac.compare_digest(provided, expected) else "malformed"
    except (OSError, UnicodeDecodeError, ValueError):
        return "malformed"
    finally:
        os.close(descriptor)


def consume_token(path):
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        info = os.fstat(descriptor)
        if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1
                or info.st_uid != os.geteuid() or info.st_mode & 0o077):
            raise OSError(errno.EPERM, "invalid launch token file")
        token = os.read(descriptor, 128).decode("ascii").strip()
        if len(token) != 48 or any(c not in "0123456789abcdef" for c in token):
            raise OSError(errno.EINVAL, "invalid launch token")
        os.unlink(path)
        return token
    finally:
        os.close(descriptor)


def main():
    marker, token_path, exec_gate, expected_digest, executable, *arguments = sys.argv[1:]
    token = consume_token(token_path)
    command = [executable, *arguments]
    if not expected_digest or not os.path.isabs(executable) or not command:
        marker_write(marker, token, "not-started")
        return 126
    child = None
    started = False
    interrupted = None
    authorization = -1

    def forward(signum, _frame):
        nonlocal interrupted, authorization
        if started:
            try:
                child.send_signal(signum)
            except ProcessLookupError:
                pass
        else:
            interrupted = signum
            if authorization >= 0:
                os.close(authorization)
                authorization = -1

    for caught in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(caught, forward)
    marker_write(marker, token, "pending")
    if interrupted is not None:
        marker_write(marker, token, "not-started")
        return 128 + interrupted
    gate_read = error_read = error_write = -1
    try:
        gate_read, authorization = os.pipe()
        error_read, error_write = os.pipe()
        environment = dict(os.environ)
        environment["LEGION_EXEC_GATE_EXPECTED_SHA256"] = expected_digest
        environment["LEGION_EXEC_GATE_ADMITTED_PATH"] = executable
        child = subprocess.Popen(
            [sys.executable, exec_gate, str(gate_read), str(error_write), *command],
            env=environment, pass_fds=(gate_read, error_write),
        )
    except OSError as error:
        marker_write(marker, token, "not-started")
        print(f"provider launch failed: {error}", file=sys.stderr)
        return 127 if error.errno == errno.ENOENT else 126
    finally:
        for descriptor in (gate_read, error_write):
            if descriptor >= 0:
                os.close(descriptor)
    try:
        if interrupted is not None or authorization < 0:
            marker_write(marker, token, "not-started")
            return 128 + interrupted if interrupted is not None else 126
        deadline = os.environ.get("LEGION_CHILD_LEASE_DEADLINE_NS", "")
        if deadline and time.monotonic_ns() >= int(deadline):
            marker_write(marker, token, "not-started")
            return 124
        os.write(authorization, b"G")
    finally:
        if authorization >= 0:
            os.close(authorization)
        if error_read >= 0:
            # Child exits when the authorization pipe closes on an early return.
            pass
    try:
        if not select.select([error_read], [], [], 2)[0]:
            raise RuntimeError("provider exec gate did not confirm launch")
        launch_error = os.read(error_read, 4097)
    finally:
        os.close(error_read)
    if launch_error:
        detail = json.loads(launch_error)
        marker_write(marker, token, "not-started")
        print(f"provider launch failed: {detail['reason']}", file=sys.stderr)
        return 127 if detail["errno"] == errno.ENOENT else 126
    marker_write(marker, token, "started", child.pid)
    started = True
    if interrupted is not None:
        forward(interrupted, None)
    return child.wait()


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--verify":
        print(verify_marker(sys.argv[2], sys.stdin.read(128).strip()), end="")
    else:
        raise SystemExit(main())
