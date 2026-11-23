# XcodeHomeRunner

Run Xcode builds, tests, and GitHub Actions workflows on another Mac from your
current Git checkout. The dashboard sends your working tree, including
uncommitted changes and new files that Git does not ignore. A host assigns the
job to an available runner and sends the results back to your Mac.

- [Set up a host and pair your dashboard](Documentation/NativeHost.md#install).
  A single Mac can host and run jobs.
- [Connect a host to GitHub](Documentation/NativeHost.md#connect-github) to use
  its Macs as self-hosted Actions runners.
- [Use XcodeRunnerKit from Swift](Sources/XcodeRunnerKit/README.md) to run
  Xcode locally from your own macOS tool.

## Run tests from your dashboard

After pairing, open a terminal in the Git checkout you want to test. This
example runs a test suite in a Swift package. Replace the scheme and test
identifier with ones from your project.

```sh
runner=/Applications/XcodeHomeRunner.app/Contents/Helpers/xcode-runner

"$runner" test --package . --scheme MyLibrary --destination 'platform=macOS' \
  -- '-only-testing:MyLibraryTests/ParserTests'
```

For an app, pass `--workspace App.xcworkspace` or `--project App.xcodeproj`.
Omit the filter after `--` to run the scheme's tests. The CLI streams the
build log and copies the log and any result bundle to `XcodeRunnerOutput`
in your checkout. For Simulator destinations, local builds, and agent setup,
see the [CLI guide](Documentation/CLI.md).

## Run a workflow before pushing

[Install the workflow engine](Documentation/NativeHost.md#run-a-workflow-from-a-dashboard)
on the runner. From a dashboard checkout with an `origin` remote, choose a
workflow file and an event it declares. For example, from an XcodeHomeRunner
checkout, run

```sh
"$runner" workflow run .github/workflows/native-ci.yml --event pull_request --base main --json
```

The JSON result includes job outcomes and the paths to the full summary, logs,
and uploaded artifacts on your dashboard.

For a clone of this repository made under its previous name, update `origin`
so the local workflow sees `lynnswap/XcodeHomeRunner` as `github.repository`.

```sh
git remote set-url origin https://github.com/lynnswap/XcodeHomeRunner.git
```

## Development

Open `XcodeRunnerKit.xcworkspace` to work on the Swift package and the
XcodeHomeRunner app together. Building from source requires Swift 6.4 or
later and macOS 26 or later. Keep the workspace and package copies of
`Package.resolved` in sync. To override the signing team, set `DEVELOPMENT_TEAM`
in the ignored `App/Configurations/Signing.local.xcconfig`.

Run this repository’s tests directly on the development Mac so they can run
while you are changing the runner service itself.

```sh
xcodebuild test -scheme XcodeRunnerKit-Package -destination 'platform=macOS,arch=arm64'
```

The [CI workflow](.github/workflows/native-ci.yml) runs the macOS tests and
checks the CLI and host app. For changes to Simulator leasing, cleanup, or
iOS destinations, also run the device checks with the CLI from your checkout.

```sh
swift build -c release --product xcode-runner
DEVELOPER_DIR="$(xcode-select -p)" python3 Scripts/check-simulators.py .build/release/xcode-runner
```

## License

[MIT](LICENSE).
