#!/bin/bash
set -euo pipefail

# TEAM_ID exports a Developer ID app with Xcode-managed signing; "-" builds an ad-hoc app for local checks.
usage="Usage: build-runner-host.sh TEAM_ID|- [OUTPUT_DIRECTORY]"
team=${1:?$usage}
if [[ $# -gt 2 ]]; then echo "$usage" >&2; exit 2; fi
output=${2:-"$PWD/.build/RunnerHost"}
output="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).expanduser().absolute())' "$output")"
script_directory="$(cd "$(dirname "$0")" && pwd)"
workspace="$script_directory/../App/XcodeHomeRunner.xcworkspace"
derived_data="$output/DerivedData"
app="$output/XcodeHomeRunner.app"
mkdir -p "$output"
if [[ "$team" == "-" ]]; then
    # The Associated Domains entitlement needs a provisioning profile, so ad-hoc builds omit entitlements.
    xcodebuild build -quiet -workspace "$workspace" -scheme XcodeHomeRunner \
        -configuration Release -destination 'generic/platform=macOS' -derivedDataPath "$derived_data" \
        CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGN_ENTITLEMENTS= CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
    built="$derived_data/Build/Products/Release/XcodeHomeRunner.app"
else
    archive="$output/XcodeHomeRunner.xcarchive"
    export_options="$output/ExportOptions.plist"
    rm -rf "$archive" "$output/Export"
    xcodebuild archive -quiet -workspace "$workspace" -scheme XcodeHomeRunner \
        -configuration Release -destination 'generic/platform=macOS' -derivedDataPath "$derived_data" \
        -archivePath "$archive" -allowProvisioningUpdates DEVELOPMENT_TEAM="$team"
    python3 - "$export_options" "$team" <<'PY'
from pathlib import Path
import plistlib, sys
Path(sys.argv[1]).write_bytes(plistlib.dumps({"method": "developer-id", "signingStyle": "automatic", "teamID": sys.argv[2]}))
PY
    xcodebuild -exportArchive -archivePath "$archive" -exportPath "$output/Export" \
        -exportOptionsPlist "$export_options" -allowProvisioningUpdates
    built="$output/Export/XcodeHomeRunner.app"
fi
rm -rf "$app"
ditto "$built" "$app"
codesign --verify --strict "$app"
printf 'Built %s\n' "$app"
