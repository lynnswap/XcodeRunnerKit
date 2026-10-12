#!/bin/bash
set -euo pipefail
umask 077

repository=${1:?Usage: install-github-runner.sh OWNER/REPO NAME ARCHIVE [LABELS]; registration token on stdin}
runner_name=${2:?Specify a unique runner name}
archive=${3:?Specify actions-runner-osx-arm64-2.338.0.tar.gz}
labels=${4:-xcode-runnerkit}
if [[ $# -gt 4 ]]; then echo "Usage: install-github-runner.sh OWNER/REPO NAME ARCHIVE [LABELS]" >&2; exit 2; fi
script_directory="$(cd "$(dirname "$0")" && pwd)"
test -r "$script_directory/enable-hosted-runner.sh"
case "$runner_name" in ""|"."|".."|*/*) echo "Runner name must be one path component." >&2; exit 1;; esac

# Verified against the official actions/runner v2.338.0 release asset digest.
expected=df4cebda25c86a886ed204e49fee63f5c2e7cec5f447b5c98440a826bbdf9df2
actual=$(shasum -a 256 "$archive")
actual=${actual%% *}
if [[ "$actual" != "$expected" ]]; then
    echo "Runner archive checksum does not match the pinned release." >&2
    exit 1
fi
layout=$("$HOME/Library/Application Support/XcodeRunnerKit/bin/xcode-runner" host storage configure --json)
runners_root=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["runnersRoot"])' <<< "$layout")
work_root=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["workDirectory"])' <<< "$layout")
directory="$runners_root/$runner_name"
# The official runner's default shell template does not quote its script path.
case "$directory" in *[[:space:]]*) echo "Runner installation paths must not contain whitespace." >&2; exit 1;; esac
if [[ -f "$directory/.runner" ]]; then
    echo "Runner already configured at $directory; use its service commands or remove its registration before reinstalling." >&2
    exit 1
fi
work_path="$work_root/$runner_name"
mkdir -p "$work_path"
work_directory="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$work_path")"
probe=$(mktemp "$work_directory/.xcode-runnerkit-setup.XXXXXX")
rm "$probe"
hooks_directory="$HOME/Library/XcodeRunnerKit/hooks/$runner_name"
case "$hooks_directory" in *[[:space:]]*) echo "Hook paths must not contain whitespace." >&2; exit 1;; esac
mkdir -p "$hooks_directory"
install -m 755 "$script_directory/cleanup-runner-temp.sh" "$hooks_directory/cleanup-runner-temp.sh"
install -m 644 "$script_directory/cleanup-runner-temp.py" "$hooks_directory/cleanup-runner-temp.py"
IFS= read -r registration_token
mkdir -p "$directory"
tar -xzf "$archive" -C "$directory"
cd "$directory"
./config.sh --unattended --url "https://github.com/$repository" --token "$registration_token" \
    --name "$runner_name" --labels "$labels" --work "$work_directory"
unset registration_token
printf 'ACTIONS_RUNNER_HOOK_JOB_COMPLETED=%s/cleanup-runner-temp.sh\n' "$hooks_directory" >> .env
bash "$script_directory/enable-hosted-runner.sh" "$directory"
printf 'Registered %s for %s with the common host.\n' "$runner_name" "$repository"
