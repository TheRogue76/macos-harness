// swift-tools-version: 6.2
import PackageDescription

let strictSafety: [SwiftSetting] = [.strictMemorySafety(), .treatAllWarnings(as: .error)]

var products: [Product] = [
    .executable(name: "macos-harness", targets: ["MacosHarnessCLI"]),
]

var targets: [Target] = [
    .target(name: "HarnessProtocol", swiftSettings: strictSafety),
    .target(
        name: "HarnessClient",
        dependencies: ["HarnessProtocol", .product(name: "Yams", package: "Yams")],
        swiftSettings: strictSafety
    ),
    .executableTarget(
        name: "MacosHarnessCLI",
        dependencies: [
            "HarnessClient",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ],
        path: "Sources/macos-harness",
        swiftSettings: strictSafety
    ),
    .target(
        name: "HarnessCore",
        dependencies: ["HarnessProtocol", .product(name: "Yams", package: "Yams")],
        swiftSettings: strictSafety
    ),
    .target(name: "HarnessHelperCore", dependencies: ["HarnessCore", "HarnessProtocol"], swiftSettings: strictSafety),
    .testTarget(
        name: "HarnessHelperCoreTests",
        dependencies: ["HarnessHelperCore", "HarnessCore", "HarnessProtocol"],
        swiftSettings: strictSafety
    ),
    .testTarget(name: "HarnessProtocolTests", dependencies: ["HarnessProtocol"], swiftSettings: strictSafety),
    .testTarget(name: "HarnessCoreTests", dependencies: ["HarnessCore", "HarnessClient"], swiftSettings: strictSafety),
    .testTarget(
        name: "HarnessClientTests",
        dependencies: ["HarnessClient", "HarnessProtocol"],
        swiftSettings: strictSafety
    ),
]

#if os(Linux)
products += [
    .executable(name: "macos-harness-helper", targets: ["HarnessLinuxHelper"]),
]
targets += [
    .target(name: "HarnessLinux", dependencies: ["HarnessCore", "HarnessProtocol"], swiftSettings: strictSafety),
    .executableTarget(
        name: "HarnessLinuxHelper",
        dependencies: ["HarnessHelperCore", "HarnessLinux", "HarnessCore", "HarnessProtocol"],
        swiftSettings: strictSafety
    ),
    .testTarget(name: "HarnessLinuxTests", dependencies: ["HarnessLinux", "HarnessCore"], swiftSettings: strictSafety),
    .testTarget(
        name: "HarnessLinuxHelperTests",
        dependencies: ["HarnessLinuxHelper", "HarnessCore", "HarnessProtocol"],
        swiftSettings: strictSafety
    ),
]
#endif

#if os(macOS)
products += [
    .executable(name: "macos-harness-helper", targets: ["MacosHarnessHelper"]),
    .executable(name: "harness-fixture", targets: ["HarnessFixture"]),
]
targets += [
    .target(name: "HarnessMac", dependencies: ["HarnessCore", "HarnessProtocol", .product(name: "Yams", package: "Yams")]),
    .executableTarget(name: "MacosHarnessHelper", dependencies: ["HarnessMac", "HarnessHelperCore", "HarnessCore"]),
    .executableTarget(name: "HarnessFixture"),
    .testTarget(name: "HarnessMacTests", dependencies: ["HarnessMac", "HarnessCore", "HarnessClient"]),
]
#endif

let package = Package(
    name: "macos-harness",
    platforms: [.macOS(.v15)],
    products: products,
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.0"),
    ],
    targets: targets
)
