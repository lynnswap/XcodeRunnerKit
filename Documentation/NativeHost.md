# GitHub Actions host setup

XcodeRunnerHost is a macOS menu bar app that starts official GitHub Actions
runners and manages their Xcode job limit.

Use an Apple silicon Mac with macOS 26 or later and Xcode 27.1 or later.
Run the setup as the macOS user that will run CI, and keep that user logged in.
Jobs share this user's files and credentials.

## Install

From a checkout on the CI Mac, build and install the CLI:

```sh
export DEVELOPER_DIR=/Applications/Xcode_27.1.app/Contents/Developer

swift build -c release --product xcode-runner
bash Scripts/install-host-tools.sh .build/release/xcode-runner \
  "$(git rev-parse HEAD)" /path/to/JobData
```

Replace `/path/to/JobData` with the folder for checkouts, build output, and the
compiler cache. Omit that argument to use
`~/Library/Application Support/XcodeRunnerKit/Storage`.

For an update, wait for running CI jobs to finish before installing. The
installer stops the current host and its runner services.

Build and install the app with a certificate from
`security find-identity -v -p codesigning`:

```sh
bash Scripts/build-runner-host.sh "SIGNING_IDENTITY" .build/RunnerHost
bash Scripts/install-runner-host.sh .build/RunnerHost/XcodeRunnerHost.app
```

The installer places the app in `~/Applications` and starts it through a user
LaunchAgent. An ad-hoc signature (`-`) is not accepted. Use the same signing
identity for updates so macOS can retain the app's access permissions.

