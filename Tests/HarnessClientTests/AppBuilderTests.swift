import Foundation
@testable import HarnessClient
import HarnessProtocol
import Testing

private let iosWithCatalyst = """
    Command line invocation:
        /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -project fixtures/ios/HarnessFixtureiOS.xcodeproj -scheme HarnessFixtureiOS -showdestinations



    \tDestinations compatible with the "HarnessFixtureiOS" scheme:
    \t\t{ platform:macOS, arch:arm64, variant:Mac Catalyst, id:00006030-000269843E28001C, name:My Mac }
    \t\t{ platform:macOS, arch:arm64, variant:Designed for [iPad,iPhone], id:00006030-000269843E28001C, name:My Mac }
    \t\t{ platform:iOS, id:dvtdevice-DVTiPhonePlaceholder-iphoneos:placeholder, name:Any iOS Device }
    \t\t{ platform:iOS Simulator, id:dvtdevice-DVTiOSDeviceSimulatorPlaceholder-iphonesimulator:placeholder, name:Any iOS Simulator Device }
    \t\t{ platform:macOS, variant:Mac Catalyst, name:Any Mac }
    \t\t{ platform:iOS Simulator, arch:arm64, id:8E53F967-1DF5-4695-AD4C-9D52CF242980, OS:27.0, name:iPhone 18 Pro Max }

    \tDestinations incompatible with the "HarnessFixtureiOS" scheme:
    \t\t{ platform:watchOS Simulator, arch:arm64, id:C6268BFB-B9F9-4952-8A23-E9376458AA18, OS:27.0, name:Apple Watch SE 3 (40mm), error:Apple Watch SE 3 (40mm)’s watchOS Simulator platform doesn’t match HarnessFixtureiOS.app’s supported platforms. }
    """

private let macOnly = """
    Command line invocation:
        /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -project fixtures/mac/HarnessFixtureMac.xcodeproj -scheme HarnessFixtureMac -showdestinations



    \tDestinations compatible with the "HarnessFixtureMac" scheme:
    \t\t{ platform:macOS, arch:arm64, id:00006030-000269843E28001C, name:My Mac }
    \t\t{ platform:macOS, name:Any Mac }

    \tDestinations incompatible with the "HarnessFixtureMac" scheme:
    \t\t{ platform:iOS Simulator, arch:arm64, id:8E53F967-1DF5-4695-AD4C-9D52CF242980, OS:27.0, name:iPhone 18 Pro Max, error:iPhone 18 Pro Max’s iOS Simulator platform doesn’t match HarnessFixtureMac.app’s supported platforms. }
    """

private let olderXcode = """
    \tAvailable destinations for the "Multi" scheme:
    \t\t{ platform:macOS, arch:x86_64, id:4C4C4544-0000-0000-0000-000000000000, name:My Mac }
    \t\t{ platform:iOS Simulator, id:dvtdevice-DVTiOSDeviceSimulatorPlaceholder-iphonesimulator:placeholder, name:Any iOS Simulator Device }

    \tIneligible destinations for the "Multi" scheme:
    \t\t{ platform:visionOS Simulator, id:dvtdevice-DVTiOSDeviceSimulatorPlaceholder-xrsimulator:placeholder, name:Any visionOS Simulator Device, error:visionOS 2.0 is not installed. }
    """

private let iosNotInstalled = """
    \tAvailable destinations for the "Phone" scheme:
    \t\t{ platform:macOS, arch:arm64, variant:Mac Catalyst, id:00006030-000269843E28001C, name:My Mac }

    \tIneligible destinations for the "Phone" scheme:
    \t\t{ platform:iOS Simulator, id:dvtdevice-DVTiOSDeviceSimulatorPlaceholder-iphonesimulator:placeholder, name:Any iOS Simulator Device, error:iOS 27.1 is not installed. }
    """

private let iPadOnMac = """
    \tDestinations compatible with the "Phone" scheme:
    \t\t{ platform:macOS, arch:arm64, variant:Designed for [iPad,iPhone], id:00006030-000269843E28001C, name:My Mac }
    \t\t{ platform:iOS, id:dvtdevice-DVTiPhonePlaceholder-iphoneos:placeholder, name:Any iOS Device }
    """

private let watchOnly = """
    \tDestinations compatible with the "Watch" scheme:
    \t\t{ platform:watchOS Simulator, id:dvtdevice-DVTiOSDeviceSimulatorPlaceholder-watchsimulator:placeholder, name:Any watchOS Simulator Device }
    """

