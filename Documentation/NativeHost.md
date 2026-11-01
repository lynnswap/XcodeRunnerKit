# GitHub Actions host setup

XcodeHomeRunner is a macOS menu bar app that starts official GitHub Actions
runners and manages their Xcode job limit.

Use an Apple silicon Mac with macOS 26 or later and Xcode 27.1 or later.
Run the setup as the macOS user that will run CI, and keep that user logged in.
Jobs share this user's files and credentials.

## Install

Build the app from a checkout on a Mac whose Xcode is signed in to your Apple
Developer account (**Xcode > Settings > Accounts**) and has your Developer ID
Application certificate. Replace `TEAM_ID` with your team identifier:

```sh
bash Scripts/build-runner-host.sh TEAM_ID .build/RunnerHost
```

Copy `.build/RunnerHost/XcodeHomeRunner.app` to the CI Mac and run the installer
inside it there. The CI Mac needs no checkout:

```sh
bash XcodeHomeRunner.app/Contents/Resources/HostSetup/install-runner-host.sh \
  XcodeHomeRunner.app /path/to/JobData
```

Replace `/path/to/JobData` with the folder for checkouts, build output, and the
compiler cache. Omit that argument to use
`~/Library/Application Support/XcodeRunnerKit/Storage`.

The app contains the `xcode-runner` CLI. The installer links
`~/Library/Application Support/XcodeRunnerKit/bin/xcode-runner` to the CLI in
the installed app, so jobs, runner setup, and SSH sessions always use the CLI
from the same build as the app. It also keeps the Mac awake with a `caffeinate`
LaunchAgent while you are logged in.

For an update, wait for running and queued CI jobs to finish, then run the new
app's installer. It stops the current host and its runner services before
replacing the app and its CLI.

The build script archives `XcodeRunnerKit.xcworkspace` and exports it for
Developer ID distribution with Xcode-managed signing. The app, CLI, and
installers use the fixed `lynnpd.xcodehomerunner` identifiers for the bundle,
LaunchAgent, and settings service, so a build with another bundle identifier
must change all of them.

The installer places the app in `~/Applications` and starts it through a user
LaunchAgent. An ad-hoc signature (`-`) is not accepted. Use the same team for
updates so macOS can retain the app's access permissions.

Hosts installed before the app was renamed from XcodeRunnerHost are migrated by
the same installer: it stops the `dev.lynnswap.XcodeRunnerHost` service, removes
its LaunchAgent, and keeps the old app as `XcodeRunnerHost.previous.app`. Runner
registrations and job data stay in place. GitHub login tokens are not carried
over, because they belong to the old app's Keychain items.

