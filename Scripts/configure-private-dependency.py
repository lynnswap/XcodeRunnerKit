#!/usr/bin/env python3
"""Register a dedicated read-only dependency key without copying controller tokens."""
import argparse
import hashlib
import json
import shlex
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("host", help="SSH host alias for the CI Mac")
parser.add_argument("repository", help="Dependency repository in OWNER/REPO form")
parser.add_argument("--host-root", default="")
args = parser.parse_args()


def github(*arguments):
    return json.loads(subprocess.check_output(["gh", "api", *arguments], text=True))


repository = github("repos/" + args.repository)["full_name"]
alias = "xrk-" + hashlib.sha256(repository.lower().encode()).hexdigest()[:16]
configuration = {"root": args.host_root, "repository": repository, "alias": alias}
remote_create_key = "import json\nfrom pathlib import Path\nimport subprocess\nimport sys\n\nconfiguration = json.load(sys.stdin)\nroot = Path(configuration[\"root\"]).expanduser() if configuration[\"root\"] else Path.home() / \"Library/Application Support/XcodeRunnerKit\"\nkeys = root / \"keys\"\nkeys.mkdir(parents=True, exist_ok=True, mode=0o700)\n(root / \"bin\").mkdir(parents=True, exist_ok=True)\nkey = keys / configuration[\"alias\"]\nif not key.exists():\n    subprocess.run([\"ssh-keygen\", \"-t\", \"ed25519\", \"-N\", \"\", \"-C\",\n                    \"XcodeRunnerKit:\" + configuration[\"repository\"], \"-f\", str(key)],\n                   check=True, stdout=subprocess.DEVNULL)\nprint(key.with_suffix(\".pub\").read_text().strip())\n"
public_key = subprocess.check_output(
    ["ssh", args.host, "python3 -c " + shlex.quote(remote_create_key)],
    input=json.dumps(configuration), text=True,
).strip()
pages = github("--paginate", "--slurp", "repos/" + repository + "/keys")
keys = [key for page in pages for key in page]
existing = next((key for key in keys if key["key"].split()[:2] == public_key.split()[:2]), None)
if existing:
    if not existing["read_only"]:
        raise RuntimeError("The existing dependency key is not read-only: " + str(existing["id"]))
    key_id = existing["id"]
else:
    result = subprocess.run(
        ["gh", "api", "-X", "POST", "repos/" + repository + "/keys", "--input", "-"],
        input=json.dumps({"title": "XcodeRunnerKit M1 Pro", "key": public_key, "read_only": True}),
        text=True, stdout=subprocess.PIPE, check=True,
    )
    key_id = json.loads(result.stdout)["id"]

configuration["ssh_keys"] = github("meta")["ssh_keys"]
remote_configure = r'''
import json
import os
from pathlib import Path
import shlex
import sys

configuration = json.load(sys.stdin)
root = Path(configuration["root"]).expanduser() if configuration["root"] else Path.home() / "Library/Application Support/XcodeRunnerKit"
state = root / "private-dependencies.json"
entries = json.loads(state.read_text()) if state.exists() else {}
entries[configuration["repository"]] = configuration["alias"]

def write(path, text, mode=0o600):
    temporary = path.with_name(path.name + ".new")
    temporary.write_text(text)
    os.chmod(temporary, mode)
    temporary.replace(path)

write(state, json.dumps(entries, indent=2) + "\n")
write(root / "known_hosts", "".join("github.com " + key + "\n" for key in configuration["ssh_keys"]))
ssh = ""
git = ""
for repository, alias in sorted(entries.items()):
    ssh += ("Host " + alias + "\n  HostName github.com\n  User git\n"
            "  IdentityFile " + json.dumps(str(root / "keys" / alias), ensure_ascii=False) + "\n"
            "  IdentitiesOnly yes\n  BatchMode yes\n  StrictHostKeyChecking yes\n"
            "  UserKnownHostsFile " + json.dumps(str(root / "known_hosts"), ensure_ascii=False) + "\n")
    git += ('[url "ssh://git@' + alias + "/" + repository + '"]\n'
            '  insteadOf = https://github.com/' + repository + "\n")
write(root / "ssh_config", ssh)
write(root / "gitconfig", git)
write(root / "bin/git-ssh", "#!/bin/sh\nexec /usr/bin/ssh -F " +
      shlex.quote(str(root / "ssh_config")) + ' "$@"\n', 0o700)
'''
subprocess.run(
    ["ssh", args.host, "python3 -c " + shlex.quote(remote_configure)],
    input=json.dumps(configuration), text=True, check=True,
)
print("Configured read-only deploy key", key_id, "for", repository, "on", args.host)
