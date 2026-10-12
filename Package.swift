// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "XcodeRunnerKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "XcodeRunnerKit", targets: ["XcodeRunnerKit"]),
        .executable(name: "xcode-runner", targets: ["XcodeRunnerCLI"]),
        .executable(name: "xcode-runner-host", targets: ["XcodeRunnerHost"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", from: "1.0.1"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
    ],
    targets: [
        .target(
            name: "XcodeRunnerKit",
            dependencies: [.product(name: "Subprocess", package: "swift-subprocess")],
            swiftSettings: [.swiftLanguageMode(.v6), .defaultIsolation(nil)]
        ),
        .executableTarget(
            name: "XcodeRunnerCLI",
            dependencies: ["XcodeRunnerKit", .product(name: "ArgumentParser", package: "swift-argument-parser")],
            swiftSettings: [.swiftLanguageMode(.v6), .defaultIsolation(nil)]
        ),
        .executableTarget(
            name: "XcodeRunnerHost",
            dependencies: [
                "XcodeRunnerKit",
                .product(name: "Subprocess", package: "swift-subprocess"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6), .defaultIsolation(nil)]
        ),
        .testTarget(
            name: "XcodeRunnerKitTests",
            dependencies: ["XcodeRunnerKit"],
            swiftSettings: [.swiftLanguageMode(.v6), .defaultIsolation(nil)]
        ),
        .testTarget(
            name: "XcodeRunnerHostTests",
            dependencies: ["XcodeRunnerHost"],
            swiftSettings: [.swiftLanguageMode(.v6), .defaultIsolation(nil)]
        ),
    ]
)
