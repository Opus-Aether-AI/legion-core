import importlib.util
import multiprocessing
import os
import sys
import time
import types
from unittest import mock

import pytest


HERE = os.path.dirname(__file__)
PATH = os.path.join(
    HERE, "..", "..", "legion-observability", "scripts", "legion_file_lock.py"
)
SPEC = importlib.util.spec_from_file_location("legion_file_lock", PATH)
file_lock = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(file_lock)


def _locked_writer(lock_path, output_path, label, entered, pause):
    with open(lock_path, "a+", encoding="utf-8") as lock:
        with file_lock.exclusive_lock(lock):
            with open(output_path, "a", encoding="utf-8") as output:
                output.write(f"{label}-start\n")
                output.flush()
                entered.set()
                time.sleep(pause)
                output.write(f"{label}-end\n")


@pytest.mark.skipif(os.name != "posix", reason="requires POSIX flock")
def test_exclusive_lock_serializes_two_writers(tmp_path):
    context = multiprocessing.get_context("fork")
    lock_path = str(tmp_path / "writers.lock")
    output_path = str(tmp_path / "writers.txt")
    first_entered = context.Event()
    second_entered = context.Event()

    first = context.Process(
        target=_locked_writer,
        args=(lock_path, output_path, "first", first_entered, 0.3),
    )
    first.start()
    assert first_entered.wait(5)

    second = context.Process(
        target=_locked_writer,
        args=(lock_path, output_path, "second", second_entered, 0),
    )
    second.start()
    first.join(5)
    second.join(5)

    assert first.exitcode == 0
    assert second.exitcode == 0
    assert (tmp_path / "writers.txt").read_text(encoding="utf-8").splitlines() == [
        "first-start",
        "first-end",
        "second-start",
        "second-end",
    ]


def test_exclusive_lock_selects_windows_msvcrt_branch(tmp_path):
    calls = []
    fake_msvcrt = types.SimpleNamespace(
        LK_LOCK=1,
        LK_NBLCK=2,
        LK_UNLCK=3,
        locking=lambda descriptor, operation, size: calls.append(
            (descriptor, operation, size)
        ),
    )

    with open(tmp_path / "windows.lock", "a+", encoding="utf-8") as lock:
        with mock.patch.object(file_lock.os, "name", "nt"), mock.patch.dict(
            sys.modules, {"msvcrt": fake_msvcrt}
        ):
            with file_lock.exclusive_lock(lock):
                pass

    assert [operation for _, operation, _ in calls] == [
        fake_msvcrt.LK_LOCK,
        fake_msvcrt.LK_UNLCK,
    ]
    assert all(size == 1 for _, _, size in calls)
