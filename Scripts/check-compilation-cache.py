#!/usr/bin/env python3
"""Verify compilation-cache reuse across relocated checkouts and DerivedData."""
import argparse
import concurrent.futures
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

REPO = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("executable", type=Path)
args = parser.parse_args()


def main():
    with tempfile.TemporaryDirectory(prefix="XcodeRunner Cache ") as temporary:
        root = Path(temporary)

        def run(name, changed=False):
            package = root / name / "BuildProbe"
            shutil.copytree(REPO / "Tests/Fixtures/BuildProbe", package,
                            ignore=shutil.ignore_patterns(".build", ".swiftpm"))
            if changed:
                source = package / "Sources/CProbe/CProbe.c"
                source.write_text(source.read_text().replace("value * 2", "value * 3"))
                test = package / "Tests/BuildProbeTests/BuildProbeTests.swift"
                test.write_text(test.read_text().replace("doubled(4) == 8", "doubled(4) == 12"))
            output = root / name / "output"
            log = root / (name + ".log")
            start = time.monotonic()
            with log.open("w") as handle:
                result = subprocess.run([
                    str(args.executable.resolve()), "test" if changed else "build-for-testing",
                    "--package", str(package), "--scheme", "BuildProbe",
                    "--destination", "platform=macOS,arch=arm64",
                    "--output-directory", str(output),
                    "--pool-directory", str(root / "pool"), "--maximum-concurrent-jobs", "2",
                    "--compilation-cache", str(root / "cas"), "--cache-diagnostics",
                    "--prefix-mapping", str((package / "Sources").resolve()) + "=/^xcodeRunnerFixtureSources",
                    "--", "-parallel-testing-enabled", "NO", "-jobs", "4",
                ], stdout=handle, stderr=subprocess.STDOUT, timeout=600)
            text = log.read_text().lower()
            errors = [line for line in log.read_text().splitlines() if "error:" in line.lower()]
            assert result.returncode == 0, (name, errors, log.read_text()[-2000:])
            # Xcode may print a remark more than once: these are note counts, not task counts.
            return {"name": name, "seconds": round(time.monotonic() - start, 2),
                    "hitNotes": text.count("replay cache hit"),
                    "missNotes": text.count("replay cache miss")}

        cold = run("cold")
        assert cold["missNotes"] > 0, cold
        relocated = run("relocated")
        assert relocated["hitNotes"] > 0 and relocated["missNotes"] == 0, relocated
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            parallel = list(pool.map(run, ["parallel-a", "parallel-b"]))
        assert all(r["hitNotes"] > 0 and r["missNotes"] == 0 for r in parallel), parallel
        changed = run("changed", changed=True)
        assert changed["missNotes"] > 0, "Changed compiler input incorrectly produced only cache hits"
        print(json.dumps({"passed": True, "runs": [cold, relocated, *parallel, changed],
                          "fixture": "Swift, Clang, SDK Observation macro; stable BuildProbe package identity"}))


if __name__ == "__main__":
    main()
