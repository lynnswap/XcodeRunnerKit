#!/usr/bin/env python3
"""Host-side key and SwiftPM mirror configuration for the controller helper."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys

configuration = json.load(sys.stdin)
root = (Path(configuration["root"]).expanduser() if configuration["root"] else Path.home() / "Library/Application Support/XcodeRunnerKit").resolve()
keys = root / "keys"
keys.mkdir(parents=True, exist_ok=True, mode=0o700)
(root / "bin").mkdir(parents=True, exist_ok=True)
repository = configuration["repository"]
alias = configuration["alias"]
key = keys / alias

if configuration["operation"] == "create-key":
    if not key.exists():
        subprocess.run(["ssh-keygen", "-t", "ed25519", "-N", "", "-C",
                        "XcodeRunnerKit:" + repository, "-f", str(key)],
                       check=True, stdout=subprocess.DEVNULL)
    print(key.with_suffix(".pub").read_text().strip())
elif configuration["operation"] == "configure":
    state = root / "private-swiftpm-dependencies.json"
    entries = json.loads(state.read_text()) if state.exists() else {}
    originals = set(entries.get(repository, {}).get("originals", []))
    originals.update(configuration["originals"])
    entries[repository] = {"alias": alias, "originals": sorted(originals)}

    def write(path, text, mode=0o600):
        temporary = path.with_name(path.name + ".new")
        temporary.write_text(text)
        os.chmod(temporary, mode)
        temporary.replace(path)

    ssh = ""
    mirrors = []
    for name, entry in sorted(entries.items()):
        ssh += ("Host " + entry["alias"] + "\n  HostName github.com\n  User git\n"
                "  IdentityFile " + json.dumps(str(keys / entry["alias"]), ensure_ascii=False) + "\n"
                "  IdentitiesOnly yes\n  BatchMode yes\n  StrictHostKeyChecking yes\n"
                "  UserKnownHostsFile " + json.dumps(str(root / "known_hosts"), ensure_ascii=False) + "\n")
        mirrors.extend({"original": original, "mirror": "ssh://git@" + entry["alias"] + "/" + name + ".git"}
                       for original in entry["originals"])
    write(root / "known_hosts", "".join("github.com " + value + "\n" for value in configuration["ssh_keys"]))
    write(root / "ssh_config", ssh)
    write(root / "bin/git-ssh", "#!/bin/sh\nexec /usr/bin/ssh -F " +
          shlex.quote(str(root / "ssh_config")) + ' "$@"\n', 0o700)
    write(root / "mirrors.json", json.dumps({"version": 1, "object": mirrors}, indent=2) + "\n")
    write(state, json.dumps(entries, indent=2) + "\n")
else:
    raise ValueError("Unknown dependency setup operation: " + configuration["operation"])
