# Native GitHub Actions host

Use one macOS user for the host's repository runners. Each runner has its own
installation and checkout directory; every XcodeRunnerKit operation uses the
same host pool and compiler CAS.

## Prepare the Mac

Use macOS 26 or later, Xcode 27.1 or later, and a GUI login for the CI user.
Keep the Mac connected to power and the lid open. Enable Remote Login if the
host is administered over SSH.

Select Xcode per command or workflow with `DEVELOPER_DIR`; the setup does not
change `xcode-select`. Install the required Simulator runtimes through Xcode.
Check available runtime/device pairs with:

```sh
DEVELOPER_DIR=/Applications/Xcode_27.1.app/Contents/Developer \
xcrun simctl list runtimes --json
```

Projects that compile Metal sources also require the Metal Toolchain:

```sh
DEVELOPER_DIR=/Applications/Xcode_27.1.app/Contents/Developer \
xcodebuild -downloadComponent MetalToolchain
```

Build a verified XcodeRunnerKit checkout and install its executable on the host:

```sh
DEVELOPER_DIR=/Applications/Xcode_27.1.app/Contents/Developer \
swift build -c release --product xcode-runner
bash Scripts/install-host-tools.sh .build/release/xcode-runner "$(git rev-parse HEAD)"
```

The default host root is `~/Library/Application Support/XcodeRunnerKit`.
The installer keeps the previous executable for rollback and records the source
commit. Its user LaunchAgent runs `caffeinate -i -s` to prevent idle sleep and
system sleep on AC power. It requires the CI user's GUI launchd domain.

## Register repository runners

For a personal GitHub account, register runners separately for each repository.
An organization can instead provide organization runners with appropriate
repository access. Register enough listeners to admit jobs from several repos;
the shared pool controls how many Xcode payloads execute.

