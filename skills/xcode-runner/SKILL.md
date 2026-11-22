---
name: xcode-runner
description: Run Xcode tests or a GitHub Actions workflow file from the current Git working tree on an XcodeHomeRunner runner, without a commit or push. Use for requests like "run this test on the runner" or "run the CI workflow on my changes".
---

# Xcode Runner

Run the app helper on the dashboard Mac. Its paired host schedules your working tree on an available runner. Staged, unstaged, and unignored untracked files are included without a commit or push.

The standalone CLI runs builds and tests locally. Use the app helper for paired execution. Adjust it if the app is installed elsewhere.

## Run selected tests

Work from the Git checkout. Pass exactly one of `--package .`, `--workspace`, or `--project` as a relative path, plus a scheme and destination. Use the destination the repository specifies, and `platform=macOS` when it specifies none.

```sh
log=$(mktemp)
/Applications/XcodeHomeRunner.app/Contents/Helpers/xcode-runner test \
  --package . --scheme MyLibrary --destination 'platform=macOS' \
  -- '-only-testing:MyLibraryTests/ParserTests/parsesEmptyInput()' \
  >"$log" 2>&1
```

- Quote Swift Testing names, which keep their `()`. Add `-testPlan` after `--` if needed.
- `test` streams the whole build log, so the example redirects it to a file outside the working tree.
- Run the command on its own so that the exit status you see is its own. A nonzero exit means the run failed or was interrupted.
- Exit 0 is a pass only if tests ran, because a selector that matches nothing also exits 0.

If the dashboard has Xcode, read the result bundle named in the log.

```sh
xcrun xcresulttool get test-results summary --path "/path/from/the/log/Results.xcresult"
```

Report a pass only when the selected tests ran, `passedTests` is above zero and `failedTests` is zero. Without `xcresulttool`, check the named test’s outcome and the executed count at the end of the transferred log. On a nonzero exit, read `testFailures` in the summary. If the build failed before any test ran, read the end of the log instead.

## Run a whole workflow

```sh
/Applications/XcodeHomeRunner.app/Contents/Helpers/xcode-runner workflow run .github/workflows/ci.yml --json
```

The checkout needs an `origin` remote. The event defaults to `workflow_dispatch`. Add `--event pull_request --base <base>` when needed.

The JSON gives the overall status (`passed`, `failed`, or `skipped`) and at most 12 jobs, failures first. The full summary, log, and local artifacts are saved under `XcodeRunnerOutput` at the paths the JSON lists. Read those files when you need a job or detail the JSON leaves out.

Report skipped jobs as skipped. If the run cannot start, report the error message. A `status` of `error` may have no job or artifact paths.

## Keep the defaults

- Leave out `--host`, `--local`, Xcode version, and output directory options unless asked. Choosing a host and waiting for a free runner are automatic, so skip listing hosts.
- Let queued runs finish. Report test failures with the failing test or step.
- If the requested destination cannot run, say so instead of substituting another.
- Follow the repository's test scope. Tests the repository runs directly on this Mac can stay there, and a full workflow is not needed after every edit.

## Limits

Workflows run directly on the runner Mac. Repository secrets and GitHub-generated pull request payloads are unavailable. The runner's Mac is persistent, so trust a pull request's source before sending it.
