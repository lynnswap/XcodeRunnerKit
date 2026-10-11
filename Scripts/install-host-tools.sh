#!/bin/bash
set -euo pipefail
umask 077

executable=${1:?Usage: install-host-tools.sh EXECUTABLE SOURCE_COMMIT [HOST_ROOT] [COMPILATION_CACHE_DIRECTORY]}
source_commit=${2:?Specify the verified XcodeRunnerKit source commit}
host_root=${3:-"$HOME/Library/Application Support/XcodeRunnerKit"}
mkdir -p "$host_root"
host_root="$(cd "$host_root" && pwd -P)"
cache_directory=${4:-"$host_root/CompilationCache"}
python3 - "$host_root" "$cache_directory" <<'PY'
from pathlib import Path
import sys
import tempfile

cache = Path(sys.argv[1]) / "CompilationCache"
destination = Path(sys.argv[2]).expanduser().absolute()
relocating = cache.resolve() != destination.resolve()
if relocating and (cache.is_symlink() or cache.exists()):
    if not cache.is_dir() or any(cache.iterdir()):
        raise RuntimeError(f"Preserve or move the existing cache at {cache} before changing its location")
destination.mkdir(parents=True, exist_ok=True)
destination = destination.resolve()
with tempfile.TemporaryFile(dir=destination):
    pass
if relocating:
    with tempfile.TemporaryDirectory(prefix=".cache-link-", dir=cache.parent) as staging:
        link = Path(staging) / "CompilationCache"
        link.symlink_to(destination, target_is_directory=True)
        if cache.exists() and not cache.is_symlink():
            cache.rmdir()
        link.replace(cache)
PY
mkdir -p "$host_root/bin" "$host_root/Pool" "$host_root/logs" "$HOME/Library/LaunchAgents"
if [[ -f "$host_root/bin/xcode-runner" ]]; then
    cp -p "$host_root/bin/xcode-runner" "$host_root/bin/xcode-runner.previous"
    if [[ -f "$host_root/bin/xcode-runner.commit" ]]; then
        cp -p "$host_root/bin/xcode-runner.commit" "$host_root/bin/xcode-runner.commit.previous"
    else
        rm -f "$host_root/bin/xcode-runner.commit.previous"
    fi
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
