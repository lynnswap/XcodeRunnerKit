#!/usr/bin/env python3
"""Cancel a real Xcode test through the shell entry process used by Actions."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import tempfile
import time

REPO = Path(__file__).resolve().parents[1]


def processes():
    result = {}
    output = subprocess.check_output(["ps", "ax", "-o", "pid=,ppid=,pgid=,stat=,comm="], text=True)
    for line in output.splitlines():
        pid, parent, group, state, command = line.strip().split(None, 4)
        result[int(pid)] = (int(parent), int(group), state, command)
    return result


def descendants(snapshot, root):
    owned = {root}
    while True:
        expanded = owned | {pid for pid, info in snapshot.items() if info[0] in owned}
        if expanded == owned:
            return owned
        owned = expanded


# Steps wait for the state they need. This limit only reports a process that hangs.
HANG_LIMIT = 120


def wait_for(predicate, timeout):
    deadline = time.monotonic() + timeout
    while not predicate():
        if time.monotonic() >= deadline:
            raise AssertionError("Timed out waiting for the cancellation probe")
        time.sleep(0.05)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("executable", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="XcodeRunnerCancellation-") as temporary:
        root = Path(temporary)
        package = root / "BuildProbe"
        shutil.copytree(REPO / "Tests/Fixtures/BuildProbe", package,
                        ignore=shutil.ignore_patterns(".build", ".swiftpm"))
        results = []
        for name, number in (("SIGINT", signal.SIGINT), ("SIGTERM", signal.SIGTERM)):
            command = [str(args.executable.resolve()), "test", "--package", str(package),
                       "--scheme", "BuildProbe", "--destination", "platform=macOS,arch=arm64",
                       "--output-directory", str(root / name),
                       "--pool-directory", str(root / "pool"), "--maximum-concurrent-jobs", "1",
                       "--environment", "TEST_RUNNER_PROBE_MODE=wait",
                       "--", "-parallel-testing-enabled", "NO", "-jobs", "3"]
            wrapper = root / (name + ".sh")
            wrapper.write_text("#!/bin/bash\nset -euo pipefail\nexec " + shlex.join(command) + "\n")
            log = root / (name + ".log")
            group = None
            owned = set()
            with log.open("wb") as output:
                job = subprocess.Popen(["/bin/bash", "-c", 'exec bash "$1"', "--", str(wrapper)],
                                       stdout=output, stderr=subprocess.STDOUT)
                try:
                    wait_for(lambda: re.search(r"BuildProbe payload ready pid=\d+\n", log.read_text(errors="replace"))
                             or job.poll() is not None, 300)
                    assert job.poll() is None, log.read_text(errors="replace")[-3000:]
                    snapshot = processes()
                    assert snapshot[job.pid][3].endswith("/xcode-runner"), snapshot[job.pid]
                    payload = int(re.search(r"BuildProbe payload ready pid=(\d+)",
                                            log.read_text(errors="replace"))[1])
                    owned = descendants(snapshot, job.pid)
                    owned.add(payload)
                    xcode = [pid for pid in owned if snapshot[pid][3].endswith("/xcodebuild")]
                    assert len(xcode) == 1, (owned, xcode)
                    group = snapshot[xcode[0]][1]
                    owned |= {pid for pid, info in snapshot.items() if info[1] == group}
                    start = time.monotonic()
                    job.send_signal(number)
                    code = job.wait(timeout=HANG_LIMIT)
                    assert code == 130, (code, log.read_text(errors="replace")[-3000:])
                    wait_for(lambda: not (owned & processes().keys()), HANG_LIMIT)
                    with (root / "pool/slot-0.lock").open("rb") as lock:
                        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    results.append({"signal": name, "seconds": round(time.monotonic() - start, 3),
                                    "entryPID": job.pid, "xcodePID": xcode[0], "testPID": payload,
                                    "remainingProcesses": [], "slotReleased": True})
                finally:
                    if job.poll() is None:
                        job.send_signal(signal.SIGTERM)
                        try:
                            job.wait(timeout=HANG_LIMIT)
                        except subprocess.TimeoutExpired:
                            job.kill()
                            job.wait()
                    if group is not None:
                        live = processes()
                        if any(pid in owned and info[1] == group and not info[2].startswith("Z")
                               for pid, info in live.items()):
                            os.killpg(group, signal.SIGKILL)
                        for pid in owned:
                            if pid in live and not live[pid][2].startswith("Z") and live[pid][3] == snapshot[pid][3]:
                                try:
                                    os.kill(pid, signal.SIGKILL)
                                except ProcessLookupError:
                                    pass
        print(json.dumps({"passed": True, "results": results}))


if __name__ == "__main__":
    main()
