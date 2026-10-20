# XcodeRunnerKit

Run Xcode builds and tests from Swift or the `xcode-runner` CLI. Each run gets
its own logs, result bundle, and DerivedData directory.

For GitHub Actions on your own Mac, use the [menu bar host](Documentation/NativeHost.md).
It provides GitHub sign-in, runner registration, and a shared limit on concurrent
Xcode jobs.

## Requirements

- macOS 26 or later
- Swift 6.4 and Xcode 27.1 or later
- The SDKs and Simulator runtimes needed by your project

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
    destination: "platform=macOS,arch=arm64",
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
`xcrun simctl list runtimes --json`. In Swift, set
`request.simulator = SimulatorConfiguration(runtimeIdentifier:deviceTypeIdentifier:)`.

The runner leases a device exclusively for each operation. Devices are shared
only when their runtime, device type, and selected Xcode match. Test operations
wait for the Simulator to finish booting before launching xcodebuild. After a
normal test exit, including a failed test run, cleanup prepares the device for
its next operation and leaves it booted. Build operations reuse their destination
without booting or changing runtime state. Cancellation or abnormal termination
retires the device by deleting it.
Cleanup waits for job subprocesses retaining the lease to exit. Other jobs can
lease different devices while those subprocesses finish.

Cleanup removes installed user apps and resets keychain, privacy permissions,
location simulation, and status bar overrides. Tests that change system app
data or other device settings should use a fresh device: add
`--fresh-simulator`, or set `request.simulator?.reusesDevice = false` in Swift.
A fresh device is deleted after the operation, including on failure or managed
cancellation.

With `--pool-directory`, the device registry lives in that pool's `Simulators`
subdirectory. Without an execution pool, the runner uses
`SimulatorPool.defaultDirectory`. Keep the registry in a persistent local
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

Devices in use continue running. Add `--developer-directory` to clean only
devices registered with a particular Xcode. Swift callers can use
`try await pool.removeIdleSimulators()` on their `SimulatorPool`.
The runner disables parallel test workers by default to avoid Xcode creating
additional device clones. A failed device cleanup appears in
`XcodeBuildFailure.cleanupErrors` as a `SimulatorCleanupFailure` with the device's
UDID and name. Use `pool clean-simulators` to retry removing any remaining pooled
devices, or `xcrun simctl delete` for a fresh device.

### Shared execution limit

Point cooperating processes at the same local pool directory:

```sh
xcode-runner test --package /path/to/Package --scheme PackageName \
  --destination 'platform=macOS,arch=arm64' \
  --pool-directory /path/to/shared-pool --maximum-concurrent-jobs 4
```

`--maximum-concurrent-jobs` sets the initial limit. Once the pool exists,
change its saved limit with:

```sh
xcode-runner pool configure --pool-directory /path/to/shared-pool --maximum-concurrent-jobs 8
xcode-runner pool status --pool-directory /path/to/shared-pool --json
```

An increase lets waiting jobs start. A decrease lets current jobs finish and
holds new jobs until the active count falls below the limit. All clients must
use the same macOS user and local pool directory.

In Swift, attach a pool to the runner:

```swift
let pool = try HostExecutionPool(
    directory: URL(filePath: "/path/to/shared-pool"),
    initialCapacity: 4
)
var runner = XcodeRunner()
runner.executionPool = pool

let status = try await pool.status()
try await pool.updateMaximumConcurrentJobs(to: 8)
```

`status()` returns `nil` for an unused pool without creating it.
`--priority high|medium|low`, or `runner.run(..., priority: .high)` in Swift,
sets the queue priority. Higher priorities start first; equal priorities start
in arrival order. Running operations are not interrupted.

For a native GitHub Actions host, use **Apply** in the app's settings. It updates
the execution limit and registers enough GitHub runners to use it. The CLI's
`pool configure` command changes only the local limit. GitHub assigns jobs to
runners before they enter the local Xcode queue.

When upgrading from the old `capacity.lock` pool format, stop all clients,
update them together, then recreate the pool. Keep pool files in place while
jobs are running.

### Shared compilation cache

Add `--compilation-cache /path/to/shared-CAS`, or set
`request.compilationCache = CompilationCache(directory: cacheURL)` in Swift.
The compiler cache is shared; each run still has separate DerivedData and build
outputs.

Keep package checkout names consistent across jobs because SwiftPM includes the
package identity in compiler inputs. For source locations outside the checkout,
use `--prefix-mapping /physical/path=/canonical-prefix` or
`CompilationCache.prefixMappings`. Path mappings also affect paths in debug and
coverage data. Explicit build settings override cache defaults.

Use `--cache-diagnostics` to see compiler cache hits and misses. Remove a shared
cache only after its users have stopped.

## Results and cancellation

Each run creates a job directory under `outputDirectory` containing
`xcodebuild.log`, `Results.xcresult`, and its default `DerivedData`.
`XcodeBuildResult.jobDirectory` names it. Early failures may produce no result
bundle.

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
path should use a CLI built from the same checkout.

## License

[MIT](LICENSE).
