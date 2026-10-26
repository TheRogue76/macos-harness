// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HarnessFixtureLinux",
    targets: [
        .systemLibrary(name: "CGtk", pkgConfig: "gtk4", providers: [.apt(["libgtk-4-dev"]), .yum(["gtk4-devel"])]),
        .executableTarget(
            name: "harness-fixture",
            dependencies: ["CGtk"],
            swiftSettings: [.swiftLanguageMode(.v5), .treatAllWarnings(as: .error)]
        ),
    ]
)
