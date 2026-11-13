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

Opening the app on a Mac where the installer set up a host starts that host. On
a Mac without a host, the app opens as a [dashboard](#show-a-host-on-another-mac)
instead.

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
stay in place. Deselecting a repository and choosing **Apply** unregisters this
Mac's runners for it from GitHub and deletes them. A busy runner is removed at a
later synchronization, after its current job finishes, and Overview lists the
repository until then. While the app is signed out or cannot access the
repository, the removal waits. Other runners stay in place, such as those of a
selected repository that the app can no longer access, those registered manually
for a repository that was never selected, and those that GitHub no longer lists
for the deselected repository.

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
until you remove it.

The managing Mac also registers runners on each paired Mac for the repositories
selected in its **GitHub** pane, up to that Mac's job limit, and removes them
when you deselect a repository. It sends the paired Mac only short-lived
registration tokens, never its GitHub sign-in, and removes registrations from
GitHub itself. **Overview** on the managing Mac counts the runners on all its
Macs and names the Mac in each of its errors. A Mac that does not answer keeps
its runners, and a deselected repository stays listed until that Mac answers
and its runners are removed. A newly paired Mac gets its runners at the next
synchronization, or when you change its job limit in its pane. While a Mac is
managed, it does not register runners from its own sign-in; the runners that it
registered before stay. **Remove Mac…** leaves the runners on that Mac.

## Show a host on another Mac

A Mac that runs no host can show a host, sign it in to GitHub, and change its
settings. Copy `XcodeHomeRunner.app` to that Mac and open it without running the
installer. Opened this way, the app is a dashboard: it creates no runner folders
or execution pool, registers no runners, and keeps no GitHub sign-in. It keeps
only its pairings, in that Mac's Keychain.

1. On the host, open **Settings…**, select that Mac under **Runners**, and choose
   **Allow Dashboard…**. The host waits five minutes for a dashboard.
2. On the other Mac, open XcodeHomeRunner, choose **Add Mac…** > **Show a Mac on
   This Dashboard…**, select the host, and choose **Continue**. Both Macs show a
   six-digit code.
3. If the codes match, choose **Pair** on the dashboard and **Allow** on the
   host. A different code means that another device answered, so choose
   **Don't Allow**.

Each host has the panes of its own window: **Overview**, **GitHub**, the host
under its name, and the Macs that it manages. While the host answers, they show
its status, repositories and runner counts, runner services, Xcode job counts,
job limit, Simulator retention, and storage folder. **Apply** and **Save** change them with the same
checks as the host's own window. After a changed job limit, the host registers
its runners itself; for a host that another Mac manages, that Mac does at its
next synchronization. When the host does not answer, the dashboard hides these
values and shows when they were last read.

To connect a host to GitHub from the dashboard, choose **Connect GitHub…** in
its **GitHub** pane. The host starts the sign-in, the dashboard shows the code,
and GitHub's page opens in the dashboard's browser, as does **Add Repositories
on GitHub…**. The host keeps the login tokens and sends the dashboard neither
them nor anything that completes a sign-in. **Apply** saves the repository
selection on the host, which then registers and removes runners; Overview shows
the progress. Changes made in the host's own window or on another dashboard
appear within a few seconds.

The dashboard reaches the Macs that a host manages through the host and does
not pair with them. Their panes show what the host's own panes for them show,
with the same controls, and a Mac that the host cannot reach appears that way.
To have a host manage another Mac, choose **Add Mac…** > **Add a Mac for** the
host **to Manage…**. The host looks for Macs that wait after **Allow
Management…**, and the dashboard shows the code: choose **Pair** on the
dashboard and **Allow** on the Mac being added. **Remove Mac…** in a managed
Mac's pane ends its pairing with the host.

A dashboard does not take over a host. The host keeps its GitHub sign-in, the
Macs it manages, and its managing Mac if it has one, and it accepts several
dashboards. A host waits for either a managing Mac or a dashboard at a time, and
refuses a request for the other.

**Remove Mac…** on the dashboard ends the pairing on both Macs. **Remove…**
under **Dashboards** on the host ends it there; the dashboard then shows the
host as not found until you remove it. Dashboards find hosts with Bonjour on the
local network, as pairing Macs does.

## Build or test on a host from another Mac

A Mac that shows a host as a dashboard can run a build or test of a checkout on
that host without GitHub. The repository needs no runners, GitHub App
installation, or selection on the host, so a repository that should not register
self-hosted runners can use the host too.

In the checkout on the dashboard's Mac, run the `xcode-runner` inside the app
with `--host` and the host's name as the dashboard lists it:

```sh
/Applications/XcodeHomeRunner.app/Contents/Helpers/xcode-runner test \
  --host "Build Mac" --package . --scheme PackageName
```

`build`, `build-for-testing`, and `test` take `--host` with their other
options. The command sends the checkout, shows the operation's output as it
runs, and exits with the operation's status. Interrupting the command stops the
operation on the host.

- **Files.** The command sends the Git checkout that contains the current
  directory: tracked files as they are in the working tree, and untracked files
  that Git does not ignore, including those of submodules. It sends them again
  for every operation, and does not send the Git history. The host runs the
  operation in its copy of the current directory, so name the workspace,
  project, or package relative to that directory.
- **Host settings.** The operation uses the host's storage, its saved Xcode, and
  its build service, and takes a place in its job limit together with the jobs
  from GitHub, waiting in arrival order. `--developer-directory` names an Xcode
  on the host. The operation runs with the host app's environment, not with the
  shell's.
- **Results.** The log and result bundle are copied to `--output-directory` on
  the dashboard's Mac, `XcodeRunnerOutput` by default. In the output and the
  copied log, the host's copy of the checkout and its output folder appear as
  the matching folders on the dashboard's Mac, so the paths in compiler messages
  open there. The result bundle keeps the host's paths. The host removes its
  copy of the checkout and the build products when the operation ends.
- **Compiler cache.** Operations from dashboards share one cache on the host,
  apart from the caches of the repositories that run jobs from GitHub. The host
  unpacks every worktree of a repository at the same path, so a later operation
  reuses the entries of earlier ones, also from another worktree.

`--derived-data`, `--compilation-cache`, `--pool-directory`,
`--build-service-path`, and `test-without-building` cannot be used with `--host`,
because the host uses its own folders and keeps no build products after an
operation.

The command starts the app that contains it to reach the host, because macOS
gives the pairings in the app's Keychain item to the app alone. It finds the
host with Bonjour on the local network, as the dashboard does.

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
| `xcode` | `developerDirectory` (an Xcode's `Contents/Developer` path, or `null` for the system selection) | Next CLI operation that names no Xcode |
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
other repository IDs use separate directories. Entries are reused between
runners only with [`--map-source-directory`](../README.md#shared-compilation-cache),
because each runner checks out at its own path. A missing or invalid ID fails the
operation instead of sharing an unscoped cache. An explicit `--compilation-cache`
uses that directory as given, so choose a repository-specific path when overriding
the default.

To select a custom build service for hosted jobs, save its executable path:

```sh
"$HOME/Library/Application Support/XcodeRunnerKit/bin/xcode-runner" \
  host build-service configure \
  --path /path/to/SWBBuildServiceBundle
```

To choose the Xcode for a Mac's jobs, select it under **Xcode** in the Mac's
pane and choose **Save**. The pane lists the Xcode apps installed on that Mac,
also when it is shown on the managing Mac or a dashboard. Jobs use the saved
Xcode when they name none: `--developer-directory` and `DEVELOPER_DIR` come
first, and with **System selection** jobs use the Xcode that `xcode-select`
names. If the saved Xcode is removed, the pane says so, and jobs that name no
Xcode fail until another one is saved. From the CLI or MCP:

```sh
xcode-runner host settings update \
  '{"scope":"xcode","developerDirectory":"/Applications/Xcode.app/Contents/Developer"}'
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
that data to finish, then choose **Restart to Apply…** in the same section. It
shows the Xcode jobs that are running and, once confirmed, stops the Mac's
runner services and restarts its host. The button also appears in the Mac's pane
on its managing Mac and on a dashboard, so the Mac does not have to be restarted
at its own screen. A host that was not started by its LaunchAgent has no such
button; restart it the way it was started.

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
previous app, including its CLI, as `XcodeHomeRunner.previous.app`.

Update every Mac of a setup, dashboards included, to the same version. Paired
Macs that run different versions keep their pairing but do not exchange
settings: each Mac's pane for the other shows **Runs another version** and names
the Mac to update, and **Add Mac…** lists a waiting Mac of another version
without pairing with it. They connect again once both run the same version. Earlier
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
