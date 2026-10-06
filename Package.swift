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
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.0"),
    ],
    targets: [
        .target(name: "HarnessProtocol"),
        .target(name: "HarnessCore", dependencies: ["HarnessProtocol", .product(name: "Yams", package: "Yams")]),
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
        .executableTarget(name: "HarnessFixture"),
        .testTarget(name: "HarnessProtocolTests", dependencies: ["HarnessProtocol"]),
        .testTarget(name: "HarnessCoreTests", dependencies: ["HarnessCore", "HarnessClient"]),
    ]
)
