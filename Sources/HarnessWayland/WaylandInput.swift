import Foundation
import Synchronization

/// Real input on wlroots compositors: a virtual pointer and a virtual keyboard, which the
/// compositor treats like the user's own devices.
public final class WaylandInput: Sendable {
    let connection: WaylandConnection
    let registry: UInt32
    let globals: [WaylandGlobal]
    let seat: UInt32
    /// Outputs by name, as `wl_output` objects.
    let outputs: [String: UInt32]
    let start = ContinuousClock.now

    private init(connection: WaylandConnection, registry: UInt32, globals: [WaylandGlobal], seat: UInt32, outputs: [String: UInt32]) {
        self.connection = connection
        self.registry = registry
        self.globals = globals
        self.seat = seat
        self.outputs = outputs
    }

    /// Binds the seat and outputs, failing when the compositor offers neither virtual device.
    public static func make(on connection: WaylandConnection) async throws -> WaylandInput {
        let (registry, globals) = try await connection.globals()
        guard let seatGlobal = globals.first(where: { $0.interface == "wl_seat" }) else { throw WaylandError.missingGlobal("wl_seat") }
        let seat = try connection.bind(seatGlobal, registry: registry, version: 1)
        let names = Mutex<[String: UInt32]>([:])
        for global in globals where global.interface == "wl_output" {
            let object = try connection.bind(global, registry: registry, version: 4)
            connection.listen(object) { event in
                guard event.opcode == 4, let name = try event.string() else { return }
                names.withLock { $0[name] = object }
            }
        }
        try await connection.roundtrip()
        return WaylandInput(connection: connection, registry: registry, globals: globals, seat: seat, outputs: names.withLock { $0 })
    }

