# XcodeRunnerKit

Run Xcode builds and tests from Swift or the `xcode-runner` CLI. Each run gets
its own logs, result bundle, and DerivedData directory.

For GitHub Actions on your own Mac, use the [menu bar host](Documentation/NativeHost.md).
It provides GitHub sign-in, runner registration, and a shared limit on concurrent
Xcode jobs.

## Requirements

- macOS 26 or later
- Swift 6.4 and Xcode 27.1 or later
- The SDKs needed by your project

Install Xcode and complete its license acceptance and first-launch setup before
running. The runner downloads missing components as described below.

The package is under development; APIs and CLI options may change.

## Use from Swift

Add the package dependency:

```swift
.package(url: "https://github.com/lynnswap/XcodeRunnerKit.git", branch: "main")
```

Add `.product(name: "XcodeRunnerKit", package: "XcodeRunnerKit")` to your target's
dependencies, then run an Xcode operation:

```swift
import Foundation
import XcodeRunnerKit

var request = XcodeBuildRequest(
    source: .workspace(URL(filePath: "/path/to/App.xcworkspace")),
    scheme: "App",
    destination: .specifier("platform=macOS,arch=arm64"),
    outputDirectory: URL(filePath: "/path/to/CIOutput")
)
request.arguments = ["-parallel-testing-enabled", "NO", "-jobs", "4"]

let runner = XcodeRunner(
    developerDirectory: URL(filePath: "/Applications/Xcode.app/Contents/Developer")
)
let result = try await runner.run(.test, request: request)
print(result.logURL)
print(result.resultBundleURL)
```

Use `.project(URL)` or `.package(URL)` for other source types.
Set `request.buildSettings` and `request.environment` to configure the child
process. Pass `onOutput` to `runner.run` to receive output as it runs.

## Use the CLI

Build from this checkout:

```sh
swift build -c release --product xcode-runner
```

Run a package's macOS tests:

```sh
.build/release/xcode-runner test \
  --package /path/to/Package --scheme PackageName \
  --destination 'platform=macOS,arch=arm64' \
  --developer-directory /Applications/Xcode.app/Contents/Developer \
  --output-directory /path/to/CIOutput
```

The commands are `build`, `build-for-testing`, `test`, and
`test-without-building`. Choose one of `--workspace`, `--project`, or
`--package`. Add Xcode arguments after `--`.

Use repeated `--setting NAME=VALUE` and `--environment NAME=VALUE` options
for build settings and environment values. `--developer-directory` selects
Xcode without changing `xcode-select`.

### Automatic Xcode components

If xcodebuild reports that the Metal Toolchain is missing, the runner downloads
it and retries the operation once. Other build or test failures are returned
without a retry. A failed download stops the operation and keeps its output in
the job log.

Component downloads use the operation's selected Xcode, including
`developerDirectory` in Swift, `--developer-directory` in the CLI, or inherited
`DEVELOPER_DIR`. Xcode installation and setup that requires administrator access
remain manual.

### Custom build service

Pass `--build-service-path /path/to/SWBBuildServiceBundle` to select a custom
build service executable for an operation. In Swift, set
`runner.buildServiceExecutableURL` to the executable's file URL.

For all jobs on an installed host, save the path once:

```sh
xcode-runner host build-service configure \
  --path /path/to/SWBBuildServiceBundle
xcode-runner host build-service status --json
```

The saved path applies to the next `xcode-runner` invocation; existing builds
continue using their current service. An operation's `--build-service-path`
overrides the saved path. Omit `--path` from `configure` to clear the host
override.

Xcode receives the selection through the child process's `SWBBUILDSERVICE_PATH`.
The explicit path takes precedence over inherited service selection, so it does
not depend on login-time activation or restarting the host. Without an explicit
or saved path, the process keeps its inherited Xcode service selection.

### iOS Simulators

To use an existing device, pass
`--destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>'`.

To reuse a managed device between runs, pass a runtime and device type:

```sh
xcode-runner test --workspace /path/to/App.xcworkspace --scheme App \
  --simulator-runtime com.apple.CoreSimulator.SimRuntime.iOS-27-0 \
  --simulator-device-type com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro \
  --output-directory /path/to/CIOutput
```

Find installed runtimes and their supported device types with
`xcrun simctl list runtimes --json`. `--destination` cannot be combined with
these options. In Swift, set
`request.destination = .managedSimulator(SimulatorConfiguration(runtimeIdentifier:deviceTypeIdentifier:))`.
The runner passes the managed device to xcodebuild as `id=<UDID>`.

If the requested runtime is absent, the runner downloads that platform and
version before creating the device. Automatic downloads support standard
`com.apple.CoreSimulator.SimRuntime` identifiers for iOS, tvOS, watchOS, and xrOS
(visionOS), such as `com.apple.CoreSimulator.SimRuntime.iOS-27-0` for iOS 27.0.
An installed runtime that CoreSimulator marks unavailable still produces an
error. A `--destination` specifier or device ID does not trigger a runtime
download.