Hosts that signed in through a GitHub App created for that host, including
hosts migrated from XcodeRunnerHost, keep their repository selection but must
sign in again through the shared app. Follow [Connect GitHub](#connect-github)
and install the shared app on the same repositories. You can then delete the
app created for the host on GitHub; this also invalidates the client secret
that earlier versions saved in Keychain.

Complete Xcode's license acceptance and first-launch setup before starting jobs.
Xcode installation and setup that requires administrator access remain manual.
Jobs download a missing [managed Simulator runtime](../README.md#ios-simulators)
when requested. If xcodebuild reports a missing Metal Toolchain, the runner
downloads it and retries the operation once. Downloads use the job's selected
Xcode, including `DEVELOPER_DIR`. Download progress appears in workflow output;
Metal download output and both build attempts also remain in the job log. A
failed download stops the job.

## Connect GitHub

Hosts sign in through the shared
[XcodeHomeRunner GitHub App](https://github.com/apps/xcodehomerunner), so you
do not create a GitHub App. Click the hammer icon in the menu bar and open
**Settings…**. Until this Mac is set up, **Overview** lists these steps and
offers the next one.

1. Choose **Connect GitHub…**. GitHub's device page opens, and the **GitHub**
   pane shows a code. Enter the code on that page and authorize the app.
2. Choose **Add Repositories on GitHub…**, install the app, and select the
   repositories this Mac will run.
3. Return to the window and choose **Reload**.
4. In **GitHub**, select the repositories to manage and choose **Apply**.

Enter only codes shown in this window. Entering a code that someone else
sent you gives them access to your repositories as you.

A new host starts with **Maximum concurrent jobs** set to 4, so runners
register without editing the execution settings first. Change the limit and the
Simulator retention policy in this Mac's pane under **Runners**, then select
**Apply**.

The app saves login tokens in Keychain and refreshes expiring tokens
automatically; it stores no client secret. To change repository access later,
choose **Add Repositories on GitHub…**, then **Reload**.

Installing the app for organization repositories may need approval from an
organization owner. The signed-in user also needs repository administration
access to manage runners.

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
With **Remove after an idle period**, it also deletes devices after the chosen
number of idle minutes, even below the limit. The default is 20 minutes. Choose
**Keep indefinitely** to keep healthy idle devices booted without a time limit. Capacity limits,
cancellation, abnormal termination, fresh-device requests, and explicit cleanup
can still delete them. The saved policy applies to all runners using this host
pool without restarting the host. Existing idle devices keep their original
return time when the setting changes.
Matching devices are reused in order of most recent return. If space is needed,
the oldest returned idle devices are removed first.
Devices in use finish before they are removed, so lowering the limit can
temporarily leave more devices than the new limit. Runner registrations and
GitHub's in-progress job count can still be higher.

**Overview** shows the host status, the running and waiting Xcode jobs, and each
repository's online and busy runner counts with any error. This Mac's pane under
**Runners** lists its runner services. The host retries synchronization every
five minutes while signed in. Pool and repository settings are saved separately; editing one does not
apply pending changes in the other. **Disconnect** removes local login tokens and
stops registration management; it leaves existing runner services running.

## Pair other Macs

One host can list the other XcodeHomeRunner hosts on your local network under
**Runners**. Install the app on each Mac first, then pair them:

1. On the Mac to add, open **Settings…**, select that Mac under **Runners**, and
   choose **Allow Management…**. The Mac waits five minutes for a managing Mac.
2. On the managing Mac, choose **Add Mac…** at the bottom of the sidebar, select
   the Mac, and choose **Continue**. Both Macs show a six-digit code.
3. If the codes match, choose **Pair** on the managing Mac and **Allow** on the
   added Mac. A different code means that another device answered, so choose
   **Don't Allow**.

The added Mac needs no GitHub sign-in, Remote Login, or SSH key. Each Mac keeps
the pairing key in its Keychain, and the key never crosses the network. The
added Mac considers one request at a time. It stops waiting when you choose
**Don't Allow** or when a request ends before the Macs pair; choose **Allow
Management…** again to retry. Pairing uses Bonjour, so macOS asks for local
network access the first time you choose **Allow Management…** or **Add Mac…**.
If you declined, allow XcodeHomeRunner in **System Settings > Privacy &
Security > Local Network**.

A Mac either manages other Macs or is managed by one. Each paired Mac's pane
shows whether the managing Mac can connect to it and, while that Mac answers,
its host status, runner services, Xcode job counts, job limit, Simulator
retention, and storage folder. **Apply** and **Save** there change that Mac's
settings with the same checks as its own window; type the storage folder's path,
because the managing Mac cannot browse the other Mac's folders. When the Mac
does not answer, its pane hides these values and shows when they were last
read. **Remove Mac…** ends the pairing on both Macs. **Stop Management…** on a
managed Mac ends it there; the managing Mac then shows that Mac as not found
until you remove it. Each Mac still keeps its own GitHub sign-in and runner
registrations.

## Settings from CLI and MCP

The GUI, CLI, and MCP server use the same settings operations. Read the catalog
from an installed CLI:

```sh
xcode-runner host settings get
xcode-runner host settings get --scope pool
xcode-runner host settings update \
  '{"scope":"pool","maximumConcurrentJobs":2,"simulatorRetention":{"mode":"forever"}}'
```

Updates are partial and apply to one scope. Omitted fields retain their saved
values. A new pool requires `maximumConcurrentJobs`. The catalog includes each
setting's current value, type, constraints, choices, and application timing.
Storage also reports the active directory separately from the requested one.
Read failures are returned as `readError`; they are distinct from unset values.

Start the MCP server with `xcode-runner mcp`. It uses stdio and exposes
`get_settings` and `update_settings`. To run it on a remote host, configure your
MCP client to launch SSH with this command:

```sh
ssh -T ci-host 'exec "$HOME/Library/Application Support/XcodeRunnerKit/bin/xcode-runner" mcp'
```

`get_settings` accepts an optional `scope`. Pass an update object directly to
`update_settings`, for example:

```json
{"scope":"pool","simulatorRetention":{"mode":"idleTimeout","minutes":30}}
```

Available scopes and when they take effect:

| Scope | Fields | Takes effect |
| --- | --- | --- |
| `pool` | `maximumConcurrentJobs`, `simulatorRetention` | Next admission or Simulator maintenance; active jobs continue |
| `buildService` | `path` (absolute path or `null` to clear) | Next CLI operation |
| `storage` | `directory` (absolute path to an existing folder) | Next host launch, after migration succeeds |
| `githubRepositories` | `selectedRepositoryIDs` | Saved by the running app, then runner registrations synchronize |

GitHub repository updates need the installed app running. Synchronizing runner
registrations also requires sign-in; a saved selection with pending
synchronization returns `savedWithErrors`. The catalog reports availability and
the selectable repository IDs. Credentials remain in the app's Keychain. Other
scopes can be read and saved without the app.

Pool fields are saved together under the pool lock. Saving a configuration can
succeed even if subsequent Simulator cleanup or runner synchronization fails;
the update then returns `state: "savedWithErrors"` and an `errors` list. Retrying
cleanup does not require reverting the saved settings. Invalid input and failures
before saving produce an error.

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

The CLI uses GitHub's `GITHUB_REPOSITORY_ID` to select a repository-specific
compiler cache. All runners and branches of that repository share the cache;
other repository IDs use separate directories. A missing or invalid ID fails the
operation instead of sharing an unscoped cache. An explicit `--compilation-cache`
uses that directory as given, so choose a repository-specific path when overriding
the default.

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
| `CompilationCache/<repository-ID>` | Compiler cache shared by jobs of that repository |
| `Build/<operation-UUID>` | DerivedData, logs, and result bundles |

Compiler cache entries from before repository scoping stay in `CompilationCache`
and are not imported into repository caches. The first build for each repository
populates its own cache.

Tools and service logs stay under
`~/Library/Application Support/XcodeRunnerKit`. Runner installations stay under
`~/Library/XcodeRunnerKit/runners`.

To move job data, choose a folder in this Mac's pane under **Runners** >
**Storage** and select **Save**. The change
takes effect on the next host launch. Wait for running jobs and other users of
that data to finish, then restart the host.

The host copies the data and keeps the originals. The destination must not
already contain `Work`, `CompilationCache`, or `Build`. If the saved folder is
temporarily missing, such as while an encrypted external volume mounts after
login, the host shows **Waiting for storage** and retries every two seconds.
Runner services start when storage preparation succeeds, without restarting the
host. The host does not recreate the missing storage parent. Folder changes saved
while waiting apply on the next host launch.

Other storage failures show **Needs attention**. Read the storage error, restore
access to the original folder or choose another destination, and restart.

For removable storage, keep the volume mounted and approve the app's initial
volume-access prompt. If you use custom `includeIf.gitdir` authentication rules,
update them for the new physical work path before restarting.

## Updates and troubleshooting

To update, repeat [the installation steps](#install). The installer keeps the
previous app, including its CLI, as `XcodeHomeRunner.previous.app`. Earlier
versions installed the CLI separately with `install-host-tools.sh`; the first
installation of an app that contains the CLI keeps that copy as
`bin/xcode-runner.previous`.

Inspect or restart the host with:

```sh
launchctl print "gui/$(id -u)/lynnpd.xcodehomerunner"
launchctl kickstart -k "gui/$(id -u)/lynnpd.xcodehomerunner"
```

Logs are under `~/Library/Application Support/XcodeRunnerKit/logs`:

- `runner-host.stdout.log` and `runner-host.stderr.log`: app startup and storage errors
- `runners/<runner-name>.log`: runner service output

GitHub's runner diagnostics are in each installation's `_diag` directory.
Xcode logs and result bundles are in the job-data folder's `Build` directory.
After a Mac reboot, log into the CI account to start its LaunchAgent.

## Existing GitHub Apps and runners

To sign in through another GitHub App, set its Client ID and slug in
`GitHubApp.xcodeHomeRunner` (`Sources/XcodeRunnerHostApp/GitHubApp.swift`) and
build the app. The slug is the name after `github.com/apps/`. The app must
enable **Device Flow** and grant repository **Administration: Read and write**
and **Metadata: Read-only**. Disable its webhook and keep user token expiration
enabled. It needs no client secret or private key.

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
