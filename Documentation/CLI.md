# Using xcode-runner

Use the CLI inside XcodeHomeRunner.app to send jobs to a
[paired host](NativeHost.md#show-a-host-on-another-mac). On the dashboard
Mac, set the path for this shell session to match where you installed the app.

```sh
runner=/Applications/XcodeHomeRunner.app/Contents/Helpers/xcode-runner
```

## Run a build or test

From the Git checkout, choose a workspace, project, or package by path
relative to the current directory. For example, to build an app, run

```sh
"$runner" build --workspace App.xcworkspace --scheme App --destination 'platform=macOS'
```

The dashboard can submit `build`, `test`, and `build-for-testing`. Use
`--setting NAME=VALUE` for a build setting, `--environment NAME=VALUE` for a
child environment variable, and `--` for additional `xcodebuild` arguments.
The CLI returns the build status. Press Control-C to cancel a running job.

### Run locally

Pass `--local` to the app's CLI to use Xcode on this Mac. You can also build
the standalone CLI from an XcodeHomeRunner checkout and then call that binary
from your project.

```sh
swift build -c release --product xcode-runner
runner="$PWD/.build/release/xcode-runner"
```

The standalone CLI runs Xcode on the Mac where you invoke it. To run
previously built tests locally, pass the same `--derived-data` directory to
`build-for-testing` and `test-without-building`.

## iOS Simulators

Pass an existing device in `--destination`, or specify a runtime and device
type to let the runner lease a Simulator for the job.

```sh
"$runner" test --workspace App.xcworkspace --scheme App \
  --simulator-runtime com.apple.CoreSimulator.SimRuntime.iOS-27-0 \
  --simulator-device-type com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro
```

On the executing Mac, list runtime identifiers and their supported device
types with `xcrun simctl list runtimes --json`. The runner can download a
missing runtime. Managed tests boot the device and disable parallel test
workers by default. After a run the pool removes user apps and resets the
keychain, permissions, location, and status bar. Add `--fresh-simulator` for
tests that change system data or require a new device.

## Shared execution limit

A host supplies its own pool. For standalone builds, configure a directory
shared by the processes on this Mac that should use the same limit.

```sh
"$runner" pool configure --pool-directory /path/to/pool --maximum-concurrent-jobs 4
"$runner" pool status --pool-directory /path/to/pool --json
```

Pass `--pool-directory /path/to/pool` to each local build or test. The limit
applies to concurrent Xcode operations and the number of managed Simulators.
Lowering it lets active operations finish. Healthy idle devices expire after
20 minutes by default. Set `--simulator-retention forever` on `pool configure`
to keep them while capacity allows. Use `pool clean-simulators` to remove
idle devices.

## Shared compilation cache

Pass `--compilation-cache <directory>` to a local operation to reuse compiler
output across builds with separate DerivedData. GitHub jobs on an installed
host share a cache by repository ID. Add `--map-source-directory` to reuse
entries across checkout paths. This changes paths in debug information,
coverage, and `#filePath`, so leave the option off for tests that locate fixtures
through those paths. `--cache-diagnostics` reports cache hits and misses.

## Logs and result bundles

Each Xcode operation writes `xcodebuild.log` and, when Xcode produces it,
`Results.xcresult` in its job directory. If compilation fails because the Metal
Toolchain is missing, the runner downloads it and retries once. The log
contains both attempts. For paired runs, use `--output-directory` to choose
where the dashboard saves the artifacts.

## Install the agent skill

Choose the command for your client. These commands install the
[bundled skill](../skills/xcode-runner/SKILL.md) under `~/.claude/skills`
or `~/.agents/skills`, respectively.

```sh
"$runner" init --client claude
"$runner" init --client agents
```

Use `--dest "$HOME/.codex/skills"` to specify another skills directory.
Interactive `init` detects existing client directories. Use `--print` to
inspect the skill, `--force` to update it, or `--uninstall` to remove it.