The runner leases a device exclusively for each operation. Devices are shared
only when their runtime, device type, and selected Xcode match. Test operations
wait for the Simulator to finish booting before launching xcodebuild. After a
normal test exit, including a failed test run, cleanup prepares the device for
its next operation and leaves it booted during its idle retention period,
which defaults to 20 minutes. The most recently returned matching device is
reused first. Each successful return restarts the retention period. Build
operations reuse their destination without booting or changing runtime state.
Cancellation or abnormal termination
retires the device by deleting it.
Cleanup waits for job subprocesses retaining the lease to exit. Other jobs can
lease different devices while those subprocesses finish.

With an execution pool, its saved job limit also caps the total number of managed
Simulators across Xcode versions, runtimes, and device types. Before creating a
device, the runner removes idle devices if needed to stay within the limit.
The oldest returned idle devices are removed first when space is needed.
Lowering the limit removes idle excess devices; devices still in use finish
first and are removed as they return. Fresh devices also count toward this limit.
A custom `runner.simulatorPool` shares the same budget when
`runner.executionPool` is set.

Choose **Keep indefinitely** or **Remove after an idle period** in the host
settings. To retain healthy idle devices without a time limit from the CLI, run:

```sh
xcode-runner pool configure --simulator-retention forever
```

For a timeout, use `--simulator-retention idleTimeout --idle-timeout-minutes 20`.
In Swift, call `try await executionPool.configure(simulatorRetention: .forever)`
or pass `.idleTimeout(minutes: 20)`. Read the saved values with
`try executionPool.configuration()`. The setting applies to all runners sharing
the execution pool, including CLI runs. Changes affect existing idle devices on
the next maintenance pass or pool operation without resetting their return time.

**Forever** removes idle expiry only. Capacity limits, fresh-device requests,
cancellation, abnormal termination, and explicit cleanup can still delete a
device. Abandoned devices left by terminated processes are reclaimed even with
this policy.

The native host removes expired idle devices automatically. Standalone library
and CLI runs remove expired devices when the pool is next used; callers can
also run `executionPool.removeExcessSimulators()` to perform that maintenance.

Cleanup removes installed user apps and resets keychain, privacy permissions,
location simulation, and status bar overrides. Tests that change system app
data or other device settings should use a fresh device: add
`--fresh-simulator`, or set `reusesDevice = false` on the `SimulatorConfiguration`
in Swift.
A fresh device is deleted after the operation, including on failure or managed
cancellation.

With `--pool-directory`, the device registry lives in that pool's `Simulators`
subdirectory (`HostExecutionPool.simulatorPool` in Swift). Without an execution
pool, the runner uses `SimulatorPool.defaultDirectory`. Keep the registry in a persistent local
directory; clean its devices before removing a temporary pool directory.
In Swift, assign a separate pool if needed:

```swift
var runner = XcodeRunner()
runner.simulatorPool = SimulatorPool(directory: URL(filePath: "/path/to/simulator-pool"))
```

Remove idle devices from an execution pool when they are no longer needed:

```sh
xcode-runner pool clean-simulators --pool-directory /path/to/shared-pool
```

The `pool` commands use the installed host's pool when `--pool-directory` is
omitted.

Devices in use continue running. Add `--developer-directory` to clean only
devices registered with a particular Xcode. Swift callers can use
`try await pool.removeIdleSimulators()` on their `SimulatorPool`.
The runner disables parallel test workers by default to avoid Xcode creating
additional device clones. A failed device cleanup appears in
`XcodeBuildFailure.cleanupErrors` as a `SimulatorCleanupFailure` with the device's
UDID and name. Use `pool clean-simulators` to retry removing remaining managed
devices, or `xcrun simctl delete` with the reported UDID.

### Shared execution limit

Configure a local pool once, then point cooperating processes at it:

```sh
xcode-runner pool configure --pool-directory /path/to/shared-pool \
  --maximum-concurrent-jobs 4 --simulator-retention forever

xcode-runner test --package /path/to/Package --scheme PackageName \
  --destination 'platform=macOS,arch=arm64' \
  --pool-directory /path/to/shared-pool
```

Build and test commands use the saved configuration and fail if the pool is
unconfigured. Change either setting without replacing the other:

```sh
xcode-runner pool configure --pool-directory /path/to/shared-pool --maximum-concurrent-jobs 8
xcode-runner pool status --pool-directory /path/to/shared-pool --json
```

An increase lets waiting jobs start. A decrease lets current jobs finish and
holds new jobs until the active count falls below the limit. All clients must
use the same macOS user and local pool directory.
The same limit bounds the pool's managed Simulators, including idle devices.

In Swift, attach a pool to the runner:

```swift
let pool = HostExecutionPool(directory: URL(filePath: "/path/to/shared-pool"))
try await pool.configure(maximumConcurrentJobs: 4, simulatorRetention: .forever)
var runner = XcodeRunner()
runner.executionPool = pool

let status = try await pool.status()
try await pool.configure(maximumConcurrentJobs: 8)
```

`configuration()` and `status()` return `nil` for an unconfigured pool without
creating it. `status.configuration` contains `maximumConcurrentJobs` and
`simulatorRetention`; the remaining status fields report active and waiting jobs.
`--priority high|medium|low`, or `runner.run(..., priority: .high)` in Swift,
sets the queue priority. Higher priorities start first; equal priorities start
in arrival order. Running operations are not interrupted.