The installer pins the initial official macOS ARM64 runner to v2.338.0 and
verifies its release asset checksum. Download that archive from
[the official release](https://github.com/actions/runner/releases/tag/v2.338.0).
Copy the archive, installer, and both `cleanup-runner-temp` scripts from
`Scripts` to the same directory on the CI Mac.

On an authenticated controller with repository administration access, obtain a
short-lived registration token and send it directly to the host installer:

```sh
gh api -X POST repos/OWNER/REPO/actions/runners/registration-token --jq .token |
ssh CI_HOST 'bash "$HOME/Library/Caches/install-github-runner.sh" OWNER/REPO runner-name "$HOME/Library/Caches/actions-runner-osx-arm64-2.338.0.tar.gz"'
```

The controller's GitHub credential stays on the controller. The host keeps the
official runner's generated registration credentials. Each runner is installed
under `~/Library/XcodeRunnerKit/runners/<runner-name>`, with its own `_work` directory and an
official service plist in `~/Library/LaunchAgents`. Runner installation and hook
paths must contain no whitespace. Work directories use physical absolute paths;
if they contain spaces, quote the script placeholder in every consumer workflow
as shown below. Toolkit tools, keys, and CAS can remain in the
Application Support path. Installation starts the
service in `gui/<CI-user-uid>`. If startup fails, the installer reports the
registered runner and installed plist so they can be started after GUI login.

The default labels include `self-hosted`, `macOS`, `ARM64`, and
`xcode-runnerkit`. The optional sixth argument selects comma-separated custom
labels. Keep the labels selected by consumer workflows in that list; hardware
or host-specific labels belong in the installation configuration.

## Storage locations

XcodeRunnerKit explicitly passes `-derivedDataPath`, so Xcode's GUI DerivedData
preference does not select native CI storage. The workflow's
`--output-directory` contains a UUID directory for each operation, including
DerivedData, the result bundle, and the log. Dependency checkouts in
`RUNNER_TEMP` follow the official runner's work directory.

Keep the runner installation, tools, credentials, and host pool on the internal
disk. To place job data and the shared CAS on another disk:

1. Create a CI directory on the mounted disk and keep that disk mounted while
   the services run. Use physical work paths: conditional Git credential
   includes used by checkout actions do not reliably match symlink aliases. In the CI user's GUI session,
   allow macOS's removable-volume access prompt for the runner or its shell.
   A service can wait for this prompt during work-directory validation; confirm
   each configured service connects after permission is granted.
2. Pass a separate work directory for each runner as the installer's fifth
   argument. Relative input is based on the runner installation. Setup creates
   the directory, confirms it is writable, and stores its physical absolute path
   before registration. A work path containing spaces requires a quoted workflow
   shell template.
3. Pass the shared CAS directory as the host-tool installer's fourth argument.
   It keeps `<host-root>/CompilationCache` as a symlink to that directory, so
   existing consumer workflows keep using the same path.

For example, with a mounted CI storage directory:

```sh
ci_root="$HOME/Library/Application Support/XcodeRunnerKit"
bash Scripts/install-host-tools.sh .build/release/xcode-runner \
  "$(git rev-parse HEAD)" "$ci_root" "/Volumes/BuildStorage/CI/CompilationCache"

# Send the registration token on stdin as in the registration example.
bash Scripts/install-github-runner.sh OWNER/REPO runner-name \
  /path/to/actions-runner-osx-arm64-2.338.0.tar.gz \
  "$HOME/Library/XcodeRunnerKit/runners" "/Volumes/BuildStorage/CI/Work/runner-name"
```

The cache installer preserves an existing cache. If its location changes and
the old directory contains data, setup stops before replacing it. Drain and
stop all cache users, copy the data to the new location, and retain the old
directory for rollback before configuring the link. Never point simultaneous
runners at the same work directory or DerivedData directory.

For an existing runner, stop its service before copying the work directory.
Back up its `.runner` file and update only `workFolder` to the new absolute,
physical path; retain the registration and credentials. Verify the new
physical storage and native jobs before removing the old copy. Rollback restores
the saved `.runner` and cache location while all users are stopped.

The default Actions bash template does not quote its script placeholder.
For work paths containing spaces, each consumer workflow must select:

```yaml
defaults:
  run:
    shell: 'bash --noprofile --norc -e -o pipefail "{0}"'
```

Keep the physical work path even when using a space-free alias for other host
data. Choosing a symlink alias to avoid shell quoting can break private-repository
checkout authentication.

## Temporary-directory cleanup

The runner installer copies the two `cleanup-runner-temp` scripts into its
host-managed `~/Library/XcodeRunnerKit/hooks/<runner-name>` directory and sets `ACTIONS_RUNNER_HOOK_JOB_COMPLETED` in
`.env`. The completed hook removes symbolic links inside `RUNNER_TEMP` without
following directory links or removing their targets. This prevents the
official runner's parallel deletion from leaving a link behind after its target
has been deleted. Regular files and runner metadata remain for the official
cleanup; the shared CAS is outside `RUNNER_TEMP`.

For an existing runner, copy those scripts to its host-managed hooks directory outside the
runner installation,
set the completed-hook variable to the absolute `.sh` path in `.env`, and
restart the service. Preserve and compose an existing custom completed hook
rather than replacing it. Artifact upload steps run before this hook, including
action post steps. A cleanup error fails the hook and is visible in the job log.
Forcefully terminating the runner can prevent hooks from running.

Check cache configuration, existing-data preservation, and temporary links with:

```sh
python3 Scripts/check-host-setup.py
```

## Configure private SwiftPM dependencies

Run this from the authenticated controller for each private dependency:

```sh
python3 Scripts/configure-private-dependency.py CI_HOST OWNER/Dependency
```

The helper generates an SSH key on the Mac, registers its public key as a
read-only deploy key for that repository, and configures a dedicated SSH alias.
It uses GitHub's published SSH host keys from the official metadata API.
Existing matching read-only keys are reused; private key material stays on the
Mac. Run setup serially before starting consumers.

Pass these values to the child Xcode operation:

```sh
--environment "SWIFTPM_MIRROR_CONFIG=$ci_root/mirrors.json" \
--environment "GIT_SSH_COMMAND='$ci_root/bin/git-ssh'" \
--environment "GIT_TERMINAL_PROMPT=0"
```

The SwiftPM mirror file matches complete dependency URLs and maps them to
repository-specific SSH aliases. Invoke the helper with the spelling used in
the dependency URL; it retains both that spelling and GitHub's canonical name,
with and without .git. Unmapped dependencies keep their usual HTTPS path.
GIT_SSH_COMMAND must quote the wrapper path: SwiftPM's default for that variable
takes precedence over GIT_SSH.
A workflow's `GITHUB_TOKEN` handles checkout of that workflow's own repository;
it does not grant access to other private dependency repositories. Add a deploy
key mapping before introducing a new private dependency.

## Run workflows

Native consumer workflows execute code trusted by the host owner. Jobs under
the same macOS user share filesystem and credential access; per-job directories,
owned Simulators, and the pool do not isolate malicious code.

XcodeRunnerKit's own public CI uses GitHub-hosted macOS runners for pull requests,
main pushes, and manual dispatches. Do not register this public package on a Mac
that holds private credentials. Use isolated runners for untrusted contribution
workflows; reviewing or merging code does not make the native host a sandbox.

All repositories use:

```sh
ci_root="$HOME/Library/Application Support/XcodeRunnerKit"
"$ci_root/bin/xcode-runner" test \
  --package "$GITHUB_WORKSPACE" --scheme PackageName \
  --destination 'platform=macOS,arch=arm64' \
  --pool-directory "$ci_root/Pool" --maximum-concurrent-jobs 2 \
  --compilation-cache "$ci_root/CompilationCache" \
  --output-directory "$RUNNER_TEMP/XcodeRunnerOutput" \
  -- -parallel-testing-enabled NO -jobs 4
```

For iOS, supply the supported Simulator runtime/device identifiers instead of
a macOS destination. Creation, execution, and device deletion hold one slot.
For apps, use the application's workspace and scheme. Consumer-owned plugin
environment values and package paths belong in that consumer's workflow.
Keep mutable SwiftPM checkouts separate between concurrent jobs.

Consumer workflows should upload logs and result bundles with short retention.
GitHub runner temporary directories are cleaned after jobs; download needed
artifacts before they expire. Native-host CAS files stay outside job temporary directories; the host root's
`CompilationCache` path can point to another disk. The package's hosted CI uses job-local CAS
and one-day artifact retention.

## Service operations and recovery

Runner service stdout/stderr are in `~/Library/Logs/actions.runner.*`.
The official runner's `_diag` directory contains listener and worker diagnostics.
Xcode output logs and result bundles are in the operation's output directory.

In a runner installation directory, use `./svc.sh status` to inspect the service.
For explicit GUI-domain control, read the installed plist from `.service` and
use its label:

```sh
plist="$(cat .service)"
label="$(/usr/libexec/PlistBuddy -c 'Print Label' "$plist")"
launchctl print "gui/$(id -u)/$label"
launchctl kickstart -k "gui/$(id -u)/$label"
```

Stop accepting jobs and let active operations finish before changing capacity,
pruning caches, or updating host tools. Remove the pool directory only after
all its users have stopped. Keep the same capacity in every workflow.
For cache retention, inspect disk usage and remove an old CAS while its users
are stopped; DerivedData and result retention are separate.

The official GitHub runner retains its normal automatic-update behavior.
Update Xcode and the toolkit during a maintenance window, verify the configured
runtime/device pairing, then run the consumer workflows again. For rollback,
restore both `bin/xcode-runner.previous` and `bin/xcode-runner.commit.previous`
to `bin/xcode-runner` and `bin/xcode-runner.commit` while the runners are stopped.
If the previous executable had no commit marker, the installer leaves no backup
marker; remove the current marker when restoring that executable so diagnostics
do not report the newer revision.

After a host reboot, authenticate FileVault and restore the CI user's GUI
session; user LaunchAgents then start the installed services. On Apple silicon
with macOS 26 or later, Remote Login and available networking also permit
FileVault unlock over SSH. This does not remove the authentication requirement.
See [Apple's FileVault guide](https://support.apple.com/guide/deployment/intro-to-filevault-dep82064ec40/web).
Check the services and GitHub runner online status after recovery.

Managed SIGINT/SIGTERM cancellation tears down Xcode and deletes its owned
Simulator. A forcibly killed wrapper can leave a device behind. Quiesce the
runners, inspect the operation's UDID in its log or failure, and delete only that
identified device after resolving the failure. Keep unrelated devices intact.
