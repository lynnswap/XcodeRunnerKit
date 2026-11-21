"""Execute one Actions workflow using a reserved slot on a paired Mac."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import uuid


def run(engine, checkout, output, file, event, repository, sha, ref, base, *custom_labels):
    checkout = Path(checkout).resolve()
    workflow = (checkout / file).resolve()
    if not workflow.is_relative_to(checkout) or not workflow.is_file():
        raise ValueError('Workflow file must exist inside the transferred checkout.')
    job = Path(output) / str(uuid.uuid4()).upper()
    job.mkdir(parents=True)
    with tempfile.TemporaryDirectory(prefix='workflow-', dir=checkout.parent) as temporary, (job / 'workflow.log').open('w') as log:
        scratch = Path(temporary)
        home = scratch / 'home'
        home.mkdir()
        env = {'PATH': str(Path(engine).parent) + ':/usr/bin:/bin:/usr/sbin:/sbin',
               'HOME': str(home), 'LANG': 'en_US.UTF-8', 'TMPDIR': tempfile.gettempdir()}
        for key in ('DEVELOPER_DIR', 'XCODE_RUNNER_HOST_ROOT', 'XCODE_RUNNER_HOST_STORAGE_DIRECTORY'):
            if key in os.environ:
                env[key] = os.environ[key]
        if 'XCODE_RUNNER_HOST_ROOT' in env:
            env['XCODE_RUNNER_WORKFLOW_DIRECTORY'] = str(scratch)
            cli = Path(env['XCODE_RUNNER_HOST_ROOT']) / 'bin/xcode-runner'
            subprocess.run([cli, 'pool', 'configure', '--pool-directory', str(scratch / 'Pool'),
                            '--maximum-concurrent-jobs', '1'], env=env, check=True, stdout=subprocess.DEVNULL)
        head = ref.removeprefix('refs/heads/')
        payload = {'repository': {'full_name': repository, 'default_branch': base}, 'ref': ref, 'after': sha}
        if event.startswith('pull_request'):
            payload['pull_request'] = {'head': {'ref': head, 'sha': sha}, 'base': {'ref': base}}
        event_file = scratch / 'event.json'
        event_file.write_text(json.dumps(payload))
        args = [engine, event, '--json', '--directory', str(checkout), '--workflows', str(workflow),
                '--eventpath', str(event_file), '--concurrent-jobs', '1', '--no-cache-server',
                '--container-daemon-socket', '-', '--use-gitignore=false', '--action-cache-path', str(scratch/'actions'),
                '--artifact-server-path', str(job / 'artifacts'), '--artifact-server-addr', '127.0.0.1',
                '--artifact-server-port', '0', '--env-file', '/dev/null', '--var-file', '/dev/null',
                '--secret-file', '/dev/null', '--input-file', '/dev/null']
        for key, value in {'GITHUB_REPOSITORY': repository, 'SHA_REF': sha, 'GITHUB_REF': ref,
                           'GITHUB_BASE_REF': base if event.startswith('pull_request') else '',
                           'GITHUB_HEAD_REF': head if event.startswith('pull_request') else ''}.items():
            args.extend(['--env', key + '=' + value])
        for label in dict.fromkeys(custom_labels):
            args.extend(['--platform', label + '=-self-hosted'])
        # act searches for its user settings in HOME and its project settings in its launch directory.
        child = subprocess.Popen(args, cwd=scratch, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, text=True, errors='replace', start_new_session=True)
        try:
            completed = False
            for line in child.stdout:
                message = line.rstrip()
                try:
                    record = json.loads(line)
                except ValueError:
                    pass
                else:
                    completed |= 'jobResult' in record
                    prefix = '[{}] '.format(record['job']) if record.get('job') else ''
                    message = prefix + str(record.get('msg', '')).rstrip()
                print(message, flush=True)
                print(message, file=log, flush=True)
            status = child.wait()
            if not status and not completed:
                print('No jobs ran for this event and ref.', file=sys.stderr)
                status = 1
        finally:
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGTERM)
                try:
                    child.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait()
            child.stdout.close()
    print('Workflow log: ' + str(job / 'workflow.log'), flush=True)
    return status


def terminate(signum, frame):
    raise SystemExit(128 + signum)


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, terminate)
    try:
        sys.exit(run(*sys.argv[1:]))
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
