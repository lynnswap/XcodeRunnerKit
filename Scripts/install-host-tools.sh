#!/bin/bash
set -euo pipefail
umask 077

executable=${1:?Usage: install-host-tools.sh EXECUTABLE SOURCE_COMMIT [HOST_ROOT]}
source_commit=${2:?Specify the verified XcodeRunnerKit source commit}
host_root=${3:-"$HOME/Library/Application Support/XcodeRunnerKit"}
mkdir -p "$host_root/bin" "$host_root/Pool" "$host_root/CompilationCache" "$host_root/logs" "$HOME/Library/LaunchAgents"
if [[ -f "$host_root/bin/xcode-runner" ]]; then
    cp -p "$host_root/bin/xcode-runner" "$host_root/bin/xcode-runner.previous"
fi
install -m 755 "$executable" "$host_root/bin/xcode-runner.new"
mv "$host_root/bin/xcode-runner.new" "$host_root/bin/xcode-runner"
printf '%s\n' "$source_commit" > "$host_root/bin/xcode-runner.commit"

python3 - "$host_root" <<'PY'
import os
from pathlib import Path
import plistlib
import sys

root = Path(sys.argv[1])
plist = Path.home() / "Library/LaunchAgents/dev.lynnswap.XcodeRunnerKit.awake.plist"
plist.write_bytes(plistlib.dumps({
    "Label": "dev.lynnswap.XcodeRunnerKit.awake",
    "ProgramArguments": ["/usr/bin/caffeinate", "-i", "-s"],
    "RunAtLoad": True,
    "KeepAlive": True,
    "StandardOutPath": str(root / "logs/awake.stdout.log"),
    "StandardErrorPath": str(root / "logs/awake.stderr.log"),
}))
os.chmod(plist, 0o600)
PY

domain="gui/$(id -u)"
service="$domain/dev.lynnswap.XcodeRunnerKit.awake"
reloaded=0
if launchctl print "$service" >/dev/null 2>&1; then
    launchctl bootout "$service"
    reloaded=1
fi
plist="$HOME/Library/LaunchAgents/dev.lynnswap.XcodeRunnerKit.awake.plist"
if launchctl bootstrap "$domain" "$plist"; then
    :
else
    status=$?
    if [[ "$reloaded" -ne 1 || "$status" -ne 5 ]]; then
        exit "$status"
    fi
    # launchd can briefly return EIO after removing an active service.
    sleep 1
    launchctl bootstrap "$domain" "$plist"
fi
printf 'Installed tools at %s (source %s)\n' "$host_root" "$source_commit"
