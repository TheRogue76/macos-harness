import CoreGraphics
import Foundation
import HarnessClient
import HarnessProtocol
import Testing
@testable import HarnessCore

private let listing = """
    {
      "devices": {
        "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
          { "udid": "AAAA-1", "name": "iPhone 18 Pro", "state": "Shutdown", "isAvailable": true,
            "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro" },
          { "udid": "AAAA-2", "name": "Tester", "state": "Booted", "isAvailable": true },
          { "udid": "AAAA-3", "name": "Gone", "state": "Shutdown", "isAvailable": false }
        ],
        "com.apple.CoreSimulator.SimRuntime.iOS-18-6": [
          { "udid": "BBBB-1", "name": "iPhone 18 Pro", "state": "Shutdown", "isAvailable": true },
          { "udid": "BBBB-2", "name": "Tester", "state": "Shutdown", "isAvailable": true }
        ]
      }
    }
    """

@Suite struct SimulatorCatalogTests {
    let devices = try! SimulatorCatalog.parseDevices(
        Data(listing.utf8), deviceTypeNames: ["com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro": "iPhone 18 Pro"]
    )

    @Test func readsAvailableDevicesBootedFirstThenNewestOS() {
        #expect(devices.map(\.udid) == ["AAAA-2", "AAAA-1", "BBBB-1", "BBBB-2"])
        #expect(devices[1].runtime == "iOS 27.0")
        #expect(devices[1].deviceType == "iPhone 18 Pro")
        #expect(devices[2].runtime == "iOS 18.6")
    }

    @Test func picksByUDIDNameOrBooted() throws {
        #expect(try SimulatorCatalog.pick("booted", from: devices).udid == "AAAA-2")
        #expect(try SimulatorCatalog.pick("aaaa-1", from: devices).udid == "AAAA-1")
        #expect(try SimulatorCatalog.pick("tester", from: devices).udid == "AAAA-2")
    }

    @Test func refusesANameSharedByDevicesThatArentBooted() {
        #expect(throws: RPCError.self) { try SimulatorCatalog.pick("iPhone 18 Pro", from: devices) }
    }

    @Test func explainsWhenNothingMatches() {
        do {
            _ = try SimulatorCatalog.pick("iPhone 18", from: devices)
            Issue.record("expected an error")
        } catch let error as RPCError {
            #expect(error.message.contains("Did you mean"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func needsExactlyOneBootedDeviceForBooted() {
        let none = devices.map { device -> SimulatorInfo in
            var copy = device
            copy.state = "Shutdown"
            return copy
        }
        #expect(throws: RPCError.self) { try SimulatorCatalog.pick("booted", from: none) }
    }

    @Test func namesRuntimes() {
        #expect(SimulatorCatalog.runtimeName("com.apple.CoreSimulator.SimRuntime.iOS-27-1") == "iOS 27.1")
        #expect(SimulatorCatalog.runtimeName("com.apple.CoreSimulator.SimRuntime.watchOS-12-0") == "watchOS 12.0")
    }

    @Test func readsSimTargets() {
        #expect(Target(app: "sim:booted").simulatorDevice == "booted")
        #expect(Target(app: "SIM:iPhone 18 Pro").simulatorDevice == "iPhone 18 Pro")
        #expect(Target(app: "sim:").simulatorDevice == "booted")
        #expect(Target(app: "Simulator").simulatorDevice == nil)
    }
}

@Suite struct SimulatorCoordinateTests {
    @Test func convertsBetweenScreenAndDevicePoints() {
        let space = CoordinateSpace(frame: CGRect(x: 821, y: 169, width: 334, height: 726), scale: 402.0 / 334.0)
        #expect(space.size.width.rounded() == 402)
        let local = space.local(CGPoint(x: 821 + 167, y: 169 + 363))
        #expect(local == Point(x: 201, y: 437))
        let global = space.global(Point(x: 201, y: 437))
        #expect(abs(global.x - 988) < 1 && abs(global.y - 532) < 1)
        #expect(space.contains(Point(x: 402, y: 874)))
        #expect(!space.contains(Point(x: 403, y: 10)))
    }

