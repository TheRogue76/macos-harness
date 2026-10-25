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
    .testTarget(name: "HarnessProtocolTests", dependencies: ["HarnessProtocol"], swiftSettings: strictSafety),
    .testTarget(
        name: "HarnessClientTests",
        dependencies: ["HarnessClient", "HarnessProtocol"],
        swiftSettings: strictSafety
    ),
]

#if os(macOS)
products += [
    .executable(name: "macos-harness-helper", targets: ["MacosHarnessHelper"]),
    .executable(name: "harness-fixture", targets: ["HarnessFixture"]),
]
targets += [
    .target(name: "HarnessCore", dependencies: ["HarnessProtocol", .product(name: "Yams", package: "Yams")]),
    .executableTarget(name: "MacosHarnessHelper", dependencies: ["HarnessCore"]),
    .executableTarget(name: "HarnessFixture"),
    .testTarget(name: "HarnessCoreTests", dependencies: ["HarnessCore", "HarnessClient"]),
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
