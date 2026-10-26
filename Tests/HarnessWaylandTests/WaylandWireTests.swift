import Foundation
import Testing
@testable import HarnessWayland

struct WaylandWireTests {
    @Test func encodesAHeaderWithTheSizeAndOpcode() {
        let (bytes, fds) = WaylandWire.encode(object: 1, opcode: 1, [.newID(2)])
        #expect(bytes == [1, 0, 0, 0, 1, 0, 12, 0, 2, 0, 0, 0])
        #expect(fds.isEmpty)
    }

    @Test func padsStringsAndArraysToWords() {
        let (bytes, _) = WaylandWire.encode(object: 3, opcode: 0, [.uint(7), .string("wl_shm"), .array([1, 2, 3]), .string(nil)])
        #expect(bytes.count == 8 + 4 + 4 + 8 + 4 + 4 + 4)
        #expect(Array(bytes[16..<24]) == Array("wl_shm".utf8) + [0, 0])
        #expect(Array(bytes[24..<32]) == [3, 0, 0, 0, 1, 2, 3, 0])
        #expect(Array(bytes[32..<36]) == [0, 0, 0, 0])
    }

    @Test func sendsDescriptorsBesideTheMessage() {
        let (bytes, fds) = WaylandWire.encode(object: 4, opcode: 0, [.newID(9), .fd(12), .int(4096)])
        #expect(fds == [12])
        #expect(bytes.count == 16)
        #expect(WaylandWire.word(bytes[...], at: 12) == 4096)
    }

    @Test func readsEventsBack() throws {
        var body: [UInt8] = []
        WaylandWire.append(UInt32(bitPattern: -5), to: &body)
        WaylandWire.append(UInt32(bitPattern: 512), to: &body)
        let text = WaylandWire.encode(object: 0, opcode: 0, [.string("HEADLESS-1"), .array([9, 8])]).bytes.dropFirst(8)
        var event = WaylandEvent(object: 6, opcode: 4, body: body + text)
        #expect(try event.int() == -5)
        #expect(try event.fixed() == 2)
        #expect(try event.string() == "HEADLESS-1")
        #expect(try event.array() == [9, 8])
        #expect(throws: WaylandError.self) { try event.uint() }
    }

    @Test func findsMessageBoundaries() throws {
        let (bytes, _) = WaylandWire.encode(object: 2, opcode: 0, [.uint(1), .uint(2)])
        #expect(try WaylandWire.size(of: bytes[...]) == 16)
        #expect(try WaylandWire.size(of: bytes.prefix(7)) == nil)
        #expect(throws: WaylandError.self) { try WaylandWire.size(of: [1, 0, 0, 0, 0, 0, 3, 0][...]) }
    }

    @Test func buildsARightsControlMessage() {
        let control = WaylandConnection.rightsMessage([7])
        let word = MemoryLayout<Int>.size
        #expect(control.count == word + 8 + (4 + word - 1) / word * word)
        #expect(control[0] == UInt8(word + 12))
        #expect(WaylandWire.word(control[...], at: word + 8) == 7)
        #expect(WaylandConnection.rightsMessage([]).isEmpty)
    }

    @Test func findsTheDisplaySocket() {
        #expect(WaylandConnection.socketPath(environment: ["XDG_RUNTIME_DIR": "/run/user/5"]) == "/run/user/5/wayland-0")
        #expect(WaylandConnection.socketPath(environment: ["XDG_RUNTIME_DIR": "/run/user/5", "WAYLAND_DISPLAY": "wayland-1"]) == "/run/user/5/wayland-1")
        #expect(WaylandConnection.socketPath(environment: ["WAYLAND_DISPLAY": "/tmp/w"]) == "/tmp/w")
        #expect(WaylandConnection.socketPath(environment: [:]) == nil)
    }