    @Test func shapesTreesInDevicePoints() {
        let screen = CGRect(x: 821, y: 169, width: 334, height: 726)
        let button = RawNode(
            key: AnyHashable("b"), role: "AXButton", title: "Tap me", actions: ["AXPress"],
            frame: CGRect(x: 834, y: 200, width: 307, height: 43)
        )
        let root = RawNode(key: AnyHashable("r"), role: "AXGroup", subrole: "iOSContentGroup", frame: screen, children: [button])
        let shaped = TreeShaper(space: CoordinateSpace(frame: screen, scale: 402.0 / 334.0), maxNodes: 10, maxDepth: 10) { _ in "s1" }.shape(root)
        let node = shaped.root.children[0]
        #expect(node.hit == Point(x: 200, y: 63))
        #expect(node.frame?.width == 370)
    }

    @Test func dropsAValueThatOnlyRepeatsThePlaceholder() {
        let field = RawNode(key: AnyHashable("f"), role: "AXTextField", placeholder: "Your name", value: "Your name")
        let node = TreeShaper(window: .zero, maxNodes: 1, maxDepth: 0) { _ in "s1" }.makeNode(field, visible: nil)
        #expect(node.value == nil)
        #expect(node.label == "Your name")
    }
}

@Suite struct SimulatorKeyboardTests {
    @Test func mapsCharactersToUSKeyCodes() {
        #expect(SimulatorInput.key(for: "a")! == (0, false))
        #expect(SimulatorInput.key(for: "A")! == (0, true))
        #expect(SimulatorInput.key(for: "!")! == (18, true))
        #expect(SimulatorInput.key(for: " ")! == (49, false))
        #expect(SimulatorInput.key(for: "\n")! == (36, false))
    }

    @Test func listsWhatItCantType() {
        #expect(SimulatorInput.untypable("Hello, World! 123").isEmpty)
        #expect(SimulatorInput.untypable("Café 😀 é") == ["é", "😀"])
    }
}

@Suite struct SimulatorScrollingTests {
    typealias Watch = SimulatorScrolling.PageWatch
    let start = Date(timeIntervalSince1970: 1_000)

    func look(_ signature: [String], found: Bool = false) -> SimulatorScrolling.Look {
        let hits = found ? [ElementSearch.Hit(raw: RawNode(role: "AXStaticText", identifier: "last-item"), path: [], visible: nil)] : []
        return SimulatorScrolling.Look(hits: hits, signature: signature)
    }

    func watch(_ reads: [(TimeInterval, [String], Bool)]) -> Watch {
        var watch = Watch(before: ["a@0", "b@40"], started: start)
        for (time, signature, found) in reads {
            watch.see(look(signature, found: found), at: start.addingTimeInterval(time))
        }
        return watch
    }

    @Test func movesOnOnceTheNewPageHoldsStill() {
        let unsettled = watch([(0.3, ["c@0"], false), (0.6, ["c@0", "d@40"], false), (0.9, ["c@0", "d@40"], false)])
        #expect(unsettled.outcome == nil)
        let settled = watch([(0.3, ["c@0"], false), (0.6, ["c@0", "d@40"], false), (1.3, ["c@0", "d@40"], false)])
        #expect(settled.outcome == .moved)
        #expect(settled.latest == ["c@0", "d@40"])
    }

    @Test func callsItTheEndWhenAPageChangesNothing() {
        #expect(watch([(0.3, ["a@0", "b@40"], false), (2.5, ["a@0", "b@40"], false)]).outcome == nil)
        #expect(watch([(0.3, ["a@0", "b@40"], false), (3.1, ["a@0", "b@40"], false)]).outcome == .atEnd)
    }