struct AppBuilderPlatformTests {
    private func platform(_ output: String, mac: Bool = false) throws -> AppBuilder.Platform {
        try AppBuilder.platform(for: AppBuilder.destinations(in: output), mac: mac, scheme: "App")
    }

    @Test func readsCompatibleDestinationsOnly() {
        let listed = AppBuilder.destinations(in: iosWithCatalyst)
        #expect(listed.count == 6)
        #expect(listed[0] == .init(platform: "macOS", arch: "arm64", variant: "Mac Catalyst"))
        #expect(listed[1].variant == "Designed for [iPad,iPhone]")
        #expect(!listed.contains { $0.platform == "watchOS Simulator" })
        #expect(AppBuilder.destinations(in: olderXcode).map(\.platform) == ["macOS", "iOS Simulator"])
        #expect(AppBuilder.destinations(in: iosNotInstalled).map(\.platform) == ["macOS"])
        #expect(AppBuilder.destinations(in: "xcodebuild: error: The project named \"App\" does not contain a scheme named \"Nope\".").isEmpty)
    }

    @Test func aSchemeWithASimulatorBuildsForItUnlessMacIsAsked() throws {
        #expect(try platform(iosWithCatalyst) == .iosSimulator)
        #expect(try platform(iosWithCatalyst, mac: true) == .macCatalyst)
        #expect(try platform(olderXcode) == .iosSimulator)
        #expect(try platform(olderXcode, mac: true) == .macOS)
    }

    @Test func aSchemeWithoutASimulatorBuildsForTheMac() throws {
        #expect(try platform(macOnly) == .macOS)
        #expect(try platform(macOnly, mac: true) == .macOS)
        #expect(try platform(iosNotInstalled) == .macCatalyst)
    }

    @Test func unreadableDestinationsKeepTheOldDefault() throws {
        #expect(try platform("") == .iosSimulator)
        #expect(try platform("", mac: true) == .macOS)
    }

    @Test func refusesPlatformsItCantRun() {
        #expect(throws: RPCError.self) { try platform(iPadOnMac, mac: true) }
        #expect(throws: RPCError.self) { try platform(watchOnly) }
        #expect(throws: RPCError.self) { try platform(watchOnly, mac: true) }
    }

    @Test func destinationsNameTheListedArchitecture() {
        let catalyst = AppBuilder.destinations(in: iosWithCatalyst)
        #expect(AppBuilder.destination(for: .macCatalyst, from: catalyst) == "platform=macOS,arch=arm64,variant=Mac Catalyst")
        #expect(AppBuilder.destination(for: .iosSimulator, from: catalyst) == "generic/platform=iOS Simulator")
        #expect(AppBuilder.destination(for: .macOS, from: AppBuilder.destinations(in: macOnly)) == "platform=macOS,arch=arm64")
        #expect(AppBuilder.destination(for: .macOS, from: AppBuilder.destinations(in: olderXcode)) == "platform=macOS,arch=x86_64")
        #expect(AppBuilder.destination(for: .macOS, from: []) == "platform=macOS")
    }

    @Test func platformsEncodeAsKebabCase() throws {
        #expect(String(decoding: try JSONEncoder().encode(AppBuilder.Platform.macCatalyst), as: UTF8.self) == "\"mac-catalyst\"")
        #expect(AppBuilder.Platform.macOS.isMac && AppBuilder.Platform.macCatalyst.isMac && !AppBuilder.Platform.iosSimulator.isMac)
    }
}

private final class FakeHelper: HarnessCalling, @unchecked Sendable {
    var calls: [(method: String, params: JSONValue)] = []
    var stillRunning: Set<Int32> = []

