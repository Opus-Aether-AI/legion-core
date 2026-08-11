#!/usr/bin/env python3
"""Run one command in a private, fully-terminated process group.

Python's ``start_new_session`` is available on both Linux and macOS, unlike the
optional ``setsid`` command.  The supervisor forwards cancellation, waits a
short grace period, escalates to SIGKILL, and does not return until the whole
provider process group is gone.
"""

from __future__ import annotations

import argparse
import errno
import os
import signal
import subprocess
import sys
import time
from typing import Optional


GRACE_SECONDS = 2.0
POLL_SECONDS = 0.05


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


def _drain_group(process: subprocess.Popen[bytes]) -> None:
    process_group = process.pid
    if not _group_exists(process_group):
        return
    _signal_group(process_group, signal.SIGTERM)
    deadline = time.monotonic() + GRACE_SECONDS
    while time.monotonic() < deadline and _group_exists(process_group):
        time.sleep(POLL_SECONDS)
    if _group_exists(process_group):
        _signal_group(process_group, signal.SIGKILL)
        deadline = time.monotonic() + GRACE_SECONDS
        while time.monotonic() < deadline and _group_exists(process_group):
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
    interrupted = 0
    returncode = 1

    def stop(signum: int, _frame: object) -> None:
        nonlocal interrupted
        interrupted = signum
        if process is not None:
            _signal_group(process.pid, signal.SIGTERM)

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGHUP, stop)

    try:
        process = subprocess.Popen(
            command,
            cwd=arguments.cwd,
            stdin=None,
            stdout=None,
            stderr=None,
            start_new_session=True,
        )
        returncode = process.wait()
    except OSError as error:
        if error.errno == errno.ENOENT:
            print(f"legion-process-supervisor: command not found: {command[0]}", file=sys.stderr)
            return 127
        raise
    finally:
        if process is not None:
            _drain_group(process)

    if interrupted:
        return 128 + interrupted
    return returncode if returncode >= 0 else 128 - returncode


if __name__ == "__main__":
    raise SystemExit(main())
