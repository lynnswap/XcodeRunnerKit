#!/usr/bin/env python3
"""Check the actual host process against service fixtures and a launchd job."""
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import tempfile
import time

executable = str(Path(sys.argv[1]).resolve())
scripts = Path(__file__).resolve().parent


def wait_for(predicate, description, seconds=15):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.1)
    raise AssertionError(description)


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def fixture(root, name):
    directory = root / name
    directory.mkdir()
    (directory / '.runner').write_text('{}')
    (directory / '.xcode-runner-host').touch()
    (directory / 'worker.py').write_text('''import json, os, signal, time
from pathlib import Path
def stop(*args):
    Path('stopping').touch()
    delay = Path('stop-delay')
    if delay.exists(): time.sleep(float(delay.read_text()))
    Path('stopped').touch()
    raise SystemExit(0)
signal.signal(signal.SIGINT, stop)
signal.signal(signal.SIGTERM, stop)
Path('pid.json').write_text(json.dumps({'pid':os.getpid(), 'group':os.getpgrp()}))
while True: time.sleep(1)
''')
    (directory / 'runsvc.sh').write_text('''#!/bin/bash
trap 'kill -INT "$PID"' TERM INT
python3 worker.py &
PID=$!
wait "$PID"
trap - TERM INT
wait "$PID"
''')
    return directory


