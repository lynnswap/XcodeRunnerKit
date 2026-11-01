#!/bin/bash
set -euo pipefail
umask 077

usage="Usage: install-runner-host.sh APP [STORAGE_DIRECTORY]; drain hosted jobs before updating"
source_app=${1:?$usage}
if [[ $# -gt 2 ]]; then echo "$usage" >&2; exit 2; fi
identifier=lynnpd.xcodehomerunner
# Hosts installed before the XcodeHomeRunner rename used this label and app name.
legacy_identifier=dev.lynnswap.XcodeRunnerHost
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
if d["CFBundleIdentifier"] != "lynnpd.xcodehomerunner" or d["CFBundleExecutable"] != "XcodeHomeRunner":
    raise RuntimeError("The app is not an XcodeHomeRunner bundle")
PY
# The app's own CLI configures storage, so a new Mac needs nothing installed first.
configuration=(host storage configure --json)
if [[ $# -eq 2 ]]; then configuration+=(--directory "$2"); fi
layout=$("$source_app/Contents/Helpers/xcode-runner" "${configuration[@]}")
runners_root=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["runnersRoot"])' <<< "$layout")
host_root=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["hostRoot"])' <<< "$layout")
applications=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["applicationsDirectory"])' <<< "$layout")
mkdir -p "$applications" "$runners_root" "$host_root/bin" "$host_root/logs/runners" "$HOME/Library/LaunchAgents"
runners_root="$(cd "$runners_root" && pwd -P)"
host_root="$(cd "$host_root" && pwd -P)"
applications="$(cd "$applications" && pwd -P)"
domain="gui/$(id -u)"
reloaded=0
app="$applications/XcodeHomeRunner.app"
staging=$(mktemp -d "$applications/.runner-host.XXXXXX")
trap 'rm -rf "$staging"' EXIT
ditto "$source_app" "$staging/XcodeHomeRunner.app"
codesign --verify --strict "$staging/XcodeHomeRunner.app"
if launchctl print "$domain/$identifier" >/dev/null 2>&1; then
    python3 "$script_directory/stop-runner-service.py" "$domain/$identifier" --ownership-lock "$runners_root/.xcode-runner-host.lock"
    reloaded=1
fi
if launchctl print "$domain/$legacy_identifier" >/dev/null 2>&1; then
    python3 "$script_directory/stop-runner-service.py" "$domain/$legacy_identifier" --ownership-lock "$runners_root/.xcode-runner-host.lock"
fi
rm -f "$HOME/Library/LaunchAgents/$legacy_identifier.plist"
if [[ -d "$applications/XcodeRunnerHost.app" ]]; then
    rm -rf "$applications/XcodeRunnerHost.previous.app"
    mv "$applications/XcodeRunnerHost.app" "$applications/XcodeRunnerHost.previous.app"
fi
if [[ -d "$app" ]]; then
    rm -rf "$applications/XcodeHomeRunner.previous.app"
    mv "$app" "$applications/XcodeHomeRunner.previous.app"
fi
mv "$staging/XcodeHomeRunner.app" "$app"
# Jobs, runner setup, and SSH sessions run bin/xcode-runner, so it always resolves to the installed app's CLI.
cli="$host_root/bin/xcode-runner"
if [[ -f "$cli" && ! -L "$cli" ]]; then
    # Earlier versions installed a separate CLI; keep it so the previous app can be restored with it.
    cp -p "$cli" "$cli.previous"
    if [[ -f "$cli.commit" ]]; then mv "$cli.commit" "$cli.commit.previous"; else rm -f "$cli.commit.previous"; fi
fi
rm -f "$cli.new"
ln -s "$app/Contents/Helpers/xcode-runner" "$cli.new"
mv -f "$cli.new" "$cli"
python3 - "$app" "$host_root" <<'PY'
from pathlib import Path
import os, plistlib, sys
app, root=map(Path, sys.argv[1:])
# CI needs the Mac awake while the user is logged in.
awake=Path.home()/"Library/LaunchAgents/dev.lynnswap.XcodeRunnerKit.awake.plist"
awake.write_bytes(plistlib.dumps({
    "Label": "dev.lynnswap.XcodeRunnerKit.awake",
    "ProgramArguments": ["/usr/bin/caffeinate", "-i", "-s"],
    "RunAtLoad": True,
    "KeepAlive": True,
    "StandardOutPath": str(root/"logs/awake.stdout.log"),
    "StandardErrorPath": str(root/"logs/awake.stderr.log"),
}))
os.chmod(awake, 0o600)
identifier="lynnpd.xcodehomerunner"
plist=Path.home()/"Library/LaunchAgents"/(identifier+".plist")
plist.write_bytes(plistlib.dumps({
    "Label": identifier,
    "ProgramArguments": [str(app/"Contents/MacOS/XcodeHomeRunner"), "--settings-service"],
    "MachServices": {"lynnpd.xcodehomerunner.settings": True},
    "AssociatedBundleIdentifiers": [identifier],
    "RunAtLoad": True,
    "KeepAlive": {"SuccessfulExit": False},
    "ThrottleInterval": 5,
    "ExitTimeOut": 60,
    "StandardOutPath": str(root/"logs/runner-host.stdout.log"),
    "StandardErrorPath": str(root/"logs/runner-host.stderr.log"),
}))
PY
awake="$domain/dev.lynnswap.XcodeRunnerKit.awake"
if ! launchctl print "$awake" >/dev/null 2>&1; then
    launchctl bootstrap "$domain" "$HOME/Library/LaunchAgents/dev.lynnswap.XcodeRunnerKit.awake.plist"
fi
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
