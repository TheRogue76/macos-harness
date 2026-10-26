import Foundation
import HarnessDBus
import HarnessProtocol

/// The harness's icon in GNOME's top bar, drawn by its Shell extension, as the Mac's menu bar
/// icon is: a click opens the Control Tower panel under it. GNOME shows tray icons only through
/// an extension, and Ubuntu's opens their menu on a click, so the harness's own extension draws it.
public final class TopBarIcon: Sendable {
    let connection: DBusConnection

    private init(connection: DBusConnection) {
        self.connection = connection
    }

    /// Shows the icon when the extension can (version 3 and later); nil otherwise. `onClick`
    /// gets where the icon is, its bottom middle.
    public static func show(title: String, attention: Bool, onClick: @escaping @Sendable (Int32, Int32) -> Void) async -> TopBarIcon? {
        guard let connection = try? await DBusConnection.session(),
              let version = try? await connection.property(GnomeCompositor.busName, GnomeCompositor.objectPath, GnomeCompositor.interface, "Version").int,
              version >= 3 else { return nil }
        let rule = "type='signal',interface='\(GnomeCompositor.interface)',member='IconClicked'"
        guard (try? await connection.addMatch(rule)) != nil else {
            connection.close()
            return nil
        }
        connection.onSignal { message in
            guard message.interface == GnomeCompositor.interface, message.member == "IconClicked", message.body.count == 2,
                  let x = message.body[0].int, let y = message.body[1].int else { return }
            onClick(Int32(clamping: x), Int32(clamping: y))
        }
        let icon = TopBarIcon(connection: connection)
        guard (try? await icon.update(title: title, attention: attention)) != nil else {
            connection.close()
            return nil
        }
        return icon
    }

    /// Changes the icon's name and its orange dot.
    public func update(title: String, attention: Bool) async throws {
        _ = try await connection.call(
            GnomeCompositor.busName, GnomeCompositor.objectPath, GnomeCompositor.interface, "ShowIcon", [.string(title), .boolean(attention)]
        )
    }

    public func close() {
        connection.close()
    }
}
