#!/usr/bin/env python3
"""Exercise pooled and fresh Simulator lifecycle using the real CLI and a public fixture."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import tempfile
import time

REPO = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("executable", type=Path)
parser.add_argument("--runtime", default="com.apple.CoreSimulator.SimRuntime.iOS-27-0")
args = parser.parse_args()


def simctl(*arguments):
    return json.loads(subprocess.check_output(["xcrun", "simctl", "list", *arguments, "--json"]))


def devices():
    return {d["udid"] for values in simctl("devices")["devices"].values() for d in values}


def booted_devices():
    return {d["udid"] for values in simctl("devices")["devices"].values()
            for d in values if d["state"] == "Booted"}


def wait_for(predicate, timeout=300):
    deadline = time.monotonic() + timeout
    while not predicate():
        if time.monotonic() >= deadline:
            raise AssertionError("Timed out waiting for a Simulator transition")
        time.sleep(0.2)


def main():
    runtime = next(r for r in simctl("runtimes")["runtimes"] if r["identifier"] == args.runtime and r["isAvailable"])
    device = next(d for d in runtime["supportedDeviceTypes"] if d["productFamily"] == "iPhone")
    baseline = devices()
    with tempfile.TemporaryDirectory(prefix="XcodeRunnerSimulator-") as temporary:
        root = Path(temporary)
        jobs = {}
        logs = []

        pool = root / "pool"
        subprocess.run([
            str(args.executable.resolve()), "pool", "configure",
            "--pool-directory", str(pool), "--maximum-concurrent-jobs", "2",
            "--simulator-retention", "forever",
        ], check=True, capture_output=True)

        def clean_pool():
            subprocess.run([
                str(args.executable.resolve()), "pool", "clean-simulators",
                "--pool-directory", str(pool),
                "--developer-directory", os.environ["DEVELOPER_DIR"],
            ], check=True)

        def start(name, mode="success", fresh=False):
            package = root / name / "BuildProbe"
            shutil.copytree(REPO / "Tests/Fixtures/BuildProbe", package, ignore=shutil.ignore_patterns(".build", ".swiftpm"))
            output = root / name / "output"
            log = open(root / (name + ".log"), "wb")
            logs.append(log)
            child_environment = dict(os.environ)
            selected_xcode = child_environment.pop("DEVELOPER_DIR")
            jobs[name] = subprocess.Popen([
                str(args.executable.resolve()), "test", "--package", str(package),
                "--scheme", "BuildProbe", "--output-directory", str(output),
                "--pool-directory", str(pool),
                "--simulator-runtime", runtime["identifier"], "--simulator-device-type", device["identifier"],
                *(["--fresh-simulator"] if fresh else []),
                "--environment", "TEST_RUNNER_PROBE_MODE=" + mode,
                "--environment", "DEVELOPER_DIR=" + selected_xcode,
                "--", "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never", "-jobs", "4",
            ], stdout=log, stderr=subprocess.STDOUT, env=child_environment)
            return jobs[name]

        def diagnose_timeout(name):
            print(f"Simulator lifecycle timeout: {name}; pool={pool}", flush=True)
            for job_name, job in jobs.items():
                print(f"Job {job_name}: pid={job.pid}, returncode={job.poll()}", flush=True)
                log_path = root / (job_name + ".log")
                print(f"Last 8000 bytes of {log_path}:", flush=True)
                print(log_path.read_bytes()[-8000:].decode(errors="replace"), flush=True)

            try:
                holders = subprocess.run(
                    ["/usr/sbin/lsof", "-nP", "+D", str(pool)],
                    capture_output=True, text=True, timeout=20,
                )
                print("Pool file descriptors (lsof -nP +D):", flush=True)
                print(holders.stdout, flush=True)
                if holders.stderr:
                    print(holders.stderr, flush=True)
                identifiers = {job.pid for job in jobs.values()}
                identifiers.update(int(fields[1]) for line in holders.stdout.splitlines()
                                   if len(fields := line.split()) > 1 and fields[1].isdigit())
                context = subprocess.run(
                    ["/bin/ps", "-axo", "pid=,ppid=,pgid=,state=,etime=,comm="],
                    check=True, capture_output=True, text=True, timeout=10,
                )
                processes = [(int(fields[0]), int(fields[1]), line)
                             for line in context.stdout.splitlines()
                             if len(fields := line.split(None, 5)) == 6]
                while True:
                    descendants = {pid for pid, parent, _ in processes if parent in identifiers}
                    if descendants <= identifiers:
                        break
                    identifiers.update(descendants)
                print("Job and pool-holder processes (PID PPID PGID STATE ELAPSED COMMAND):", flush=True)
                for pid, _, line in processes:
                    if pid in identifiers:
                        print(line, flush=True)
            except (OSError, subprocess.SubprocessError) as error:
                print(f"Timeout process diagnostics failed: {error}", flush=True)

        def finish(name, succeeds=True):
            try:
                # Cold compilation and boots before testing and cleanup share this budget.
                code = jobs[name].wait(timeout=900)
            except subprocess.TimeoutExpired:
                diagnose_timeout(name)
                raise
            assert (code == 0) == succeeds, (name, code, (root / (name + ".log")).read_text()[-3000:])

        def used_identifier(name):
            build_log, = (root / name / "output").glob("*/xcodebuild.log")
            match = re.search(r"-destination \"?id=([0-9A-Fa-f-]{36})", build_log.read_text())
            assert match, (name, "No Simulator destination in xcodebuild log")
            return match[1].upper()

        def payload_started(name):
            # A compiler diagnostic can quote the marker's source line, which has no process identifier.
            return re.search(r"BuildProbe payload ready pid=\d+", (root / (name + ".log")).read_text(errors="replace"))

        def failed_tests(name):
            bundle, = (root / name / "output").glob("*/Results.xcresult")
            summary = json.loads(subprocess.check_output(
                ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(bundle)]))
            return [failure["testName"] for failure in summary["testFailures"]]

        try:
            start("a")
            start("b")
            wait_for(lambda: len(devices() - baseline) == 2)
            owned = devices() - baseline
            assert len(owned) == 2
            for name in ("a", "b"):
                finish(name)
            assert {used_identifier("a"), used_identifier("b")} == owned
            assert devices() == baseline | owned, "Successful jobs did not retain their devices"
            assert owned <= booted_devices(), "Idle pooled devices did not remain booted"

            cancelled = start("cancel", "wait")
            wait_for(lambda: payload_started("cancel"))
            cancelled.send_signal(signal.SIGTERM)
            assert cancelled.wait(timeout=60) == 130
            cancelled_identifier = used_identifier("cancel")
            assert cancelled_identifier in owned
            retained = owned - {cancelled_identifier}
            assert devices() == baseline | retained, "Cancelled test did not retire its device"

            # Only one pooled device remains, so the next pooled jobs must reuse it instead of creating another.
            start("failure", "failure")
            finish("failure", succeeds=False)
            # A build failure also exits nonzero, so require the payload to start and fail its intended expectation.
            assert payload_started("failure"), (root / "failure.log").read_text(errors="replace")[-3000:]
            failures = failed_tests("failure")
            assert failures == ["controlledPayload()"], failures
            assert used_identifier("failure") in retained, "Cancellation left the pool unavailable"
            assert devices() == baseline | retained, "Failed test did not release its device for reuse"
            assert retained <= booted_devices(), "Failed test shut down a pooled device"

            start("reuse")
            finish("reuse")
            assert used_identifier("reuse") == used_identifier("failure"), "Next job did not reuse the failed test's device"
            assert devices() == baseline | retained, "Sequential job created another device"
            assert retained <= booted_devices(), "Sequential job shut down a pooled device"

            start("fresh", fresh=True)
            finish("fresh")
            assert used_identifier("fresh") not in retained
            assert devices() == baseline | retained, "Fresh device survived its operation"

            clean_pool()
            assert devices() == baseline, "Pool cleanup left idle devices behind"
            print(json.dumps({"passed": True, "parallelDeviceIdentifiers": sorted(owned),
                              "runtime": runtime["identifier"], "deviceType": device["identifier"],
                              "sequentialReuse": True, "failureReuse": True,
                              "cancellationRetirement": True, "freshCleanup": True}))
        finally:
            for job in jobs.values():
                if job.poll() is None:
                    job.send_signal(signal.SIGTERM)
                try:
                    job.wait(timeout=60)
                except subprocess.TimeoutExpired:
                    job.kill()
                    job.wait()
            try:
                clean_pool()
            finally:
                for log in logs:
                    log.close()


if __name__ == "__main__":
    main()
