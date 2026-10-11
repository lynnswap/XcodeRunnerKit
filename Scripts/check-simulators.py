#!/usr/bin/env python3
"""Exercise job-owned Simulator lifecycle using the real CLI and a public fixture."""
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

        def start(name, mode="success"):
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
                "--pool-directory", str(root / "pool"), "--maximum-concurrent-jobs", "2",
                "--simulator-runtime", runtime["identifier"], "--simulator-device-type", device["identifier"],
                "--environment", "TEST_RUNNER_PROBE_MODE=" + mode,
                "--environment", "DEVELOPER_DIR=" + selected_xcode,
                "--", "-parallel-testing-enabled", "NO", "-jobs", "4",
            ], stdout=log, stderr=subprocess.STDOUT, env=child_environment)
            return jobs[name]

        try:
            start("a")
            start("b")
            wait_for(lambda: len(devices() - baseline) == 2)
            owned = devices() - baseline
            assert len(owned) == 2
            for name in ("a", "b"):
                code = jobs[name].wait(timeout=600)
                assert code == 0, (name, code, (root / (name + ".log")).read_text()[-3000:])
            assert devices() == baseline, "Successful jobs left devices behind"

            failed = start("failure", "failure")
            assert failed.wait(timeout=600) != 0
            assert devices() == baseline, "Failed test left a device behind"

            cancelled = start("cancel", "wait")
            wait_for(lambda: "BuildProbe payload ready" in (root / "cancel.log").read_text())
            cancelled.send_signal(signal.SIGTERM)
            assert cancelled.wait(timeout=60) == 130
            assert devices() == baseline, "Cancelled test left a device behind"
            print(json.dumps({"passed": True, "parallelDeviceIdentifiers": sorted(owned),
                              "runtime": runtime["identifier"], "deviceType": device["identifier"],
                              "failureCleanup": True, "cancellationCleanup": True}))
        finally:
            for job in jobs.values():
                if job.poll() is None:
                    job.send_signal(signal.SIGTERM)
                try:
                    job.wait(timeout=60)
                except subprocess.TimeoutExpired:
                    job.kill()
                    job.wait()
            for log in logs:
                log.close()


if __name__ == "__main__":
    main()
