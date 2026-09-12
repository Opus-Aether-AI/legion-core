#!/usr/bin/env python3
"""Wait for one parent authorization byte before replacing this process.

The error descriptor is close-on-exec for the provider. EOF therefore means
the requested executable actually started; an errno record means it did not.
"""

import json
import os
import sys


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
        os.execvpe(command[0], command, os.environ)
    except OSError as error:
        os.write(errors, (json.dumps({"errno": error.errno or 1,
                                      "reason": str(error)}) + "\n").encode())
        return 127 if error.errno == 2 else 126


if __name__ == "__main__":
    raise SystemExit(main())