Complete Xcode's license acceptance and first-launch setup before starting jobs.
Xcode installation and setup that requires administrator access remain manual.
Jobs download a missing [managed Simulator runtime](../README.md#ios-simulators)
when requested. If xcodebuild reports a missing Metal Toolchain, the runner
downloads it and retries the operation once. Downloads use the job's selected
Xcode, including `DEVELOPER_DIR`. Download progress appears in workflow output;
Metal download output and both build attempts also remain in the job log. A
failed download stops the job.

## Connect GitHub

Click the hammer icon in the menu bar and open **Settings…**.

1. Leave **Organization** blank for personal repositories, or enter the
   organization name for organization repositories. Choose **Create GitHub App…**,
   then name the app and confirm its creation in the browser. Permissions are
   filled in automatically.
2. The installation page opens. Select the repositories this Mac will run.
3. Return to settings, choose **Sign In…**, and approve access in the browser.
4. Select the repositories to manage, enter **Maximum concurrent Xcode jobs**,
   and choose **Apply**.

The app saves its client secret and login tokens in Keychain. It refreshes
expiring tokens automatically. To change repository access later, choose
**Install App…**, then **Reload Repositories**.

For organization repositories, you need permission to create and install the
GitHub App in that organization. The signed-in user also needs repository
administration access to manage runners.

### What the limit controls

Set the limit to 24 to allow 24 XcodeRunnerKit builds or test runs across the Mac.
The app registers 24 runners for each selected repository, so any one repository
can use the full limit.
GitHub's in-progress count also includes checkout, uploads, and jobs waiting
for an Xcode slot.

Lowering the limit lets running operations finish. Extra runner registrations
stay in place. Deselecting a repository leaves its existing runners running;
it stops the app from managing their count.

The same limit caps the total managed Simulators across Xcode versions,
runtimes, and device types. The host removes idle devices above the limit.
It also deletes devices that have been idle for 20 minutes, even below the limit.
Matching devices are reused in order of most recent return. If space is needed,
the oldest returned idle devices are removed first.
Devices in use finish before they are removed, so lowering the limit can
temporarily leave more devices than the new limit. Runner registrations and
GitHub's in-progress job count can still be higher.

Settings shows each repository's registered, online, and busy runner counts,
plus any error. The host retries synchronization every five minutes while signed
in. **Disconnect** removes local login tokens and stops registration management;
it leaves existing runner services running.

## Configure a workflow

Use labels that match your runners. New runners include `xcode-runnerkit`
and copy custom labels shared by existing managed runners. Labels assigned to
only some runners, such as `ci-interactive`, need separate configuration.

A macOS package test job can use:

```yaml
jobs:
  test:
    runs-on: [self-hosted, macOS, ARM64, xcode-runnerkit]
    defaults:
      run:
        shell: 'bash --noprofile --norc -e -o pipefail "{0}"'
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - name: Test
        run: |
          exec "$XCODE_RUNNER_HOST_ROOT/bin/xcode-runner" test \
            --package "$GITHUB_WORKSPACE" --scheme PackageName \
            --destination 'platform=macOS,arch=arm64'
```

Replace `PackageName` with your scheme. Use `--workspace` or `--project` for
an app, or the [Simulator options](../README.md#ios-simulators) for iOS tests.

Keep `"{0}"` quoted in the shell template: job-data paths can contain spaces.
Use `exec` in shell wrappers so cancellation reaches `xcode-runner`.
The host supplies the shared pool, compiler cache, and output directory;
those flags are not needed in each workflow.

To select a custom build service for hosted jobs, save its executable path:

```sh
"$HOME/Library/Application Support/XcodeRunnerKit/bin/xcode-runner" \
  host build-service configure \
  --path /path/to/SWBBuildServiceBundle
```

The next job reads the saved path directly. No host restart or login-time
environment setup is needed. A workflow can override it with
`--build-service-path /path/to/SWBBuildServiceBundle`. Run
`host build-service status --json` to inspect the saved selection, or
`host build-service configure` without `--path` to clear the override.
For the Homebrew package, the executable is
`$(brew --prefix custom-xcode-build-service)/libexec/libexec/swift-build/SWBBuildService.bundle/SWBBuildServiceBundle`.

### Private SwiftPM dependencies

For each private dependency, run this on a controller with `gh` authenticated:

```sh
python3 Scripts/configure-private-dependency.py CI_HOST OWNER/Dependency
```

The helper creates a read-only deploy key on the CI Mac and configures a SwiftPM
mirror. The workflow's own `GITHUB_TOKEN` does not provide access to other private
repositories.

Add these options to the Xcode command:

```sh
--environment "SWIFTPM_MIRROR_CONFIG=$XCODE_RUNNER_HOST_ROOT/mirrors.json" \
--environment "GIT_SSH_COMMAND='$XCODE_RUNNER_HOST_ROOT/bin/git-ssh'" \
--environment GIT_TERMINAL_PROMPT=0
```

Keep the inner quotes around the `git-ssh` path because it contains spaces.

## Storage

The job-data folder contains:

| Directory | Contents |
| --- | --- |
| `Work/<runner-name>` | Checkouts and temporary job files |
| `CompilationCache` | Shared compiler cache |
| `Build/<operation-UUID>` | DerivedData, logs, and result bundles |

Tools and service logs stay under
`~/Library/Application Support/XcodeRunnerKit`. Runner installations stay under
`~/Library/XcodeRunnerKit/runners`.

To move job data, choose a folder in **Storage** and select **Save**. The change
takes effect on the next host launch. Wait for running jobs and other users of
that data to finish, then restart the host.

The host copies the data and keeps the originals. The destination must not
already contain `Work`, `CompilationCache`, or `Build`. If startup shows
**Needs attention**, read the storage error, restore access to the original
folder or choose another destination, and restart.

For removable storage, keep the volume mounted and approve the app's initial
volume-access prompt. If you use custom `includeIf.gitdir` authentication rules,
update them for the new physical work path before restarting.

## Updates and troubleshooting

To update, repeat [the installation steps](#install). The installers keep the
previous app as
`XcodeRunnerHost.previous.app` and the previous CLI as `bin/xcode-runner.previous`.

Inspect or restart the host with:

```sh
launchctl print "gui/$(id -u)/dev.lynnswap.XcodeRunnerHost"
launchctl kickstart -k "gui/$(id -u)/dev.lynnswap.XcodeRunnerHost"
```

Logs are under `~/Library/Application Support/XcodeRunnerKit/logs`:

- `runner-host.stdout.log` and `runner-host.stderr.log`: app startup and storage errors
- `runners/<runner-name>.log`: runner service output

GitHub's runner diagnostics are in each installation's `_diag` directory.
Xcode logs and result bundles are in the job-data folder's `Build` directory.
After a Mac reboot, log into the CI account to start its LaunchAgent.

## Existing GitHub Apps and runners

To use an existing GitHub App, enable **Device Flow** and grant repository
**Administration: Read and write** and **Metadata: Read-only**. Disable its
webhook and keep user token expiration enabled. Install it for the repositories,
then enter its Client ID and app slug under **Existing GitHub App**. Choose
**Sign In…** and enter the displayed code on GitHub. The slug is the name after
`github.com/apps/`.

For manual registration, download the official
[macOS ARM64 runner v2.338.0](https://github.com/actions/runner/releases/tag/v2.338.0)
and run from the checkout on the CI Mac with `gh` authenticated:

```sh
gh api -X POST repos/OWNER/REPO/actions/runners/registration-token --jq .token |
  bash Scripts/install-github-runner.sh OWNER/REPO runner-name /path/to/runner.tar.gz
```

The optional fourth argument sets custom labels; the fifth sets the SHA-256
digest when using a different official release.

To move an existing runner from its individual service to the host, first drain
its jobs. Its work folder must already be the physical
`<job-data>/Work/<runner-name>` path. Then run:

```sh
bash Scripts/enable-hosted-runner.sh "$HOME/Library/XcodeRunnerKit/runners/runner-name"
```

This keeps the registration and credentials, removes the individual service,
and lets the common host start the runner. Runners with an individual `.service`
are otherwise left unchanged.
