import ArgumentParser
import Foundation
import HarnessClient
import HarnessProtocol

struct AndroidCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "android",
        abstract: "Start and stop Android emulators, run apps on emulators and phones, and change their settings.",
        discussion: """
            To see and operate a device's screen, use the usual commands with `-a android:<device>`, \
            e.g. `snapshot -a android:booted` or `press -a android:emulator-5554 --text Settings`. \
            A device is an adb serial, an emulator's name, a phone's model, or `booted` for the only \
            running device. Coordinates are the screen's pixels. Needs the Android SDK (adb).
            """,
        subcommands: [
            AndroidList.self, AndroidBoot.self, AndroidShutdown.self, AndroidInstall.self, AndroidUninstall.self,
            AndroidLaunch.self, AndroidTerminate.self, AndroidOpenURL.self, AndroidButtonCommand.self, AndroidPermission.self,
            AndroidLocation.self, AndroidAppearance.self, AndroidRotate.self, AndroidStatusBar.self,
        ]
    )
}

enum AndroidRunner {
    static func run(_ params: AndroidMethod.Params, output: OutputOptions, timeout: TimeInterval = 120) throws {
        try reportingErrors(json: output.json) {
            let result = try HarnessConnection.openAnnouncingPairing().call(AndroidMethod.self, params, timeout: timeout)
            output.json ? try Output.json(result) : print(Render.android(result))
        }
    }
}

struct AndroidDeviceArgument: ParsableArguments {
    @Argument(help: "The device: an adb serial, an emulator's name, a phone's model, or `booted`.")
    var device: String
}

struct AndroidList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List connected devices and emulators, running ones first.")
    @OptionGroup var output: OutputOptions

    func run() throws {
        try AndroidRunner.run(.init(action: .list), output: output)
    }
}

struct AndroidBoot: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "boot", abstract: "Start an emulator and wait until Android has booted.")
    @OptionGroup var device: AndroidDeviceArgument
    @Flag(help: "Run it without a window.")
    var headless = false
    @OptionGroup var output: OutputOptions

    func run() throws {
        try AndroidRunner.run(.init(action: .boot, device: device.device, headless: headless), output: output, timeout: 360)
    }
}

struct AndroidShutdown: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "shutdown", abstract: "Shut an emulator down.")
    @OptionGroup var device: AndroidDeviceArgument
    @OptionGroup var output: OutputOptions

    func run() throws {
        try AndroidRunner.run(.init(action: .shutdown, device: device.device), output: output)
    }
}

struct AndroidInstall: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "install", abstract: "Install an .apk (or replace the installed one).")
    @OptionGroup var device: AndroidDeviceArgument
    @Argument(help: "The .apk file.")
    var apk: String
    @OptionGroup var output: OutputOptions

    func run() throws {
        let path = URL(fileURLWithPath: (apk as NSString).expandingTildeInPath).standardizedFileURL.path
        try AndroidRunner.run(.init(action: .install, device: device.device, path: path), output: output, timeout: 360)
    }
}

struct AndroidUninstall: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "uninstall", abstract: "Remove an app.")
    @OptionGroup var device: AndroidDeviceArgument
    @Argument(help: "The app's package name.")
    var package: String
    @OptionGroup var output: OutputOptions

    func run() throws {
        try AndroidRunner.run(.init(action: .uninstall, device: device.device, package: package), output: output)
    }
}

struct AndroidLaunch: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "launch", abstract: "Start an app's launcher activity (restarting it if it's running).")
    @OptionGroup var device: AndroidDeviceArgument
    @Argument(help: "The app's package name.")
    var package: String
    @OptionGroup var output: OutputOptions

    func run() throws {
        try AndroidRunner.run(.init(action: .launch, device: device.device, package: package), output: output)
    }
}