For a native GitHub Actions host, use **Apply** in the app's execution settings.
The app synchronizes runner registrations to the saved job limit.
The CLI's `pool configure` command saves the local configuration without requiring
the app or a GitHub connection. GitHub assigns jobs to runners before they enter
the local Xcode queue. See the [host guide](Documentation/NativeHost.md#settings-from-cli-and-mcp)
for the settings catalog and MCP updates.

When upgrading, stop all clients and update them together. The first explicit
configuration update migrates the previous capacity and retention files into
`configuration.json`, preserving unspecified values. Remove
`--maximum-concurrent-jobs` from build and test commands; it is now a
`pool configure` option only. Swift callers must replace
`initialMaximumConcurrentJobs` and the individual update methods with
`configure(maximumConcurrentJobs:simulatorRetention:)`. Keep pool files in place
while jobs are running. Pools using the older `capacity.lock` format must still
be recreated after stopping their clients.

### Shared compilation cache

Add `--compilation-cache /path/to/shared-CAS`, or set
`request.compilationCache = CompilationCache(directory: cacheURL)` in Swift.
The compiler cache is shared; each run still has separate DerivedData and build
outputs.

For jobs started by XcodeRunnerHost, the CLI defaults to
`<Storage>/CompilationCache/<GITHUB_REPOSITORY_ID>`. Jobs from the same repository
share a cache across runners and branches; different repository IDs use separate
directories. The hosted default requires a valid `GITHUB_REPOSITORY_ID` and never
falls back to an unscoped cache. Existing unscoped cache entries are retained but
are not imported into repository caches. An explicit `--compilation-cache` or
Swift `CompilationCache(directory:)` uses the supplied directory as given.

Keep package checkout names consistent across jobs because SwiftPM includes the
package identity in compiler inputs. For source locations outside the checkout,
use `--prefix-mapping /physical/path=/canonical-prefix` or
`CompilationCache.prefixMappings`. Path mappings also affect paths in debug and
coverage data. Explicit build settings override cache defaults.

Use `--cache-diagnostics` to see compiler cache hits and misses. Remove a shared
cache only after its users have stopped.

## Results and cancellation

Each run creates a job directory under `outputDirectory` containing
`xcodebuild.log`, `Results.xcresult`, and its default `DerivedData`. The run
creates `outputDirectory`, the compilation cache, and the hosted cache root when
they are missing. Their containing storage folders must already exist, so a job
fails instead of writing to the startup volume when removable storage is not mounted.
`XcodeBuildResult.jobDirectory` names it. Early failures may produce no result
bundle.

When a missing Metal Toolchain triggers a retry, `xcodebuild.log` includes both
attempts and the download output. The first attempt's result bundle, when
present, is kept as `Results-before-component-download.xcresult`;
`Results.xcresult` belongs to the retry.

`runner.run` throws `XcodeBuildFailure` for every unsuccessful operation.
Its `result` contains the exit status and artifact paths, and is `nil` only when
the operation failed before creating its job directory. `underlyingError` keeps
the error that stopped the operation, and `cleanupErrors` keeps every failure
from closing the log, cleaning up a Simulator, or releasing host locks. A
successful status with cleanup errors means only cleanup failed.

The CLI exits with xcodebuild's status, `128 + signal` for a terminated
process, and 130 after cancellation. It prints the log path for every operation
that created a job directory, and prints cleanup failures before exiting.

Cancel the calling Swift task, or send the CLI SIGINT/SIGTERM, to terminate the
process group and clean up an owned Simulator. A forced kill can prevent cleanup,
and a cancelled result bundle may be incomplete.

For `test-without-building`, reuse the previous build with
`derivedDataDirectory` or `--derived-data`. Do not share mutable DerivedData
between concurrent runs.

## GitHub Actions host

See [the host setup guide](Documentation/NativeHost.md) for installation,
GitHub login, workflow configuration, and private SwiftPM dependencies.
The app supplies storage, cache, and pool settings to the jobs it starts.

## Development

Run package tests with:

```sh
DEVELOPER_DIR=/Applications/Xcode_27.1.app/Contents/Developer \
xcodebuild test -scheme XcodeRunnerKit-Package \
  -destination 'platform=macOS,arch=arm64'
```

The `Scripts/check-*.py` scripts cover process cancellation, shared pools,
compilation caching, Simulators, and host setup. Checks that take an executable
path should use a CLI built from the same checkout. CI runs only macOS
operations, because booting a Simulator on the CI runner takes minutes and slows
the other checks. `check-simulators.py` runs iOS tests on real Simulators
through pooled, fresh, failed, and cancelled operations and takes a few minutes
locally. Run it before merging changes to Simulator leasing, cleanup, retirement,
or iOS destinations:

```sh
swift build -c release --product xcode-runner
DEVELOPER_DIR=/Applications/Xcode_27.1.app/Contents/Developer \
python3 Scripts/check-simulators.py .build/release/xcode-runner
```

## License

[MIT](LICENSE).
