"""Build the separate-process probe against the production Swift package."""
from pathlib import Path
import json
import shutil
import subprocess

REPO = Path(__file__).resolve().parents[1]


def build_execution_pool_probe(destination):
    package = REPO / ".build/ExecutionPoolProbe"
    sources = package / "Sources"
    sources.mkdir(parents=True, exist_ok=True)
    manifest = '''// swift-tools-version: 6.4
import PackageDescription
let package = Package(
    name: "ExecutionPoolProbe",
    platforms: [.macOS(.v26)],
    dependencies: [.package(path: %s)],
    targets: [.executableTarget(
        name: "execution-pool-probe",
        dependencies: [.product(name: "XcodeRunnerKit", package: %s)],
        path: "Sources", sources: ["ExecutionPoolProbe.swift"]
    )]
)
''' % (json.dumps(str(REPO), ensure_ascii=False), json.dumps(REPO.name, ensure_ascii=False))
    manifest_path = package / "Package.swift"
    if not manifest_path.exists() or manifest_path.read_text() != manifest:
        manifest_path.write_text(manifest)
    shutil.copy2(REPO / "Tests/Fixtures/ExecutionPoolProbe.swift", sources)
    shutil.copy2(REPO / "Package.resolved", package)
    arguments = [
        "xcrun", "swift", "build",
        "--package-path", str(package),
        "--scratch-path", str(package / "Build"),
        "--disable-automatic-resolution",
    ]
    subprocess.run([*arguments, "--product", "execution-pool-probe"], check=True)
    products = subprocess.run([*arguments, "--show-bin-path"], check=True,
                              capture_output=True, text=True)
    shutil.copy2(Path(products.stdout.strip()) / "execution-pool-probe", destination)
