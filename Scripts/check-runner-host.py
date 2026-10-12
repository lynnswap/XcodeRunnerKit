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


def stop_host(host, runners):
    if host.poll() is not None:
        return
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


def fixture(root, name):
    directory = root / name
    directory.mkdir()
    home = root.parents[2]
    work = home/'Library/Application Support/XcodeRunnerKit/Storage/Work'/name
    work.mkdir(parents=True, exist_ok=True)
    (directory / '.runner').write_text(json.dumps({'agentName': name, 'workFolder': str(work.resolve())}))
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
pending = Path('pid.pending')
pending.write_text(json.dumps({'pid':os.getpid(), 'group':os.getpgrp(),
                              'storage':os.environ.get('XCODE_RUNNER_HOST_STORAGE_DIRECTORY'),
                              'hostRoot':os.environ.get('XCODE_RUNNER_HOST_ROOT')}))
pending.replace('pid.json')
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
    home = root / 'home'
    host_root = home/'Library/Application Support/XcodeRunnerKit'
    runners = home/'Library/XcodeRunnerKit/runners'
    runners.mkdir(parents=True)
    first = fixture(runners, '.hidden-first')
    excluded = fixture(runners, 'individual')
    (excluded / '.service').touch()
    arguments = [executable, '--home-directory', str(home)]
    with (root/'host.log').open('w') as log:
        host = subprocess.Popen([Path(executable).name]+arguments[1:], cwd=root,
                                env={**os.environ, 'PATH':str(Path(executable).parent)+os.pathsep+os.environ['PATH']},
                                stdout=log, stderr=log)
        try:
            wait_for(lambda:(first/'pid.json').exists(), 'Hidden runner did not start')
            first_pid = json.loads((first/'pid.json').read_text())['pid']
            first_environment = json.loads((first/'pid.json').read_text())
            assert first_environment['storage'] == str((host_root/'Storage').resolve())
            assert Path(first_environment['hostRoot']).resolve() == host_root.resolve()
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
            instant_log = host_root/'logs/runners/instant-exit.log'
            wait_for(lambda:instant_log.exists() and 'Official runner service ended' in instant_log.read_text(), 'Immediate service exit was not observed')
            (first/'.xcode-runner-host').unlink()
            wait_for(lambda:(first/'stopped').exists() and not alive(first_pid), 'Removed runner did not stop')
            host.send_signal(signal.SIGTERM)
            assert host.wait(timeout=15) == 0
            assert (second/'stopped').exists() and not alive(second_pid)
        finally:
            stop_host(host, runners)
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
    assert not (host_root/'Pool').exists(), 'Host status reads configured an unused pool'

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

with tempfile.TemporaryDirectory(prefix='RunnerHost blocked pool ') as temporary:
    root = Path(temporary)
    home = root/'home'
    host_root = home/'Library/Application Support/XcodeRunnerKit'
    runners = home/'Library/XcodeRunnerKit/runners'
    runners.mkdir(parents=True)
    pool = host_root/'Pool'
    pool.mkdir(parents=True)
    ready = root/'pool-held'
    holder = subprocess.Popen([sys.executable, '-c', '''import fcntl, sys, time
from pathlib import Path
with open(sys.argv[1], 'a+b') as coordinator:
    fcntl.flock(coordinator, fcntl.LOCK_EX)
    ready = Path(sys.argv[2])
    pending = ready.with_suffix('.pending')
    pending.write_text('locked')
    pending.replace(ready)
    while True: time.sleep(1)
''', str(pool/'pool.lock'), str(ready)])
    try:
        wait_for(ready.exists, 'External process did not hold the pool coordinator')
        first = fixture(runners, 'first')
        arguments = [executable, '--home-directory', str(home)]
        with (root/'host.log').open('w') as log:
            host = subprocess.Popen(arguments, stdout=log, stderr=log)
            try:
                wait_for(lambda:(first/'pid.json').exists(), 'Pool status wait prevented initial runner discovery')
                first_pid = json.loads((first/'pid.json').read_text())['pid']
                second = fixture(runners, 'second')
                wait_for(lambda:(second/'pid.json').exists(), 'Pool status wait prevented new runner discovery')
                second_pid = json.loads((second/'pid.json').read_text())['pid']
                (first/'.xcode-runner-host').unlink()
                wait_for(lambda:(first/'stopped').exists() and not alive(first_pid), 'Pool status wait prevented runner removal')
                assert holder.poll() is None
                host.send_signal(signal.SIGTERM)
                assert host.wait(timeout=15) == 0
                assert (second/'stopped').exists() and not alive(second_pid)
                assert holder.poll() is None, 'Pool coordinator must remain held throughout host shutdown'
            finally:
                stop_host(host, runners)
    finally:
        holder.terminate()
        holder.wait(timeout=10)
    assert not (pool/'capacity').exists(), 'Host status reads configured an unused pool'

