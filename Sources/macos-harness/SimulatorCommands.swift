import ArgumentParser
import Foundation
import HarnessClient
import HarnessProtocol

struct SimCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sim",
        abstract: "Start, stop and set up iOS Simulators, and run apps on them.",
        discussion: """
            To see and operate a simulator's screen, use the usual commands with `-a sim:<device>`, \
            e.g. `snapshot -a sim:booted` or `press -a "sim:iPhone 18 Pro" --text Settings`. \
            A device is a UDID, a name, or `booted` for the only booted simulator. Needs Xcode 27 or later.
            """,
        subcommands: [
            SimList.self, SimBoot.self, SimShutdown.self, SimInstall.self, SimUninstall.self, SimLaunch.self,
            SimTerminate.self, SimOpenURL.self, SimButton.self, SimPrivacy.self, SimPush.self, SimLocation.self,
            SimAppearance.self, SimStatusBar.self, SimPasteboard.self,
        ]
    )
}

enum SimRunner {
    static func run(_ params: SimulatorMethod.Params, output: OutputOptions, timeout: TimeInterval = 120) throws {
        try reportingErrors(json: output.json) {
            let result = try HarnessConnection.openAnnouncingPairing().call(SimulatorMethod.self, params, timeout: timeout)
            output.json ? try Output.json(result) : print(Render.simulator(result))
        }
    }
}

struct SimDevice: ParsableArguments {
    @Argument(help: "The simulator: a UDID, a name, or `booted`.")
    var device: String
}

struct SimList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List the available simulators, booted ones first.")
    @OptionGroup var output: OutputOptions

    func run() throws {
        try SimRunner.run(.init(action: .list), output: output)
    }
}

struct SimBoot: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "boot", abstract: "Boot a simulator, wait until it's ready, and show it in Device Hub."
    )
    @OptionGroup var device: SimDevice
    @OptionGroup var output: OutputOptions

    func run() throws {
        try SimRunner.run(.init(action: .boot, device: device.device), output: output, timeout: 900)
    }
}

struct SimShutdown: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "shutdown", abstract: "Shut a simulator down.")
    @OptionGroup var device: SimDevice
    @OptionGroup var output: OutputOptions

    func run() throws {
        try SimRunner.run(.init(action: .shutdown, device: device.device), output: output, timeout: 180)
    }
}

struct SimInstall: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "install", abstract: "Install a built .app on a simulator.")
    @OptionGroup var device: SimDevice
    @Argument(help: "The .app bundle, built for the simulator.")
    var app: String
    @OptionGroup var output: OutputOptions

    func run() throws {
        let path = URL(fileURLWithPath: (app as NSString).expandingTildeInPath).standardizedFileURL.path
        try SimRunner.run(.init(action: .install, device: device.device, path: path), output: output, timeout: 360)
    }
}

struct SimUninstall: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "uninstall", abstract: "Remove an app from a simulator.")
    @OptionGroup var device: SimDevice
    @Argument(help: "The app's bundle ID.")
    var bundleID: String
    @OptionGroup var output: OutputOptions

    func run() throws {
        try SimRunner.run(.init(action: .uninstall, device: device.device, bundleIdentifier: bundleID), output: output, timeout: 180)
    }
}

struct SimLaunch: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "launch", abstract: "Start an app on a simulator (restarting it if it's running)."
    )
    @OptionGroup var device: SimDevice
    @Argument(help: "The app's bundle ID.")
    var bundleID: String
    @Option(name: .customLong("arg"), help: "A launch argument (repeat for more; use --arg=-flag for values starting with -).")
    var arguments: [String] = []
    @Option(name: .customLong("env"), help: "An environment variable as NAME=value (repeat for more).")
    var environment: [String] = []
    @OptionGroup var output: OutputOptions

    func run() throws {
        var variables: [String: String] = [:]
        for pair in environment {
            guard let equals = pair.firstIndex(of: "=") else {
                throw ValidationError("--env takes NAME=value, not \(pair).")
            }
            variables[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
        }
        try SimRunner.run(
            .init(action: .launch, device: device.device, bundleIdentifier: bundleID, arguments: arguments, environment: variables),
            output: output, timeout: 180
        )
    }
}

struct SimTerminate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "terminate", abstract: "Stop an app running on a simulator.")
    @OptionGroup var device: SimDevice
    @Argument(help: "The app's bundle ID.")
    var bundleID: String
    @OptionGroup var output: OutputOptions

    func run() throws {
        try SimRunner.run(.init(action: .terminate, device: device.device, bundleIdentifier: bundleID), output: output)
    }
}

struct SimOpenURL: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open-url", abstract: "Open a URL on a simulator: a web page, a deep link or a universal link."
    )
    @OptionGroup var device: SimDevice
    @Argument(help: "The URL.")
    var url: String
    @OptionGroup var output: OutputOptions

    func run() throws {
        try SimRunner.run(.init(action: .openURL, device: device.device, url: url), output: output)
    }
}

extension SimulatorButton: ExpressibleByArgument {}

