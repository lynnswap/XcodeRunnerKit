#!/bin/bash
set -euo pipefail
umask 077

directory=${1:?Usage: enable-hosted-runner.sh RUNNER_DIRECTORY; drain its jobs before migrating}
script_directory="$(cd "$(dirname "$0")" && pwd)"
cd "$directory"
test -f .runner
install -m 755 bin/runsvc.sh runsvc.sh.new
trap 'rm -f runsvc.sh.new' EXIT
if [[ -f .service ]]; then
    plist=$(cat .service)
    label=$(python3 - "$plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as f:
    print(plistlib.load(f)["Label"])
PY
)
    cp -p .service .service.before-host
    cp -p "$plist" "$plist.before-host"
    service="gui/$(id -u)/$label"
    python3 "$script_directory/stop-runner-service.py" "$service" --runner-directory "$PWD"
    rm "$plist" .service
fi
mv runsvc.sh.new runsvc.sh
touch .xcode-runner-host
printf 'Opted in %s; the common host discovers it within two seconds.\n' "$PWD"
