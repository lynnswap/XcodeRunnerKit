# XcodeRunnerKit

XcodeRunnerKit runs `xcodebuild` on the Mac calling your Swift code. Use it
to build a project, run selected tests, or collect logs and result bundles
from your own macOS tool. For builds on a paired Mac, use the
[XcodeHomeRunner app and CLI](../../README.md).

## Add the SDK

Use a Swift 6.4 or later toolchain and a macOS 26 or later deployment target.
Add the repository to your package's `dependencies`.

```swift
.package(url: "https://github.com/lynnswap/XcodeHomeRunner.git", branch: "main")
```

In the target that will run Xcode, add the library product.

```swift
.product(name: "XcodeRunnerKit", package: "XcodeHomeRunner")
```

When you update an existing manifest to this URL, also change the product's
`package:` argument to `"XcodeHomeRunner"`. Swift files still use
`import XcodeRunnerKit`.

In an Xcode project, add the same repository URL under **Package Dependencies**,
choose the `main` branch, and add **XcodeRunnerKit** to your target.

## Run a test

The Mac running the tool needs Xcode and the SDK for the chosen destination.
This example runs tests for the `App` scheme in a workspace and writes build
output to the terminal as it arrives. Replace the workspace URL and scheme
with your own.

```swift
import Foundation
import XcodeRunnerKit

let request = XcodeBuildRequest(
    source: .workspace(URL(filePath: "/path/to/App.xcworkspace")),
    scheme: "App",
    destination: .specifier("platform=macOS"),
    outputDirectory: URL.temporaryDirectory.appending(path: "XcodeRunnerOutput")
)

let runner = XcodeRunner()
do {
    let result = try await runner.run(.test, request: request) { data in
        try FileHandle.standardOutput.write(contentsOf: data)
    }
    print(result.resultBundleURL.path())
} catch let failure as XcodeBuildFailure {
    if let result = failure.result {
        print(result.logURL.path())
    }
    throw failure
}
```

Use `.project(url)` for an Xcode project or `.package(url)` for a Swift
package directory. To select an Xcode installation, pass its
`Contents/Developer` URL to `XcodeRunner(developerDirectory:)`. Set
`buildSettings`, `environment`, or `arguments` on a mutable request to
pass build settings, environment variables, or additional `xcodebuild`
arguments such as a test filter.

Each operation creates a job directory under `outputDirectory` for
`xcodebuild.log` and, when Xcode produces it, `Results.xcresult`.
Cancelling the Swift task stops the run. `run` throws `XcodeBuildFailure`
for build, cancellation, and cleanup failures. Its `result` is available
once a job directory exists, and `cleanupErrors` records any failures that
occurred while releasing resources.

## Share build products, Simulators, or compiler output

- To run previously built tests, use `.buildForTesting` followed by
  `.testWithoutBuilding` with the same `derivedDataDirectory`.
- For a managed Simulator, create a `SimulatorConfiguration` with the runtime
  and device type identifiers, then pass `.managedSimulator(configuration)`
  as the request's destination. Set `reusesDevice` to `false` for a fresh device.
- To limit simultaneous operations on one Mac, configure a
  `HostExecutionPool` with `configure(maximumConcurrentJobs:)` and assign
  it to `runner.executionPool` on a mutable runner. Use the same pool directory
  in each process that shares the limit.
- To reuse compiler output across jobs with separate DerivedData, set
  `request.compilationCache` to a `CompilationCache(directory:)`.
  Enable `mapsSourceDirectory` to share entries across checkout paths. This
  changes paths in debug information, coverage, and `#filePath` and affects
  tests that use those paths to read fixtures.
