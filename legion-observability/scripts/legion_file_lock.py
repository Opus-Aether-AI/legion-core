"""Cross-platform advisory file locks for Legion scripts."""

from __future__ import annotations

import contextlib
import os
from typing import IO, Iterator


@contextlib.contextmanager
def exclusive_lock(lock: IO[str] | int, *, blocking: bool = True) -> Iterator[None]:
    """Hold an exclusive advisory lock for ``lock``.

    Accepts either a file object or a raw file descriptor: callers that opened
    a lock with ``os.open`` (legion-converge, the handoff broker) have no file
    object to hand over, and wrapping one just to lock it would close the
    descriptor on exit.

    Windows locks a single, stable byte at offset 0; POSIX preserves the
    existing whole-file ``flock`` behaviour.
    """
    descriptor = lock if isinstance(lock, int) else lock.fileno()

    if os.name == "nt":
        import msvcrt

        # msvcrt.locking always acts at the CURRENT file position, so every
        # lock and unlock has to be issued from the same offset. The caller
        # owns the position between them -- writing to the lock file is exactly
        # what these locks protect -- so seek deliberately at both ends rather
        # than assuming it stayed put.
        position = None if isinstance(lock, int) else lock.tell()

        def _seek_to_locked_byte() -> None:
            if position is not None:
                lock.seek(0)
            else:
                os.lseek(descriptor, 0, os.SEEK_SET)

        _seek_to_locked_byte()
        if blocking:
            # LK_LOCK is not "block until free": it retries ten times at one
            # second intervals and then raises. flock(LOCK_EX) has no such
            # ceiling, and a caller asking for a blocking lock means it. Retry
            # until acquired so both platforms honour the same contract.
            while True:
                try:
                    msvcrt.locking(descriptor, msvcrt.LK_LOCK, 1)
                    break
                except OSError:
                    _seek_to_locked_byte()
        else:
            msvcrt.locking(descriptor, msvcrt.LK_NBLCK, 1)
        try:
            yield
        finally:
            # Unlock the byte that was locked, not wherever the body left the
            # cursor -- otherwise this either raises or silently leaves the
            # lock held.
            _seek_to_locked_byte()
            try:
                msvcrt.locking(descriptor, msvcrt.LK_UNLCK, 1)
            finally:
                if position is not None:
                    lock.seek(position)
        return

    import fcntl

    operation = fcntl.LOCK_EX if blocking else fcntl.LOCK_EX | fcntl.LOCK_NB
    fcntl.flock(descriptor, operation)
    try:
        yield
    finally:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
