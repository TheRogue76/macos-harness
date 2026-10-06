import AppKit
import HarnessCore
import HarnessProtocol
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: "io.github.therogue76.macos-harness", category: "helper")
    private let variant = HarnessVariant(bundleIdentifier: Bundle.main.bundleIdentifier ?? "") ?? .dev
    private let pairings = PairingStore()
    private lazy var pairingPrompt = PairingPrompt(store: pairings)
    private var server: SocketServer?
    private var statusMenu: StatusMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let router = Router(gate: pairingPrompt)
        HelperHandlers.register(on: router, pairings: pairings)

        let server = SocketServer(path: HarnessPaths.socketPath(for: variant), router: router)
        do {
            try server.start()
        } catch {
            log.error("could not start: \(String(describing: error), privacy: .public)")
            let alert = NSAlert()
            alert.messageText = "\(variant.appName) couldn't start"
            alert.informativeText = String(describing: error)
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        self.server = server
        statusMenu = StatusMenu(variant: variant, pairings: pairings)
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
    }
}