    /// Milliseconds since this input was made, for events' timestamps.
    var time: UInt32 {
        let elapsed = ContinuousClock.now - start
        return UInt32(truncatingIfNeeded: elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    func global(_ interface: String) throws -> WaylandGlobal {
        guard let global = globals.first(where: { $0.interface == interface }) else { throw WaylandError.missingGlobal(interface) }
        return global
    }

    /// A pointer whose absolute positions are in an output's logical coordinates.
    public func pointer(on output: String?) throws -> WaylandPointer {
        let manager = try connection.bind(try global("zwlr_virtual_pointer_manager_v1"), registry: registry, version: 2)
        let pointer = connection.allocate()
        if let output, let object = outputs[output], (try global("zwlr_virtual_pointer_manager_v1")).version >= 2 {
            try connection.send(manager, 2, [.object(seat), .object(object), .newID(pointer)])
        } else {
            try connection.send(manager, 0, [.object(seat), .newID(pointer)])
        }
        return WaylandPointer(input: self, object: pointer, manager: manager)
    }

    /// A keyboard whose keymap holds the given keys, by XKB keysym name.
    public func keyboard(keys: [String]) throws -> WaylandKeyboard {
        let manager = try connection.bind(try global("zwp_virtual_keyboard_manager_v1"), registry: registry, version: 1)
        let keyboard = connection.allocate()
        try connection.send(manager, 0, [.object(seat), .newID(keyboard)])
        let keymap = XKBKeymap(keys: keys)
        let text = Array(keymap.text.utf8) + [0]
        let buffer = try SharedBuffer(size: text.count)
        defer { buffer.release() }
        buffer.write(text)
        try connection.send(keyboard, 0, [.uint(1), .fd(buffer.fd), .uint(UInt32(text.count))])
        return WaylandKeyboard(input: self, object: keyboard, manager: manager, keymap: keymap)
    }
}

/// A virtual pointer. Buttons are evdev codes.
public struct WaylandPointer: Sendable {
    public static let left: UInt32 = 0x110
    public static let right: UInt32 = 0x111
    public static let middle: UInt32 = 0x112

    let input: WaylandInput
    let object: UInt32
    let manager: UInt32

    /// Moves to `x`, `y` within an area `width` by `height` (the output's logical size).
    public func move(x: Double, y: Double, width: Double, height: Double) throws {
        let extentX = UInt32(max(width, 1)), extentY = UInt32(max(height, 1))
        let clampedX = UInt32(min(max(x, 0), Double(extentX - 1))), clampedY = UInt32(min(max(y, 0), Double(extentY - 1)))
        try input.connection.send(object, 1, [.uint(input.time), .uint(clampedX), .uint(clampedY), .uint(extentX), .uint(extentY)])
        try frame()
    }

    public func button(_ button: UInt32, pressed: Bool) throws {
        try input.connection.send(object, 2, [.uint(input.time), .uint(button), .uint(pressed ? 1 : 0)])
        try frame()
    }

    /// Scrolls by pixels: positive `dy` moves content up, as on a trackpad, which is the wheel
    /// turned down.
    public func scroll(dx: Double, dy: Double) throws {
        try input.connection.send(object, 5, [.uint(0)])
        if dy != 0 {
            try input.connection.send(object, 7, [.uint(input.time), .uint(0), .fixed(-dy), .int(Int32((-dy / 15).rounded()))])
        }
        if dx != 0 {
            try input.connection.send(object, 7, [.uint(input.time), .uint(1), .fixed(-dx), .int(Int32((-dx / 15).rounded()))])
        }
        try frame()
    }

    func frame() throws {
        try input.connection.send(object, 4)
    }

    /// Removes the pointer and its manager.
    public func close() {
        try? input.connection.send(object, 8)
        try? input.connection.send(manager, 1)
    }
}

/// A virtual keyboard with its own keymap.
public struct WaylandKeyboard: Sendable {
    let input: WaylandInput
    let object: UInt32
    let manager: UInt32
    let keymap: XKBKeymap

    /// Presses and releases a key by keysym name, holding `modifiers` (XKB's real modifier
    /// masks) meanwhile.
    public func tap(_ key: String, modifiers: UInt32 = 0) throws {
        guard let code = keymap.codes[key] else { throw WaylandError.malformed("the keymap has no \(key)") }
        if modifiers != 0 { try input.connection.send(object, 2, [.uint(modifiers), .uint(0), .uint(0), .uint(0)]) }
        try input.connection.send(object, 1, [.uint(input.time), .uint(code - 8), .uint(1)])
        try input.connection.send(object, 1, [.uint(input.time), .uint(code - 8), .uint(0)])
        if modifiers != 0 { try input.connection.send(object, 2, [.uint(0), .uint(0), .uint(0), .uint(0)]) }
    }

    /// Sets the modifiers held (XKB's real modifier masks), 0 for none.
    public func setModifiers(_ modifiers: UInt32) throws {
        try input.connection.send(object, 2, [.uint(modifiers), .uint(0), .uint(0), .uint(0)])
    }

    /// Types text, one key per character.
    public func type(_ text: String) throws {
        for character in text {
            try tap(XKBKeymap.keysym(for: character))
        }
    }

    public func close() {
        try? input.connection.send(object, 3)
    }
}

/// A keymap with one key per keysym it was asked for, the way `wtype` builds one, so any text
/// types whatever the user's layout is.
public struct XKBKeymap: Sendable, Equatable {
    /// XKB's real modifier masks.
    public static let shift: UInt32 = 0x1
    public static let control: UInt32 = 0x4
    public static let alt: UInt32 = 0x8
    public static let superKey: UInt32 = 0x40

    public let text: String
    /// Each keysym name's XKB keycode (evdev code plus 8).
    public let codes: [String: UInt32]

    public init(keys: [String]) {
        var seen: Set<String> = []
        let wanted = (["Shift_L", "Control_L", "Alt_L", "Super_L"] + keys).filter { seen.insert($0).inserted }
        var codes: [String: UInt32] = [:]
        var keycodes: [String] = []
        var symbols: [String] = []
        for (index, key) in wanted.prefix(240).enumerated() {
            let code = UInt32(index + 9)
            codes[key] = code
            keycodes.append("    <K\(code)> = \(code);")
            symbols.append("    key <K\(code)> { [ \(key) ] };")
        }
        let modifiers = [("Shift", "Shift_L"), ("Control", "Control_L"), ("Mod1", "Alt_L"), ("Mod4", "Super_L")]
            .compactMap { modifier, key in codes[key].map { "    modifier_map \(modifier) { <K\($0)> };" } }
        text = """
            xkb_keymap {
            xkb_keycodes "harness" {
                minimum = 8;
                maximum = 255;
            \(keycodes.joined(separator: "\n"))
            };
            xkb_types "harness" { include "complete" };
            xkb_compatibility "harness" { include "complete" };
            xkb_symbols "harness" {
            \(symbols.joined(separator: "\n"))
            \(modifiers.joined(separator: "\n"))
            };
            };
            """
        self.codes = codes
    }

    /// The keysym name that types a character: XKB's Unicode keysym for anything printable,
    /// and the named keys for newlines and tabs.
    public static func keysym(for character: Character) -> String {
        switch character {
        case "\n", "\r", "\r\n": return "Return"
        case "\t": return "Tab"
        default:
            let scalar = character.unicodeScalars.first?.value ?? 0x20
            let hex = String(scalar, radix: 16, uppercase: true)
            return "U" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex
        }
    }
}

extension SharedBuffer {
    /// Copies bytes into the start of the buffer.
    func write(_ bytes: [UInt8]) {
        unsafe mappingPointer.copyMemory(from: bytes, byteCount: min(bytes.count, size))
    }
}
