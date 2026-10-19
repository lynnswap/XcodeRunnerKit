#!/usr/bin/env python3
"""Check unified job storage and installers without starting a GUI service."""
import json
import fcntl
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time

scripts = Path(__file__).resolve().parent
executable = Path(sys.argv[1]).resolve()


def configure(home, directory):
    return subprocess.run([str(executable), "host", "storage", "configure", "--directory", str(directory), "--json"],
                          env={**os.environ, "HOME": str(home)}, umask=0o022,
                          check=True, capture_output=True, text=True)


def storage_status(home):
    result = subprocess.run([str(executable), "host", "storage", "status", "--json"],
                            env={**os.environ, "HOME": str(home)}, check=True, capture_output=True, text=True)
    return json.loads(result.stdout)


def wait_for(predicate, description, timeout=30):
    deadline = time.monotonic() + timeout
    while not predicate():
        if time.monotonic() >= deadline:
            raise AssertionError(description)
        time.sleep(0.02)


def install_cli(home):
    installed = home / "Library/Application Support/XcodeRunnerKit/bin/xcode-runner"
    installed.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(executable, installed)


def compilation_cache_in(log):
    setting = "COMPILATION_CACHE_CAS_PATH = "
    return Path(next(line.strip()[len(setting):] for line in log.read_text().splitlines()
                     if line.strip().startswith(setting))).resolve()


with tempfile.TemporaryDirectory(prefix="Host storage permissions ") as temporary:
    root = Path(temporary)
    home = root / "home"
    storage = root / "Selected parent"
    storage.mkdir(mode=0o750)
    parent_mode = stat.S_IMODE(storage.stat().st_mode)
    layout = json.loads(configure(home, storage).stdout)
    assert stat.S_IMODE(storage.stat().st_mode) == parent_mode
    for name in ("Work", "CompilationCache", "Build"):
        assert stat.S_IMODE((storage / name).stat().st_mode) == 0o700
        shutil.rmtree(storage / name)
    assert json.loads(configure(home, storage).stdout) == layout
    assert stat.S_IMODE(storage.stat().st_mode) == parent_mode
    for name in ("Work", "CompilationCache", "Build"):
        assert stat.S_IMODE((storage / name).stat().st_mode) == 0o700
    shutil.rmtree(storage)
    failure = subprocess.run([str(executable), "host", "storage", "configure", "--json"],
                             env={**os.environ, "HOME": str(home)}, capture_output=True, timeout=30)
    assert failure.returncode != 0, "Reinitialization must fail when the saved parent is unavailable"
    assert not storage.exists(), "Reinitialization recreated an unavailable parent"
    assert storage_status(home) == layout, "Failed reinitialization changed the active storage record"


with tempfile.TemporaryDirectory(prefix="Host storage concurrent initialization ") as temporary:
    root = Path(temporary)
    home = root / "home"
    parents = [root / "First parent", root / "Second parent"]
    processes = []
    try:
        for parent in parents:
            processes.append(subprocess.Popen(
                ["/bin/bash", "-c", 'read -r start; exec "$@"', "host-storage-configure",
                 str(executable), "host", "storage", "configure", "--directory", str(parent), "--json"],
                env={**os.environ, "HOME": str(home)}, umask=0o022,
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True))
        for process in processes:
            process.stdin.write("start\n")
            process.stdin.flush()
        outputs = [process.communicate(timeout=30) for process in processes]
        winners = [index for index, process in enumerate(processes) if process.returncode == 0]
        assert len(winners) == 1, [(process.returncode, outputs[index]) for index, process in enumerate(processes)]
        winner = winners[0]
        layout = json.loads(outputs[winner][0])
        assert layout["storageDirectory"] == str(parents[winner].resolve())
        assert storage_status(home) == layout
        assert not parents[1 - winner].exists(), "The rejected initializer prepared its requested parent"
    finally:
        for process in processes:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=10)


