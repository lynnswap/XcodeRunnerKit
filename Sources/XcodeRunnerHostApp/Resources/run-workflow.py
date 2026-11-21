"""Execute one Actions workflow using a reserved slot on a paired Mac."""
from collections import deque
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import uuid


def run(engine, checkout, output, file, event, repository, sha, ref, base, presentation, runner, *custom_labels, plan=False):
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
        if plan:
            env['XCODE_RUNNER_PLAN'] = '1'
        if 'XCODE_RUNNER_HOST_ROOT' in env:
            env['XCODE_RUNNER_WORKFLOW_DIRECTORY'] = str(scratch)
        head = ref.removeprefix('refs/heads/')
        payload = {'repository': {'full_name': repository, 'default_branch': base}, 'ref': ref, 'after': sha}
        if event.startswith('pull_request'):
            payload['pull_request'] = {'head': {'ref': head, 'sha': sha}, 'base': {'ref': base}}
        event_file = scratch / 'event.json'
        event_file.write_text(json.dumps(payload))
        args = [engine, event, '--json', '--directory', str(checkout), '--workflows', str(workflow),
                '--eventpath', str(event_file), '--concurrent-jobs', '1', '--no-cache-server',
                '--container-daemon-socket', '-', '--use-gitignore=false', '--action-cache-path', str(scratch/'actions'),
                '--env-file', '/dev/null', '--var-file', '/dev/null',
                '--secret-file', '/dev/null', '--input-file', '/dev/null']
        if not plan:
            args.extend(['--artifact-server-path', str(job / 'artifacts'), '--artifact-server-addr', '127.0.0.1',
                         '--artifact-server-port', '0'])
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
            jobs = {}
            recent = {}
            failure = None
            log_line = 1
            for line in child.stdout:
                message = line.rstrip()
                try:
                    record = json.loads(line)
                except ValueError:
                    pass
                else:
                    name = record.get('job', '').strip()
                    body = str(record.get('msg', '')).rstrip()
                    message = ('[' + name + '] ' if name else '') + body
                    if name:
                        job_id = record.get('jobID') or name
                        identity = (job_id, json.dumps(record.get('matrix', {}), sort_keys=True))
                        job_result = jobs.setdefault(identity, {'id': job_id, 'name': name, 'status': 'incomplete'})
                        if record.get('raw_output') and body:
                            step = record.get('step')
                            previous, lines = recent.setdefault(identity, (step, deque(maxlen=3)))
                            if previous != step:
                                lines = deque(maxlen=3)
                                recent[identity] = (step, lines)
                            lines.append(body[:240])
                        if record.get('stepConclusion', record.get('stepResult')) == 'failure' and 'step' not in job_result:
                            job_result['logLine'] = log_line
                            job_result['step'] = str(record.get('step') or body)[:240]
                            if identity in recent and recent[identity][0] == record.get('step'):
                                job_result['message'] = '\n'.join(recent[identity][1])
                        if 'jobResult' in record:
                            job_result['status'] = record['jobResult']
                            if job_result['status'] == 'success':
                                job_result.pop('step', None)
                                job_result.pop('message', None)
                                job_result.pop('logLine', None)
                if message.startswith(('Error:', 'panic:')):
                    failure = message[:480]
                if presentation == 'verbose' or (plan and message.startswith(('Error:', 'panic:'))):
                    print(message, flush=True)
                print(message, file=log, flush=True)
                log_line += message.count("\n") + 1
            status = child.wait()
            if plan and status and not failure:
                print(f'The workflow planner exited with status {status}.', file=sys.stderr)
            if not plan and not status and not any(j['status'] == 'success' for j in jobs.values()):
                failure = 'No jobs succeeded for this event and ref.'
                status = 1
        finally:
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGTERM)
                try:
                    child.wait(timeout=22)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait()
            child.stdout.close()
    if not plan:
        summary = {'status': 'failed' if status else 'passed', 'runner': runner, 'jobs': list(jobs.values())}
        if failure and not any(j['status'] == 'failure' for j in jobs.values()):
            summary['message'] = failure
        (job / 'summary.json').write_text(json.dumps(summary, ensure_ascii=False) + '\n')
    return status


