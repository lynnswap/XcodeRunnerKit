#!/usr/bin/env python3
"""Remove temporary symlinks before the official runner deletes their targets."""
import os
from pathlib import Path

temporary = Path(os.environ["RUNNER_TEMP"])
if not temporary.is_absolute() or temporary.name != "_temp":
    raise ValueError("RUNNER_TEMP must name the official runner's absolute _temp directory")

if temporary.is_symlink():
    raise ValueError("RUNNER_TEMP itself must not be a symbolic link")


def traversal_failed(error):
    raise error


removed = 0
for directory, folders, files in os.walk(temporary, followlinks=False, onerror=traversal_failed):
    for name in folders[:]:
        path = Path(directory) / name
        if path.is_symlink():
            path.unlink()
            folders.remove(name)
            removed += 1
    for name in files:
        path = Path(directory) / name
        if path.is_symlink():
            path.unlink()
            removed += 1
print(f"Removed {removed} temporary symlinks from {temporary}")
