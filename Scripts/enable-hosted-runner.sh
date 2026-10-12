#!/bin/bash
set -euo pipefail
umask 077

enable_hosted_runner() {
    directory=${1:?Usage: enable-hosted-runner.sh RUNNER_DIRECTORY; drain its jobs before migrating}
    script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    cd "$directory"
    test -f .runner
    layout=$("$HOME/Library/Application Support/XcodeRunnerKit/bin/xcode-runner" host storage configure --json)
    python3 - "$layout" <<'PY'
import json, os, sys
with open('.runner', encoding='utf-8-sig') as file:
    registered = json.load(file).get('workFolder')
expected = os.path.realpath(os.path.join(json.loads(sys.argv[1])['workDirectory'], os.path.basename(os.getcwd())))
if not isinstance(registered, str) or not os.path.isabs(registered) or os.path.realpath(registered) != expected:
    raise SystemExit(f"Runner work folder does not match the current host storage. Reconfigure this runner with --work '{expected}' before enabling it.")
PY
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
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    exec python3 "$(dirname "$0")/lock-host-storage.py" "$0" enable_hosted_runner "$@"
fi
