#!/usr/bin/env python3
"""Unload a user service and wait for its processes and ownership lock."""
import argparse
import fcntl
import os
from pathlib import Path
import re
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('service')
parser.add_argument('--runner-directory', type=Path)
parser.add_argument('--ownership-lock', type=Path)
arguments = parser.parse_args()


def processes():
    output = subprocess.check_output(['ps', '-ww', '-axo', 'pid=,ppid=,pgid=,stat=,comm='], text=True)
    result = {}
    for line in output.splitlines():
        pid, parent, group, state, executable = line.strip().split(None, 4)
        result[int(pid)] = (int(parent), int(group), state, executable)
    return result


status = subprocess.run(['launchctl', 'print', arguments.service], capture_output=True, text=True)
table = processes()
roots = set()
pid = re.search(r'^\s*pid = (\d+)', status.stdout, re.MULTILINE)
if pid and int(pid[1]) > 0:
    roots.add(int(pid[1]))
if arguments.runner_directory:
    prefix = str(arguments.runner_directory.resolve()) + os.sep
    roots.update(identifier for identifier, info in table.items() if info[3].startswith(prefix))
descendants = set(roots)
while True:
    children = {identifier for identifier, info in table.items() if info[0] in descendants}
    if children <= descendants:
        break
    descendants.update(children)
groups = {table[identifier][1] for identifier in descendants if identifier in table}
if status.returncode == 0:
    subprocess.run(['launchctl', 'bootout', arguments.service], check=True)

lock = None
try:
    if arguments.ownership_lock:
        try:
            lock = arguments.ownership_lock.open('rb')
        except FileNotFoundError:
            pass
    deadline = time.monotonic() + 60
    while True:
        live = [identifier for identifier, info in processes().items()
                if info[1] in groups and not info[2].startswith('Z')]
        available = True
        if lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                available = False
        if not live and available:
            break
        if time.monotonic() >= deadline:
            raise TimeoutError(f'Service {arguments.service} did not finish shutdown; live processes: {live}')
        time.sleep(0.1)
finally:
    if lock:
        lock.close()
