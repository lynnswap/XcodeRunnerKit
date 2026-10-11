#!/bin/bash
set -euo pipefail
umask 077

source_app=${1:?Usage: install-runner-host.sh APP [RUNNERS_ROOT] [HOST_ROOT] [APPLICATIONS_DIRECTORY]; drain hosted jobs before updating}
runners_root=${2:-"$HOME/Library/XcodeRunnerKit/runners"}
host_root=${3:-"$HOME/Library/Application Support/XcodeRunnerKit"}
applications=${4:-"$HOME/Applications"}
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
    old_lock=$(python3 - "$HOME/Library/LaunchAgents/$identifier.plist" <<'PY'
from pathlib import Path
import plistlib, sys
with open(sys.argv[1], 'rb') as f:
    args=plistlib.load(f)['ProgramArguments']
print(Path(args[args.index('--runners-root')+1])/'.xcode-runner-host.lock')
PY
)
    python3 "$script_directory/stop-runner-service.py" "$domain/$identifier" --ownership-lock "$old_lock"
    reloaded=1
fi
if [[ -d "$app" ]]; then
    rm -rf "$applications/XcodeRunnerHost.previous.app"
    mv "$app" "$applications/XcodeRunnerHost.previous.app"
fi
mv "$staging/XcodeRunnerHost.app" "$app"
python3 - "$app" "$runners_root" "$host_root" <<'PY'
from pathlib import Path
import plistlib, sys
app, runners, root=map(Path, sys.argv[1:])
identifier="dev.lynnswap.XcodeRunnerHost"
plist=Path.home()/"Library/LaunchAgents"/(identifier+".plist")
plist.write_bytes(plistlib.dumps({
    "Label": identifier,
    "ProgramArguments": [str(app/"Contents/MacOS/xcode-runner-host"), "--runners-root", str(runners), "--logs-directory", str(root/"logs/runners")],
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
