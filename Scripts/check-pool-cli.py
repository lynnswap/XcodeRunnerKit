#!/usr/bin/env python3
"""Verify pool administration, admission priorities, and Xcode commands."""
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
from execution_pool_probe import build_execution_pool_probe

REPO = Path(__file__).resolve().parents[1]
ACTIONS = ("build", "build-for-testing", "test", "test-without-building")
# Steps wait for the state they need. This limit only reports a process that hangs.
HANG_LIMIT = 120


def expected_status(capacity, active, high=0, medium=0, low=0):
    return {"maximumConcurrentJobs": capacity, "activeJobCount": active,
            "waitingJobCounts": {"high": high, "medium": medium, "low": low}}


def wait_for(predicate, timeout=HANG_LIMIT):
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

    def command(*values, success=True, timeout=HANG_LIMIT, env=None):
        job = subprocess.Popen([executable, *map(str, values)], stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True, env=env)
        try:
            stdout, stderr = job.communicate(timeout=timeout)
        except BaseException:
            if job.poll() is None:
                job.send_signal(signal.SIGTERM)
                try:
                    job.communicate(timeout=HANG_LIMIT)
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
        assert status() == expected_status(6, 0)
        assert "Waiting jobs: 0 (high: 0, medium: 0, low: 0)" in command(
            "pool", "status", "--pool-directory", pool).stdout

        probe = root / "pool-probe"
        build_execution_pool_probe(probe)
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
            assert jobs[name].wait(timeout=HANG_LIMIT) == 0, (root / (name + ".log")).read_text()

        try:
            for index in range(6):
                start(f"active-{index}")
            wait_for(lambda: all(started(f"active-{index}") for index in range(6)))
            assert status() == expected_status(6, 6)
            start("waiter")
            wait_for(lambda: status() == expected_status(6, 6, medium=1))
            configured = configure(4)
            assert "Maximum concurrent jobs: 4" in configured.stdout
            assert "Active jobs: 6" in configured.stdout
            assert "Waiting jobs: 1 (high: 0, medium: 1, low: 0)" in configured.stdout
            assert status() == expected_status(4, 6, medium=1)
            assert all(jobs[f"active-{index}"].poll() is None for index in range(6))
            assert not started("waiter"), "Shrinking the pool started a queued job"
            release("active-0")
            release("active-1")
            assert status() == expected_status(4, 4, medium=1)
            assert not started("waiter"), "A queued job bypassed the reduced capacity"
            release("active-2")
            wait_for(lambda: started("waiter"))
            assert status() == expected_status(4, 4)
            saved = status()
            # Only "0" reaches the positive-limit check; ArgumentParser rejects "-1" as a missing value.
            for value in ("0", "-1", "invalid"):
                configure(value, success=False)
                assert status() == saved
            for name in ("active-3", "active-4", "active-5", "waiter"):
                release(name)
            assert status() == expected_status(4, 0)

            package = root / "BuildProbe"
            shutil.copytree(REPO / "Tests/Fixtures/BuildProbe", package,
                            ignore=shutil.ignore_patterns(".build", ".swiftpm"))
            compiler = root / "gated-clang"
            compiler.write_text('''#!/bin/bash
set -euo pipefail
touch "$CLI_PRIORITY_GATE.started"
while [[ ! -e "$CLI_PRIORITY_GATE.release" ]]; do sleep 0.02; done
exec "$(xcrun --find clang)" "$@"
''')
            compiler.chmod(0o755)
            configure(1)
            start("priority-blocker")
            wait_for(lambda: started("priority-blocker"))
            waiting_counts = {"high": 0, "medium": 0, "low": 0}
            for priority in ("low", "medium", "high"):
                output = open(root / (priority + ".log"), "wb")
                logs.append(output)
                # Omit the medium flag to verify the default through actual admission.
                priority_arguments = [] if priority == "medium" else ["--priority", priority]
                jobs[priority] = subprocess.Popen([
                    executable, "build", "--package", str(package), "--scheme", "BuildProbe",
                    "--destination", "platform=macOS,arch=arm64",
                    "--output-directory", str(root / (priority + "-output")),
                    "--pool-directory", str(pool), "--maximum-concurrent-jobs", "2",
                    "--setting", f"CC={compiler}",
                    "--environment", f"CLI_PRIORITY_GATE={root / priority}",
                    *priority_arguments, "--", "-jobs", "2",
                ], stdout=output, stderr=subprocess.STDOUT)
                waiting_counts[priority] += 1
                wait_for(lambda: status() == expected_status(1, 1, **waiting_counts))
                assert jobs[priority].poll() is None, (root / (priority + ".log")).read_text()
            waiting_text = command("pool", "status", "--pool-directory", pool).stdout
            assert "Waiting jobs: 3 (high: 1, medium: 1, low: 1)" in waiting_text
            assert all(not (root / (value + "-output")).exists() for value in ("high", "medium", "low"))
            release("priority-blocker")
            for priority, later in (("high", ("medium", "low")), ("medium", ("low",)), ("low", ())):
                wait_for(lambda: (root / (priority + ".started")).exists(), timeout=300)
                assert all(not (root / (value + "-output")).exists() for value in later), "Wrong CLI admission order"
                (root / (priority + ".release")).touch()
                assert jobs[priority].wait(timeout=300) == 0, (root / (priority + ".log")).read_text()
            assert status() == expected_status(1, 0)
        finally:
            for job in jobs.values():
                if job.poll() is None:
                    job.send_signal(signal.SIGTERM)
                    try:
                        job.wait(timeout=HANG_LIMIT)
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
        # Without --pool-directory, pool commands use the installed host's pool under HOME.
        host_home = root / "Host home"
        host_environment = {key: value for key, value in os.environ.items()
                            if not key.startswith("XCODE_RUNNER_HOST_")}
        host_environment["HOME"] = str(host_home)
        assert "not configured" in command("pool", "status", env=host_environment).stdout
        configured = command("pool", "configure", "--maximum-concurrent-jobs", "4", "--json", env=host_environment)
        assert json.loads(configured.stdout) == expected_status(4, 0)
        assert (host_home / "Library/Application Support/XcodeRunnerKit/Pool/capacity").read_text() == "4"
        assert json.loads(command("pool", "status", "--json", env=host_environment).stdout) == expected_status(4, 0)
        result = command("build", "--package", root / "Missing", "--scheme", "Fixture",
                         "--pool-directory", root / "Unconfigured pool", success=False)
        assert "has no maximum concurrent job count" in result.stderr, result.stderr
        # An invalid initial limit fails the same way whether or not the pool already has a saved limit.
        for directory in (root / "Unconfigured pool", pool):
            result = command("build", "--package", root / "Missing", "--scheme", "Fixture",
                             "--pool-directory", directory, "--maximum-concurrent-jobs", "0", success=False)
            assert "must be positive" in result.stderr, result.stderr
        assert not (root / "Unconfigured pool/capacity").exists()
        for action in ACTIONS:
            command(action, "--help")
        # All actions share BuildOptions and run for real below, so one action checks the shared help and rejections.
        help_text = command("build", "--help").stdout
        assert all(option in help_text for option in ("--scheme", "--compilation-cache", "--priority"))
        assert "GitHub dispatch is unaffected" in " ".join(help_text.split())
        # Priorities are case-sensitive, and an explicit empty value does not fall back to medium.
        for invalid in ("HIGH", ""):
            result = command("build", "--package", root / "Missing", "--scheme", "Fixture",
                             "--priority", invalid, success=False)
            assert "Expected high, medium, or low for --priority" in result.stderr
        result = command("build", "--package", root / "Missing", "--scheme", "Fixture",
                         "--simulator-runtime", "runtime", success=False)
        assert "Specify both --simulator-runtime and --simulator-device-type." in result.stderr
        result = command("build", "--package", root / "Missing", "--scheme", "Fixture",
                         "--destination", "platform=macOS,arch=arm64",
                         "--simulator-runtime", "runtime", "--simulator-device-type", "device",
                         success=False)
        assert "Specify either --destination or the Simulator options, not both." in result.stderr

        for source_option in ("--workspace", "--project"):
            result = command("test", source_option, package, "--package", package,
                             "--scheme", "BuildProbe", success=False)
            assert "Specify exactly one" in result.stderr
        for action, priority in (("build-for-testing", "high"), ("test-without-building", "low"),
                                 ("build", "medium"), ("test", None)):
            priority_arguments = ["--priority", priority] if priority else []
            # An existing pool keeps its saved limit, so the test action omits it.
            pool_arguments = {"build": [], "test": ["--pool-directory", pool]}.get(
                action, ["--pool-directory", pool, "--maximum-concurrent-jobs", "2"])
            result = command(action, "--package", package, "--scheme", "BuildProbe",
                             "--destination", "platform=macOS,arch=arm64",
                             "--derived-data", root / "FixtureDerivedData",
                             "--output-directory", root / "FixtureOutput",
                             *pool_arguments,
                             "--setting", "CLI_PROBE_SETTING=accepted",
                             "--environment", "TEST_RUNNER_PROBE_MODE=success",
                             *priority_arguments,
                             "--", "-parallel-testing-enabled", "NO", "-jobs", "2",
                             timeout=300)
            assert "Log: " in result.stdout and "Result bundle: " in result.stdout
            if action in ("test", "test-without-building"):
                assert "BuildProbe payload ready" in result.stdout

        # xcrun and xcodebuild follow DEVELOPER_DIR, so a fake Xcode can fail Simulator deletion.
        fake_tools = root / "FakeXcode.app/Contents/Developer/usr/bin"
        fake_tools.mkdir(parents=True)
        for name, body in {
            "xcrun": 'tool="$1"; shift; exec "$(dirname "$0")/$tool" "$@"',
            "xcodebuild": "echo fake-test-failure; exit 65",
            "simctl": '''device="$(dirname "$0")/device-present"
case "$1" in
create) touch "$device"; echo 11111111-2222-3333-4444-555555555555;;
list)
    if [ -e "$device" ]; then
        echo '{"devices":{"runtime":[{"udid":"11111111-2222-3333-4444-555555555555","name":"fixture","isAvailable":true}]}}'
    else echo '{"devices":{}}'; fi;;
delete) echo fake-deletion-failed >&2; exit 9;;
esac''',
        }.items():
            (fake_tools / name).write_text("#!/bin/sh\n" + body + "\n")
            (fake_tools / name).chmod(0o755)
        result = command("test", "--package", package, "--scheme", "BuildProbe",
                         "--simulator-runtime", "runtime", "--simulator-device-type", "device",
                         "--fresh-simulator", "--developer-directory", fake_tools.parents[1],
                         "--pool-directory", root / "CleanupFailurePool", "--maximum-concurrent-jobs", "1",
                         "--output-directory", root / "CleanupFailureOutput", success=False)
        assert result.returncode == 65, (result.returncode, result.stdout, result.stderr)
        assert "Log: " in result.stderr and "fake-deletion-failed" in result.stderr, result.stderr
        print("PASS: CLI status/configure, live shrink, priority admission and counts, invalid input, existing Xcode actions, host pool defaults, cleanup failure exit status")


if __name__ == "__main__":
    main()
