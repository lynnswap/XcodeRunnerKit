# XcodeRunnerKit

Run Xcode builds and tests on a macOS host from Swift or the `xcode-runner` CLI.
Each operation preserves a combined output log and reserves its own result-bundle
location. Task cancellation tears down the launched process group.

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

## Development

```sh
DEVELOPER_DIR=/Applications/Xcode_27.1.app/Contents/Developer \
xcodebuild test \
  -scheme XcodeRunnerKit-Package \
  -destination 'platform=macOS,arch=arm64'
```