with tempfile.TemporaryDirectory(prefix="Hosted CLI unavailable storage ") as temporary:
    root = Path(temporary)
    home = root / "home"
    storage = root / "Job data"
    layout = json.loads(configure(home, storage).stdout)
    offline = root / "Offline job data"
    environment = {**os.environ, "HOME": str(home),
                   "XCODE_RUNNER_HOST_STORAGE_DIRECTORY": layout["storageDirectory"],
                   "XCODE_RUNNER_HOST_ROOT": layout["hostRoot"]}
    package = root / "BuildProbe"
    shutil.copytree(scripts.parent / "Tests/Fixtures/BuildProbe", package,
                    ignore=shutil.ignore_patterns(".build", ".swiftpm"))
    build = [str(executable), "build", "--package", str(package), "--scheme", "BuildProbe",
             "--destination", "platform=macOS,arch=arm64", "--", "-jobs", "2"]
    storage.rename(offline)
    failure = subprocess.run(build, env=environment, capture_output=True, timeout=30)
    assert failure.returncode != 0, "A hosted operation accepted its unavailable storage parent"
    assert not storage.exists(), "A hosted operation recreated its unavailable storage parent"
    assert not list((offline / "Build").iterdir())
    assert storage_status(home) == layout
    offline.rename(storage)

    probe = root / "pool-probe"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
                    str(scripts.parent / "Sources/XcodeRunnerKit/HostExecutionPool.swift"),
                    str(scripts.parent / "Tests/Fixtures/ExecutionPoolProbe.swift"),
                    "-o", str(probe)], check=True)
    admission = root / "Admission"
    admission.mkdir()
    pool = admission / "pool"

    def pool_status():
        result = subprocess.run([str(executable), "pool", "status", "--pool-directory", str(pool), "--json"],
                                env=environment, check=True, capture_output=True, text=True)
        return json.loads(result.stdout)

    pool_arguments = ["--pool-directory", str(pool), "--maximum-concurrent-jobs", "1"]
    blocker = subprocess.Popen([str(probe), str(admission), "blocker", "1"],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    queued = None
    try:
        wait_for(lambda: (admission / "blocker.started").exists(), "Pool blocker did not acquire its slot")
        queued = subprocess.Popen(build[:-3] + pool_arguments + build[-3:], env=environment,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        wait_for(lambda: pool_status()["waitingJobCounts"]["medium"] == 1,
                 "Hosted operation did not wait for the pool")
        assert queued.poll() is None
        assert not list((storage / "Build").iterdir())
        storage.rename(offline)
        (admission / "blocker.release").touch()
        stdout, stderr = blocker.communicate(timeout=30)
        assert blocker.returncode == 0, (stdout, stderr)
        stdout, stderr = queued.communicate(timeout=30)
        assert queued.returncode != 0, (stdout, stderr)
        assert not storage.exists(), "A queued operation recreated its unavailable storage parent"
        assert not list((offline / "Build").iterdir())
        status = pool_status()
        assert status["activeJobCount"] == 0 and not any(status["waitingJobCounts"].values())
    finally:
        for process in (queued, blocker):
            if process is not None and process.poll() is None:
                process.terminate()
                try:
                    process.communicate(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.communicate()

    override_build = root / "Override Build"
    override_cache = root / "Override Cache"
    result = subprocess.run(build[:-3] + ["--output-directory", str(override_build),
                            "--compilation-cache", str(override_cache), *pool_arguments, *build[-3:]],
                            env=environment, check=True, capture_output=True, text=True, timeout=300)
    log = Path(next(line[5:] for line in result.stdout.splitlines() if line.startswith("Log: ")))
    assert override_build.resolve() in log.resolve().parents
    assert compilation_cache_in(log) == override_cache.resolve()
    assert not storage.exists(), "Explicit paths changed the unavailable managed parent"


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
    host = home / "Library/Application Support/XcodeRunnerKit"
    storage = root / "External disk" / "Job data"
    cache = storage / "CompilationCache"
    cache.mkdir(parents=True)
    (cache / "retained").write_text("cache data")
    host.mkdir(parents=True)
    (host / "CompilationCache").symlink_to(cache, target_is_directory=True)
    work = storage / "Work" / "existing-runner"
    work.mkdir(parents=True)
    (work / "retained").write_text("work data")
    existing_modes = {path: stat.S_IMODE(path.stat().st_mode) for path in (storage, cache, work.parent)}
    command = ["bash", str(scripts / "install-host-tools.sh"), str(executable), "test-source", str(storage)]
    subprocess.run(command, env=environment, check=True, capture_output=True)
    assert (host / "CompilationCache").is_symlink()
    assert (host / "CompilationCache").resolve() == cache.resolve()
    assert (storage / "Build").is_dir()
    assert all(stat.S_IMODE(path.stat().st_mode) == mode for path, mode in existing_modes.items())
    layout = json.loads(configure(home, storage).stdout)
    assert layout["storageDirectory"] == str(storage.resolve())
    assert layout["buildDirectory"] == str((storage / "Build").resolve())
    assert layout["workDirectory"] == str((storage / "Work").resolve())
    subprocess.run(command, env=environment, check=True, capture_output=True)
    assert (cache / "retained").read_text() == "cache data"
    assert (work / "retained").read_text() == "work data"
    failure = subprocess.run(command[:-1] + [str(root / "Different storage")], env=environment, capture_output=True)
    assert failure.returncode != 0
    assert (host / "CompilationCache").resolve() == cache.resolve()
    assert (cache / "retained").read_text() == "cache data"
    assert (work / "retained").read_text() == "work data"
    absent_volume = root / "Absent volume"
    absent_volume.symlink_to(root / "missing-volume", target_is_directory=True)
    failure = subprocess.run(command[:-1] + [str(absent_volume / "Job data")],
                             env={**environment, "HOME": str(root / "fresh-home")}, capture_output=True)
    assert failure.returncode != 0
    unwritable = root / "Unwritable storage"
    unwritable.mkdir()
    unwritable.chmod(0o555)
    try:
        failure = subprocess.run(command[:-1] + [str(unwritable)],
                                 env={**environment, "HOME": str(root / "readonly-home")}, capture_output=True)
        assert failure.returncode != 0
    finally:
        unwritable.chmod(0o755)

    package = storage / "Work" / "BuildProbe"
    shutil.copytree(scripts.parent / "Tests/Fixtures/BuildProbe", package,
                    ignore=shutil.ignore_patterns(".build", ".swiftpm"))
    developer = Path(os.environ.get("DEVELOPER_DIR") or subprocess.run(
        ["xcode-select", "-p"], check=True, capture_output=True, text=True).stdout.strip())
    bundled_service = developer.parent / (
        "SharedFrameworks/SwiftBuild.framework/Versions/A/PlugIns/"
        "SWBBuildService.bundle/Contents/MacOS/SWBBuildService")
    assert bundled_service.is_file(), bundled_service
    # Xcode reads the selected service's Mach-O deployment target before launching it.
    service_source = root / "BuildServiceProbe.c"
    service_source.write_text('''#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
int main(int argc, char **argv) {
    char *marker;
    if (asprintf(&marker, "%s.started", argv[0]) < 0) return 1;
    FILE *output = fopen(marker, "a");
    free(marker);
    if (!output) { perror("service marker"); return 1; }
    fputs("started\\n", output);
    if (fclose(output) != 0) { perror("service marker"); return 1; }
    execv(getenv("XRK_FIXTURE_BUNDLED_SERVICE"), argv);
    perror("bundled service");
    return 1;
}
''')
    service_wrappers = [root / name for name in ("Saved service", "Operation service")]
    service_markers = [Path(str(wrapper) + ".started") for wrapper in service_wrappers]
    subprocess.run(["xcrun", "clang", str(service_source), "-o", str(service_wrappers[0])], check=True)
    shutil.copy2(service_wrappers[0], service_wrappers[1])
    service_command = [str(executable), "host", "build-service"]
    initial_service_status = json.loads(subprocess.run(
        service_command + ["status", "--json"], env=environment,
        check=True, capture_output=True, text=True, timeout=30).stdout)
    assert initial_service_status == {"hostRoot": layout["hostRoot"]}
    configured_service_status = json.loads(subprocess.run(
        service_command + ["configure", "--path", str(service_wrappers[0]), "--json"],
        env=environment, check=True, capture_output=True, text=True, timeout=30).stdout)
    assert configured_service_status == {**initial_service_status,
                                         "buildServiceExecutablePath": str(service_wrappers[0])}
    hosted_environment = {**environment, "HOME": str(root / "different-home"),
                          "XCODE_RUNNER_HOST_STORAGE_DIRECTORY": str(storage.resolve()),
                          "XCODE_RUNNER_HOST_ROOT": str(host.resolve()),
                          "XRK_FIXTURE_BUNDLED_SERVICE": str(bundled_service),
                          "SWBBUILDSERVICE_PATH": str(root / "missing inherited SWB service"),
                          "XCBBUILDSERVICE_PATH": str(root / "missing inherited XCB service")}
    build = [str(executable), "build", "--package", str(package), "--scheme", "BuildProbe",
             "--destination", "platform=macOS,arch=arm64", "--", "-jobs", "2"]
    shutil.rmtree(storage / "Build")
    result = subprocess.run(build, env=hosted_environment, check=True, capture_output=True, text=True, timeout=300)
    log = Path(next(line[5:] for line in result.stdout.splitlines() if line.startswith("Log: ")))
    assert (storage / "Build").resolve() in log.parents
    assert compilation_cache_in(log) == cache.resolve()
    saved_service_launches = service_markers[0].read_text()
    assert saved_service_launches and not service_markers[1].exists()
    pool_status = subprocess.run([str(executable), "pool", "status", "--pool-directory", str(host / "Pool"), "--json"],
                                 env=environment, check=True, capture_output=True, text=True)
    assert json.loads(pool_status.stdout)["maximumConcurrentJobs"] == 4
    assert not (root / "different-home").exists()
    override = root / "Overrides"
    override_build = override / "Build"
    override_cache = override / "Cache"
    override_pool = override / "Pool"
    result = subprocess.run(build[:-3] + ["--output-directory", str(override_build),
                            "--compilation-cache", str(override_cache),
                            "--pool-directory", str(override_pool), "--maximum-concurrent-jobs", "1",
                            "--build-service-path", str(service_wrappers[1]),
                            *build[-3:]], env=hosted_environment, check=True, capture_output=True, text=True, timeout=300)
    log = Path(next(line[5:] for line in result.stdout.splitlines() if line.startswith("Log: ")))
    assert override_build.resolve() in log.resolve().parents
    assert compilation_cache_in(log) == override_cache.resolve()
    assert json.loads(subprocess.run([str(executable), "pool", "status", "--pool-directory", str(override_pool), "--json"],
                                    env=environment, check=True, capture_output=True, text=True).stdout)["maximumConcurrentJobs"] == 1
    assert service_markers[1].read_text()
    assert service_markers[0].read_text() == saved_service_launches
    assert json.loads(subprocess.run(service_command + ["status", "--json"], env=environment,
                                    check=True, capture_output=True, text=True, timeout=30).stdout) == configured_service_status
    assert json.loads(subprocess.run(service_command + ["configure", "--json"], env=environment,
                                    check=True, capture_output=True, text=True, timeout=30).stdout) == initial_service_status
    assert json.loads(subprocess.run(service_command + ["status", "--json"], env=environment,
                                    check=True, capture_output=True, text=True, timeout=30).stdout) == initial_service_status

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
    (outside / "outside-link").symlink_to("retained")
    linked_root = root / "linked-root" / "_temp"
    linked_root.parent.mkdir()
    linked_root.symlink_to(outside, target_is_directory=True)
    failure = subprocess.run(["bash", str(scripts / "cleanup-runner-temp.sh")], env={**environment, "RUNNER_TEMP": str(linked_root)}, capture_output=True)
    assert failure.returncode != 0
    assert (outside / "outside-link").is_symlink()
    unreadable = runner_temp / "unreadable"
    unreadable.mkdir()
    unreadable.chmod(0)
    try:
        failure = subprocess.run(["bash", str(scripts / "cleanup-runner-temp.sh")], env={**environment, "RUNNER_TEMP": str(runner_temp)}, capture_output=True)
        assert failure.returncode != 0
    finally:
        unreadable.chmod(0o700)


with tempfile.TemporaryDirectory(prefix="XcodeRunnerKit-runner-") as temporary:
    import io
    import tarfile

    root = Path(temporary)
    tools = root / "tools"
    tools.mkdir()
    checksum = tools / "shasum"
    checksum.write_text("#!/bin/bash\necho ${XRK_FIXTURE_ARCHIVE_SHA256:-df4cebda25c86a886ed204e49fee63f5c2e7cec5f447b5c98440a826bbdf9df2} fixture\n")
    checksum.chmod(0o755)
    launchctl = tools / "launchctl"
    launchctl.write_text("#!/bin/bash\nexit 0\n")
    launchctl.chmod(0o755)
    archive = root / "runner.tar.gz"
    config = """#!/usr/bin/env python3
import json, os, sys, time
from pathlib import Path
a=sys.argv
if counter := os.environ.get('XRK_FIXTURE_CONFIG_COUNTER'):
    with Path(counter).open('a') as output: output.write('configured\\n')
if arguments := os.environ.get('XRK_FIXTURE_CONFIG_ARGUMENTS'):
    Path(arguments).write_text(json.dumps(a[1:]))
if os.environ.get('XRK_FIXTURE_CONFIG_FAIL') == '1':
    raise SystemExit('Fixture registration failed before creating .runner')
if remote := os.environ.get('XRK_FIXTURE_REMOTE_REGISTRATION'):
    remote = Path(remote)
    if not remote.exists():
        remote.write_text('remote registration created')
        Path('.credentials').write_text('partial credentials')
        raise SystemExit('Fixture registration interrupted before saving .runner')
    if '--replace' not in a:
        raise SystemExit('A runner exists with the same name')
if gate := os.environ.get('XRK_FIXTURE_CONFIG_GATE'):
    gate = Path(gate)
    (gate / 'entered').touch()
    while not (gate / 'release').exists(): time.sleep(0.02)
Path('.runner').write_text(json.dumps({'workFolder':a[a.index('--work')+1], 'labels':a[a.index('--labels')+1]}), encoding='utf-8-sig')
Path('.env').write_text('')
Path('.credentials').write_text('registered credentials')
"""
    with tarfile.open(archive, "w:gz") as target:
        for name, content in {"config.sh": config, "svc.sh": "#!/bin/bash\nprintf '%s\\n' fixture.plist > .service\n", "bin/runsvc.sh": "#!/bin/bash\nexit 0\n"}.items():
            data = content.encode()
            info = tarfile.TarInfo(name)
            info.size = len(data)
            info.mode = 0o755
            target.addfile(info, io.BytesIO(data))
    environment = {**os.environ, "HOME": str(root), "PATH": str(tools) + os.pathsep + os.environ["PATH"]}
    installation_root = root / "Library/XcodeRunnerKit/runners"
    physical_work = root / "External work data"
    physical_work.mkdir()
    work_alias = root / "work-alias"
    work_alias.symlink_to(physical_work, target_is_directory=True)
    configure(root, work_alias)
    install_cli(root)
    work = physical_work / "Work" / "fixture"
    installer = ["bash", str(scripts / "install-github-runner.sh"), "OWNER/REPO", "fixture", str(archive), "xcode-runnerkit,custom-host"]
    subprocess.run(installer, input="fixture-token\n", text=True, env=environment, check=True, capture_output=True)
    installation = installation_root / "fixture"
    received = json.loads((installation / ".runner").read_text(encoding="utf-8-sig"))
    assert received == {"workFolder": str(work.resolve()), "labels": "xcode-runnerkit,custom-host"}
    assert work.is_dir()
    credential_fixture = root / "credential-fixture.config"
    credential_fixture.write_text("[fixture]\n    marker = present\n")
    git = ["git", "-C", received["workFolder"]]
    subprocess.run(git + ["init", "-q"], env=environment, check=True)
    subprocess.run(git + ["config", "--local", f'includeIf.gitdir:{received["workFolder"]}/.git.path', str(credential_fixture)], env=environment, check=True)
    marker = subprocess.check_output(git + ["config", "--get", "fixture.marker"], env=environment, text=True)
    assert marker.strip() == "present"
    hook = Path((installation / ".env").read_text().strip().split("=", 1)[1])
    assert hook.is_absolute() and installation not in hook.parents
    temporary_data = work / "_temp"
    temporary_data.mkdir()
    (temporary_data / "dangling").symlink_to("missing")
    subprocess.run(["bash", str(hook)], env={**environment, "RUNNER_TEMP": str(temporary_data)}, check=True)
    assert not (temporary_data / "dangling").is_symlink()

    hosted = ["bash", str(scripts / "install-github-runner.sh"), "OWNER/REPO", "hosted", str(archive), "xcode-runnerkit"]
    subprocess.run(hosted, input="fixture-token\n", text=True, env=environment, check=True, capture_output=True)
    hosted_directory = installation_root / "hosted"
    assert (hosted_directory / ".xcode-runner-host").exists()
    assert not (hosted_directory / ".service").exists()
    assert (hosted_directory / "runsvc.sh").is_file()
    assert (hosted_directory / ".runner").is_file()

    release_digest = "a" * 64
    release_environment = {**environment, "XRK_FIXTURE_ARCHIVE_SHA256": release_digest}
    released = installer[:3] + ["release-digest", str(archive), "xcode-runnerkit", release_digest]
    subprocess.run(released, input="fixture-token\n", text=True, env=release_environment, check=True, capture_output=True)
    assert (installation_root / "release-digest" / ".xcode-runner-host").exists()
    rejected = installer[:3] + ["wrong-digest", str(archive), "xcode-runnerkit", "b" * 64]
    failure = subprocess.run(rejected, input="fixture-token\n", text=True, env=release_environment, capture_output=True)
    assert failure.returncode != 0 and "does not match the expected release digest" in failure.stderr
    assert not (installation_root / "wrong-digest").exists()
    assert not (physical_work / "Work" / "wrong-digest").exists()

    managed_environment = {**environment, "XCODE_RUNNER_INSTALLATION_REPOSITORY_ID": "42"}
    pending_name = "pending-configuration"
    pending_directory = installation_root / pending_name
    pending = installer[:3] + [pending_name, str(archive)]
    pending_counter = root / "pending-config-count"
    failing_environment = {**managed_environment, "XRK_FIXTURE_CONFIG_FAIL": "1",
                           "XRK_FIXTURE_CONFIG_COUNTER": str(pending_counter)}
    for _ in range(3):
        failure = subprocess.run(pending, input="fixture-token\n", text=True, env=failing_environment, capture_output=True)
        assert failure.returncode != 0
        assert (pending_directory / ".xcode-runner-installation").read_text().strip() == "42"
        assert not (pending_directory / ".runner").exists()
    assert len(pending_counter.read_text().splitlines()) == 3
    subprocess.run(pending, input="fixture-token\n", text=True,
                   env={**managed_environment, "XRK_FIXTURE_CONFIG_COUNTER": str(pending_counter)},
                   check=True, capture_output=True)
    assert len(pending_counter.read_text().splitlines()) == 4
    assert (pending_directory / ".xcode-runner-host").exists()
    assert not (pending_directory / ".xcode-runner-installation").exists()

    remote_pending = installer[:3] + ["pending-remote-registration", str(archive)]
    remote_directory = installation_root / "pending-remote-registration"
    remote_arguments = root / "remote-registration-arguments"
    remote_environment = {**managed_environment, "XRK_FIXTURE_REMOTE_REGISTRATION": str(root / "remote-registration"),
                          "XRK_FIXTURE_CONFIG_ARGUMENTS": str(remote_arguments)}
    failure = subprocess.run(remote_pending, input="fixture-token\n", text=True, env=remote_environment, capture_output=True)
    assert failure.returncode != 0 and "interrupted before saving .runner" in failure.stderr
    assert "--replace" not in json.loads(remote_arguments.read_text())
    assert not (remote_directory / ".runner").exists()
    failure = subprocess.run(remote_pending, input="fixture-token\n", text=True, env=remote_environment, capture_output=True)
    assert failure.returncode != 0 and "A runner exists with the same name" in failure.stderr
    subprocess.run(remote_pending, input="fixture-token\n", text=True,
                   env={**remote_environment, "XCODE_RUNNER_REPLACE_REGISTRATION": "1"}, check=True, capture_output=True)
    assert "--replace" in json.loads(remote_arguments.read_text())
    assert (remote_directory / ".xcode-runner-host").exists()
    assert not (remote_directory / ".xcode-runner-installation").exists()

    refused_replace_arguments = root / "unowned-replace-arguments"
    refused_replace = installer[:3] + ["unowned-replacement", str(archive)]
    failure = subprocess.run(refused_replace, input="fixture-token\n", text=True,
                             env={**managed_environment, "XCODE_RUNNER_REPLACE_REGISTRATION": "1",
                                  "XRK_FIXTURE_CONFIG_ARGUMENTS": str(refused_replace_arguments)}, capture_output=True)
    assert failure.returncode != 0 and "existing incomplete installation" in failure.stderr
    assert not refused_replace_arguments.exists()

    setup = root / "resumable-setup"
    setup.mkdir()
    for name in ("install-github-runner.sh", "lock-host-storage.py", "cleanup-runner-temp.sh", "cleanup-runner-temp.py"):
        shutil.copy2(scripts / name, setup / name)
    (setup / "enable-hosted-runner.sh").write_text('''#!/bin/bash
if [[ "${XRK_FIXTURE_OPT_IN_FAIL:-}" == "1" ]]; then
    echo "Fixture opt-in failed after registration" >&2
    exit 1
fi
exec /bin/bash "$XRK_FIXTURE_ENABLE_SCRIPT" "$@"
''')
    registered_counter = root / "registered-config-count"
    registered_environment = {**managed_environment, "XRK_FIXTURE_CONFIG_COUNTER": str(registered_counter),
                              "XRK_FIXTURE_ENABLE_SCRIPT": str(scripts / "enable-hosted-runner.sh")}
    registered = ["bash", str(setup / "install-github-runner.sh"), "OWNER/REPO", "pending-opt-in", str(archive)]
    failure = subprocess.run(registered, input="fixture-token\n", text=True,
                             env={**registered_environment, "XRK_FIXTURE_OPT_IN_FAIL": "1"}, capture_output=True)
    assert failure.returncode != 0 and "Fixture opt-in failed" in failure.stderr
    registered_directory = installation_root / "pending-opt-in"
    metadata = (registered_directory / ".runner").read_bytes()
    credentials = (registered_directory / ".credentials").read_bytes()
    assert not (registered_directory / ".xcode-runner-host").exists()
    subprocess.run(registered, input="fixture-token\n", text=True, env=registered_environment, check=True, capture_output=True)
    assert len(registered_counter.read_text().splitlines()) == 1
    assert (registered_directory / ".runner").read_bytes() == metadata
    assert (registered_directory / ".credentials").read_bytes() == credentials
    assert (registered_directory / ".xcode-runner-host").exists()
    assert not (registered_directory / ".xcode-runner-installation").exists()
    assert len((registered_directory / ".env").read_text().splitlines()) == 1

    unowned_directory = installation_root / "unowned"
    unowned_directory.mkdir()
    retained = unowned_directory / "retained"
    retained.write_text("existing user data")
    unowned = installer[:3] + ["unowned", str(archive)]
    failure = subprocess.run(unowned, input="fixture-token\n", text=True, env=managed_environment, capture_output=True)
    assert failure.returncode != 0 and "not this repository's incomplete installation" in failure.stderr
    assert retained.read_text() == "existing user data"
    assert not (unowned_directory / "config.sh").exists()

    service_plist = root / "individual.plist"
    import plistlib
    service_plist.write_bytes(plistlib.dumps({"Label": "fixture-individual"}))
    (installation / ".service").write_text(str(service_plist) + "\n")
    subprocess.run(["bash", str(scripts / "enable-hosted-runner.sh"), str(installation)], env=environment, check=True, capture_output=True)
    assert (installation / ".xcode-runner-host").exists()
    assert not (installation / ".service").exists()
    assert (installation / ".service.before-host").read_text().strip() == str(service_plist)
    assert service_plist.with_suffix(".plist.before-host").exists()
    assert json.loads((installation / ".runner").read_text(encoding="utf-8-sig")) == received

    storage_probe_source = root / "StorageProbe.swift"
    storage_probe_source.write_text('''import Foundation
@main enum StorageProbe {
    static func main() async throws {
        let arguments = CommandLine.arguments
        let installation = HostInstallation(homeDirectory: URL(filePath: arguments[2]))
        if arguments[1] == "request" {
            _ = try await installation.requestStorageDirectory(URL(filePath: arguments[3]))
        } else {
            if arguments.count > 3 { try Data().write(to: URL(filePath: arguments[3])) }
            let storage = try await installation.prepareStorageForLaunch()
            print(storage.directory.path(percentEncoded: false))
        }
    }
}
''')
    storage_probe = root / "storage-probe"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
                    "-package-name", "XcodeRunnerKit",
                    *[str(scripts.parent / "Sources/XcodeRunnerKit" / name) for name in
                      ("HostInstallation.swift", "HostStorageMigration.swift", "CompilationCache.swift")],
                    str(storage_probe_source), "-o", str(storage_probe)], check=True)

    def request_storage(home, target):
        subprocess.run([str(storage_probe), "request", str(home), str(target)],
                       check=True, capture_output=True, text=True, timeout=30)

    # Registration owns storage from layout selection through publishing its host marker.
    first_home = root / "registration-first-home"
    source = root / "Registration first source"
    target = root / "Registration first target"
    target.mkdir()
    configure(first_home, source)
    install_cli(first_home)
    request_storage(first_home, target)
    gate = root / "registration-gate"
    gate.mkdir()
    runner_name = "registration-first"
    first_environment = {**environment, "HOME": str(first_home), "XRK_FIXTURE_CONFIG_GATE": str(gate)}
    registration = subprocess.Popen(installer[:3] + [runner_name, str(archive)],
                                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    text=True, env=first_environment, start_new_session=True)
    migration = None
    try:
        registration.stdin.write("fixture-token\n")
        registration.stdin.flush()
        wait_for(lambda: (gate / "entered").exists(), "Runner configuration did not reach its gate")
        retained = source / "Work" / runner_name / "retained"
        retained.write_text("runner work data")
        started = root / "registration-first-migration-started"
        migration = subprocess.Popen([str(storage_probe), "prepare", str(first_home), str(started)],
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                     start_new_session=True)
        wait_for(started.exists, "Storage preparation did not start")
        lock_path = first_home / "Library/Application Support/XcodeRunnerKit/storage.lock"
        with lock_path.open("r+") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                pass
            else:
                raise AssertionError("Runner configuration released its storage transaction before opt-in")
        assert migration.poll() is None and storage_status(first_home)["storageDirectory"] == str(source.resolve())
        assert not (target / "Work").exists()
        (gate / "release").touch()
        stdout, stderr = registration.communicate(timeout=30)
        assert registration.returncode == 0, (stdout, stderr)
        stdout, stderr = migration.communicate(timeout=30)
        assert migration.returncode == 0, (stdout, stderr)
        runner = first_home / "Library/XcodeRunnerKit/runners" / runner_name
        record = json.loads((runner / ".runner").read_text(encoding="utf-8-sig"))
        assert record["workFolder"] == str((target / "Work" / runner_name).resolve())
        assert (runner / ".xcode-runner-host").exists()
        assert (target / "Work" / runner_name / "retained").read_text() == "runner work data"
        assert retained.read_text() == "runner work data"
        assert storage_status(first_home)["storageDirectory"] == str(target.resolve())
    finally:
        for process in (registration, migration):
            if process is not None and process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate(timeout=10)

    # A queued registration obtains the committed layout after the migration transaction.
    second_home = root / "migration-first-home"
    source = root / "Migration first source"
    target = root / "Migration first target"
    target.mkdir()
    layout = json.loads(configure(second_home, source).stdout)
    install_cli(second_home)
    request_storage(second_home, target)
    runner_name = "migration-first"
    second_environment = {**environment, "HOME": str(second_home)}
    unhosted = second_home / "Library/XcodeRunnerKit/runners/unhosted"
    unhosted.mkdir(parents=True)
    old_work = source / "Work" / unhosted.name
    old_work.mkdir()
    original_registration = ('\ufeff' + json.dumps({"workFolder": str(old_work.resolve())})).encode()
    (unhosted / ".runner").write_bytes(original_registration)
    (unhosted / "bin").mkdir()
    (unhosted / "bin/runsvc.sh").write_text("#!/bin/bash\nexit 0\n")
    (unhosted / "runsvc.sh").write_text("original service script")
    activation = None
    with (Path(layout["hostRoot"]) / "storage.lock").open("r+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        registration = subprocess.Popen(installer[:3] + [runner_name, str(archive)],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        text=True, env=second_environment, start_new_session=True)
        try:
            registration.stdin.write("fixture-token\n")
            registration.stdin.flush()
            activation = subprocess.Popen(["bash", str(scripts / "enable-hosted-runner.sh"), str(unhosted)],
                                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                          env=second_environment, start_new_session=True)
            subprocess.run([str(storage_probe), "prepare", str(second_home)],
                           env={**second_environment, "XCODE_RUNNER_STORAGE_LOCK_DESCRIPTOR": str(lock.fileno())},
                           pass_fds=(lock.fileno(),), check=True, capture_output=True, text=True, timeout=30)
            assert registration.poll() is None
            assert activation.poll() is None
            assert not (source / "Work" / runner_name).exists()
            assert not (target / "Work" / runner_name).exists()
            fcntl.flock(lock, fcntl.LOCK_UN)
            stdout, stderr = registration.communicate(timeout=30)
            assert registration.returncode == 0, (stdout, stderr)
            runner = second_home / "Library/XcodeRunnerKit/runners" / runner_name
            record = json.loads((runner / ".runner").read_text(encoding="utf-8-sig"))
            assert record["workFolder"] == str((target / "Work" / runner_name).resolve())
            assert (runner / ".xcode-runner-host").exists()
            assert not (source / "Work" / runner_name).exists()
            stdout, stderr = activation.communicate(timeout=30)
            assert activation.returncode != 0 and "Reconfigure this runner with --work" in stderr, (stdout, stderr)
            assert str((target / "Work" / unhosted.name).resolve()) in stderr
            assert not (unhosted / ".xcode-runner-host").exists()
            assert not (unhosted / ".service").exists()
            assert (unhosted / ".runner").read_bytes() == original_registration
            assert (unhosted / "runsvc.sh").read_text() == "original service script"
            assert not (unhosted / "runsvc.sh.new").exists()
        finally:
            for process in (registration, activation):
                if process is not None and process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.communicate(timeout=10)

    unrelated = root / "unrelated-lock"
    with unrelated.open("w+") as wrong_lock:
        failure = subprocess.run(["bash", str(scripts / "enable-hosted-runner.sh"), str(installation)],
                                 env={**environment, "XCODE_RUNNER_STORAGE_LOCK_DESCRIPTOR": str(wrong_lock.fileno())},
                                 pass_fds=(wrong_lock.fileno(),), capture_output=True, text=True, timeout=30)
    assert failure.returncode != 0 and "does not match" in failure.stderr
    assert json.loads((installation / ".runner").read_text(encoding="utf-8-sig")) == received

    broken = root / "unavailable"
    broken.symlink_to(root / "missing-volume", target_is_directory=True)
    (physical_work / "Work" / "unavailable").symlink_to(broken, target_is_directory=True)
    failure = subprocess.run(installer[:3] + ["unavailable", str(archive)], input="fixture-token\n", text=True, env=environment, capture_output=True)
    assert failure.returncode != 0 and "mkdir" in failure.stderr
    assert not (installation_root / "unavailable").exists()
    readonly = physical_work / "Work" / "readonly"
    readonly.mkdir()
    readonly.chmod(0o555)
    try:
        failure = subprocess.run(installer[:3] + ["readonly", str(archive)], input="fixture-token\n", text=True, env=environment, capture_output=True)
        assert failure.returncode != 0 and "mktemp" in failure.stderr
        assert not (installation_root / "readonly").exists()
    finally:
        readonly.chmod(0o755)

with tempfile.TemporaryDirectory(prefix="RunnerHost installer ") as temporary:
    import plistlib
    root = Path(temporary)
    home = root / "home"
    home.mkdir()
    tools = root / "tools"
    tools.mkdir()
    for name, body in {"codesign": "exit 0", "launchctl": "[[ \"$1\" != print ]]"}.items():
        tool = tools / name
        tool.write_text("#!/bin/bash\n" + body + "\n")
        tool.chmod(0o755)
    app = root / "input" / "XcodeRunnerHost.app"
    (app / "Contents/MacOS").mkdir(parents=True)
    (app / "Contents/MacOS/xcode-runner-host").write_text("first executable")
    setup = app / "Contents/Resources/HostSetup"
    setup.mkdir(parents=True)
    (setup / "install-github-runner.sh").write_text("first setup script")
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "dev.lynnswap.XcodeRunnerHost",
        "CFBundleExecutable": "xcode-runner-host",
    }))
    env = {**os.environ, "HOME": str(home), "PATH": str(tools) + os.pathsep + os.environ["PATH"]}
    install_cli(home)
    runners = home / "Library/XcodeRunnerKit/runners"
    host = home / "Library/Application Support/XcodeRunnerKit"
    applications = home / "Applications"
    command = ["bash", str(scripts / "install-runner-host.sh"), str(app)]
    subprocess.run(command, env=env, check=True, capture_output=True)
    plist = plistlib.loads((home / "Library/LaunchAgents/dev.lynnswap.XcodeRunnerHost.plist").read_bytes())
    assert plist["AssociatedBundleIdentifiers"] == ["dev.lynnswap.XcodeRunnerHost"]
    assert plist["ProgramArguments"] == [str(applications.resolve() / "XcodeRunnerHost.app/Contents/MacOS/xcode-runner-host")]
    assert (applications / "XcodeRunnerHost.app/Contents/Resources/HostSetup/install-github-runner.sh").read_text() == "first setup script"
    (app / "Contents/MacOS/xcode-runner-host").write_text("updated executable")
    (setup / "install-github-runner.sh").write_text("updated setup script")
    subprocess.run(command, env=env, check=True, capture_output=True)
    assert (applications / "XcodeRunnerHost.previous.app/Contents/MacOS/xcode-runner-host").read_text() == "first executable"
    assert (applications / "XcodeRunnerHost.app/Contents/MacOS/xcode-runner-host").read_text() == "updated executable"
    assert (applications / "XcodeRunnerHost.previous.app/Contents/Resources/HostSetup/install-github-runner.sh").read_text() == "first setup script"
    assert (applications / "XcodeRunnerHost.app/Contents/Resources/HostSetup/install-github-runner.sh").read_text() == "updated setup script"
    (tools / "codesign").write_text("#!/bin/bash\nif [[ \"$1\" == -dv ]]; then echo Signature=adhoc >&2; fi\n")
    failure = subprocess.run(command, env=env, capture_output=True)
    assert failure.returncode != 0 and b"certificate signing identity" in failure.stderr
    assert (applications / "XcodeRunnerHost.app/Contents/MacOS/xcode-runner-host").read_text() == "updated executable"

print("PASS: unified storage, serialized initial selection and runner registration/startup migration, unavailable parent rejection at setup and admitted execution, saved and per-operation build service selection, explicit overrides, managed directory recovery and permissions, existing data preservation, cleanup, physical runner work paths, common-host opt-in, app installation, and signature requirements")
