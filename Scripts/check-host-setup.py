#!/usr/bin/env python3
"""Check unified job storage and installers without starting a GUI service."""
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile

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
    hosted_environment = {**environment, "HOME": str(root / "different-home"),
                          "XCODE_RUNNER_HOST_STORAGE_DIRECTORY": str(storage.resolve()),
                          "XCODE_RUNNER_HOST_ROOT": str(host.resolve())}
    build = [str(executable), "build", "--package", str(package), "--scheme", "BuildProbe",
             "--destination", "platform=macOS,arch=arm64", "--", "-jobs", "2"]
    result = subprocess.run(build, env=hosted_environment, check=True, capture_output=True, text=True, timeout=300)
    log = Path(next(line[5:] for line in result.stdout.splitlines() if line.startswith("Log: ")))
    assert (storage / "Build").resolve() in log.parents
    assert compilation_cache_in(log) == cache.resolve()
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
                            *build[-3:]], env=hosted_environment, check=True, capture_output=True, text=True, timeout=300)
    log = Path(next(line[5:] for line in result.stdout.splitlines() if line.startswith("Log: ")))
    assert override_build.resolve() in log.resolve().parents
    assert compilation_cache_in(log) == override_cache.resolve()
    assert json.loads(subprocess.run([str(executable), "pool", "status", "--pool-directory", str(override_pool), "--json"],
                                    env=environment, check=True, capture_output=True, text=True).stdout)["maximumConcurrentJobs"] == 1

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
    checksum.write_text("#!/bin/bash\necho df4cebda25c86a886ed204e49fee63f5c2e7cec5f447b5c98440a826bbdf9df2 fixture\n")
    checksum.chmod(0o755)
    launchctl = tools / "launchctl"
    launchctl.write_text("#!/bin/bash\nexit 0\n")
    launchctl.chmod(0o755)
    archive = root / "runner.tar.gz"
    config = """#!/usr/bin/env python3
import json, sys
from pathlib import Path
a=sys.argv
Path('.runner').write_text(json.dumps({'workFolder':a[a.index('--work')+1], 'labels':a[a.index('--labels')+1]}), encoding='utf-8-sig')
Path('.env').write_text('')
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
    (app / "Contents/MacOS/xcode-runner-host").write_text("updated executable")
    subprocess.run(command, env=env, check=True, capture_output=True)
    assert (applications / "XcodeRunnerHost.previous.app/Contents/MacOS/xcode-runner-host").read_text() == "first executable"
    assert (applications / "XcodeRunnerHost.app/Contents/MacOS/xcode-runner-host").read_text() == "updated executable"
    (tools / "codesign").write_text("#!/bin/bash\nif [[ \"$1\" == -dv ]]; then echo Signature=adhoc >&2; fi\n")
    failure = subprocess.run(command, env=env, capture_output=True)
    assert failure.returncode != 0 and b"certificate signing identity" in failure.stderr
    assert (applications / "XcodeRunnerHost.app/Contents/MacOS/xcode-runner-host").read_text() == "updated executable"

print("PASS: unified storage, serialized initial selection, unavailable parent rejection, managed directory recovery and permissions, existing data preservation, cleanup, physical runner work paths, common-host opt-in, app installation, and signature requirements")
