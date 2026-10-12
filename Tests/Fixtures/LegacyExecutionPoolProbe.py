#!/usr/bin/env python3
"""The original pool acquisition protocol, before live capacity updates."""
import fcntl
import os
from pathlib import Path
import sys
import time


root = Path(sys.argv[1])
identifier = sys.argv[2]
initial_capacity = int(sys.argv[3])
pool = root / "pool"
pool.mkdir(parents=True, exist_ok=True)
(root / (identifier + ".ready")).touch()

with os.fdopen(os.open(pool / "capacity.lock", os.O_CREAT | os.O_RDWR, 0o600), "r+") as configuration:
    fcntl.flock(configuration, fcntl.LOCK_EX)
    stored = configuration.read()
    if stored:
        capacity = int(stored)
    else:
        capacity = initial_capacity
        configuration.write(str(capacity))
        configuration.flush()
        os.fsync(configuration.fileno())

while True:
    for index in range(capacity):
        slot = os.fdopen(os.open(pool / f"slot-{index}.lock", os.O_CREAT | os.O_RDWR, 0o600), "r+")
        try:
            fcntl.flock(slot, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            slot.close()
            continue
        with slot:
            (root / (identifier + ".started")).write_text(str(os.getpid()))
            while not (root / (identifier + ".release")).exists():
                time.sleep(0.02)
        sys.exit(0)
    time.sleep(0.1)
