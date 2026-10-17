#!/bin/bash
set -euo pipefail

identity=${1:?Usage: build-runner-host.sh SIGNING_IDENTITY [OUTPUT_DIRECTORY] [EXECUTABLE]}
output=${2:-"$PWD/.build/RunnerHost"}
output="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).expanduser().absolute())' "$output")"
script_directory="$(cd "$(dirname "$0")" && pwd)"
if [[ $# -ge 3 ]]; then
    executable=$3
else
    cd "$script_directory/.."
    swift build -c release --product xcode-runner-host
    executable="$(swift build -c release --show-bin-path)/xcode-runner-host"
fi
app="$output/XcodeRunnerHost.app"
setup="$app/Contents/Resources/HostSetup"
mkdir -p "$app/Contents/MacOS" "$setup"
install -m 755 "$executable" "$app/Contents/MacOS/xcode-runner-host"
for name in install-github-runner.sh enable-hosted-runner.sh cleanup-runner-temp.sh; do
    install -m 755 "$script_directory/$name" "$setup/$name"
done
for name in lock-host-storage.py stop-runner-service.py cleanup-runner-temp.py; do
    install -m 644 "$script_directory/$name" "$setup/$name"
done
python3 - "$app/Contents/Info.plist" <<'PY'
from pathlib import Path
import plistlib, sys
Path(sys.argv[1]).write_bytes(plistlib.dumps({
    "CFBundleIdentifier": "dev.lynnswap.XcodeRunnerHost",
    "CFBundleExecutable": "xcode-runner-host",
    "CFBundleName": "XcodeRunnerHost",
    "CFBundleDisplayName": "XcodeRunnerHost",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": "0.0.0",
    "CFBundleVersion": "1",
    "LSMinimumSystemVersion": "26.0",
    "LSUIElement": True,
    "NSPrincipalClass": "NSApplication",
    "NSRemovableVolumesUsageDescription": "Runs your build and test jobs from storage you selected.",
}))
PY
codesign --force --options runtime --sign "$identity" "$app"
codesign --verify --strict "$app"
printf 'Built %s\n' "$app"
