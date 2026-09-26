#!/usr/bin/env python3
"""Hold an OS-managed lock for the full lifetime of a build command."""

import fcntl
from pathlib import Path
import subprocess
import sys


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: with_lock.py LOCK_FILE COMMAND [ARGS...]", file=sys.stderr)
        return 2
    lock_path = Path(sys.argv[1])
    try:
        with lock_path.open("a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                print("Another bundle build is in progress; the existing app was left unchanged.", file=sys.stderr)
                return 1
            # The child retains the lock if this wrapper is terminated first.
            return subprocess.run(sys.argv[2:], pass_fds=(lock.fileno(),)).returncode
    except OSError as error:
        print(f"Build lock failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
