import AppKit
import HarnessCore
import HarnessProtocol

/// The menu bar icon: permission status, paired agents, quit.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let variant: HarnessVariant
    private let pairings: PairingStore

    init(variant: HarnessVariant, pairings: PairingStore) {
        self.variant = variant
        self.pairings = pairings
        super.init()
        item.button?.image = NSImage(
            systemSymbolName: "macwindow.and.cursorarrow", accessibilityDescription: variant.appName
        )
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
    }

    /// Rebuilt on every open so permission and pairing state are always current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(disabled("\(variant.appName) \(HarnessVersion.string)"))
        menu.addItem(.separator())

        if Permissions.accessibility {
            menu.addItem(disabled("Accessibility: granted"))
        } else {
            menu.addItem(action("Grant Accessibility…", #selector(grantAccessibility)))
        }
        if Permissions.screenRecording {
            menu.addItem(disabled("Screen Recording: granted"))
        } else {
            menu.addItem(action("Grant Screen Recording…", #selector(grantScreenRecording)))
        }
        menu.addItem(.separator())

        let paired = pairings.all
        let agents = NSMenuItem(title: "Paired Agents (\(paired.count))", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        if paired.isEmpty {
            submenu.addItem(disabled("None yet"))
        }
        for pairing in paired {
            let revoke = action("Revoke \(pairing.displayName)", #selector(revoke(_:)))
            revoke.representedObject = pairing.key
            revoke.toolTip = pairing.key
            submenu.addItem(revoke)
        }
        agents.submenu = submenu
        menu.addItem(agents)
        menu.addItem(.separator())
        menu.addItem(action("Restart Helper", #selector(restart)))
        menu.addItem(action("Quit \(variant.appName)", #selector(quit), key: "q"))
    }

    @objc private func grantAccessibility() {
        Permissions.requestAccessibility()
        Permissions.openSettings(.accessibility)
    }

    @objc private func grantScreenRecording() {
        Permissions.requestScreenRecording()
        Permissions.openSettings(.screenRecording)
    }

    @objc private func revoke(_ sender: NSMenuItem) {
        if let key = sender.representedObject as? String {
            pairings.revoke(key: key)
        }
    }

    /// Screen Recording only takes effect after a restart, so offer one.
    @objc private func restart() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }
}