    @Test func waitsOutAnEmptyTreeInsteadOfCallingItTheEnd() {
        #expect(watch([(1, [], false), (3.5, [], false)]).outcome == nil)
        #expect(watch([(1, [], false), (3.5, [], false), (6.1, [], false)]).outcome == .atEnd)
        let refilled = watch([(1, [], false), (3.5, ["c@0"], false), (4.2, ["c@0"], false)])
        #expect(refilled.outcome == .moved)
    }

    @Test func stopsAsSoonAsTheElementShows() {
        let found = watch([(0.3, ["c@0"], true), (1.5, ["c@0"], false)])
        #expect(found.outcome == .found)
        #expect(found.hits.count == 1)
    }

    @Test func givesUpOnAPageThatKeepsChanging() {
        let reads: [(TimeInterval, [String], Bool)] = (1...20).map { index in (Double(index) * 0.35, ["tick \(index)"], false) }
        #expect(watch(reads).outcome == .moved)
    }

    @Test func startsUpwardWhenTheListCantScrollDown() {
        #expect(SimulatorScrolling.directions(canScrollDown: true) == [.down, .up])
        #expect(SimulatorScrolling.directions(canScrollDown: false) == [.up, .down])
    }

    @Test func signsTheScreenByElementAndPlace() {
        let screen = RawNode(role: "AXGroup", frame: CGRect(x: 0, y: 0, width: 400, height: 800), children: [
            RawNode(role: "AXGroup", children: [
                RawNode(role: "AXButton", title: "Item 1", identifier: "item-1", frame: CGRect(x: 10.4, y: 99.6, width: 380, height: 44)),
            ]),
        ])
        #expect(SimulatorScrolling.Look.signature(of: screen) == ["AXGroup|||-", "AXButton|item-1|Item 1|10,100"])
        #expect(SimulatorScrolling.Look.signature(of: RawNode(role: "AXGroup")).isEmpty)
    }

    @Test func saysHowFarItScrolledWhenNothingMatches() {
        let selector = ElementSelector(identifier: "last-item")
        let missing = SimulatorScrolling.notFound(selector, down: 1, up: 4, timedOut: false)
        #expect(missing.contains("Nothing matches id last-item"))
        #expect(missing.contains("1 page down and 4 up"))
        let slow = SimulatorScrolling.notFound(selector, down: 0, up: 2, timedOut: true)
        #expect(slow.contains("within 35 s"))
    }
}

@Suite struct SettleReplacementTests {
    @Test func reportsAReplacedElementAsOneChange() {
        let old = UINode(ref: "k20", role: "AXStaticText", value: "Swipes: 0", identifier: "swipe-count")
        let new = UINode(ref: "k31", role: "AXStaticText", value: "Swipes: 1", identifier: "swipe-count")
        let other = UINode(ref: "k40", role: "AXButton", label: "OK")
        let changes = Settle.diff(before: [("k20", old)], after: [("k31", new), ("k40", other)])
        #expect(changes.map(\.kind) == ["changed", "added"])
        #expect(changes[0].before?.value == "Swipes: 0")
        #expect(changes[0].node.value == "Swipes: 1")
    }
}

@Suite struct SimulatorPolicyTests {
    @Test func namesSimulatorRequestsBySimTarget() throws {
        let request = RPCRequest(id: 1, method: SimulatorMethod.name, params: try JSONValue(encoding: SimulatorMethod.Params(action: .launch, device: "Tester", bundleIdentifier: "com.example.bank")))
        #expect(PolicyEnforcer.targetApp(of: request) == "sim:Tester")
        #expect(PolicyEnforcer.policyMethod(of: request) == SimulatorMethod.name)
        let list = RPCRequest(id: 2, method: SimulatorMethod.name, params: try JSONValue(encoding: SimulatorMethod.Params(action: .list)))
        #expect(PolicyEnforcer.policyMethod(of: list) == SnapshotMethod.name)
    }