struct SimButton: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "button",
        abstract: "Press a hardware button or turn the device.",
        discussion: "home and rotate work in the background; lock, siri, app-switcher and action use Device Hub's menu, which brings it to the front."
    )
    @OptionGroup var device: SimDevice
    @Argument(help: "home, lock, siri, app-switcher, action, rotate-left or rotate-right.")
    var button: SimulatorButton
    @OptionGroup var output: OutputOptions

    func run() throws {
        try SimRunner.run(.init(action: .button, device: device.device, button: button), output: output)
    }
}

struct SimPrivacy: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "privacy", abstract: "Grant, revoke or reset an app's access to photos, location, camera and the like."
    )
    @OptionGroup var device: SimDevice
    @Argument(help: "grant, revoke or reset.")
    var operation: String
    @Argument(help: "The service: all, calendar, contacts, location, location-always, photos, photos-add, media-library, microphone, motion, reminders, siri, camera…")
    var service: String
    @Argument(help: "The app's bundle ID (optional for reset).")
    var bundleID: String?
    @OptionGroup var output: OutputOptions

    func run() throws {
        try SimRunner.run(
            .init(action: .privacy, device: device.device, bundleIdentifier: bundleID, operation: operation, service: service),
            output: output
        )
    }
}

struct SimPush: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "push", abstract: "Send a push notification to an app on a simulator.")
    @OptionGroup var device: SimDevice
    @Argument(help: "The app's bundle ID.")
    var bundleID: String
    @Argument(help: "A JSON file with the payload, or - for standard input.")
    var payload: String
    @OptionGroup var output: OutputOptions

    func run() throws {
        let data = payload == "-" ? FileHandle.standardInput.readDataToEndOfFile()
            : try Data(contentsOf: URL(fileURLWithPath: (payload as NSString).expandingTildeInPath))
        try SimRunner.run(
            .init(action: .push, device: device.device, bundleIdentifier: bundleID, payload: String(decoding: data, as: UTF8.self)),
            output: output
        )
    }
}

struct SimLocation: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "location", abstract: "Set or clear a simulator's location.")
    @OptionGroup var device: SimDevice
    @Argument(help: "latitude,longitude (e.g. 59.33,18.07), or clear.")
    var location: String
    @OptionGroup var output: OutputOptions

    func run() throws {
        if location == "clear" {
            return try SimRunner.run(.init(action: .location, device: device.device, operation: "clear"), output: output)
        }
        let parts = location.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, let latitude = parts[0], let longitude = parts[1] else {
            throw ValidationError("Give the location as latitude,longitude, e.g. 59.33,18.07, or clear.")
        }
        try SimRunner.run(.init(action: .location, device: device.device, operation: "set", latitude: latitude, longitude: longitude), output: output)
    }
}

struct SimAppearance: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "appearance", abstract: "Switch a simulator to light or dark mode.")
    @OptionGroup var device: SimDevice
    @Argument(help: "light or dark.")
    var appearance: String
    @OptionGroup var output: OutputOptions

    func run() throws {
        try SimRunner.run(.init(action: .appearance, device: device.device, appearance: appearance), output: output)
    }
}

struct SimStatusBar: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status-bar", abstract: "Show fixed status bar values (for clean screenshots), or clear them."
    )
    @OptionGroup var device: SimDevice
    @Flag(help: "Go back to the real status bar.")
    var clear = false
    @Option(help: "Time to show, e.g. 9:41.")
    var time: String?
    @Option(help: "Battery level, 0–100.")
    var battery: Int?
    @Option(help: "charging, charged or discharging.")
    var batteryState: String?
    @Option(help: "Wi-Fi bars, 0–3.")
    var wifi: Int?
    @Option(help: "Cellular bars, 0–4.")
    var cellular: Int?
    @Option(help: "Data network: wifi, 3g, 4g, lte, lte-a, lte+, 5g, 5g+, 5g-uwb, 5g-uc…")
    var network: String?
    @Option(help: "Carrier name.")
    var carrier: String?
    @OptionGroup var output: OutputOptions

    func run() throws {
        let overrides = StatusBarOverrides(
            time: time, batteryLevel: battery, batteryState: batteryState, wifiBars: wifi, cellularBars: cellular,
            dataNetwork: network, operatorName: carrier
        )
        try SimRunner.run(
            .init(action: .statusBar, device: device.device, operation: clear ? "clear" : "override", statusBar: overrides),
            output: output
        )
    }
}

struct SimPasteboard: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pasteboard", abstract: "Put text on a simulator's pasteboard, or read what's there."
    )
    @OptionGroup var device: SimDevice
    @Argument(help: "get, or set.")
    var operation: String
    @Argument(help: "The text to put on the pasteboard (set).")
    var text: String?
    @OptionGroup var output: OutputOptions

    func run() throws {
        guard ["get", "set"].contains(operation) else { throw ValidationError("pasteboard takes get or set.") }
        try SimRunner.run(.init(action: .pasteboard, device: device.device, operation: operation, text: text), output: output)
    }
}
