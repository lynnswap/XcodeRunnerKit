# XcodeRunnerKit

> [!NOTE]
> Work in progress. APIs, command-line options, and behavior may change.

Run Xcode builds and tests on a macOS host from Swift or the `xcode-runner` CLI.
Each operation preserves a combined output log and reserves its own result-bundle
location. Task cancellation tears down the launched process group.

For trusted self-hosted GitHub Actions jobs, an optional windowless
[signed host app](Documentation/NativeHost.md#common-host-app) starts multiple
repository runners under one macOS privacy identity.

## Requirements

- macOS 26 or later
- Swift 6.4 and Xcode 27.1 or later
- The SDKs, Simulator runtimes, and additional components required by the project

The library runs on macOS. Its Xcode destination can be macOS or an existing
iOS Simulator.

## Swift usage

Add the library product to a Swift package target:

```swift
.package(url: "https://github.com/lynnswap/XcodeRunnerKit.git", branch: "main")
```

```swift
.product(name: "XcodeRunnerKit", package: "XcodeRunnerKit")
```

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

Use `.project(URL)` for an Xcode project or `.package(URL)` for a Swift package.
`buildSettings` and `environment` pass values to the child process.
An optional `onOutput` closure receives output bytes while the command runs.

## Command-line usage

Build the executable with:

```sh
swift build -c release --product xcode-runner
```

Run a macOS package's tests:

```sh
.build/release/xcode-runner test \
  --package /path/to/Package \
  --scheme PackageName \
  --destination 'platform=macOS,arch=arm64' \
  --developer-directory /Applications/Xcode.app/Contents/Developer \
  --output-directory /path/to/CIOutput
```

Run an application's tests on an existing Simulator:

```sh
.build/release/xcode-runner test \
  --workspace /path/to/App.xcworkspace \
  --scheme App \
  --destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' \
  --output-directory /path/to/CIOutput \
  -- -parallel-testing-enabled NO -jobs 4
```

The executable accepts `build`, `build-for-testing`, `test`, and
`test-without-building`. Specify exactly one of `--workspace`, `--project`,
or `--package`. Forward additional Xcode arguments after `--`.

Repeat `--setting NAME=VALUE` for build settings and
`--environment NAME=VALUE` for child environment values.
`--developer-directory` selects Xcode without changing the host's
`xcode-select` setting.

## Job-owned iOS Simulators

Select an available iOS runtime and a device type from that runtime's
`supportedDeviceTypes` metadata:

```sh
DEVELOPER_DIR=/Applications/Xcode_27.1.app/Contents/Developer xcrun simctl list runtimes --json
```

Pass both identifiers to the CLI:

```sh
xcode-runner test --workspace /path/to/App.xcworkspace --scheme App \
  --simulator-runtime com.apple.CoreSimulator.SimRuntime.iOS-27-0 \
  --simulator-device-type com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro \
  --pool-directory /path/to/shared-pool --maximum-concurrent-jobs 2
```

In Swift, set `request.simulator = SimulatorConfiguration(runtimeIdentifier:
deviceTypeIdentifier:)`. The runner creates a fresh device, replaces the test
destination with its UDID, and deletes that exact device after success, failure,
or managed cancellation. Creation and deletion remain inside the execution
slot. Existing devices are never selected for deletion.

Parallel test workers are disabled by default for owned devices. Keep this
setting to prevent Xcode from creating additional worker clones; explicitly
forwarded Xcode options can override it. Direct macOS destinations and existing
Simulator destinations remain available when `simulator` is nil.

Creation finishes before cancellation cleanup begins so the device identifier
is known. A stuck simctl create or delete therefore delays completion.
`SimulatorCleanupFailure` preserves the original operation error, any completed
build result, the owned UDID, and the deletion error. If deletion fails, use
`xcrun simctl delete <reported-UDID>` after resolving the reported cause.
Force-killing the wrapper can leave a device behind.

The public fixture contains Swift, Clang, and the SDK's Observation macro.
Validate concurrent devices, test-failure cleanup, and cancellation cleanup:

```sh
DEVELOPER_DIR=/Applications/Xcode_27.1.app/Contents/Developer \
python3 Scripts/check-simulators.py /absolute/path/to/xcode-runner
```


## Shared compilation cache

Set `request.compilationCache = CompilationCache(directory: cacheURL)`, or add
`--compilation-cache <shared-CAS-directory>` to the CLI. Each operation keeps its
own DerivedData, build database, intermediate products, and result bundle.

The cache configuration enables Swift and Clang compilation caching and maps
the source root and DerivedData to stable compiler-visible prefixes. Cached
operations use canonical physical paths, including /private for /var and /tmp.
Additional
locations outside the source root can be mapped with `prefixMappings` in Swift
or repeated `--prefix-mapping /physical/path=/canonical-prefix` options.
Use physical paths and distinct replacement prefixes for extra mappings.
The fixture uses a relative Clang module map so its contents stay unchanged
when relocated. Generated module maps that embed absolute paths can miss
because their contents are different compiler inputs.
Raw `buildSettings` or `--setting` values take precedence over cache defaults.

Keep the package checkout basename consistent across jobs: SwiftPM's package
identity is a compiler input. Changes to source, compiler flags, toolchains,
SDKs, dependencies, or macro behavior can legitimately cause misses.
Prefix mapping changes paths recorded in compiler outputs, including debug and
coverage data. Use unmapped builds when a consumer needs original physical paths.

Add `--cache-diagnostics` to inspect replay hit/miss notes. The reproducible
check uses paths containing spaces, relocated checkouts, concurrent builds,
and a changed Clang input:

```sh
DEVELOPER_DIR=/Applications/Xcode_27.1.app/Contents/Developer \
python3 Scripts/check-compilation-cache.py /absolute/path/to/xcode-runner
```

The check records cold and relocated build timings, cache replay diagnostics,
and concurrent runs. Xcode can repeat diagnostic notes, so note counts are not
compiler-task counts. It also changes the C implementation and its expected
result to verify that the cache respects changed compiler inputs.

The fixture exercises the SDK's Observation macro. Its result does not establish
cache reuse for every third-party macro or build-tool plugin. Those consumers
need their own build verification. Keep shared CAS directories separate from
job artifact retention, and remove a CAS only while its users are stopped.

Xcode settings: [Apple build settings reference](https://developer.apple.com/documentation/xcode/build-settings-reference).
The path-mapping approach also follows [this worktree cache investigation](https://zenn.dev/sryu/articles/worktree-compilation-cache).

## Shared host capacity

Configure the same pool directory in every repository runner:

```swift
var runner = XcodeRunner()
runner.executionPool = try HostExecutionPool(
    directory: URL(filePath: "/Users/ci/Library/Application Support/XcodeRunnerKit/Pool"),
    maximumConcurrentJobs: 2
)
```

Add `--pool-directory <path> --maximum-concurrent-jobs 2` to CLI operations.
The first operation initializes an empty pool with the specified capacity.
Later operations use the pool's saved capacity, even when the workflow specifies
a different value. A workflow specifying four against a two-slot pool waits
when both slots are occupied. A workflow specifying two against a four-slot
pool can use any available slot.

The kernel holds each slot through execution and log cleanup. Waiting jobs can
be cancelled. Invalid saved configuration or lock I/O failures stop the operation.

Use a local filesystem and the same macOS user for all cooperating runners.
Keep lock files in place while jobs run. To change capacity, stop all runners,
wait for their managed jobs to finish, remove the pool directory, then restart
every runner with the new capacity. Locks coordinate XcodeRunnerKit operations;
unmanaged commands do not participate. Force-killing the wrapper does not
provide cleanup guarantees for its subprocesses; use Task, SIGINT, or SIGTERM
cancellation for managed teardown.

The separate-process check compiles the production pool implementation:

```sh
DEVELOPER_DIR=/Applications/Xcode_27.1.app/Contents/Developer \
python3 Scripts/check-execution-pool.py
```

## Results and cancellation

Each operation creates a uniquely named directory under `outputDirectory`.
It contains `xcodebuild.log`, the requested `Results.xcresult`, and the default
`DerivedData` directory. Early failures may leave no result bundle.

To reuse a completed build with `test-without-building`, set
`derivedDataDirectory` in Swift or pass `--derived-data` to the CLI.
Use a separate DerivedData directory for concurrent jobs.

An unsuccessful operation throws `XcodeBuildFailure`. Its `result` preserves
the termination or cancellation state and artifact locations.
`underlyingError` and `cleanupError` retain execution and log-closing failures.
Cancel the calling Swift task to forcefully terminate the process group with
SIGKILL. A cancelled result bundle may be incomplete. The CLI handles SIGINT
and SIGTERM through the same cancellation path.

## GitHub Actions

This package's own CI runs pull requests, main pushes, and manual dispatches
on fresh GitHub-hosted macOS runners. Each job builds the CLI from its checkout
and uses temporary pool, cache, and output directories. The workflow covers
macOS tests, separate-process capacity, and the iOS consumer fixture.

[Set up a native host](Documentation/NativeHost.md) to run trusted consumer
repositories on an owned Mac, including private dependency authentication,
service operation, and cache retention. Public contribution workflows belong
on isolated hosted runners rather than a Mac that holds private credentials.

## Development

```sh
DEVELOPER_DIR=/Applications/Xcode_27.1.app/Contents/Developer \
xcodebuild test \
  -scheme XcodeRunnerKit-Package \
  -destination 'platform=macOS,arch=arm64'
```

## License

MIT License. See [LICENSE](LICENSE).
