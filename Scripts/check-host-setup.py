#!/usr/bin/env python3
"""Check external cache setup and symlink cleanup without a GUI service."""
import os
from pathlib import Path
import subprocess
import tempfile

scripts = Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix="XcodeRunnerKit host setup ") as temporary:
    root = Path(temporary)
    home = root / "home"
    home.mkdir()
    tools = root / "tools"
    tools.mkdir()
    launchctl = tools / "launchctl"
    launchctl.write_text('#!/bin/bash\n[[ "$1" != print ]]\n')
    launchctl.chmod(0o755)
    environment = {**os.environ, "HOME": str(home), "PATH": str(tools) + os.pathsep + os.environ["PATH"]}
    executable = root / "executable"
    executable.write_text("test executable")
    host = root / "Host"
    cache = root / "External disk" / "Cache"
    command = ["bash", str(scripts / "install-host-tools.sh"), str(executable), "test-source", str(host), str(cache)]
    subprocess.run(command, env=environment, check=True, capture_output=True)
    assert (host / "CompilationCache").is_symlink()
    assert (host / "CompilationCache").resolve() == cache.resolve()
    (cache / "retained").write_text("cache data")
    subprocess.run(command, env=environment, check=True, capture_output=True)
    assert (cache / "retained").read_text() == "cache data"
    failure = subprocess.run(command[:-1] + [str(root / "Different cache")], env=environment, capture_output=True)
    assert failure.returncode != 0
    assert (host / "CompilationCache").resolve() == cache.resolve()
    assert (cache / "retained").read_text() == "cache data"

    legacy = root / "Legacy host"
    subprocess.run(command[:-2] + [str(legacy)], env=environment, check=True, capture_output=True)
    (legacy / "CompilationCache" / "retained").write_text("legacy data")
    failure = subprocess.run(command[:-2] + [str(legacy), str(cache)], env=environment, capture_output=True)
    assert failure.returncode != 0
    assert (legacy / "CompilationCache" / "retained").read_text() == "legacy data"

    runner_temp = root / "work" / "_temp"
    runner_temp.mkdir(parents=True)
    package = runner_temp / "SourcePackages" / "checkout"
    package.mkdir(parents=True)
    (package / "target").write_text("ordinary file")
    (package / "link").symlink_to("target")
    (package / "dangling").symlink_to("missing")
    outside = root / "outside"
    outside.mkdir()
    (outside / "retained").write_text("outside data")
    (runner_temp / "outside-directory").symlink_to(outside, target_is_directory=True)
    commands = runner_temp / "_runner_file_commands"
    commands.mkdir()
    (commands / "output").write_text("pending file command")
    subprocess.run(["bash", str(scripts / "cleanup-runner-temp.sh")], env={**environment, "RUNNER_TEMP": str(runner_temp)}, check=True)
    assert not (package / "link").is_symlink()
    assert not (package / "dangling").is_symlink()
    assert not (runner_temp / "outside-directory").is_symlink()
    assert (package / "target").read_text() == "ordinary file"
    assert (outside / "retained").read_text() == "outside data"
    assert (commands / "output").read_text() == "pending file command"
    failure = subprocess.run(["bash", str(scripts / "cleanup-runner-temp.sh")], env={**environment, "RUNNER_TEMP": str(outside)}, capture_output=True)
    assert failure.returncode != 0
    assert (outside / "retained").read_text() == "outside data"
    unreadable = runner_temp / "unreadable"
    unreadable.mkdir()
    unreadable.chmod(0)
    try:
        failure = subprocess.run(["bash", str(scripts / "cleanup-runner-temp.sh")], env={**environment, "RUNNER_TEMP": str(runner_temp)}, capture_output=True)
        assert failure.returncode != 0
    finally:
        unreadable.chmod(0o700)

print("PASS: external cache, repeated setup, existing-data preservation, temporary links, outside targets, runner metadata")