with tempfile.TemporaryDirectory(prefix='RunnerHost test 日本語 ') as temporary:
    root = Path(temporary)
    runners = root / 'runners'
    runners.mkdir()
    first = fixture(runners, 'first')
    excluded = fixture(runners, 'individual')
    (excluded / '.service').touch()
    arguments = [executable, '--runners-root', str(runners), '--logs-directory', str(root/'logs')]
    with (root/'host.log').open('w') as log:
        host = subprocess.Popen([Path(executable).name]+arguments[1:], cwd=root,
                                env={**os.environ, 'PATH':str(Path(executable).parent)+os.pathsep+os.environ['PATH']},
                                stdout=log, stderr=log)
        try:
            wait_for(lambda:(first/'pid.json').exists(), 'First runner did not start')
            first_pid = json.loads((first/'pid.json').read_text())['pid']
            assert not (excluded/'pid.json').exists()
            duplicate = subprocess.run(arguments, capture_output=True, timeout=10)
            assert duplicate.returncode != 0 and b'Another runner host' in duplicate.stderr
            second = fixture(runners, 'second')
            wait_for(lambda:(second/'pid.json').exists(), 'New runner was not discovered')
            second_pid = json.loads((second/'pid.json').read_text())['pid']
            first_group = json.loads((first/'pid.json').read_text())['group']
            second_group = json.loads((second/'pid.json').read_text())['group']
            assert first_group != second_group
            legacy = fixture(runners, 'legacy-migration')
            (legacy/'.xcode-runner-host').unlink()
            (legacy/'stop-delay').write_text('8')
            (legacy/'bin').mkdir()
            (legacy/'bin/runsvc.sh').write_text((legacy/'runsvc.sh').read_text())
            legacy_label = f'dev.lynnswap.XcodeRunnerHost.legacy.{os.getpid()}'
            legacy_target = f'gui/{os.getuid()}/{legacy_label}'
            legacy_plist = root/'legacy.plist'
            legacy_plist.write_bytes(plistlib.dumps({
                'Label':legacy_label, 'ProgramArguments':['/bin/bash',str(legacy/'runsvc.sh')],
                'WorkingDirectory':str(legacy), 'RunAtLoad':True,
            }))
            (legacy/'.service').write_text(str(legacy_plist)+'\n')
            subprocess.run(['launchctl','bootstrap',f'gui/{os.getuid()}',str(legacy_plist)],check=True)
            try:
                wait_for(lambda:(legacy/'pid.json').exists(), 'Individual service did not start')
                legacy_pid = json.loads((legacy/'pid.json').read_text())['pid']
                migration = subprocess.Popen(['bash',str(scripts/'enable-hosted-runner.sh'),str(legacy)],stdout=log,stderr=log)
                wait_for(lambda:(legacy/'stopping').exists(), 'Individual service did not start shutdown')
                assert alive(legacy_pid) and not (legacy/'.xcode-runner-host').exists()
                assert migration.wait(timeout=20) == 0
                assert not alive(legacy_pid)
                wait_for(lambda:json.loads((legacy/'pid.json').read_text())['pid']!=legacy_pid, 'Migrated service did not start')
            finally:
                subprocess.run(['launchctl','bootout',legacy_target],capture_output=True)
            crashed = fixture(runners, 'crashed-helper')
            wait_for(lambda:(crashed/'pid.json').exists(), 'Helper-crash fixture did not start')
            crash_process = json.loads((crashed/'pid.json').read_text())
            assert crash_process['group'] not in {first_group, second_group}
            os.kill(crash_process['group'], signal.SIGKILL)
            wait_for(lambda:not alive(crash_process['pid']), 'Runner survived its helper crash')
            assert alive(first_pid) and alive(second_pid)
            (crashed/'.xcode-runner-host').unlink()
            instant = fixture(runners, 'instant-exit')
            (instant/'runsvc.sh').write_text('#!/bin/bash\nexit 0\n')
            instant_log = root/'logs/instant-exit.log'
            wait_for(lambda:instant_log.exists() and 'Official runner service ended' in instant_log.read_text(), 'Immediate service exit was not observed')
            (first/'.xcode-runner-host').unlink()
            wait_for(lambda:(first/'stopped').exists() and not alive(first_pid), 'Removed runner did not stop')
            host.send_signal(signal.SIGTERM)
            assert host.wait(timeout=15) == 0
            assert (second/'stopped').exists() and not alive(second_pid)
        finally:
            if host.poll() is None:
                host.send_signal(signal.SIGTERM)
                try:
                    host.wait(timeout=45)
                except subprocess.TimeoutExpired:
                    host.kill()
                    host.wait()
                    for directory in runners.iterdir():
                        if (directory/'pid.json').exists():
                            pid = json.loads((directory/'pid.json').read_text())['pid']
                            if alive(pid): os.kill(pid, signal.SIGTERM)
        host_log = (root/'host.log').read_text()
        print(host_log)
        assert 'service ended: Error' not in host_log

    launched = fixture(runners, 'launchd')
    (launched/'stop-delay').write_text('8')
    label = f'dev.lynnswap.XcodeRunnerHost.test.{os.getpid()}'
    target = f'gui/{os.getuid()}/{label}'
    plist = root/'service.plist'
    plist.write_bytes(plistlib.dumps({
        'Label':label, 'ProgramArguments':arguments, 'RunAtLoad':True, 'ThrottleInterval':1,
        'StandardOutPath':str(root/'launchd.stdout'),
        'StandardErrorPath':str(root/'launchd.stderr'),
    }))
    subprocess.run(['launchctl','bootstrap',f'gui/{os.getuid()}',str(plist)],check=True)
    try:
        wait_for(lambda:(launched/'pid.json').exists(), 'LaunchAgent runner did not start')
        process = json.loads((launched/'pid.json').read_text())
        subprocess.run(['launchctl','kill','SIGKILL',target],check=True)
        wait_for(lambda:(launched/'stopping').exists(), 'Old service did not start shutdown')
        # The old helper still owns the lock during this delayed shutdown.
        assert alive(process['pid'])
        failed_start = subprocess.run(arguments, capture_output=True, timeout=10)
        assert failed_start.returncode != 0 and b'Another runner host' in failed_start.stderr
        assert json.loads((launched/'pid.json').read_text())['pid'] == process['pid']
        subprocess.run(['launchctl','kickstart',target],check=True)
        wait_for(lambda:not alive(process['pid']), 'Runner helper left a runner alive after host crash')
        (launched/'pid.json').unlink()
        subprocess.run(['launchctl','kickstart',target],check=True)
        wait_for(lambda:(launched/'pid.json').exists(), 'LaunchAgent did not restart')
        restarted = json.loads((launched/'pid.json').read_text())
        assert restarted['pid'] != process['pid']
    finally:
        subprocess.run(['launchctl','bootout',target],check=True)
    wait_for(lambda:not alive(restarted['pid']), 'Runner survived service removal')

    subprocess.run(['bash',str(scripts/'build-runner-host.sh'),'-',str(root/'packaging'),executable],check=True,capture_output=True)
    tools = root/'tools'
    tools.mkdir()
    fake_launchctl = tools/'launchctl'
    fake_launchctl.write_text('#!/bin/bash\nexit 0\n')
    fake_launchctl.chmod(0o755)
    environment = {**os.environ, 'HOME':str(root/'home'), 'PATH':str(tools)+os.pathsep+os.environ['PATH']}
    rejected = subprocess.run(['bash',str(scripts/'install-runner-host.sh'),str(root/'packaging/XcodeRunnerHost.app')],env=environment,capture_output=True)
    assert rejected.returncode != 0 and b'certificate signing identity' in rejected.stderr
    assert not (root/'home/Applications').exists()

print('PASS: multiple runners, separate service groups, discovery, individual-service exclusion, singleton, graceful shutdown, host/helper crash cleanup, immediate service exit, and restart')
