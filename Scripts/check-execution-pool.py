#!/usr/bin/env python3
"""Verify production pool locks using separate operating-system processes."""
from pathlib import Path
import json
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

        def start(name, capacity=2, job_root=root, priority="medium"):
            roots[name] = job_root
            log = open(root / (name + ".log"), "wb")
            logs.append(log)
            jobs[name] = subprocess.Popen(
                [str(executable), str(job_root), name, str(capacity), priority], stdout=log, stderr=subprocess.STDOUT
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

        def status(job_root=root):
            result = subprocess.run([str(executable), str(job_root), "status"], check=True, capture_output=True)
            return json.loads(result.stdout)

        def update(capacity, job_root=root):
            result = subprocess.run(
                [str(executable), str(job_root), "update", str(capacity)], check=True, capture_output=True
            )
            return json.loads(result.stdout)

        def expected_status(capacity, active, high=0, medium=0, low=0):
            return {
                "maximumConcurrentJobs": capacity, "activeJobCount": active,
                "waitingJobCounts": {"high": high, "medium": medium, "low": low},
            }

        def assert_waiting(name):
            # A bounded observation window checks that no payload starts without a slot release.
            end = time.monotonic() + 0.3
            while time.monotonic() < end:
                assert not started(name), f"Waiting process {name} executed its payload"
                assert jobs[name].poll() is None, f"Waiting process {name} exited"
                time.sleep(0.02)

        try:
            assert status() is None
            assert not (root / "pool").exists(), "Reading status initialized an empty pool"
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
            assert status() == expected_status(2, 2)

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
            assert status(larger) == expected_status(4, 4)
            for name in ("large-b", "large-c", "large-d", "large-waiter"):
                release(name)

            shrink = root / "shrink"
            shrink.mkdir()
            for index in range(6):
                name = f"shrink-{index}"
                start(name, 6, shrink)
                wait_for(lambda name=name: started(name))
            start("shrink-waiter", 6, shrink)
            assert_waiting("shrink-waiter")
            coordinator_inode = (shrink / "pool/pool.lock").stat().st_ino
            assert update(4, shrink) == expected_status(4, 6, medium=1)
            assert (shrink / "pool/pool.lock").stat().st_ino == coordinator_inode
            assert all(jobs[f"shrink-{index}"].poll() is None for index in range(6))
            release("shrink-0")
            assert status(shrink) == expected_status(4, 5, medium=1)
            assert_waiting("shrink-waiter")
            release("shrink-1")
            assert status(shrink) == expected_status(4, 4, medium=1)
            assert_waiting("shrink-waiter")
            release("shrink-2")
            wait_for(lambda: started("shrink-waiter"))
            assert status(shrink) == expected_status(4, 4)
            assert all(jobs[f"shrink-{index}"].poll() is None for index in (3, 4, 5))
            for name in ("shrink-3", "shrink-4", "shrink-5", "shrink-waiter"):
                release(name)

            grow = root / "grow"
            grow.mkdir()
            for name in ("grow-a", "grow-b"):
                start(name, 2, grow)
                wait_for(lambda name=name: started(name))
            start("grow-c", 2, grow)
            assert_waiting("grow-c")
            assert update(4, grow)["maximumConcurrentJobs"] == 4
            wait_for(lambda: started("grow-c"))
            start("grow-d", 2, grow)
            wait_for(lambda: started("grow-d"))
            assert status(grow) == expected_status(4, 4)
            start("grow-cancelled", 2, grow)
            assert_waiting("grow-cancelled")
            cancel("grow-cancelled")
            assert not started("grow-cancelled")
            start("grow-after-exit", 2, grow)
            assert_waiting("grow-after-exit")
            jobs["grow-a"].kill()
            assert jobs["grow-a"].wait(timeout=10) == -signal.SIGKILL
            wait_for(lambda: started("grow-after-exit"))
            assert status(grow) == expected_status(4, 4)
            for name in ("grow-b", "grow-c", "grow-d", "grow-after-exit"):
                release(name)

            ordered = root / "ordered"
            ordered.mkdir()
            start("priority-running", 1, ordered, priority="low")
            wait_for(lambda: started("priority-running"))
            priorities = (
                ("low-first", "low"), ("medium-first", "medium"), ("low-second", "low"),
                ("high-first", "high"), ("high-second", "high"),
            )
            counts = {"high": 0, "medium": 0, "low": 0}
            for name, priority in priorities:
                start(name, 1, ordered, priority=priority)
                counts[priority] += 1
                wait_for(lambda: status(ordered)["waitingJobCounts"] == counts)
                assert not started(name)
            assert status(ordered) == expected_status(1, 1, high=2, medium=1, low=2)
            assert jobs["priority-running"].poll() is None, "A high priority preempted an active operation"
            previous = "priority-running"
            execution_order = ("high-first", "high-second", "medium-first", "low-first", "low-second")
            for index, name in enumerate(execution_order):
                release(previous)
                wait_for(lambda name=name: started(name))
                assert all(not started(pending) for pending in execution_order[index + 1:])
                previous = name
            release(previous)
            assert status(ordered) == expected_status(1, 0)
            assert not list((ordered / "pool").glob("waiter-*.lock")), "Finished queue records were retained"

            abandoned = root / "abandoned"
            abandoned.mkdir()
            start("abandoned-running", 1, abandoned)
            wait_for(lambda: started("abandoned-running"))
            start("surviving-low", 1, abandoned, priority="low")
            wait_for(lambda: status(abandoned)["waitingJobCounts"]["low"] == 1)
            start("cancelled-high", 1, abandoned, priority="high")
            wait_for(lambda: status(abandoned)["waitingJobCounts"]["high"] == 1)
            cancel("cancelled-high")
            assert status(abandoned) == expected_status(1, 1, low=1)
            start("killed-high", 1, abandoned, priority="high")
            wait_for(lambda: status(abandoned)["waitingJobCounts"]["high"] == 1)
            jobs["killed-high"].kill()
            assert jobs["killed-high"].wait(timeout=10) == -signal.SIGKILL
            assert status(abandoned) == expected_status(1, 1, low=1)
            assert not started("cancelled-high") and not started("killed-high")
            release("abandoned-running")
            wait_for(lambda: started("surviving-low"))
            release("surviving-low")
            assert not list((abandoned / "pool").glob("waiter-*.lock")), "Dead queue records blocked cleanup"

            resized_priority = root / "resized-priority"
            resized_priority.mkdir()
            for name in ("resize-running-a", "resize-running-b"):
                start(name, 2, resized_priority, priority="low")
                wait_for(lambda name=name: started(name))
            start("resize-low", 2, resized_priority, priority="low")
            wait_for(lambda: status(resized_priority)["waitingJobCounts"]["low"] == 1)
            start("resize-high", 2, resized_priority, priority="high")
            wait_for(lambda: status(resized_priority)["waitingJobCounts"]["high"] == 1)
            assert update(1, resized_priority) == expected_status(1, 2, high=1, low=1)
            release("resize-running-a")
            assert_waiting("resize-high")
            release("resize-running-b")
            wait_for(lambda: started("resize-high"))
            assert_waiting("resize-low")
            update(2, resized_priority)
            wait_for(lambda: started("resize-low"))
            assert status(resized_priority) == expected_status(2, 2)
            for name in ("resize-high", "resize-low"):
                release(name)

            physical = root / "physical"
            (physical / "pool").mkdir(parents=True)
            alias = root / "alias"
            alias.mkdir()
            (alias / "pool").symlink_to(physical / "pool", target_is_directory=True)
            assert status(alias) is None
            assert not list((physical / "pool").iterdir()), "Reading an unconfigured alias initialized its target"
            assert update(2, physical) == expected_status(2, 0)
            assert status(alias) == status(physical)
            start("alias-a", 4, alias)
            wait_for(lambda: started("alias-a"))
            start("physical-b", 4, physical)
            wait_for(lambda: started("physical-b"))
            start("alias-waiter", 4, alias)
            assert_waiting("alias-waiter")
            assert update(1, alias) == expected_status(1, 2, medium=1)
            release("alias-a")
            assert_waiting("alias-waiter")
            release("physical-b")
            wait_for(lambda: started("alias-waiter"))
            assert status(alias) == status(physical) == expected_status(1, 1)
            release("alias-waiter")

            unconfigured = root / "unconfigured"
            (unconfigured / "pool").mkdir(parents=True)
            (unconfigured / "pool/pool.lock").touch()
            assert status(unconfigured) is None
            assert not (unconfigured / "pool/capacity").exists()
            assert update(3, unconfigured) == expected_status(3, 0)
            assert (unconfigured / "pool/capacity").read_text() == "3"
            for capacity in (0, -1):
                result = subprocess.run(
                    [str(executable), str(unconfigured), "update", str(capacity)], capture_output=True
                )
                assert result.returncode != 0
                assert "invalidCapacity" in result.stderr.decode()
                assert status(unconfigured)["maximumConcurrentJobs"] == 3

            unreadable = unconfigured / "pool/capacity"
            unreadable.chmod(0)
            try:
                result = subprocess.run([str(executable), str(unconfigured), "status"], capture_output=True)
                assert result.returncode != 0, "A saved-capacity read failure returned an empty status"
                job = start("unreadable-capacity", 4, unconfigured)
                assert job.wait(timeout=10) != 0
                assert not started("unreadable-capacity"), "A capacity read failure executed a payload"
            finally:
                unreadable.chmod(0o600)
            pool_directory = unconfigured / "pool"
            pool_directory.chmod(0o500)
            try:
                result = subprocess.run([str(executable), str(unconfigured), "update", "5"], capture_output=True)
                assert result.returncode != 0, "A saved-capacity write failure returned success"
                job = start("unwritable-queue", 3, unconfigured, priority="high")
                assert job.wait(timeout=10) != 0
                assert not started("unwritable-queue"), "A waiting-record write failure executed a payload"
            finally:
                pool_directory.chmod(0o700)
            assert status(unconfigured) == expected_status(3, 0)

            coordinator = unconfigured / "pool/pool.lock"
            coordinator.chmod(0)
            try:
                result = subprocess.run([str(executable), str(unconfigured), "status"], capture_output=True)
                assert result.returncode != 0, "A coordinator open failure returned an empty status"
            finally:
                coordinator.chmod(0o600)

            (unconfigured / "pool/capacity").write_text("")
            result = subprocess.run([str(executable), str(unconfigured), "status"], capture_output=True)
            assert result.returncode != 0
            assert "invalidStoredCapacity" in result.stderr.decode()

            for index, value in enumerate(("0", "invalid")):
                invalid = root / f"invalid-{index}"
                (invalid / "pool").mkdir(parents=True)
                (invalid / "pool/capacity").write_text(value)
                name = f"invalid-{index}"
                job = start(name, 2, invalid)
                assert job.wait(timeout=10) != 0
                assert not started(name), "Invalid saved capacity executed a payload"
                assert "invalidStoredCapacity" in (root / (name + ".log")).read_text()

            print("PASS: stored capacities, differing callers, live shrink/grow, priorities, same-priority FIFO, queued counts, cancellation, process exit, invalid configuration, I/O failures")
        finally:
            for job in jobs.values():
                if job.poll() is None:
                    job.kill()
                job.wait()
            for log in logs:
                log.close()


if __name__ == "__main__":
    main()
