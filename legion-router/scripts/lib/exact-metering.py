#!/usr/bin/env python3
"""Preserve canonical token integers across jq 1.6 shell JSON boundaries.

Only metering fields are copied; status and other terminal evidence remain the
caller's responsibility. File inputs are bounded, regular, single-link leaves.
"""

import json
import os
import stat
import sys

MAX_RECEIPT = 65536
MAX_JSON = 8 * 1048576
FIELDS = {"usage", "known_usage", "reconciliation.usage", "reconciliation.known_usage"}


def read_bounded(stream, maximum):
    raw = stream.read(maximum + 1)
    if len(raw) > maximum:
        raise ValueError("metering JSON exceeds byte limit")
    return json.loads(raw)


def read_file(path):
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOFOLLOW", 0))
    try:
        before = os.fstat(fd)
        leaf = os.stat(path, follow_symlinks=False)
        if (not stat.S_ISREG(before.st_mode) or before.st_nlink != 1
                or before.st_size > MAX_RECEIPT
                or (before.st_dev, before.st_ino) != (leaf.st_dev, leaf.st_ino)):
            raise ValueError("unsafe attempt receipt")
        with os.fdopen(os.dup(fd), "rb") as stream:
            raw = stream.read(MAX_RECEIPT + 1)
        after = os.fstat(fd)
        leaf_after = os.stat(path, follow_symlinks=False)
        if (len(raw) != before.st_size
                or (after.st_dev, after.st_ino, after.st_size)
                != (before.st_dev, before.st_ino, before.st_size)
                or (leaf_after.st_dev, leaf_after.st_ino) != (before.st_dev, before.st_ino)):
            raise ValueError("attempt receipt changed during read")
        return json.loads(raw)
    finally:
        os.close(fd)


def dump(value):
    print(json.dumps(value, separators=(",", ":"), allow_nan=False))


def get(source, field):
    if field not in FIELDS:
        raise ValueError("unsupported metering field")
    value = source
    for component in field.split("."):
        if not isinstance(value, dict) or component not in value:
            raise ValueError("missing metering field")
        value = value[component]
    return value


def patch(terminal, source):
    if not isinstance(terminal, dict) or not isinstance(source, dict):
        raise ValueError("metering envelope must be an object")
    metering = source.get("reconciliation")
    if metering is None:
        metering = source
    if not isinstance(metering, dict):
        raise ValueError("invalid reconciliation")
    # An outer containment/no-launch path can intentionally downgrade the
    # terminal status. Never replace that status with a stale attempt value.
    if terminal.get("usage_status") == metering.get("usage_status"):
        if "usage" in metering:
            terminal["usage"] = metering["usage"]
            if "tokens" in terminal:
                terminal["tokens"] = metering["usage"]
        if terminal.get("usage_status") == "partial" and "known_usage" in metering:
            terminal["known_usage"] = metering["known_usage"]
    if terminal.get("cost_status") == metering.get("cost_status"):
        if "cost_usd" in metering:
            terminal["cost_usd"] = metering["cost_usd"]
        if terminal.get("cost_status") == "partial" and "known_cost_usd" in metering:
            terminal["known_cost_usd"] = metering["known_cost_usd"]
    if "metering_reconciliation" in terminal:
        terminal["metering_reconciliation"] = (metering if metering.get("attempt_count", 1) else None)
    return terminal


def main():
    if len(sys.argv) == 4 and sys.argv[1] == "get":
        source = read_bounded(sys.stdin.buffer, MAX_JSON) if sys.argv[2] == "-" else read_file(sys.argv[2])
        dump(get(source, sys.argv[3]))
    elif len(sys.argv) == 3 and sys.argv[1] == "patch-attempt":
        terminal = read_bounded(sys.stdin.buffer, MAX_JSON)
        dump(patch(terminal, read_file(sys.argv[2])))
    elif len(sys.argv) == 2 and sys.argv[1] == "patch-reconciliation":
        terminal = read_bounded(sys.stdin.buffer, MAX_JSON)
        with os.fdopen(3, "rb", closefd=False) as source_stream:
            source = read_bounded(source_stream, MAX_JSON)
        dump(patch(terminal, source))
    else:
        raise ValueError("usage: exact-metering.py get PATH FIELD | patch-attempt PATH | patch-reconciliation")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, TypeError, KeyError, UnicodeDecodeError) as exc:
        print(f"exact metering: {exc}", file=sys.stderr)
        raise SystemExit(1)
