# XcodeRunnerKit

Run Xcode tests or a GitHub Actions workflow on a Mac paired with
[XcodeHomeRunner](Documentation/NativeHost.md). The dashboard sends your working
tree, including uncommitted edits and new files that Git does not ignore. The
host assigns the work to a runner with an available slot.

The Swift package and standalone CLI also run Xcode builds and tests locally.
Building the package requires macOS 26 or later and a Swift 6.4 toolchain.
On each runner, install the SDKs your project uses and complete Xcode’s first-launch setup.

## Run from a paired dashboard

From the Git checkout on your dashboard Mac, use the CLI inside the app.

```sh
runner=/Applications/XcodeHomeRunner.app/Contents/Helpers/xcode-runner

"$runner" test --package . --scheme MyLibrary --destination 'platform=macOS' \
  -- '-only-testing:MyLibraryTests/ParserTests'
"$runner" workflow run .github/workflows/native-ci.yml --event pull_request --base main --json
```

Choose a scheme and test identifier from your project. For an app, pass
`--workspace App.xcworkspace` or `--project App.xcodeproj`. Omit the test
filter to run the scheme’s tests. The runner uses its configured Xcode.

Results return to `XcodeRunnerOutput` on the dashboard. For a workflow, start with
the compact JSON result. It names the failed step, the log and the full summary.
See [pairing a dashboard](Documentation/NativeHost.md#show-a-host-on-another-mac)
and [workflow support](Documentation/NativeHost.md#run-a-workflow-from-a-dashboard).

### Install the agent skill

```sh
"$runner" init --client claude
"$runner" init --client agents
```

These install the [bundled skill](skills/xcode-runner/SKILL.md) in
`~/.claude/skills` and `~/.agents/skills`, respectively. Use
`--dest "$HOME/.codex/skills"` for a custom skills directory. In a terminal,
`init` with no options detects the existing client directories. Use `--print`
to inspect the skill, `--force` to update it, or `--uninstall` to remove it.

## Use the standalone CLI

```sh
swift build -c release --product xcode-runner
.build/release/xcode-runner test --package . --scheme MyLibrary --destination 'platform=macOS'
```

The standalone executable runs on the Mac that invoked it. The app helper also
supports local execution with `--local`. Use `build`, `test`,
`build-for-testing`, or `test-without-building`. To run previously built
tests, use the same `--derived-data` for both operations. Pass build settings
with `--setting NAME=VALUE`, environment variables with `--environment NAME=VALUE`,
and additional xcodebuild arguments after `--`.

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

### iOS Simulators

Pass an existing device in `--destination`, or ask the runner to manage a device.

```sh
xcode-runner test --workspace App.xcworkspace --scheme App \
  --simulator-runtime com.apple.CoreSimulator.SimRuntime.iOS-27-0 \
  --simulator-device-type com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro
```

Find identifiers with `xcrun simctl list runtimes --json`. Managed destinations
can download a missing platform runtime. Managed tests boot the device and
disable parallel test workers by default. After a run the pool removes user
apps and resets the keychain, permissions, location and status bar. Use
`--fresh-simulator` for tests that change system data or require a clean device.

### Shared execution limit

A pool limits concurrent Xcode operations and the number of managed Simulators
on one Mac. Configure it once for all processes using the same account.

```sh
xcode-runner pool configure --pool-directory /path/to/pool --maximum-concurrent-jobs 4
xcode-runner pool status --pool-directory /path/to/pool --json
```

Pass that directory to standalone operations with `--pool-directory`, or set
`runner.executionPool` in Swift. The installed host supplies its own pool.
Lowering the limit lets current jobs finish. Healthy idle devices expire after
20 minutes by default. Set `--simulator-retention forever` to keep them while
capacity allows. Use `pool clean-simulators` to remove idle devices.

### Shared compilation cache

Set `--compilation-cache <directory>` or `request.compilationCache` to reuse
compiler output across builds with separate DerivedData. GitHub jobs on an
installed host share a cache by repository ID. To reuse entries across checkout
paths, add `--map-source-directory`. This changes paths in debug info, coverage
and `#filePath`, so leave it off for tests that locate fixtures through those
paths. Use `--cache-diagnostics` to inspect hits and misses.

## Results and cancellation

Each Xcode operation writes `xcodebuild.log` and, when Xcode produces it,
`Results.xcresult` in its job directory. A missing Metal Toolchain triggers
one download and retry. The log contains both attempts. In Swift, catch
`XcodeBuildFailure` for the exit status, artifact paths and cleanup errors.

Cancel the Swift task, or send the CLI SIGINT or SIGTERM to stop the build and
clean up its Simulator. The CLI returns the build status and exits 130 on
cancellation.

## Development

Open `XcodeRunnerKit.xcworkspace` to work on the package and host app together.
Keep the workspace and package copies of `Package.resolved` in sync.
To override the signing team, set `DEVELOPMENT_TEAM` in the ignored
`App/Configurations/Signing.local.xcconfig`.

```sh
xcodebuild test -scheme XcodeRunnerKit-Package -destination 'platform=macOS,arch=arm64'
```

[Native CI](.github/workflows/native-ci.yml) runs the macOS tests and CLI and host
checks. For changes to Simulator leasing, cleanup or iOS destinations, also
run the device checks against the CLI from the same checkout.

```sh
swift build -c release --product xcode-runner
DEVELOPER_DIR="$(xcode-select -p)" python3 Scripts/check-simulators.py .build/release/xcode-runner
```

## License

[MIT](LICENSE).
