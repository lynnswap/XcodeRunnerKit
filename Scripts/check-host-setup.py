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
    empty_host = root / "Empty host"
    empty_cache = root / "Empty external cache"
    subprocess.run(command[:-2] + [str(empty_host), str(empty_cache)], env=environment, check=True, capture_output=True)
    moved_empty = root / "Moved empty cache"
    subprocess.run(command[:-2] + [str(empty_host), str(moved_empty)], env=environment, check=True, capture_output=True)
    assert (empty_host / "CompilationCache").resolve() == moved_empty.resolve()
    assert empty_cache.is_dir() and not any(empty_cache.iterdir())
    absent_volume = root / "Absent volume"
    absent_volume.symlink_to(root / "missing-volume", target_is_directory=True)
    failure = subprocess.run(command[:-2] + [str(empty_host), str(absent_volume / "Cache")], env=environment, capture_output=True)
    assert failure.returncode != 0
    assert (empty_host / "CompilationCache").resolve() == moved_empty.resolve()
    unwritable_cache = root / "Unwritable cache"
    unwritable_cache.mkdir()
    unwritable_cache.chmod(0o555)
    try:
        failure = subprocess.run(command[:-2] + [str(empty_host), str(unwritable_cache)], env=environment, capture_output=True)
        assert failure.returncode != 0
        assert (empty_host / "CompilationCache").resolve() == moved_empty.resolve()
    finally:
        unwritable_cache.chmod(0o755)

    nested = empty_host / "CompilationCache" / "nested"
    expected_nested = nested.resolve()
    subprocess.run(command[:-2] + [str(empty_host), str(nested)], env=environment, check=True, capture_output=True)
    assert (empty_host / "CompilationCache").resolve() == expected_nested
    assert expected_nested.is_dir()

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
    import json
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
Path('.runner').write_text(json.dumps({'workFolder':a[a.index('--work')+1], 'labels':a[a.index('--labels')+1]}))
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
    installation_root = root / "runners"
    physical_work = root / "External work data"
    physical_work.mkdir()
    work_alias = root / "work-alias"
    work_alias.symlink_to(physical_work, target_is_directory=True)
    work = work_alias / "fixture"
    installer = ["bash", str(scripts / "install-github-runner.sh"), "OWNER/REPO", "fixture", str(archive), str(installation_root), str(work), "xcode-runnerkit,custom-host"]
    subprocess.run(installer, input="fixture-token\n", text=True, env=environment, check=True, capture_output=True)
    installation = installation_root / "fixture"
    received = json.loads((installation / ".runner").read_text())
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

    hosted = installer[:3] + ["hosted"] + installer[4:6] + [str(physical_work / "hosted"), "xcode-runnerkit", "host"]
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
    assert json.loads((installation / ".runner").read_text()) == received

    broken = root / "unavailable"
    broken.symlink_to(root / "missing-volume", target_is_directory=True)
    failure = subprocess.run(installer[:3] + ["unavailable"] + installer[4:6] + [str(broken / "work")], input="fixture-token\n", text=True, env=environment, capture_output=True)
    assert failure.returncode != 0 and "mkdir" in failure.stderr
    assert not (installation_root / "unavailable").exists()
    readonly = root / "readonly-work"
    readonly.mkdir()
    readonly.chmod(0o555)
    try:
        failure = subprocess.run(installer[:3] + ["readonly"] + installer[4:6] + [str(readonly)], input="fixture-token\n", text=True, env=environment, capture_output=True)
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
    runners, host, applications = root / "runner installations", root / "host data", root / "applications"
    command = ["bash", str(scripts / "install-runner-host.sh"), str(app), str(runners), str(host), str(applications)]
    subprocess.run(command, env=env, check=True, capture_output=True)
    plist = plistlib.loads((home / "Library/LaunchAgents/dev.lynnswap.XcodeRunnerHost.plist").read_bytes())
    assert plist["AssociatedBundleIdentifiers"] == ["dev.lynnswap.XcodeRunnerHost"]
    assert plist["ProgramArguments"] == [str(applications.resolve() / "XcodeRunnerHost.app/Contents/MacOS/xcode-runner-host"), "--runners-root", str(runners.resolve()), "--logs-directory", str(host.resolve() / "logs/runners")]
    (app / "Contents/MacOS/xcode-runner-host").write_text("updated executable")
    subprocess.run(command, env=env, check=True, capture_output=True)
    assert (applications / "XcodeRunnerHost.previous.app/Contents/MacOS/xcode-runner-host").read_text() == "first executable"
    assert (applications / "XcodeRunnerHost.app/Contents/MacOS/xcode-runner-host").read_text() == "updated executable"
    (tools / "codesign").write_text("#!/bin/bash\nif [[ \"$1\" == -dv ]]; then echo Signature=adhoc >&2; fi\n")
    failure = subprocess.run(command, env=env, capture_output=True)
    assert failure.returncode != 0 and b"certificate signing identity" in failure.stderr
    assert (applications / "XcodeRunnerHost.app/Contents/MacOS/xcode-runner-host").read_text() == "updated executable"

print("PASS: cache relocation, cleanup, runner storage, common-host opt-in and migration, app installation, update preservation, and signature requirements")
