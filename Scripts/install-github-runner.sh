#!/bin/bash
set -euo pipefail
umask 077

repository=${1:?Usage: install-github-runner.sh OWNER/REPO NAME ARCHIVE [RUNNERS_ROOT] [WORK_DIRECTORY] [LABELS]; registration token on stdin}
runner_name=${2:?Specify a unique runner name}
archive=${3:?Specify actions-runner-osx-arm64-2.338.0.tar.gz}
runners_root=${4:-"$HOME/Library/XcodeRunnerKit/runners"}
work_directory=${5:-_work}
labels=${6:-xcode-runnerkit}
script_directory="$(cd "$(dirname "$0")" && pwd)"
case "$runner_name" in ""|"."|".."|*/*) echo "Runner name must be one path component." >&2; exit 1;; esac

# Verified against the official actions/runner v2.338.0 release asset digest.
expected=df4cebda25c86a886ed204e49fee63f5c2e7cec5f447b5c98440a826bbdf9df2
actual=$(shasum -a 256 "$archive")
actual=${actual%% *}
if [[ "$actual" != "$expected" ]]; then
    echo "Runner archive checksum does not match the pinned release." >&2
    exit 1
fi
runners_root="$(python3 -c 'import os, sys; print(os.path.abspath(sys.argv[1]))' "$runners_root")"
directory="$runners_root/$runner_name"
# The official runner's default shell template does not quote its script path.
case "$directory$work_directory" in *[[:space:]]*) echo "Runner installation and work paths must not contain whitespace." >&2; exit 1;; esac
if [[ -f "$directory/.runner" ]]; then
    echo "Runner already configured at $directory; use its service commands or remove its registration before reinstalling." >&2
    exit 1
fi
IFS= read -r registration_token
mkdir -p "$directory"
tar -xzf "$archive" -C "$directory"
cd "$directory"
./config.sh --unattended --url "https://github.com/$repository" --token "$registration_token" \
    --name "$runner_name" --labels "$labels" --work "$work_directory"
unset registration_token
mkdir -p hooks
install -m 755 "$script_directory/cleanup-runner-temp.sh" hooks/cleanup-runner-temp.sh
install -m 644 "$script_directory/cleanup-runner-temp.py" hooks/cleanup-runner-temp.py
printf 'ACTIONS_RUNNER_HOOK_JOB_COMPLETED=%s/hooks/cleanup-runner-temp.sh\n' "$directory" >> .env
./svc.sh install
plist=$(cat .service)
if ! launchctl bootstrap "gui/$(id -u)" "$plist"; then
    echo "Runner is registered and its service is installed at $plist, but service startup failed. Log in to the CI user's GUI session and start the installed service." >&2
    exit 1
fi
printf 'Registered %s for %s; service %s\n' "$runner_name" "$repository" "$plist"
