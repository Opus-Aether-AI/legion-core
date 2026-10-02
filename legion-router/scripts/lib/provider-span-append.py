#!/usr/bin/env python3
"""Append one receipt-bound provider span to the inode pinned by its intent.

The shell emitter supplies task/trace/artifact context on stdin. Identity,
terminal outcome and metering are taken from the immutable attempt receipt,
never from jq's potentially lossy representation of large integers.
"""

import json
import os
import stat
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "legion-observability" / "scripts"))
from legion_receipts import validate_attempt  # noqa: E402

MAX_SPAN = 1024 * 1024


def bounded_regular(path: str, maximum: int):
    flags = os.O_RDONLY | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        info = os.fstat(descriptor)
        path_info = os.stat(path, follow_symlinks=False)
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_nlink != 1
            or info.st_size > maximum
            or (info.st_dev, info.st_ino) != (path_info.st_dev, path_info.st_ino)
        ):
            raise ValueError("unsafe receipt or append intent")
        raw = os.read(descriptor, maximum + 1)
        after = os.fstat(descriptor)
        path_after = os.stat(path, follow_symlinks=False)
        if (
            len(raw) != info.st_size
            or (after.st_dev, after.st_ino, after.st_size)
            != (info.st_dev, info.st_ino, info.st_size)
            or (path_after.st_dev, path_after.st_ino) != (info.st_dev, info.st_ino)
        ):
            raise ValueError("receipt or intent changed during read")
        return json.loads(raw)
    finally:
        os.close(descriptor)


def append(attempt_path: str, telemetry_dir: str, date: str):
    telemetry_dir = os.path.realpath(telemetry_dir)
    attempt = validate_attempt(bounded_regular(attempt_path, 65536))
    if attempt["attempt_kind"] != "provider":
        raise ValueError("only provider attempts can be appended")
    intent = bounded_regular(attempt_path + ".provider-span-intent", 4096)
    telemetry_path = os.path.join(telemetry_dir, date + ".jsonl")
    if (
        not isinstance(intent, dict)
        or set(intent) != {
            "schema", "attempt_receipt", "date", "telemetry_path",
            "device", "inode", "offset",
        }
        or intent["schema"] != "legion.provider-span-intent.v1"
        or intent["attempt_receipt"] != attempt_path
        or intent["date"] != date
        or intent["telemetry_path"] != telemetry_path
        or type(intent["device"]) is not int
        or type(intent["inode"]) is not int
        or type(intent["offset"]) is not int
        or intent["offset"] < 0
    ):
        raise ValueError("invalid or mismatched append intent")

    raw = sys.stdin.buffer.read(MAX_SPAN + 1)
    if len(raw) > MAX_SPAN or not raw.endswith(b"\n") or raw.count(b"\n") != 1:
        raise ValueError("provider span must be one bounded complete JSONL record")
    span = json.loads(raw)
    if not isinstance(span, dict) or span.get("schema") != "legion.span.v1":
        raise ValueError("invalid provider span")
    artifacts = span.get("artifacts")
    if (
        not isinstance(artifacts, dict)
        or artifacts.get("provider_attempt") is not True
        or artifacts.get("attempt_receipt") != attempt_path
    ):
        raise ValueError("span does not name the pinned attempt")
    terminal = attempt["terminal_status"]
    span_status = {
        "succeeded": "ok", "failed": "failed", "cancelled": "failed",
        "timed_out": "timed_out", "refused": "refused",
    }[terminal]
    if terminal == "failed" and isinstance(attempt.get("failure"), dict) and (
        attempt["failure"].get("class") == "quota"
    ):
        span_status = "blocked"
    span.update({
        "run_id": attempt["run_id"],
        "attempt_id": attempt["attempt_id"],
        "attempt_ordinal": attempt["ordinal"],
        "attempt_terminal_status": attempt["terminal_status"],
        "executor": attempt["executor"],
        "model": attempt.get("effective_model") or attempt.get("requested_model") or "unknown",
        "status": span_status,
        "duration_ms": attempt["duration_ms"],
        "tokens": attempt["usage"],
        "usage_status": attempt["usage_status"],
        "cost_usd": attempt["cost_usd"],
        "cost_status": attempt["cost_status"],
    })
    encoded = (json.dumps(span, separators=(",", ":"), allow_nan=False) + "\n").encode()
    if len(encoded) > MAX_SPAN:
        raise ValueError("canonical provider span exceeds byte limit")

    flags = os.O_WRONLY | os.O_APPEND | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(telemetry_path, flags)
    try:
        info = os.fstat(descriptor)
        path_info = os.stat(telemetry_path, follow_symlinks=False)
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_nlink != 1
            or info.st_size < intent["offset"]
            or (info.st_dev, info.st_ino) != (intent["device"], intent["inode"])
            or (path_info.st_dev, path_info.st_ino) != (info.st_dev, info.st_ino)
        ):
            raise ValueError("pinned telemetry inode was replaced")
        if os.write(descriptor, encoded) != len(encoded):
            raise OSError("partial provider span append")
        os.fsync(descriptor)
        after = os.fstat(descriptor)
        path_after = os.stat(telemetry_path, follow_symlinks=False)
        if (after.st_dev, after.st_ino) != (info.st_dev, info.st_ino) or (
            path_after.st_dev, path_after.st_ino
        ) != (info.st_dev, info.st_ino):
            raise ValueError("telemetry leaf changed during append")
    finally:
        os.close(descriptor)


if __name__ == "__main__":
    try:
        append(*sys.argv[1:])
    except (OSError, ValueError, TypeError, KeyError, UnicodeDecodeError) as error:
        print(f"provider span append: {error}", file=sys.stderr)
        raise SystemExit(1)
