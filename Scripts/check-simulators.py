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
                "--pool-directory", str(pool), "--maximum-concurrent-jobs", "2",
                "--simulator-runtime", runtime["identifier"], "--simulator-device-type", device["identifier"],
                *(["--fresh-simulator"] if fresh else []),
                "--environment", "TEST_RUNNER_PROBE_MODE=" + mode,
                "--environment", "DEVELOPER_DIR=" + selected_xcode,
                "--", "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never", "-jobs", "4",
            ], stdout=log, stderr=subprocess.STDOUT, env=child_environment)
            return jobs[name]

        def finish(name, succeeds=True):
            code = jobs[name].wait(timeout=600)
            assert (code == 0) == succeeds, (name, code, (root / (name + ".log")).read_text()[-3000:])

        def used_identifier(name):
            build_log, = (root / name / "output").glob("*/xcodebuild.log")
            match = re.search(r"platform=iOS Simulator,id=([0-9A-Fa-f-]{36})", build_log.read_text())
            assert match, (name, "No Simulator destination in xcodebuild log")
            return match[1].upper()

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

            start("reuse")
            finish("reuse")
            assert used_identifier("reuse") in owned
            assert devices() == baseline | owned, "Sequential job created another device"
            assert owned <= booted_devices(), "Sequential job shut down a pooled device"

            start("failure", "failure")
            finish("failure", succeeds=False)
            assert used_identifier("failure") in owned
            assert devices() == baseline | owned, "Failed test did not release its device for reuse"
            assert owned <= booted_devices(), "Failed test shut down a pooled device"

            cancelled = start("cancel", "wait")
            wait_for(lambda: "BuildProbe payload ready" in (root / "cancel.log").read_text())
            cancelled.send_signal(signal.SIGTERM)
            assert cancelled.wait(timeout=60) == 130
            cancelled_identifier = used_identifier("cancel")
            assert cancelled_identifier in owned
            retained = owned - {cancelled_identifier}
            assert devices() == baseline | retained, "Cancelled test did not retire its device"

            start("after-cancel")
            finish("after-cancel")
            assert used_identifier("after-cancel") in retained
            assert devices() == baseline | retained, "Cancellation left the pool unavailable"

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
