import AppKit
import Foundation
import HarnessCore
import HarnessProtocol

/// The clipboard: read for agents, and borrowed to paste text, with what the user copied put back.
@MainActor
public enum Clipboard {
    /// What was on a pasteboard, kept to put back after pasting.
    struct Snapshot {
        var items: [[(type: NSPasteboard.PasteboardType, data: Data)]]
    }

    /// Marks an item a password manager copied, which agents aren't given.
    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    /// Marks an item clipboard managers should skip, as the text the harness pastes is.
    static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// How macOS lets the helper read the clipboard: `allow`, `ask` (it prompts the user), or `deny`.
    public static func access(_ pasteboard: NSPasteboard = .general) -> String {
        guard #available(macOS 15.4, *) else { return "allow" }
        switch pasteboard.accessBehavior {
        case .alwaysAllow: return "allow"
        case .alwaysDeny: return "deny"
        default: return "ask"
        }
    }

    /// Throws when macOS doesn't let the helper read the clipboard.
    static func checkReadable(_ pasteboard: NSPasteboard = .general, doing: String) throws {
        guard access(pasteboard) == "deny" else { return }
        throw RPCError(
            code: RPCErrorCode.permissionMissing,
            message: "macOS doesn't let macOS Harness read the clipboard, so it can't \(doing). Allow it in System Settings › Privacy & Security › Paste from Other Apps."
        )
    }

    /// What's on the pasteboard: its types, and its text unless a password manager concealed it.
    public static func read(_ pasteboard: NSPasteboard = .general) throws -> ClipboardMethod.Result {
        try checkReadable(pasteboard, doing: "read it")
        let types = (pasteboard.types ?? []).map(\.rawValue)
        let isConcealed = types.contains(concealed.rawValue)
        return ClipboardMethod.Result(
            types: types, text: isConcealed ? nil : pasteboard.string(forType: .string), concealed: isConcealed,
            items: pasteboard.pasteboardItems?.count ?? 0
        )
    }

    /// Everything on the pasteboard, every item in every type it has.
    static func save(_ pasteboard: NSPasteboard = .general) throws -> Snapshot {
        try checkReadable(pasteboard, doing: "keep what's on it while pasting")
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        return Snapshot(items: items)
    }

    /// Puts `text` on the pasteboard, marked transient, and returns its change count after.
    static func put(_ text: String, on pasteboard: NSPasteboard = .general) -> Int {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: transient)
        pasteboard.writeObjects([item])
        return pasteboard.changeCount
    }

    /// Puts a snapshot back unless something else changed the pasteboard since `changeCount`;
    /// false when it was left alone.
    static func restore(_ snapshot: Snapshot, ifStill changeCount: Int, on pasteboard: NSPasteboard = .general) -> Bool {
        guard pasteboard.changeCount == changeCount else { return false }
        pasteboard.clearContents()
        let items = snapshot.items.map { entries in
            let item = NSPasteboardItem()
            for entry in entries { item.setData(entry.data, forType: entry.type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
        return true
    }
}
