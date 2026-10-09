import CoreGraphics
import Foundation
import HarnessClient
import HarnessProtocol
import Testing
@testable import HarnessCore

private let dump = """
    <?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation="0">\
    <node index="0" text="" resource-id="android:id/content" class="android.widget.FrameLayout" package="io.example" content-desc="" checkable="false" checked="false" clickable="false" enabled="true" focusable="false" focused="false" scrollable="false" long-clickable="false" password="false" selected="false" bounds="[0,0][1080,2400]" hint="">\
    <node index="0" text="" resource-id="io.example:id/list" class="android.widget.ScrollView" package="io.example" content-desc="" checkable="false" checked="false" clickable="false" enabled="true" focusable="true" focused="false" scrollable="true" long-clickable="false" password="false" selected="false" bounds="[0,200][1080,2400]" hint="">\
    <node index="0" text="TAP ME" resource-id="io.example:id/tap_button" class="android.widget.Button" package="io.example" content-desc="" checkable="false" checked="false" clickable="true" enabled="true" focusable="true" focused="false" scrollable="false" long-clickable="false" password="false" selected="false" bounds="[40,300][1040,420]" hint="" />\
    <node index="1" text="Taps: 2" resource-id="io.example:id/tap_count" class="android.widget.TextView" package="io.example" content-desc="" checkable="false" checked="false" clickable="false" enabled="true" focusable="false" focused="false" scrollable="false" long-clickable="false" password="false" selected="false" bounds="[40,440][1040,500]" hint="" />\
    <node index="2" text="Your name" resource-id="io.example:id/name_field" class="android.widget.EditText" package="io.example" content-desc="" checkable="false" checked="false" clickable="true" enabled="true" focusable="true" focused="true" scrollable="false" long-clickable="true" password="false" selected="false" bounds="[40,520][1040,640]" hint="Your name" />\
    <node index="3" text="Notifications" resource-id="io.example:id/notifications" class="android.widget.Switch" package="io.example" content-desc="" checkable="true" checked="true" clickable="true" enabled="true" focusable="true" focused="false" scrollable="false" long-clickable="false" password="false" selected="false" bounds="[40,660][1040,760]" hint="" />\
    <node index="4" text="" resource-id="" class="android.widget.ImageButton" package="io.example" content-desc="Navigate up" checkable="false" checked="false" clickable="true" enabled="false" focusable="true" focused="false" scrollable="false" long-clickable="false" password="false" selected="false" bounds="[0,100][120,200]" hint="" />\
    <node index="5" text="Play Store" resource-id="" class="android.widget.TextView" package="io.example" content-desc="Play Store" checkable="false" checked="false" clickable="true" enabled="true" focusable="true" focused="false" scrollable="false" long-clickable="true" password="false" selected="false" bounds="[40,780][300,900]" hint="" />\
    </node></node></hierarchy>UI hierchary dumped to: /dev/tty
    """

private func parsed() throws -> RawNode {
    let start = dump.range(of: "<?xml")!.lowerBound
    let end = dump.range(of: "</hierarchy>")!.upperBound
    return try AndroidTree.parse(Data(dump[start..<end].utf8), serial: "emulator-5554", size: CGSize(width: 1080, height: 2400))
}

private func all(_ node: RawNode) -> [RawNode] {
    [node] + node.children.flatMap(all)
}

