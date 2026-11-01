#!/bin/bash
set -euo pipefail

identity=${1:?Usage: build-runner-host.sh SIGNING_IDENTITY [OUTPUT_DIRECTORY]}
if [[ $# -gt 2 ]]; then echo "Usage: build-runner-host.sh SIGNING_IDENTITY [OUTPUT_DIRECTORY]" >&2; exit 2; fi
output=${2:-"$PWD/.build/RunnerHost"}
output="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).expanduser().absolute())' "$output")"
script_directory="$(cd "$(dirname "$0")" && pwd)"
derived_data="$output/DerivedData"
# Xcode adds a debugging entitlement and omits the secure timestamp in plain builds; installed hosts need neither difference.
signing=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO)
if [[ "$identity" != "-" ]]; then signing+=(OTHER_CODE_SIGN_FLAGS=--timestamp); fi
xcodebuild build -quiet \
    -workspace "$script_directory/../App/XcodeRunnerHost.xcworkspace" -scheme XcodeRunnerHost \
    -configuration Release -destination 'generic/platform=macOS' -derivedDataPath "$derived_data" \
    "${signing[@]}"
app="$output/XcodeRunnerHost.app"
rm -rf "$app"
ditto "$derived_data/Build/Products/Release/XcodeRunnerHost.app" "$app"
codesign --verify --strict "$app"
printf 'Built %s\n' "$app"
