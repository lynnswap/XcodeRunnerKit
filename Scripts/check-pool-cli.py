#!/usr/bin/env python3
"""Verify pool administration and the existing Xcode command interface."""
import argparse
import json
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time

REPO = Path(__file__).resolve().parents[1]
ACTIONS = ("build", "build-for-testing", "test", "test-without-building")


def wait_for(predicate, timeout=10):
    deadline = time.monotonic() + timeout
    while not predicate():
        if time.monotonic() >= deadline:
            raise AssertionError("Timed out waiting for a process transition")
        time.sleep(0.02)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("executable", type=Path)
    args = parser.parse_args()
    executable = str(args.executable.resolve())

    def interrupt(_number, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupt)

    def command(*values, success=True, timeout=10):
        job = subprocess.Popen([executable, *map(str, values)], stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True)
        try:
            stdout, stderr = job.communicate(timeout=timeout)
        except BaseException:
            if job.poll() is None:
                job.send_signal(signal.SIGTERM)
                try:
                    job.communicate(timeout=10)
                except subprocess.TimeoutExpired:
                    job.kill()
                    job.communicate()
            raise
        result = subprocess.CompletedProcess(job.args, job.returncode, stdout, stderr)
        assert (result.returncode == 0) == success, (values, result.returncode,
                                                    result.stdout, result.stderr)
        return result

    with tempfile.TemporaryDirectory(prefix="XcodeRunnerPoolCLI-") as temporary:
        root = Path(temporary)
        pool = root / "pool"

        def status():
            return json.loads(command("pool", "status", "--pool-directory", pool, "--json").stdout)

        def configure(capacity, success=True):
            return command("pool", "configure", "--pool-directory", pool,
                           "--maximum-concurrent-jobs", capacity, success=success)

        assert status() is None
        assert not pool.exists(), "Status initialized an unconfigured pool"
        assert "not configured" in command("pool", "status", "--pool-directory", pool).stdout
        configure(6)
        assert status() == {"maximumConcurrentJobs": 6, "activeJobCount": 0}

        probe = root / "pool-probe"
        subprocess.run([
            "xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
            str(REPO / "Sources/XcodeRunnerKit/HostExecutionPool.swift"),
            str(REPO / "Tests/Fixtures/ExecutionPoolProbe.swift"),
            "-o", str(probe),
        ], check=True)
        jobs = {}
        logs = []

        def start(name):
            output = open(root / (name + ".log"), "wb")
            logs.append(output)
            jobs[name] = subprocess.Popen([str(probe), str(root), name, "6"],
                                          stdout=output, stderr=subprocess.STDOUT)
            wait_for(lambda: (root / (name + ".ready")).exists() or jobs[name].poll() is not None)
            assert jobs[name].poll() is None, (root / (name + ".log")).read_text()

        def started(name):
            return (root / (name + ".started")).exists()

        def release(name):
            (root / (name + ".release")).touch()
            assert jobs[name].wait(timeout=10) == 0, (root / (name + ".log")).read_text()

        try:
            for index in range(6):
                start(f"active-{index}")
            wait_for(lambda: all(started(f"active-{index}") for index in range(6)))
            assert status() == {"maximumConcurrentJobs": 6, "activeJobCount": 6}
            start("waiter")
            configured = configure(4)
            assert "Maximum concurrent jobs: 4" in configured.stdout
            assert "Active jobs: 6" in configured.stdout
            assert status() == {"maximumConcurrentJobs": 4, "activeJobCount": 6}
            assert all(jobs[f"active-{index}"].poll() is None for index in range(6))
            assert not started("waiter"), "Shrinking the pool started a queued job"
            release("active-0")
            release("active-1")
            assert status() == {"maximumConcurrentJobs": 4, "activeJobCount": 4}
            assert not started("waiter"), "A queued job bypassed the reduced capacity"
            release("active-2")
            wait_for(lambda: started("waiter"))
            assert status() == {"maximumConcurrentJobs": 4, "activeJobCount": 4}
            saved = status()
            for value in ("0", "-1", "invalid"):
                configure(value, success=False)
                assert status() == saved
            for name in ("active-3", "active-4", "active-5", "waiter"):
                release(name)
            assert status() == {"maximumConcurrentJobs": 4, "activeJobCount": 0}
        finally:
            for job in jobs.values():
                if job.poll() is None:
                    job.send_signal(signal.SIGTERM)
                    try:
                        job.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        job.kill()
                job.wait()
            for log in logs:
                log.close()

        root_help = command("--help").stdout
        assert all(action in root_help for action in (*ACTIONS, "pool"))
        command("pool", "--help")
        command("pool", "status", "--help")
        command("pool", "configure", "--help")
        command("pool", "status", success=False)
        command("pool", "configure", "--maximum-concurrent-jobs", "4", success=False)
        for action in ACTIONS:
            help_text = command(action, "--help").stdout
            assert "--scheme" in help_text and "--compilation-cache" in help_text
            result = command(action, "--package", root / "Missing", "--scheme", "Fixture",
                             "--destination", "platform=macOS,arch=arm64",
                             "--output-directory", root / "Output",
                             "--developer-directory", "/Applications/Xcode.app/Contents/Developer",
                             "--derived-data", root / "DerivedData",
                             "--compilation-cache", root / "Cache", "--cache-diagnostics",
                             "--prefix-mapping", f"{root}=/fixture",
                             "--setting", "CLI_PROBE_SETTING=accepted",
                             "--environment", "CLI_PROBE_ENVIRONMENT=accepted",
                             "--pool-directory", pool, "--maximum-concurrent-jobs", "2",
                             "--simulator-runtime", "missing-device-type",
                             "--", "-parallel-testing-enabled", "NO", "-jobs", "2",
                             success=False)
            assert "Specify both --simulator-runtime and --simulator-device-type." in result.stderr

        package = root / "BuildProbe"
        shutil.copytree(REPO / "Tests/Fixtures/BuildProbe", package,
                        ignore=shutil.ignore_patterns(".build", ".swiftpm"))
        for source_option in ("--workspace", "--project"):
            result = command("test", source_option, package, "--package", package,
                             "--scheme", "BuildProbe", success=False)
            assert "Specify exactly one" in result.stderr
        for action in ("build-for-testing", "test-without-building", "build", "test"):
            result = command(action, "--package", package, "--scheme", "BuildProbe",
                             "--destination", "platform=macOS,arch=arm64",
                             "--derived-data", root / "FixtureDerivedData",
                             "--output-directory", root / "FixtureOutput",
                             "--pool-directory", pool, "--maximum-concurrent-jobs", "2",
                             "--setting", "CLI_PROBE_SETTING=accepted",
                             "--environment", "TEST_RUNNER_PROBE_MODE=success",
                             "--", "-parallel-testing-enabled", "NO", "-jobs", "2",
                             timeout=300)
            assert "Log: " in result.stdout and "Result bundle: " in result.stdout
            if action in ("test", "test-without-building"):
                assert "BuildProbe payload ready" in result.stdout
        print("PASS: CLI status/configure, live shrink, invalid input, command help, existing Xcode actions")


if __name__ == "__main__":
    main()