@Suite struct AndroidTreeTests {
    @Test func readsAndroidClassesAsHarnessRoles() throws {
        let nodes = all(try parsed())
        let button = try #require(nodes.first { $0.identifier == "tap_button" })
        #expect(button.role == "AXButton" && button.label == "TAP ME" && button.actions == ["AXPress"])
        #expect(button.frame == CGRect(x: 40, y: 300, width: 1000, height: 120))
        let count = try #require(nodes.first { $0.identifier == "tap_count" })
        #expect(count.role == "AXStaticText" && count.value == "Taps: 2")
        let field = try #require(nodes.first { $0.identifier == "name_field" })
        #expect(field.role == "AXTextField" && field.value == nil && field.label == "Your name" && field.focused == true)
        let toggle = try #require(nodes.first { $0.identifier == "notifications" })
        #expect(toggle.role == "AXCheckBox" && toggle.subrole == "AXSwitch" && toggle.value == "1")
        let back = try #require(nodes.first { $0.label == "Navigate up" })
        #expect(back.role == "AXButton" && back.enabled == false)
        let icon = try #require(nodes.first { $0.label == "Play Store" })
        #expect(icon.role == "AXButton" && icon.actions.contains("long-press"))
        let list = try #require(nodes.first { $0.identifier == "list" })
        #expect(list.role == "AXScrollArea" && list.actions == ["scroll"])
    }

    @Test func dropsFrameworkContainerIDsAndKeysByPlace() throws {
        let root = try parsed()
        #expect(root.subrole == AndroidTree.screenSubrole)
        #expect(root.frame == CGRect(x: 0, y: 0, width: 1080, height: 2400))
        #expect(root.children[0].identifier == nil)
        let key = try #require(root.children[0].children[0].children[0].key?.base as? AndroidKey)
        #expect(key.path == "0.0.0" && key.resourceID == "io.example:id/tap_button" && key.label == "TAP ME")
    }

    @Test func shapesIntoATreeOfRefs() throws {
        var counter = 0
        let shaped = TreeShaper(window: CGRect(x: 0, y: 0, width: 1080, height: 2400), maxNodes: 50, maxDepth: 20) { _ in
            counter += 1
            return "a\(counter)"
        }.shape(try parsed())
        let scroll = try #require(shaped.root.children.first)
        #expect(scroll.role == "AXScrollArea")
        #expect(scroll.children.map(\.identifier).contains("tap_button"))
        #expect(scroll.children.first { $0.identifier == "tap_button" }?.hit == Point(x: 540, y: 360))
    }
}

@Suite struct AndroidCatalogTests {
    let listing = """
        List of devices attached
        emulator-5554          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a transport_id:2
        R5CT1234ABC            device usb:1-1 product:dm3q model:SM_S918B device:dm3q transport_id:3
        0A1B2C3D               unauthorized usb:1-2 transport_id:4

        """

    @Test func readsAdbDevices() {
        let devices = AndroidCatalog.parseDevices(listing)
        #expect(devices.map(\.serial) == ["emulator-5554", "R5CT1234ABC", "0A1B2C3D"])
        #expect(devices.map(\.kind) == ["emulator", "phone", "phone"])
        #expect(devices[1].name == "SM S918B")
        #expect(devices[2].state == "unauthorized")
    }

    @Test func picksBySerialNameOrTheOnlyRunningOne() throws {
        var devices = AndroidCatalog.parseDevices(listing)
        devices[0].name = "macos_harness_tests"
        devices.append(AndroidDeviceInfo(serial: "", name: "Pixel_9_Pro_XL", kind: "emulator", state: "stopped"))
        #expect(try AndroidCatalog.pick("r5ct1234abc", from: devices).kind == "phone")
        #expect(try AndroidCatalog.pick("macos harness tests", from: devices).serial == "emulator-5554")
        #expect(try AndroidCatalog.pick("Pixel_9_Pro_XL", from: devices).state == "stopped")
        #expect(throws: RPCError.self) { try AndroidCatalog.pick("booted", from: devices) }
        let one = devices.filter { $0.serial == "emulator-5554" }
        #expect(try AndroidCatalog.pick("booted", from: one).serial == "emulator-5554")
    }

    @Test func readsAndroidTargets() {
        #expect(Target(app: "android:booted").androidDevice == "booted")
        #expect(Target(app: "Android:emulator-5554").androidDevice == "emulator-5554")
        #expect(Target(app: "android:").androidDevice == "booted")
        #expect(Target(app: "Android Studio").androidDevice == nil)
    }
}

