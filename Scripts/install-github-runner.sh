#!/bin/bash
set -euo pipefail
umask 077

install_github_runner() {
    repository=${1:?Usage: install-github-runner.sh OWNER/REPO NAME ARCHIVE [LABELS]; registration token on stdin}
    runner_name=${2:?Specify a unique runner name}
    archive=${3:?Specify actions-runner-osx-arm64-2.338.0.tar.gz}
    labels=${4:-xcode-runnerkit}
    if [[ $# -gt 5 ]]; then echo "Usage: install-github-runner.sh OWNER/REPO NAME ARCHIVE [LABELS] [SHA256]" >&2; exit 2; fi
    script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    test -r "$script_directory/enable-hosted-runner.sh"
    case "$runner_name" in ""|"."|".."|*/*) echo "Runner name must be one path component." >&2; exit 1;; esac

    # Verified against the official actions/runner v2.338.0 release asset digest.
    expected=${5:-df4cebda25c86a886ed204e49fee63f5c2e7cec5f447b5c98440a826bbdf9df2}
    actual=$(shasum -a 256 "$archive")
    actual=${actual%% *}
    if [[ "$actual" != "$expected" ]]; then
        echo "Runner archive checksum does not match the expected release digest." >&2
        exit 1
    fi
    layout=$("$HOME/Library/Application Support/XcodeRunnerKit/bin/xcode-runner" host storage configure --json)
    runners_root=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["runnersRoot"])' <<< "$layout")
    work_root=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["workDirectory"])' <<< "$layout")
    directory="$runners_root/$runner_name"
    # The official runner's default shell template does not quote its script path.
    case "$directory" in *[[:space:]]*) echo "Runner installation paths must not contain whitespace." >&2; exit 1;; esac
    managed_repository_id=${XCODE_RUNNER_INSTALLATION_REPOSITORY_ID:-}
    installation_owner="$directory/.xcode-runner-installation"
    if [[ -n "$managed_repository_id" ]]; then
        if [[ -e "$directory" ]]; then
            if [[ ! -f "$installation_owner" ]] || [[ "$(cat "$installation_owner")" != "$managed_repository_id" ]]; then
                echo "Existing runner directory is not this repository's incomplete installation: $directory" >&2
                exit 1
            fi
            if [[ -f "$directory/.xcode-runner-host" || -f "$directory/.service" ]]; then
                echo "This runner already has a service; its installation cannot be resumed." >&2
                exit 1
            fi
        else
            mkdir -p "$runners_root"
            mkdir "$directory"
            if ! printf '%s\n' "$managed_repository_id" > "$installation_owner"; then
                echo "Could not record the new runner installation's owner: $directory" >&2
                if ! rm -f "$installation_owner" || ! rmdir "$directory"; then
                    echo "The new incomplete runner directory could not be removed: $directory" >&2
                fi
                exit 1
            fi
        fi
    elif [[ -f "$directory/.runner" ]]; then
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
    if [[ ! -f "$directory/.runner" ]]; then
        tar -xzf "$archive" -C "$directory"
    fi
    cd "$directory"
    if [[ ! -f .runner ]]; then
        ./config.sh --unattended --url "https://github.com/$repository" --token "$registration_token" \
            --name "$runner_name" --labels "$labels" --work "$work_directory"
    fi
    unset registration_token
    hook="ACTIONS_RUNNER_HOOK_JOB_COMPLETED=$hooks_directory/cleanup-runner-temp.sh"
    if [[ ! -f .env ]] || ! grep -Fxq "$hook" .env; then
        printf '%s\n' "$hook" >> .env
    fi
    bash "$script_directory/enable-hosted-runner.sh" "$directory"
    if [[ -n "$managed_repository_id" ]]; then rm "$installation_owner"; fi
    printf 'Registered %s for %s with the common host.\n' "$runner_name" "$repository"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    exec python3 "$(dirname "$0")/lock-host-storage.py" "$0" install_github_runner "$@"
fi