    func call<M: RPCMethod>(_ method: M.Type, _ params: M.Params, timeout: TimeInterval?) throws -> M.Result {
        let encoded = try JSONValue(encoding: params)
        calls.append((M.name, encoded))
        let result: JSONValue
        switch M.name {
        case AppsMethod.name:
            result = try JSONValue(encoding: AppsMethod.Result(apps: [
                .init(name: "Fixture", bundleIdentifier: "com.example.Fixture", pid: 11, active: false, hidden: false, activationPolicy: "regular", windowCount: 1),
                .init(name: "Fixture", bundleIdentifier: "COM.EXAMPLE.FIXTURE", pid: 12, active: false, hidden: false, activationPolicy: "regular", windowCount: 0),
                .init(name: "Fixture Helper", bundleIdentifier: "com.example.Fixture.Helper", pid: 13, active: false, hidden: false, activationPolicy: "accessory", windowCount: 0),
                .init(name: "Notes", bundleIdentifier: "com.apple.Notes", pid: 14, active: true, hidden: false, activationPolicy: "regular", windowCount: 1),
            ]))
        case QuitMethod.name:
            let pid = Int32(encoded["app"]?.stringValue ?? "") ?? 0
            let app = AppRef(name: "Fixture", bundleIdentifier: "com.example.Fixture", pid: pid)
            result = try JSONValue(encoding: QuitMethod.Result(app: app, quit: !stillRunning.contains(pid), message: "done"))
        case LaunchMethod.name:
            let app = AppRef(name: "Fixture", bundleIdentifier: "com.example.Fixture", pid: 20)
            result = try JSONValue(encoding: LaunchMethod.Result(app: app, windows: [], alreadyRunning: false, milliseconds: 300))
        default:
            throw RPCError(code: RPCErrorCode.methodNotFound, message: M.name)
        }
        return try result.decode(as: M.Result.self)
    }
}

struct MacRunTests {
    private let outcome = AppBuilder.Outcome(
        succeeded: true, scheme: "Fixture", platform: .macOS, appPath: "/tmp/DerivedData/Build/Products/Debug/Fixture.app",
        bundleIdentifier: "com.example.Fixture", errors: [], warnings: 0, seconds: 3, logPath: "/tmp/build.log"
    )

    @Test func quitsOnlyCopiesWithTheBundleIDThenLaunchesTheBuild() throws {
        let helper = FakeHelper()
        let run = try AppBuilder.runOnMac(outcome, caller: helper)
        #expect(run.replaced.map(\.pid) == [11, 12])
        #expect(run.launch.app.pid == 20)
        let quits = helper.calls.filter { $0.method == QuitMethod.name }
        #expect(quits.map { $0.params["app"]?.stringValue } == ["11", "12"])
        #expect(quits.allSatisfy { $0.params["force"] == .bool(false) })
        #expect(helper.calls.last?.method == LaunchMethod.name)
        #expect(helper.calls.last?.params["app"]?.stringValue == outcome.appPath)
    }

    @Test func stopsWhenACopyWontQuit() {
        let helper = FakeHelper()
        helper.stillRunning = [11]
        #expect(throws: RPCError.self) { try AppBuilder.runOnMac(outcome, caller: helper) }
        #expect(!helper.calls.contains { $0.method == LaunchMethod.name })
    }

    @Test func refusesSimulatorBuilds() {
        var simulator = outcome
        simulator.platform = .iosSimulator
        #expect(throws: RPCError.self) { try AppBuilder.runOnMac(simulator, caller: FakeHelper()) }
    }
}

struct MacBuildFlowTests {
    @Test func parsesMacBuildSteps() throws {
        let flow = try FlowParser.parse("""
            name: Mac
            app: fixture
            setup:
              - build: { project: App.xcodeproj, mac: true, launch: true, as: fixture }
            steps:
              - press: { id: increment-button }
            """)
        guard case let .build(request, _, launch, alias) = flow.setup[0].action else {
            Issue.record("not a build")
            return
        }
        #expect(request.mac && request.device == nil && launch && alias == "fixture")
        #expect(flow.setup[0].summary == "build App.xcodeproj for this Mac and launch it as fixture")
    }

    @Test func rejectsContradictoryBuildSteps() {
        #expect(throws: FlowError.self) { try FlowParser.parse("name: x\nsteps:\n  - build: { mac: true, device: booted }\n") }
        #expect(throws: FlowError.self) { try FlowParser.parse("name: x\nsteps:\n  - build: { mac: true, as: fixture }\n") }
    }

    @Test func theToolTakesMac() {
        let build = MCPTools.definitions.first {
            if case .object(let object) = $0 { return object["name"] == .string("build") }
            return false
        }
        guard case .object(let object)? = build, case .object(let schema)? = object["inputSchema"],
              case .object(let properties)? = schema["properties"] else {
            Issue.record("no build tool")
            return
        }
        #expect(properties["mac"] != nil && properties["run"] != nil)
    }
}
