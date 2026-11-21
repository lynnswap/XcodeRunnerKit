#!/bin/bash
# Build the native Actions runner and install its JavaScript runtime for this Mac.
set -euo pipefail
script_dir=$(cd "$(dirname "$0")" && pwd)
case "$(uname -m)" in
    arm64)
        go_arch=arm64
        node_arch=arm64
        go_hash=0b5183492292ada170f9b561a834863808dd02edba599e4ad0e89899330020b3
        node_hash=ff6e17d4874b76d272212b908cc020d6e815fba5a6c7eaaa06add725840307fd ;;
    x86_64)
        go_arch=amd64
        node_arch=x64
        go_hash=e820ab780c273ae4a340b79d0f3c4313b74ee029aa3874792145d44b9f4f91da
        node_hash=977614af0504c81045e7fd85596dbca0e5f951b96681516dadafedcca8c447f7 ;;
    *) echo "Unsupported workflow engine architecture: $(uname -m)" >&2; exit 1 ;;
esac
root="$HOME/Library/Application Support/XcodeRunnerKit/WorkflowEngine"
target="$root/act-0.2.98-xrk5"
if [[ -x "$target/xrk-act" && -x "$target/node" ]]; then exit 0; fi
mkdir -p "$root"
staging=$(mktemp -d "$root/.install.XXXXXX")
trap 'chmod -R u+w "$staging" && rm -rf "$staging"' EXIT
cd "$staging"
download() {
    curl --fail --location --silent --show-error --retry 2 --output "$1" "$2"
    echo "$3  $1" | shasum -a 256 -c -
}
download go.tar.gz "https://go.dev/dl/go1.26.10.darwin-$go_arch.tar.gz" "$go_hash"
tar -xzf go.tar.gz
download source.tar.gz https://api.github.com/repos/nektos/act/tarball/v0.2.98 \
    4015d079ab409dc05bc0e5ecbdd88596500e10014911b93a80fe2c207476b28c
mkdir source engine
tar -xzf source.tar.gz --strip-components 1 -C source
(
    cd source
    # act's v4 artifact service needs the v7 upload client's protobuf and URL encodings.
    # The native runner also enforces job timeouts and every runs-on label.
    patch -s -p1 < "$script_dir/workflow-act.patch"
    cp "$script_dir/workflow-act-context.go" pkg/runner/xcode_workflow.go
    cp "$script_dir/workflow-act-step.go" pkg/container/xcode_workflow.go
    GOTOOLCHAIN=local GOCACHE="$staging/go-cache" GOMODCACHE="$staging/modules" \
        "$staging/go/bin/go" build -trimpath -ldflags '-s -w -X main.version=0.2.98' -o "$staging/engine/xrk-act" .
)
node=node-v24.22.3-darwin-$node_arch
download node.tar.gz "https://nodejs.org/dist/v24.22.3/$node.tar.gz" "$node_hash"
tar -xzf node.tar.gz -C engine --strip-components 2 "$node/bin/node"
tar -xzOf node.tar.gz "$node/LICENSE" > engine/Node-LICENSE
cp source/LICENSE engine/act-LICENSE
# Concurrent installers publish only complete directories.
python3 - "$target" <<'PY'
from pathlib import Path
import os, sys
target = Path(sys.argv[1])
try:
    os.rename('engine', target)
except OSError:
    if not all(os.access(target / tool, os.X_OK) for tool in ('xrk-act', 'node')):
        raise
PY