def check_plan(engine, *labels):
    spec = json.load(sys.stdin)
    with tempfile.TemporaryDirectory(prefix='xrkw-plan-') as temp:
        checkout = Path(temp) / 'checkout'
        checkout.mkdir()
        directory = checkout / '.github/workflows'
        directory.mkdir(parents=True)
        for name, definition in spec.get('localWorkflows', {}).items():
            if Path(name).name != name:
                raise ValueError('Invalid local workflow filename.')
            (directory / name).write_text(definition)
        file = checkout / 'workflow.yml'
        file.write_text(spec['definition'])
        return run(engine, checkout, Path(temp) / 'output', file.name, spec['event'], spec['repository'],
                   spec['sha'], spec['ref'], spec['base'], 'concise', '', *labels, plan=True)


def snapshot_git(source, destination, sha, ref, repository):
    """A shallow HEAD and the index for local checkout, without the developer's config, hooks or other refs."""
    env = {'PATH': '/usr/bin:/bin', 'HOME': destination, 'GIT_CONFIG_NOSYSTEM': '1',
           'GIT_CONFIG_GLOBAL': '/dev/null', 'GIT_TERMINAL_PROMPT': '0'}
    def git(directory, *args, **options):
        return subprocess.run(['git', '-C', directory, *args], env=env, check=True, **options)
    fmt = git(source, 'rev-parse', '--show-object-format', stdout=subprocess.PIPE).stdout.decode().strip()
    git(destination, 'init', '-q', '--template=', '--object-format=' + fmt)
    git(destination, 'fetch', '--quiet', '--depth=1', '--no-tags', '--no-recurse-submodules',
        '--no-write-fetch-head', source, sha)
    if ref.startswith(('refs/heads/', 'refs/tags/')):
        git(destination, 'update-ref', ref, sha)
    if ref.startswith('refs/heads/'):
        git(destination, 'symbolic-ref', 'HEAD', ref)
    else:
        git(destination, 'update-ref', '--no-deref', 'HEAD', sha)
    # The host copies files into each job, so keep a ref even for a detached HEAD with no branches.
    git(destination, 'update-ref', 'refs/xcode-runner/snapshot', sha)
    git(destination, 'remote', 'add', 'origin', 'https://github.com/' + repository + '.git')
    index = git(source, 'ls-files', '--stage', '-z', stdout=subprocess.PIPE).stdout
    blobs = {entry.split(b' ', 2)[1] for entry in index.split(b'\x00') if entry and not entry.startswith(b'160000 ')}
    checked = git(destination, 'cat-file', '--batch-check', input=b'\n'.join(blobs), stdout=subprocess.PIPE).stdout
    missing = [line.split()[0] for line in checked.splitlines() if line.endswith(b' missing')]
    if missing:
        with tempfile.TemporaryFile() as pack:
            git(source, 'pack-objects', '--stdout', input=b'\n'.join(missing) + b'\n', stdout=pack)
            pack.seek(0)
            git(destination, 'index-pack', '--stdin', stdin=pack, stdout=subprocess.DEVNULL)
    git(destination, 'update-index', '-z', '--index-info', input=index)
    subprocess.run(['/usr/bin/tar', '-cf', str(Path(destination) / 'metadata.tar'), '--no-mac-metadata',
                    '--no-xattrs', '-C', destination, '.git'], check=True)


def terminate(signum, frame):
    raise SystemExit(128 + signum)


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, terminate)
    try:
        if sys.argv[1] == 'plan':
            sys.exit(check_plan(*sys.argv[2:]))
        if sys.argv[1] == 'snapshot-git':
            snapshot_git(*sys.argv[2:])
        else:
            sys.exit(run(*sys.argv[1:]))
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
