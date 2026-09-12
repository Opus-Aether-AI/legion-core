#!/usr/bin/env python3
"""Wait for one parent authorization byte before replacing this process.

The error descriptor is close-on-exec for the provider. EOF therefore means
the requested executable actually started; an errno record means it did not.
"""

import errno
import hashlib
import json
import os
import re
import stat
import sys
import time


def main():
    gate = int(sys.argv[1])
    errors = int(sys.argv[2])
    command = sys.argv[3:]
    try:
        decision = os.read(gate, 1)
    finally:
        os.close(gate)
    if decision != b"G" or not command:
        return 125
    os.set_inheritable(errors, False)
    try:
        expected = os.environ.pop("LEGION_EXEC_GATE_EXPECTED_SHA256", "")
        admitted_path = os.environ.pop("LEGION_EXEC_GATE_ADMITTED_PATH", "")
        if expected:
            if not re.fullmatch(r"[a-f0-9]{64}", expected) or not admitted_path or not os.path.isabs(admitted_path):
                raise OSError(errno.EINVAL, "invalid admitted executable digest")
            resolved = os.path.realpath(admitted_path)
            descriptor = os.open(resolved, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
            try:
                if not stat.S_ISREG(os.fstat(descriptor).st_mode):
                    raise OSError(errno.EINVAL, "admitted executable is not a regular file")
                hasher = hashlib.sha256()
                while True:
                    block = os.read(descriptor, 1024 * 1024)
                    if not block:
                        break
                    hasher.update(block)
                actual = os.stat(resolved, follow_symlinks=False)
                opened = os.fstat(descriptor)
                if (hasher.hexdigest() != expected or
                        (actual.st_dev, actual.st_ino) != (opened.st_dev, opened.st_ino) or
                        os.path.realpath(admitted_path) != resolved):
                    raise OSError(errno.ESTALE, "admitted executable changed before provider exec")
            finally:
                os.close(descriptor)
        absolute_deadline = os.environ.get("LEGION_CHILD_LEASE_DEADLINE_NS", "")
        if absolute_deadline:
            try:
                deadline_ns = int(absolute_deadline)
            except ValueError:
                raise OSError(errno.EINVAL, "invalid inherited child lease deadline")
            if deadline_ns <= time.monotonic_ns():
                raise OSError(errno.ETIMEDOUT,
                              "inherited child lease deadline expired during launch setup")
        os.execvpe(command[0], command, os.environ)
    except OSError as error:
        os.write(errors, (json.dumps({"errno": error.errno or 1,
                                      "reason": str(error)}) + "\n").encode())
        return 124 if error.errno == errno.ETIMEDOUT else (127 if error.errno == 2 else 126)


if __name__ == "__main__":
    raise SystemExit(main())