with tempfile.TemporaryDirectory(prefix='RunnerHost storage change ') as temporary:
    root = Path(temporary)
    home = root/'home'
    host_root = home/'Library/Application Support/XcodeRunnerKit'
    runners = home/'Library/XcodeRunnerKit/runners'
    runners.mkdir(parents=True)
    first = fixture(runners, 'first')
    credential = b'unchanged registration credentials'
    (first/'.credentials').write_bytes(credential)
    arguments = [executable, '--home-directory', str(home)]
    with (root/'host.log').open('w') as log:
        host = subprocess.Popen(arguments, stdout=log, stderr=log)
        try:
            wait_for(lambda:(first/'pid.json').exists(), 'Storage fixture runner did not start')
            original_process = json.loads((first/'pid.json').read_text())
            original_registration = (first/'.runner').read_bytes()
            source = Path((host_root/'storage-directory').read_text())
            for name in ['Work', 'CompilationCache', 'Build']:
                (source/name/'retained').write_text('preserved job data')
            destination = root/'New job data'
            destination.mkdir()
            (host_root/'requested-storage-directory').write_text(str(destination.resolve()))
            time.sleep(3)
            assert alive(original_process['pid']), 'Saving a storage selection stopped an active runner'
            assert (first/'.runner').read_bytes() == original_registration
            assert (host_root/'storage-directory').read_text() == str(source)
            stop_host(host, runners)
            assert not alive(original_process['pid'])
            (first/'pid.json').unlink()
            host = subprocess.Popen(arguments, stdout=log, stderr=log)
            wait_for(lambda:(first/'pid.json').exists(), 'Runner did not start after storage migration')
            migrated_process = json.loads((first/'pid.json').read_text())
            assert migrated_process['storage'] == str(destination.resolve())
            registration = json.loads((first/'.runner').read_text(encoding='utf-8-sig'))
            assert registration['workFolder'] == str((destination/'Work/first').resolve())
            assert (first/'.credentials').read_bytes() == credential
            for name in ['Work', 'CompilationCache', 'Build']:
                assert (source/name/'retained').read_text() == 'preserved job data'
                assert (destination/name/'retained').read_text() == 'preserved job data'
            collision = root/'Occupied storage'
            (collision/'Work').mkdir(parents=True)
            (collision/'Work/foreign').write_text('keep existing data')
            (host_root/'requested-storage-directory').write_text(str(collision.resolve()))
            stop_host(host, runners)
            (first/'pid.json').unlink()
            host = subprocess.Popen(arguments, stdout=log, stderr=log)
            time.sleep(3)
            assert host.poll() is None, 'Storage failure exited the host instead of keeping settings available'
            assert not (first/'pid.json').exists(), 'A listener started after storage migration failed'
            assert (host_root/'storage-directory').read_text() == str(destination.resolve())
            assert (collision/'Work/foreign').read_text() == 'keep existing data'
            replacement = root/'Replacement storage'
            replacement.mkdir()
            (host_root/'requested-storage-directory').write_text(str(replacement.resolve()))
            stop_host(host, runners)
            host = subprocess.Popen(arguments, stdout=log, stderr=log)
            wait_for(lambda:(first/'pid.json').exists(), 'Saving another folder did not recover the next host launch')
            assert json.loads((first/'pid.json').read_text())['storage'] == str(replacement.resolve())
            assert (replacement/'Work/retained').read_text() == 'preserved job data'
        finally:
            stop_host(host, runners)

print('PASS: runner lifecycle, hidden runner discovery, pool-lock independence, storage snapshot, next-launch migration, retained source and credentials, visible failure without listeners, and recovery with another storage folder')