@Suite struct AndroidInputTests {
    @Test func mapsKeysAndCombinations() throws {
        #expect(try AndroidInput.command(for: "enter") == "input keyevent KEYCODE_ENTER")
        #expect(try AndroidInput.command(for: "ctrl+a") == "input keycombination KEYCODE_CTRL_LEFT KEYCODE_A")
        #expect(try AndroidInput.command(for: "back") == "input keyevent KEYCODE_BACK")
        #expect(try AndroidInput.command(for: "KEYCODE_CAMERA") == "input keyevent KEYCODE_CAMERA")
        #expect(throws: RPCError.self) { try AndroidInput.command(for: "hyper+a") }
    }

    @Test func typesASCIIWithSpacesQuotesAndNewlines() {
        #expect(AndroidInput.commands(for: "Hello world") == ["input text 'Hello%sworld'"])
        #expect(AndroidInput.commands(for: "it's\nok") == ["input text 'it'\\''s'", "input keyevent KEYCODE_ENTER", "input text 'ok'"])
        #expect(AndroidInput.untypable("Café ok") == ["é"])
        #expect(AndroidInput.untypable("tab\tand\nnewline").isEmpty)
    }

    @Test func readsGrantedRuntimePermissions() {
        let dump = """
                install permissions:
                  android.permission.INTERNET: granted=true
                runtime permissions:
                  android.permission.CAMERA: granted=true, flags=[ USER_SET ]
                  android.permission.RECORD_AUDIO: granted=false, flags=[ USER_SET ]
                  android.permission.POST_NOTIFICATIONS: granted=true, flags=[ ]
                disabledComponents:
            """
        #expect(AndroidControl.grantedRuntimePermissions(dump) == ["android.permission.CAMERA", "android.permission.POST_NOTIFICATIONS"])
    }
}

@Suite struct AndroidFlowAndPolicyTests {
    @Test func parsesAndroidSteps() throws {
        let flow = try FlowParser.parse("""
            name: Android
            app: "android:${device}"
            vars: { device: booted }
            steps:
              - android: { action: install, path: app.apk }
              - android: { action: button, button: back }
              - android: { action: rotate, orientation: landscape }
            """)
        #expect(flow.app == "android:booted")
        guard case let .android(install) = flow.steps[0].action, case let .android(back) = flow.steps[1].action else {
            Issue.record("not android steps")
            return
        }
        #expect(install.action == .install && install.path == "app.apk" && install.device == nil)
        #expect(back.button == .back)
        #expect(throws: FlowError.self) { try FlowParser.parse("name: x\nsteps:\n  - android: { action: shake }\n") }
    }

    @Test func blocksAndroidAndItsAppsByName() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("policy.yaml").path
        try "read_only: [Android]\nblocked: [com.example.bank]\n".write(toFile: path, atomically: true, encoding: .utf8)
        let store = PolicyStore(path: path)
        let snapshot = RPCRequest(id: 1, method: SnapshotMethod.name, params: try JSONValue(encoding: SnapshotMethod.Params(target: Target(app: "android:booted"))))
        #expect(await PolicyEnforcer.refusal(for: snapshot, store: store) == nil)
        let tap = RPCRequest(id: 2, method: PointerMethod.name, params: try JSONValue(encoding: PointerMethod.Params(target: Target(app: "android:booted"), action: .click, point: Point(x: 10, y: 10))))
        #expect(await PolicyEnforcer.refusal(for: tap, store: store)?.code == RPCErrorCode.blockedByPolicy)
        let list = RPCRequest(id: 3, method: AndroidMethod.name, params: try JSONValue(encoding: AndroidMethod.Params(action: .list)))
        #expect(await PolicyEnforcer.refusal(for: list, store: store) == nil)
        let launch = RPCRequest(id: 4, method: AndroidMethod.name, params: try JSONValue(encoding: AndroidMethod.Params(action: .launch, package: "com.example.bank")))
        #expect(await PolicyEnforcer.refusal(for: launch, store: store)?.message.contains("blocks") == true)
    }
}
