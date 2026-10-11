#!/usr/bin/env python3
"""Verify production pool locks using separate operating-system processes."""
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time

REPO = Path(__file__).resolve().parents[1]


def wait_for(predicate, timeout=10):
    end = time.monotonic() + timeout
    while not predicate():
        if time.monotonic() >= end:
            raise AssertionError("Timed out waiting for a process transition")
        time.sleep(0.02)


def main():
    with tempfile.TemporaryDirectory(prefix="XcodeRunnerPool-") as temporary:
        root = Path(temporary)
        executable = root / "pool-probe"
        subprocess.run([
            "xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
            str(REPO / "Sources/XcodeRunnerKit/HostExecutionPool.swift"),
            str(REPO / "Tests/Fixtures/ExecutionPoolProbe.swift"),
            "-o", str(executable),
        ], check=True)
        jobs = {}
        logs = []

        def start(name, capacity=2):
            log = open(root / (name + ".log"), "wb")
            logs.append(log)
            jobs[name] = subprocess.Popen(
                [str(executable), str(root), name, str(capacity)],
                stdout=log, stderr=subprocess.STDOUT,
            )
            wait_for(lambda: (root / (name + ".ready")).exists() or jobs[name].poll() is not None)
            return jobs[name]

        def started(name):
            return (root / (name + ".started")).exists()

        def cancel(name):
            jobs[name].send_signal(signal.SIGTERM)
            code = jobs[name].wait(timeout=10)
            assert code == 130, (name, code, (root / (name + ".log")).read_text())

        try:
            start("a")
            start("b")
            wait_for(lambda: started("a") and started("b"))
            start("c")
            time.sleep(0.3)
            assert not started("c"), "Third process bypassed the two-slot limit"
            cancel("c")
            assert not started("c"), "Cancelled waiter executed its payload"

            start("d")
            time.sleep(0.3)
            assert not started("d")
            cancel("a")
            wait_for(lambda: started("d"))
            assert jobs["b"].poll() is None

            conflict = start("conflict", 3)
            assert conflict.wait(timeout=10) != 0
            assert not started("conflict"), "Conflicting capacity executed a payload"

            for name in ("b", "d"):
                (root / (name + ".release")).touch()
                assert jobs[name].wait(timeout=10) == 0
            start("e")
            wait_for(lambda: started("e"))
            (root / "e.release").touch()
            assert jobs["e"].wait(timeout=10) == 0
            print("PASS: two slots, third waiter, waiting/running cancellation, reuse, capacity conflict")
        finally:
            for job in jobs.values():
                if job.poll() is None:
                    job.kill()
                job.wait()
            for log in logs:
                log.close()


if __name__ == "__main__":
    main()
