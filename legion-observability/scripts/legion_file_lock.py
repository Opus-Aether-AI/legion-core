"""Cross-platform advisory file locks for Legion scripts."""

from __future__ import annotations

import contextlib
import os
from typing import IO, Iterator


@contextlib.contextmanager
def exclusive_lock(lock: IO[str] | int, *, blocking: bool = True) -> Iterator[None]:
    """Hold an exclusive advisory lock for ``lock``.

    Accepts either a file object or a raw file descriptor: callers that opened
    a lock with ``os.open`` (legion-converge) have no file object to hand over,
    and wrapping one just to lock it would close the descriptor on exit.

    Windows locks a single, stable byte at the beginning of the lock file;
    POSIX preserves the existing whole-file ``flock`` behaviour.
    """
    descriptor = lock if isinstance(lock, int) else lock.fileno()
    if os.name == "nt":
        import msvcrt

        # A raw descriptor has no independent position to preserve.
        position = None if isinstance(lock, int) else lock.tell()
        if position is not None:
            lock.seek(0)
        else:
            os.lseek(descriptor, 0, os.SEEK_SET)
        operation = msvcrt.LK_LOCK if blocking else msvcrt.LK_NBLCK
        msvcrt.locking(descriptor, operation, 1)
        try:
            yield
        finally:
            msvcrt.locking(descriptor, msvcrt.LK_UNLCK, 1)
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