struct AndroidTerminate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "terminate", abstract: "Stop an app.")
    @OptionGroup var device: AndroidDeviceArgument
    @Argument(help: "The app's package name.")
    var package: String
    @OptionGroup var output: OutputOptions

    func run() throws {
        try AndroidRunner.run(.init(action: .terminate, device: device.device, package: package), output: output)
    }
}

struct AndroidOpenURL: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "open-url", abstract: "Open a URL: a web page or an app link.")
    @OptionGroup var device: AndroidDeviceArgument
    @Argument(help: "The URL.")
    var url: String
    @Option(help: "Open it in this app.")
    var package: String?
    @OptionGroup var output: OutputOptions

    func run() throws {
        try AndroidRunner.run(.init(action: .openURL, device: device.device, package: package, url: url), output: output)
    }
}

extension AndroidButton: ExpressibleByArgument {}

struct AndroidButtonCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "button", abstract: "Press a system button, or pull down the notifications.")
    @OptionGroup var device: AndroidDeviceArgument
    @Argument(help: "home, back, app-switcher, power, volume-up, volume-down, menu or notifications.")
    var button: AndroidButton
    @OptionGroup var output: OutputOptions

    func run() throws {
        try AndroidRunner.run(.init(action: .button, device: device.device, button: button), output: output)
    }
}

struct AndroidPermission: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "permission", abstract: "Grant or revoke an app's runtime permission, or revoke all of them.")
    @OptionGroup var device: AndroidDeviceArgument
    @Argument(help: "grant, revoke or reset.")
    var operation: String
    @Argument(help: "The app's package name.")
    var package: String
    @Argument(help: "The permission, e.g. camera or android.permission.ACCESS_FINE_LOCATION (not for reset).")
    var permission: String?
    @OptionGroup var output: OutputOptions

    func run() throws {
        try AndroidRunner.run(
            .init(action: .permission, device: device.device, package: package, operation: operation, permission: permission), output: output
        )
    }
}

struct AndroidLocation: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "location", abstract: "Set an emulator's location.")
    @OptionGroup var device: AndroidDeviceArgument
    @Argument(help: "latitude,longitude, e.g. 59.33,18.07.")
    var location: String
    @OptionGroup var output: OutputOptions

    func run() throws {
        let parts = location.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, let latitude = parts[0], let longitude = parts[1] else {
            throw ValidationError("Give the location as latitude,longitude, e.g. 59.33,18.07.")
        }
        try AndroidRunner.run(.init(action: .location, device: device.device, latitude: latitude, longitude: longitude), output: output)
    }
}

struct AndroidAppearance: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "appearance", abstract: "Switch to light or dark mode.")
    @OptionGroup var device: AndroidDeviceArgument
    @Argument(help: "light or dark.")
    var appearance: String
    @OptionGroup var output: OutputOptions

    func run() throws {
        try AndroidRunner.run(.init(action: .appearance, device: device.device, appearance: appearance), output: output)
    }
}

struct AndroidRotate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rotate", abstract: "Turn the screen, or let it follow the device again.")
    @OptionGroup var device: AndroidDeviceArgument
    @Argument(help: "portrait, landscape, reverse-portrait, reverse-landscape or auto.")
    var orientation: String
    @OptionGroup var output: OutputOptions

    func run() throws {
        try AndroidRunner.run(.init(action: .rotate, device: device.device, orientation: orientation), output: output)
    }
}

struct AndroidStatusBar: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status-bar", abstract: "Show a clean status bar (demo mode) for screenshots, or go back to the real one."
    )
    @OptionGroup var device: AndroidDeviceArgument
    @Flag(help: "Go back to the real status bar.")
    var clear = false
    @Option(help: "Time to show, e.g. 9:41.")
    var time: String?
    @Option(help: "Battery level, 0–100.")
    var battery: Int?
    @OptionGroup var output: OutputOptions

    func run() throws {
        try AndroidRunner.run(
            .init(action: .statusBar, device: device.device, operation: clear ? "clear" : "set",
                  statusBar: StatusBarOverrides(time: time, batteryLevel: battery)),
            output: output
        )
    }
}
