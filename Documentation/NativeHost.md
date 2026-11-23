# Set up and manage an XcodeHomeRunner host

The **dashboard** is the menu bar app on the Mac where you work. A **host**
accepts its requests and assigns each job to a **runner**. One Mac can be both
host and runner. A dashboard Mac can submit jobs without running any itself.

Use an Apple silicon runner with macOS 26 or later and Xcode 27.1 or later.
Keep the runner account logged in. Jobs execute with that user’s access to files
and settings, including when a dashboard submits a checkout. Run builds, tests
and workflows from sources you trust.

For a first setup, [install the app](#install), then [pair the dashboard
Mac](#show-a-host-on-another-mac). To run jobs triggered by GitHub, also
[connect the host to GitHub](#connect-github). You can [add a runner
Mac](#pair-other-macs) when you need more capacity.

## Install

Build the app from a checkout on a Mac whose Xcode is signed in to your Apple
Developer account (**Xcode > Settings > Accounts**) and has your Developer ID
Application certificate. Replace `TEAM_ID` with your team identifier.

```sh
bash Scripts/build-runner-host.sh TEAM_ID .build/RunnerHost
```

Copy `.build/RunnerHost/XcodeHomeRunner.app` to the Mac that will host jobs.
On that Mac, run the installer from the directory containing the copied app.

```sh
bash XcodeHomeRunner.app/Contents/Resources/HostSetup/install-runner-host.sh \
  XcodeHomeRunner.app /path/to/JobData
```

Replace `/path/to/JobData` with the folder for checkouts, build output, and the
compiler cache. Omit that argument to use
`~/Library/Application Support/XcodeRunnerKit/Storage`.

The installer puts the app in `~/Applications`, starts a user LaunchAgent,
and links `~/Library/Application Support/XcodeRunnerKit/bin/xcode-runner` to
the embedded CLI. The host stays awake while the runner account is logged in.
Complete Xcode’s license acceptance and first-launch setup on each runner.

## Show a host on another Mac

Copy the signed app to the dashboard Mac’s Applications folder and open it.
The installer is for a Mac that will host runners. Both Macs must be reachable
on the local network and allow XcodeHomeRunner to use Bonjour.

1. On the host, open **Settings…** and choose **Allow Dashboard…** under
   **Dashboards**. The host waits five minutes for a dashboard.
2. On the dashboard Mac, open XcodeHomeRunner and choose **File > Add Mac >
   Show a Mac on This Dashboard…**. An empty dashboard also has an **Add Mac…**
   button. Select the host and choose **Continue**. Both Macs show a six-digit code.
3. If the codes match, choose **Pair** on the dashboard and **Allow** on the
   host. A different code means that another device answered, so choose
   **Don't Allow**.

The menu bar lists paired hosts. Open **Settings…** to manage GitHub and
repositories, or select a runner in the sidebar for its jobs, CPU load, memory
pressure, storage and Xcode settings. **Open dashboard at login** controls
automatic launch on this Mac. Removing a dashboard pairing ends its access.

## Set build defaults for a host

Select the host’s **Settings** in the sidebar. Under **Build Settings** or
**Environment Variables**, use **+** to add a name and value, then choose
**Save**. Uncheck a row to stop using it and keep it for later.

For example, add `SWIFT_ENABLE_BATCH_MODE` with the value `NO` under
**Build Settings** to disable Swift batch compilation. Environment variables
go into the `xcodebuild` process. A job can override either value with
`--setting NAME=VALUE` or `--environment NAME=VALUE` on its
`xcode-runner` build or test command.

Dashboard submissions and GitHub Actions steps that invoke `xcode-runner`
in the host environment use these defaults. A standalone terminal command
with `--local` uses its own settings. An existing GitHub runner uses its last
synchronized values until the next successful host check, including after
reconnecting. The host also synchronizes before it forwards a dashboard job
or registers a new GitHub runner.

## Build or test on a host from another Mac

Run the embedded CLI from the Git checkout on the dashboard.

```sh
runner=/Applications/XcodeHomeRunner.app/Contents/Helpers/xcode-runner
"$runner" test --workspace App.xcworkspace --scheme App \
  --destination 'platform=iOS Simulator,name=iPhone 17' -- '-only-testing:AppTests/ParserTests'
```

The host dispatches `build`, `build-for-testing` and `test` to a Mac with a
matching Xcode and destination. If all eligible slots are busy, the command
waits. To inspect the available Macs, run `"$runner" host runners`.

The transfer includes tracked edits and unignored new files present when the
job is accepted, including those in submodules. Name the project, workspace or
package relative to the current directory. The runner copies the log and
result bundle back to `XcodeRunnerOutput` on the dashboard. Pass
`--output-directory` to change that location. Interrupt the CLI to cancel.

The executing Mac supplies the Xcode, build service, pool and compiler cache.
For a local DerivedData directory or `test-without-building`, run the CLI
locally. Direct submissions work independently of GitHub runner registration.

## Run a workflow from a dashboard

On each Mac that will execute workflow files, open a checkout of XcodeHomeRunner
and install its patched [act](https://github.com/nektos/act) engine.

```sh
bash Scripts/install-workflow-engine.sh
```

From a dashboard checkout with an `origin` remote, run the workflow by path.

```sh
/Applications/XcodeHomeRunner.app/Contents/Helpers/xcode-runner workflow run \
  .github/workflows/native-ci.yml --event pull_request --base main --json
```

The default event is `workflow_dispatch`. Choose an event the YAML declares.
For `pull_request`, the base defaults to the remote’s default branch. The
simulated event uses the submitted checkout. For a test of GitHub’s proposed
merge tree, check out that tree before running the workflow.

The host reserves one slot. Jobs run serially on that Mac using its runner
labels, installed tools and selected Xcode. Local reusable workflows need a
literal `./.github/workflows/<file>` reference. A label that depends on a
previous job’s output may only be known once that job finishes. Each invocation
has its own artifact store. Workflows that require repository secrets, GitHub’s
full webhook payload or cross-run concurrency need GitHub Actions.

Start with the exit status and compact result. It lists up to twelve jobs,
failures first, with log locations for failed steps. Under
`XcodeRunnerOutput/<run ID>/` on the dashboard, `summary.json` lists every
job, `workflow.log` contains the transcript, and `artifacts/` holds uploads.
Use `--verbose` when you need to watch each step.

## Connect GitHub

Connect a host to GitHub to let workflows on GitHub use its runners. For
public repositories, set **Settings > Actions > General > Require approval for
all external contributors**. For private repositories, disable fork PR
workflows or require approval. Review the code before approving a run.
Workflows such as `pull_request_target` also need to restrict the code they
execute. The host checks the fork settings before registering new runners.
Existing services can still take jobs.

Open **Settings…** on the host or its paired dashboard.

1. Under **GitHub**, choose **Connect GitHub…**. GitHub's device page opens,
   and the pane shows a code. Enter the code on that page and authorize the app.
2. For a personal account, choose **Add Repositories on GitHub…** under
   **Repositories** to install the app or change its repository selection.
   For a new organization, choose **Add Organization…** under **GitHub**,
   select the organization and its repositories, and install the app or
   request installation from an organization owner.
3. Once the installation is approved and complete, return to the window and
   choose the reload button beside **Repositories**.
4. Switch on the repositories to manage and choose **Save** in the toolbar.

Enter the device code shown by your own app. Runner management requires
repository administration access and the [XcodeHomeRunner GitHub
App](https://github.com/apps/xcodehomerunner) installation. The host keeps
sign-in tokens in Keychain. Disconnecting pauses registration management.
Existing runner services and their jobs continue.

### Set a concurrency limit

In the runner’s pane, set **Maximum concurrent jobs** and choose **Save**.
All repositories and direct jobs share that Mac’s Xcode slots. Each selected
repository gets enough GitHub runner registrations to use the whole limit.
GitHub also counts checkout, uploads and jobs waiting for Xcode, so its
in-progress count can exceed the number of occupied slots.

Lowering the limit lets running operations finish. Extra registrations may
remain. Deselecting a repository removes its managed runners after active jobs
finish and the host can reach both GitHub and the Mac. The limit also caps the
runner’s [managed Simulators](CLI.md#ios-simulators).

### Pause a Mac

Turn off **Take new jobs** in the runner pane to drain that Mac. Existing
operations finish. A GitHub job accepted while a runner service is stopping
can be cancelled. Turn the setting back on to resume the registered services.

## Pair other Macs

To add execution capacity, install a runner on the additional Mac and pair it
with the managing host.

1. On the Mac to add, open **Settings…** and turn off **Host** under **Roles**.
   The Mac waits five minutes for a host.
2. On the managing host, choose **Add Mac…** in **Settings**, select
   the Mac, and choose **Continue**. Both Macs show a six-digit code.
3. If the codes match, choose **Pair** on the managing Mac and **Allow** on the
   added Mac. A different code means that another device answered, so choose
   **Don't Allow**.

The host can forward work to the added Mac and register GitHub runners on it
for the selected repositories. It sends short-lived registration tokens.
Dashboards reach that Mac through the host. **Remove Mac…** ends the pairing
and leaves existing registrations on that Mac.

## Configure a workflow

For workflows dispatched by GitHub, match the host’s labels in `runs-on`.
Set **Runner labels** in a runner’s pane to target specific tools or hardware.

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

Use `exec` in shell wrappers so cancellation reaches the CLI. The host supplies
the pool, output directory and repository-scoped compiler cache. See
[shared compilation cache](CLI.md#shared-compilation-cache) for reuse
across checkout paths. The runner’s **Xcode** settings select the developer
directory and optional build service for subsequent jobs. An explicit
`--developer-directory` or `DEVELOPER_DIR` takes precedence over the saved
Xcode. **System selection** uses `xcode-select`.

### Private SwiftPM dependencies

Install the XcodeHomeRunner GitHub App on the dependency repositories and grant
**Contents: read**. On the runner Mac, sign in to the app. List the
packages jobs may fetch in
`~/Library/Application Support/XcodeRunnerKit/github-package-repositories.json`.
Use the owner and repository names from their package URLs.

```json
["my-org/PrivateLibrary", "my-org/DesignKit"]
```

Choose **Reload** under **Repositories** to apply the list. Keep the ordinary
GitHub HTTPS package URLs in the project. Jobs on this signed-in Mac receive
the Git configuration automatically. Adding a dependency to this list
does not register a GitHub Actions runner for it.

The host authenticates Git fetches to GitHub through a read-only relay bound to
its loopback interface. A job can read the listed packages. The GitHub user
token stays with the host. Each runner using these credentials needs its own
authorized sign-in. A dashboard submits its checkout without credentials.
Jobs share the runner account’s access to files, including the approved
package sources.

## Commands for the host

Use the CLI embedded in the installed app. For host administration,
`--host` addresses a paired host and `--mac` addresses one of its runners.
Use the identifiers returned by `host runners`.

```sh
xcode-runner host runners         # runner Macs and free Xcode slots, including the host itself
xcode-runner host status          # state, jobs, runner services, labels, and settings
xcode-runner host pause           # take no new jobs
xcode-runner host resume
xcode-runner host labels fast gpu # replace the runner labels; --none removes them
xcode-runner host restart         # stop the host and start it again
```

`configure` changes what a Mac's pane saves with **Save**:

```sh
xcode-runner host configure --maximum-jobs 2 --simulator-retention 20   # minutes, or forever
xcode-runner host configure --xcode /Applications/Xcode.app/Contents/Developer   # or system
xcode-runner host configure --build-service /path/to/SWBBuildServiceBundle   # or none
xcode-runner host configure --storage /path/to/JobData
xcode-runner host configure --repositories 101 102   # IDs from github status; --no-repositories selects none
```

`host restart` normally requires an idle Mac. Use `host github --help` for
sign-in and repository commands, `host pairing --help` for dashboard pairing,
and `host macs --help` to manage other runner Macs. For CLI pairing, exchange
the six-digit codes between the two trusted Macs and confirm the code shown
by the other Mac on each side.

## Settings from CLI and MCP

```sh
xcode-runner host settings get
xcode-runner host settings update '{"scope":"pool","maximumConcurrentJobs":2}'
```

The catalog gives the current values, available choices and when each setting
takes effect. Updates change only the supplied fields in one scope. The
`githubRepositories`, `runnerLabels` and `paused` scopes require the running
app. A `savedWithErrors` result means the setting was saved and a subsequent
operation needs attention. Inspect `errors` for the failed operation.

The stdio server `xcode-runner mcp` exposes `get_settings` and
`update_settings`. To reach a remote host, configure the client to launch:

```sh
ssh -T ci-host 'exec "$HOME/Library/Application Support/XcodeRunnerKit/bin/xcode-runner" mcp'
```

## Storage

The job data folder you select at installation holds these directories.

| Directory | Contents |
| --- | --- |
| `Work/<runner-name>` | Checkouts and temporary job files |
| `CompilationCache/<repository-ID>` | Compiler cache shared by jobs of that repository |
| `Build/<operation-UUID>` | DerivedData, logs, and result bundles |

Tools and service logs live under `~/Library/Application Support/XcodeRunnerKit`.
Runner installations live under `~/Library/XcodeRunnerKit/runners`.

To move job data, choose the new folder in the runner’s **Storage** settings
and save. Drain jobs, stop other tools using these files, then choose **Restart
to Apply…**. The host copies existing data and keeps the original files. The
destination must be free of `Work`, `CompilationCache` and `Build`. If a
volume is missing at login the host waits for it to mount. For **Needs
attention**, inspect the storage error and restore access before restarting.

## Updates and troubleshooting

Drain queued and running jobs before updating an installed host. Repeat the
[installation](#install) with a build signed by the same team. The installer
keeps `XcodeHomeRunner.previous.app`. To update a dashboard, replace its app.
When a pane reports **Runs another version**, update the named Mac.

```sh
launchctl print "gui/$(id -u)/lynnpd.xcodehomerunner"
```

Check `logs/runner-host.stderr.log` and `logs/runner-host.stdout.log` under
the support directory for startup errors. Per-service output is in
`logs/runners/<runner-name>.log`. GitHub diagnostics live in the runner
installation’s `_diag` folder.

## Existing GitHub Apps and runners

When migrating from XcodeRunnerHost or a per-host GitHub App, install the
current app, sign in again and grant its shared GitHub App access to the same
repositories. The installer preserves runner registrations and job data.

For manual registration, download the official
[macOS ARM64 runner v2.338.0](https://github.com/actions/runner/releases/tag/v2.338.0)
and run from the checkout on the CI Mac with `gh` authenticated:

```sh
gh api --hostname github.com -X POST repos/OWNER/REPO/actions/runners/registration-token --jq .token |
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

This transfers the service to the host and keeps its registration and credentials.
