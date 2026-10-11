#!/usr/bin/env python3
"""Register a dedicated read-only dependency key without copying controller tokens."""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("host", help="SSH host alias for the CI Mac")
parser.add_argument("repository", help="Dependency repository in OWNER/REPO form, using the dependency URL's spelling")
parser.add_argument("--host-root", default="")
args = parser.parse_args()


def github(*arguments):
    return json.loads(subprocess.check_output(["gh", "api", *arguments], text=True))


repository = github("repos/" + args.repository)["full_name"]
alias = "xrk-" + hashlib.sha256(repository.lower().encode()).hexdigest()[:16]
originals = sorted({"https://github.com/" + name + suffix
                    for name in (args.repository, repository) for suffix in ("", ".git")})
configuration = {"root": args.host_root, "repository": repository, "alias": alias, "originals": originals}
host_helper = Path(__file__).with_name("private-dependency-host.py").read_text()


def on_host(operation):
    configuration["operation"] = operation
    return subprocess.check_output(
        ["ssh", args.host, "python3 -c " + shlex.quote(host_helper)],
        input=json.dumps(configuration), text=True,
    ).strip()


public_key = on_host("create-key")
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
        input=json.dumps({"title": "XcodeRunnerKit", "key": public_key, "read_only": True}),
        text=True, stdout=subprocess.PIPE, check=True,
    )
    key_id = json.loads(result.stdout)["id"]

configuration["ssh_keys"] = github("meta")["ssh_keys"]
on_host("configure")
print("Configured read-only deploy key", key_id, "for", repository, "on", args.host)