    @Test func readsPixelsInEachLayout() throws {
        let bgrx: [UInt8] = [10, 20, 30, 0, 40, 50, 60, 0]
        #expect(WaylandCapture.rgba(from: bgrx, width: 2, height: 1, stride: 8, layout: try #require(.init(format: 1)), flipped: false).rgba
            == [30, 20, 10, 255, 60, 50, 40, 255])
        let bgr24: [UInt8] = [1, 2, 3, 4, 5, 6]
        #expect(WaylandCapture.rgba(from: bgr24, width: 1, height: 2, stride: 3, layout: try #require(.init(format: 0x3432_4742)), flipped: true).rgba
            == [4, 5, 6, 255, 1, 2, 3, 255])
        #expect(WaylandCapture.PixelLayout(format: 0x1234) == nil)
    }
}

struct SwayIPCTests {
    @Test func framesRequests() {
        let bytes = SwayIPC.encode(type: SwayIPC.getTree, payload: "")
        #expect(Array(bytes.prefix(6)) == Array("i3-ipc".utf8))
        #expect(WaylandWire.word(bytes[...], at: 6) == 0)
        #expect(WaylandWire.word(bytes[...], at: 10) == 4)
    }

    @Test func findsWindowsWithTheirContentRectangles() throws {
        let tree = try JSONSerialization.jsonObject(with: Data("""
            {"type": "root", "nodes": [{"type": "output", "name": "HEADLESS-1", "nodes": [{"type": "workspace", "nodes": [
              {"type": "con", "id": 5, "pid": 42, "app_id": "org.gnome.Calculator", "name": "Calculator", "focused": true, "visible": true,
               "rect": {"x": 0, "y": 0, "width": 640, "height": 800}, "window_rect": {"x": 2, "y": 25, "width": 636, "height": 773}},
              {"type": "con", "nodes": [{"type": "con", "id": 6, "pid": 43, "name": "Notes", "visible": false,
               "rect": {"x": 640, "y": 0, "width": 640, "height": 800}, "window_rect": {"x": 0, "y": 0, "width": 640, "height": 800}}]}
            ], "floating_nodes": []}]}]}
            """.utf8))
        let windows = SwayIPC.windows(inTree: tree)
        #expect(windows.map(\.title) == ["Calculator", "Notes"])
        #expect(windows[0].x == 2 && windows[0].y == 25 && windows[0].width == 636)
        #expect(windows[0].pid == 42 && windows[0].focused && windows[0].output == "HEADLESS-1")
        #expect(windows[1].x == 640 && !windows[1].visible)
    }

    @Test func readsActiveOutputs() throws {
        let reply = try JSONSerialization.jsonObject(with: Data("""
            [{"name": "HEADLESS-1", "active": true, "scale": 2.0, "rect": {"x": 0, "y": 0, "width": 640, "height": 400}},
             {"name": "HDMI-A-1", "active": false, "rect": {"x": 0, "y": 0, "width": 0, "height": 0}}]
            """.utf8))
        #expect(SwayIPC.outputs(inReply: reply) == [SwayOutput(name: "HEADLESS-1", x: 0, y: 0, width: 640, height: 400, scale: 2)])
    }
}

struct XKBKeymapTests {
    @Test func namesKeysymsForCharacters() {
        #expect(XKBKeymap.keysym(for: "a") == "U0061")
        #expect(XKBKeymap.keysym(for: "é") == "U00E9")
        #expect(XKBKeymap.keysym(for: "😀") == "U1F600")
        #expect(XKBKeymap.keysym(for: "\n") == "Return")
        #expect(XKBKeymap.keysym(for: "\t") == "Tab")
    }

    @Test func givesEachKeyItsOwnKeycodeAfterTheModifiers() {
        let keymap = XKBKeymap(keys: ["U0061", "Return", "U0061"])
        #expect(keymap.codes["Shift_L"] == 9)
        #expect(keymap.codes["Super_L"] == 12)
        #expect(keymap.codes["U0061"] == 13)
        #expect(keymap.codes["Return"] == 14)
        #expect(keymap.codes.count == 6)
        #expect(keymap.text.contains("key <K13> { [ U0061 ] };"))
        #expect(keymap.text.contains("modifier_map Control { <K10> };"))
        #expect(keymap.text.contains(#"xkb_types "harness" { include "complete" };"#))
    }
}
