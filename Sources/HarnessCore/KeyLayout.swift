import Carbon
import CoreGraphics
import Foundation

/// Where a keyboard layout puts the characters it types: for each character, the key that types
/// it and whether Shift is needed, both plain and with Command held.
public struct KeyLayout: Sendable {
    /// A key on the keyboard and whether Shift must be held with it.
    public struct Key: Equatable, Sendable {
        public var code: CGKeyCode
        public var shift: Bool

        public init(code: CGKeyCode, shift: Bool = false) {
            self.code = code
            self.shift = shift
        }
    }

    /// The input source the table came from, such as com.apple.keylayout.German.
    public let id: String
    let plain: [Character: Key]
    let command: [Character: Key]

    /// Keys that type characters: the main block, without return, tab and space.
    static let typingKeys: [CGKeyCode] = (0...50).filter { ![36, 48, 49].contains($0) }

    init(id: String, plain: [Character: Key], command: [Character: Key]) {
        self.id = id
        self.plain = plain
        self.command = command
    }

    /// Builds the table from a layout's Unicode key layout ('uchr') data, as
    /// `kTISPropertyUnicodeKeyLayoutData` gives it, for a physical keyboard type such as
    /// `LMGetKbdType()`. Nil when the data types nothing.
    public init?(id: String, layoutData: Data, keyboardType: UInt32) {
        let tables = layoutData.withUnsafeBytes { raw -> (plain: [Character: Key], command: [Character: Key])? in
            guard let base = raw.baseAddress, raw.count >= MemoryLayout<UCKeyboardLayout>.size else { return nil }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            return (
                Self.table(layout, holding: 0, keyboardType: keyboardType),
                Self.table(layout, holding: UInt32(cmdKey), keyboardType: keyboardType)
            )
        }
        guard let tables, !tables.plain.isEmpty else { return nil }
        self.init(id: id, plain: tables.plain, command: tables.command)
    }

    /// The key that types `character`: when `command` is true, the one that types it with
    /// Command held if there is one, else the one that types it plain.
    public func key(for character: Character, command: Bool) -> Key? {
        if command, let key = self.command[character] { return key }
        return plain[character]
    }

    /// Each character the layout types with `modifiers` (Carbon modifier bits) held, alone or with
    /// Shift; the unshifted key wins, then the lowest key code.
    static func table(_ layout: UnsafePointer<UCKeyboardLayout>, holding modifiers: UInt32, keyboardType: UInt32) -> [Character: Key] {
        var table: [Character: Key] = [:]
        for shift in [false, true] {
            let state = modifiers | (shift ? UInt32(shiftKey) : 0)
            for code in typingKeys {
                guard let character = translate(layout, code: code, modifiers: state, keyboardType: keyboardType),
                      table[character] == nil else { continue }
                table[character] = Key(code: code, shift: shift)
            }
        }
        return table
    }

    /// The one character a key types with `modifiers` held, ignoring dead-key composition; nil for
    /// control characters, whitespace and keys that type nothing or several characters.
    static func translate(_ layout: UnsafePointer<UCKeyboardLayout>, code: CGKeyCode, modifiers: UInt32, keyboardType: UInt32) -> Character? {
        var deadKeyState: UInt32 = 0
        var length = 0
        var units = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(
            layout, code, UInt16(kUCKeyActionDown), (modifiers >> 8) & 0xFF, keyboardType,
            OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState, units.count, &length, &units
        )
        guard status == noErr, length > 0 else { return nil }
        let text = String(utf16CodeUnits: units, count: length)
        guard text.count == 1, let character = text.first, !character.isWhitespace,
              !character.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return nil }
        return character
    }
}

extension KeyLayout {
    @MainActor private static var cache = KeyLayoutCache()

    /// The table for the keyboard layout in use now (the one an input method types with), built
    /// once per input source and keyboard type; nil when the layout has no Unicode data.
    @MainActor public static func current() -> KeyLayout? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let id = string(source, kTISPropertyInputSourceID) else { return nil }
        let keyboardType = UInt32(LMGetKbdType())
        return cache.layout(id: id, keyboardType: keyboardType) {
            make(source, id: id, keyboardType: keyboardType)
        }
    }

    /// The table for an installed keyboard layout, by input source ID, whether or not the user
    /// has turned it on.
    @MainActor public static func installed(_ id: String, keyboardType: UInt32) -> KeyLayout? {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let sources = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
              let source = sources.first else { return nil }
        return make(source, id: id, keyboardType: keyboardType)
    }

    @MainActor static func make(_ source: TISInputSource, id: String, keyboardType: UInt32) -> KeyLayout? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return KeyLayout(id: id, layoutData: data, keyboardType: keyboardType)
    }

    @MainActor static func string(_ source: TISInputSource, _ property: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, property) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    /// The US ANSI positions of the characters a US keyboard types without Shift, used when no
    /// layout data is at hand or the layout lacks the character.
    public static let us: KeyLayout = {
        let keys: [(Character, CGKeyCode)] = [
            ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7), ("c", 8), ("v", 9),
            ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15), ("y", 16), ("t", 17), ("1", 18), ("2", 19),
            ("3", 20), ("4", 21), ("6", 22), ("5", 23), ("=", 24), ("9", 25), ("7", 26), ("-", 27), ("8", 28),
            ("0", 29), ("]", 30), ("o", 31), ("u", 32), ("[", 33), ("i", 34), ("p", 35), ("l", 37), ("j", 38),
            ("'", 39), ("k", 40), (";", 41), ("\\", 42), (",", 43), ("/", 44), ("n", 45), ("m", 46), (".", 47),
            ("`", 50),
        ]
        let table = Dictionary(uniqueKeysWithValues: keys.map { ($0.0, Key(code: $0.1)) })
        return KeyLayout(id: "US (built in)", plain: table, command: table)
    }()
}

/// Keeps the table for the input source last asked about, building a new one only when the
/// input source or keyboard type changes.
struct KeyLayoutCache {
    private var entry: (id: String, keyboardType: UInt32, layout: KeyLayout?)?

    mutating func layout(id: String, keyboardType: UInt32, build: () -> KeyLayout?) -> KeyLayout? {
        if let entry, entry.id == id, entry.keyboardType == keyboardType { return entry.layout }
        let layout = build()
        entry = (id, keyboardType, layout)
        return layout
    }
}
