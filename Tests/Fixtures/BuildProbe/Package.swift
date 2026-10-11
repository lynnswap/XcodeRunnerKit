// swift-tools-version: 6.4
import PackageDescription
let package = Package(
    name: "BuildProbe",
    platforms: [.macOS(.v26), .iOS(.v18)],
    products: [.library(name: "BuildProbe", targets: ["BuildProbe"])],
    targets: [
        .target(name: "CProbe"),
        .target(name: "BuildProbe", dependencies: ["CProbe"]),
        .testTarget(name: "BuildProbeTests", dependencies: ["BuildProbe"]),
    ]
)