    @Test func blocksSimulatorsAndTheirAppsByName() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("policy.yaml").path
        try "read_only: [Simulator]\nblocked: [com.example.bank]\n".write(toFile: path, atomically: true, encoding: .utf8)
        let store = PolicyStore(path: path)
        let snapshot = RPCRequest(id: 1, method: SnapshotMethod.name, params: try JSONValue(encoding: SnapshotMethod.Params(target: Target(app: "sim:booted"))))
        #expect(await PolicyEnforcer.refusal(for: snapshot, store: store) == nil)
        let press = RPCRequest(id: 2, method: ActMethod.name, params: try JSONValue(encoding: ActMethod.Params(target: Target(app: "sim:booted"), element: ElementSelector(text: "OK"), action: .press)))
        #expect(await PolicyEnforcer.refusal(for: press, store: store)?.code == RPCErrorCode.blockedByPolicy)
        let launch = RPCRequest(id: 3, method: SimulatorMethod.name, params: try JSONValue(encoding: SimulatorMethod.Params(action: .launch, bundleIdentifier: "com.example.bank")))
        #expect(await PolicyEnforcer.refusal(for: launch, store: store)?.message.contains("blocks") == true)
    }
}

@Suite struct SimulatorFlowTests {
    @Test func parsesSimulatorSteps() throws {
        let flow = try FlowParser.parse("""
            name: iOS
            app: "sim:${device}"
            vars: { device: booted }
            setup:
              - build: { project: App.xcodeproj, scheme: App, launch: true }
            steps:
              - sim: { action: button, button: home }
              - sim: { action: launch, bundle_id: com.example.app, args: [-reset], env: { MODE: test } }
              - long-press: { id: hold, hold: 1.5 }
              - swipe: { id: card, left: 200 }
            """)
        #expect(flow.app == "sim:booted")
        guard case let .build(request, install, launch) = flow.setup[0].action else {
            Issue.record("not a build")
            return
        }
        #expect(request.project == "App.xcodeproj" && request.scheme == "App" && install && launch)
        guard case let .simulator(button) = flow.steps[0].action else {
            Issue.record("not a sim step")
            return
        }
        #expect(button.action == .button && button.button == .home && button.device == nil)
        guard case let .simulator(launchStep) = flow.steps[1].action else {
            Issue.record("not a sim step")
            return
        }
        #expect(launchStep.arguments == ["-reset"] && launchStep.environment == ["MODE": "test"])
        guard case let .pointer(press) = flow.steps[2].action else {
            Issue.record("not a pointer step")
            return
        }
        #expect(press.action == .longPress && press.hold == 1.5)
        guard case let .pointer(swipe) = flow.steps[3].action else {
            Issue.record("not a pointer step")
            return
        }
        #expect(swipe.action == .swipe && swipe.dx == -200 && swipe.dy == 0)
    }

    @Test func rejectsUnknownSimulatorActionsAndButtons() {
        #expect(throws: FlowError.self) { try FlowParser.parse("name: x\nsteps:\n  - sim: { action: shake }\n") }
        #expect(throws: FlowError.self) { try FlowParser.parse("name: x\nsteps:\n  - sim: { action: button, button: volume-up }\n") }
    }

    @Test func exportsSimulatorCallsAsSimSteps() throws {
        var entry = JournalEntry(
            time: Date(), session: "s", agent: "Claude Code", agentKey: "k", method: SimulatorMethod.name, app: "sim:booted",
            window: nil, via: nil, error: nil, milliseconds: 10
        )
        entry.action = "launch"
        entry.params = try JSONValue(encoding: SimulatorMethod.Params(action: .launch, device: "booted", bundleIdentifier: "com.example.app"))
        let yaml = FlowExporter.yaml(name: "Replay", entries: [entry])
        #expect(yaml.contains("sim: { action: launch, device: \"booted\", bundle_id: \"com.example.app\" }"))
    }
}
