#!/usr/bin/env python3
"""Verify production pool locks using separate operating-system processes."""
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
        roots = {}
        logs = []

        def start(name, capacity=2, job_root=root):
            roots[name] = job_root
            log = open(root / (name + ".log"), "wb")
            logs.append(log)
            jobs[name] = subprocess.Popen(
                [str(executable), str(job_root), name, str(capacity)],
                stdout=log, stderr=subprocess.STDOUT,
            )
            wait_for(lambda: (job_root / (name + ".ready")).exists() or jobs[name].poll() is not None)
            return jobs[name]

        def started(name):
            return (roots[name] / (name + ".started")).exists()

        def release(name):
            (roots[name] / (name + ".release")).touch()
            assert jobs[name].wait(timeout=10) == 0, (name, (root / (name + ".log")).read_text())

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

            start("overflow", 4)
            time.sleep(0.3)
            assert jobs["overflow"].poll() is None, "Larger caller capacity was rejected"
            assert not started("overflow"), "Larger caller capacity bypassed the two-slot pool"
            release("b")
            wait_for(lambda: started("overflow"))
            assert (root / "pool/capacity.lock").read_text() == "2"

            for name in ("overflow", "d"):
                release(name)
            start("e")
            wait_for(lambda: started("e"))
            release("e")

            larger = root / "larger"
            larger.mkdir()
            start("large-a", 4, larger)
            wait_for(lambda: started("large-a"))
            for name in ("large-b", "large-c", "large-d"):
                start(name, 2, larger)
            wait_for(lambda: all(started(name) for name in ("large-b", "large-c", "large-d")))
            start("large-waiter", 2, larger)
            time.sleep(0.3)
            assert jobs["large-waiter"].poll() is None
            assert not started("large-waiter"), "Fifth process bypassed the four-slot pool"
            release("large-a")
            wait_for(lambda: started("large-waiter"))
            assert (larger / "pool/capacity.lock").read_text() == "4"
            for name in ("large-b", "large-c", "large-d", "large-waiter"):
                release(name)

            for index, value in enumerate(("0", "invalid")):
                invalid = root / f"invalid-{index}"
                (invalid / "pool").mkdir(parents=True)
                (invalid / "pool/capacity.lock").write_text(value)
                name = f"invalid-{index}"
                job = start(name, 2, invalid)
                assert job.wait(timeout=10) != 0
                assert not started(name), "Invalid saved capacity executed a payload"
                assert "invalidStoredCapacity" in (root / (name + ".log")).read_text()

            print("PASS: stored capacities 2/4, differing callers 4/2, queueing, cancellation, reuse, invalid configuration")
        finally:
            for job in jobs.values():
                if job.poll() is None:
                    job.kill()
                job.wait()
            for log in logs:
                log.close()


if __name__ == "__main__":
    main()
