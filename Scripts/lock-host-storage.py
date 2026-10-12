#!/usr/bin/env python3
"""Run an installer operation under the host's storage transaction lock."""
import fcntl
import os
from pathlib import Path
import sys

script, operation, *arguments = sys.argv[1:]
host_root = Path.home() / "Library/Application Support/XcodeRunnerKit"
host_root.mkdir(mode=0o700, parents=True, exist_ok=True)
lock = host_root / "storage.lock"
inherited = os.environ.get("XCODE_RUNNER_STORAGE_LOCK_DESCRIPTOR")
if inherited is None:
    descriptor = os.open(lock, os.O_CREAT | os.O_RDWR, 0o600)
else:
    descriptor = int(inherited)
    opened = os.fstat(descriptor)
    current = lock.stat()
    if (opened.st_dev, opened.st_ino) != (current.st_dev, current.st_ino):
        raise RuntimeError("The inherited storage lock does not match this host installation.")
fcntl.flock(descriptor, fcntl.LOCK_EX)
os.set_inheritable(descriptor, True)
environment = {**os.environ, "XCODE_RUNNER_STORAGE_LOCK_DESCRIPTOR": str(descriptor)}
os.execvpe("bash", ["bash", "-c", 'source "$1"; "$2" "${@:3}"',
                    "host-storage-operation", script, operation, *arguments], environment)
