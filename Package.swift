// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "macos-harness",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "macos-harness", targets: ["MacosHarnessCLI"]),
        .executable(name: "macos-harness-helper", targets: ["MacosHarnessHelper"]),
        .executable(name: "harness-fixture", targets: ["HarnessFixture"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        // Wire protocol, paths and socket I/O shared by every process.
        .target(name: "HarnessProtocol"),
        // Everything that runs inside the helper app and needs its permissions.
        .target(name: "HarnessCore", dependencies: ["HarnessProtocol"]),
        // Client side: finds, launches and talks to the helper.
        .target(name: "HarnessClient", dependencies: ["HarnessProtocol"]),
        .executableTarget(
            name: "MacosHarnessCLI",
            dependencies: [
                "HarnessClient",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/macos-harness"
        ),
        .executableTarget(name: "MacosHarnessHelper", dependencies: ["HarnessCore"]),
        // Deterministic test target app for the harness's own tests.
        .executableTarget(name: "HarnessFixture"),
        .testTarget(name: "HarnessProtocolTests", dependencies: ["HarnessProtocol"]),
        .testTarget(name: "HarnessCoreTests", dependencies: ["HarnessCore", "HarnessClient"]),
    ]
)
