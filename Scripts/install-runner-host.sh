#!/bin/bash
set -euo pipefail
umask 077

source_app=${1:?Usage: install-runner-host.sh APP; drain hosted jobs before updating}
if [[ $# -ne 1 ]]; then echo "Usage: install-runner-host.sh APP" >&2; exit 2; fi
identifier=dev.lynnswap.XcodeRunnerHost
script_directory="$(cd "$(dirname "$0")" && pwd)"
codesign --verify --strict "$source_app"
signature=$(codesign -dv "$source_app" 2>&1)
if [[ "$signature" == *Signature=adhoc* ]]; then
    echo "Use a certificate signing identity for persistent macOS privacy permissions." >&2
    exit 1
fi
python3 - "$source_app" <<'PY'
from pathlib import Path
import plistlib, sys
d=plistlib.loads((Path(sys.argv[1])/"Contents/Info.plist").read_bytes())
if d["CFBundleIdentifier"] != "dev.lynnswap.XcodeRunnerHost" or d["CFBundleExecutable"] != "xcode-runner-host":
    raise RuntimeError("The app is not an XcodeRunnerHost bundle")
PY
layout=$("$HOME/Library/Application Support/XcodeRunnerKit/bin/xcode-runner" host storage configure --json)
runners_root=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["runnersRoot"])' <<< "$layout")
host_root=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["hostRoot"])' <<< "$layout")
applications=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["applicationsDirectory"])' <<< "$layout")
mkdir -p "$applications" "$runners_root" "$host_root/logs/runners" "$HOME/Library/LaunchAgents"
runners_root="$(cd "$runners_root" && pwd -P)"
host_root="$(cd "$host_root" && pwd -P)"
applications="$(cd "$applications" && pwd -P)"
domain="gui/$(id -u)"
reloaded=0
app="$applications/XcodeRunnerHost.app"
staging=$(mktemp -d "$applications/.runner-host.XXXXXX")
trap 'rm -rf "$staging"' EXIT
ditto "$source_app" "$staging/XcodeRunnerHost.app"
codesign --verify --strict "$staging/XcodeRunnerHost.app"
if launchctl print "$domain/$identifier" >/dev/null 2>&1; then
    python3 "$script_directory/stop-runner-service.py" "$domain/$identifier" --ownership-lock "$runners_root/.xcode-runner-host.lock"
    reloaded=1
fi
if [[ -d "$app" ]]; then
    rm -rf "$applications/XcodeRunnerHost.previous.app"
    mv "$app" "$applications/XcodeRunnerHost.previous.app"
fi
mv "$staging/XcodeRunnerHost.app" "$app"
python3 - "$app" "$host_root" <<'PY'
from pathlib import Path
import plistlib, sys
app, root=map(Path, sys.argv[1:])
identifier="dev.lynnswap.XcodeRunnerHost"
plist=Path.home()/"Library/LaunchAgents"/(identifier+".plist")
plist.write_bytes(plistlib.dumps({
    "Label": identifier,
    "ProgramArguments": [str(app/"Contents/MacOS/xcode-runner-host"), "--settings-service"],
    "MachServices": {"dev.lynnswap.XcodeRunnerHost.Settings": True},
    "AssociatedBundleIdentifiers": [identifier],
    "RunAtLoad": True,
    "KeepAlive": {"SuccessfulExit": False},
    "ThrottleInterval": 5,
    "ExitTimeOut": 60,
    "StandardOutPath": str(root/"logs/runner-host.stdout.log"),
    "StandardErrorPath": str(root/"logs/runner-host.stderr.log"),
}))
PY
plist="$HOME/Library/LaunchAgents/$identifier.plist"
if launchctl bootstrap "$domain" "$plist"; then
    :
else
    status=$?
    if [[ "$reloaded" -ne 1 || "$status" -ne 5 ]]; then
        echo "Installed $app and $plist, but service startup failed." >&2
        exit "$status"
    fi
    # launchd can briefly return EIO after removing an active service.
    sleep 1
    launchctl bootstrap "$domain" "$plist"
fi
printf 'Installed %s; service %s/%s\n' "$app" "$domain" "$identifier"
