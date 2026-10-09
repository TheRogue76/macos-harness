import Foundation

/// An iOS Simulator device, as `simctl` reports it.
public struct SimulatorInfo: Codable, Sendable, Equatable {
    public var udid: String
    public var name: String
    /// The OS and version, e.g. `iOS 27.0`.
    public var runtime: String
    /// `Booted`, `Shutdown`, `Booting`, …
    public var state: String
    /// The device type, e.g. `iPhone 18 Pro`.
    public var deviceType: String?
    /// The screen in points, in portrait.
    public var screen: Size?
    /// Pixels per point on the device's screen.
    public var screenScale: Double?

    public init(
        udid: String, name: String, runtime: String, state: String, deviceType: String? = nil, screen: Size? = nil,
        screenScale: Double? = nil
    ) {
        self.udid = udid
        self.name = name
        self.runtime = runtime
        self.state = state
        self.deviceType = deviceType
        self.screen = screen
        self.screenScale = screenScale
    }

    public var isBooted: Bool { state == "Booted" }
}

public struct Size: Codable, Sendable, Equatable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// Things to do with a simulator other than operating its screen.
public enum SimulatorAction: String, Codable, Sendable, CaseIterable {
    case list
    case boot
    case shutdown
    case install
    case uninstall
    case launch
    case terminate
    case openURL = "open-url"
    case button
    case privacy
    case push
    case location
    case appearance
    case statusBar = "status-bar"
    case pasteboard

    /// Actions that only read.
    public static let reading: Set<SimulatorAction> = [.list]
}

/// Hardware buttons and device controls of a simulator.
public enum SimulatorButton: String, Codable, Sendable, CaseIterable {
    case home
    case lock
    case siri
    case appSwitcher = "app-switcher"
    case action
    case rotateLeft = "rotate-left"
    case rotateRight = "rotate-right"
}

/// Status bar values to show instead of the real ones, for clean screenshots.
public struct StatusBarOverrides: Codable, Sendable, Equatable {
    /// e.g. `9:41`.
    public var time: String?
    /// 0–100.
    public var batteryLevel: Int?
    /// `charging`, `charged` or `discharging`.
    public var batteryState: String?
    /// 0–3.
    public var wifiBars: Int?
    /// 0–4.
    public var cellularBars: Int?
    /// e.g. `5g`, `lte`, `wifi`.
    public var dataNetwork: String?
    public var operatorName: String?

    public init(
        time: String? = nil, batteryLevel: Int? = nil, batteryState: String? = nil, wifiBars: Int? = nil,
        cellularBars: Int? = nil, dataNetwork: String? = nil, operatorName: String? = nil
    ) {
        self.time = time
        self.batteryLevel = batteryLevel
        self.batteryState = batteryState
        self.wifiBars = wifiBars
        self.cellularBars = cellularBars
        self.dataNetwork = dataNetwork
        self.operatorName = operatorName
    }

    public var isEmpty: Bool {
        time == nil && batteryLevel == nil && batteryState == nil && wifiBars == nil && cellularBars == nil
            && dataNetwork == nil && operatorName == nil
    }
}

/// Lifecycle, apps, buttons and settings of an iOS Simulator, through `simctl` and Device Hub.
public enum SimulatorMethod: RPCMethod {
    public static let name = "simulator"

    public struct Params: Codable, Sendable, Equatable {
        public var action: SimulatorAction
        /// A UDID, a device name, or `booted` for the only booted simulator.
        public var device: String?
        public var bundleIdentifier: String?
        /// The `.app` to install.
        public var path: String?
        public var url: String?
        /// Launch arguments.
        public var arguments: [String]
        /// Launch environment.
        public var environment: [String: String]
        public var button: SimulatorButton?
        /// privacy: `grant`, `revoke` or `reset`; location: `set` or `clear`; status-bar:
        /// `override` or `clear`; pasteboard: `set` or `get`.
        public var operation: String?
        /// privacy: the service (`photos`, `location`, `camera`, `all`, …).
        public var service: String?
        /// push: the notification payload as JSON.
        public var payload: String?
        public var latitude: Double?
        public var longitude: Double?
        /// `light` or `dark`.
        public var appearance: String?
        public var statusBar: StatusBarOverrides?
        /// pasteboard set: the text to copy onto the simulator's pasteboard.
        public var text: String?

        public init(
            action: SimulatorAction, device: String? = nil, bundleIdentifier: String? = nil, path: String? = nil,
            url: String? = nil, arguments: [String] = [], environment: [String: String] = [:], button: SimulatorButton? = nil,
            operation: String? = nil, service: String? = nil, payload: String? = nil, latitude: Double? = nil,
            longitude: Double? = nil, appearance: String? = nil, statusBar: StatusBarOverrides? = nil, text: String? = nil
        ) {
            self.action = action
            self.device = device
            self.bundleIdentifier = bundleIdentifier
            self.path = path
            self.url = url
            self.arguments = arguments
            self.environment = environment
            self.button = button
            self.operation = operation
            self.service = service
            self.payload = payload
            self.latitude = latitude
            self.longitude = longitude
            self.appearance = appearance
            self.statusBar = statusBar
            self.text = text
        }
    }

    public struct Result: Codable, Sendable {
        /// What happened, in a sentence.
        public var performed: String
        public var device: SimulatorInfo?
        /// list: every available simulator.
        public var devices: [SimulatorInfo]?
        /// launch: the app's process ID.
        public var pid: Int32?
        /// pasteboard get: the text on the pasteboard.
        public var text: String?
        public var notices: [Notice]

        public init(
            performed: String, device: SimulatorInfo? = nil, devices: [SimulatorInfo]? = nil, pid: Int32? = nil,
            text: String? = nil, notices: [Notice] = []
        ) {
            self.performed = performed
            self.device = device
            self.devices = devices
            self.pid = pid
            self.text = text
            self.notices = notices
        }
    }
}

extension Target {
    /// The prefix that makes a target an iOS Simulator: `sim:<UDID, name or booted>`.
    public static let simulatorPrefix = "sim:"

    /// The device part of a `sim:` target, or nil for a Mac app.
    public var simulatorDevice: String? { Target.simulatorDevice(in: app) }

    /// The device part of a `sim:` app string, or nil for a Mac app.
    public static func simulatorDevice(in app: String) -> String? {
        guard app.lowercased().hasPrefix(simulatorPrefix) else { return nil }
        let device = app.dropFirst(simulatorPrefix.count).trimmingCharacters(in: .whitespaces)
        return device.isEmpty ? "booted" : device
    }
}

/// Reads `simctl` device listings and picks a device out of them.
public enum SimulatorCatalog {
    /// The device a query picks: a UDID, a name (the booted one when several share it), or
    /// `booted` for the only booted simulator.
    public static func pick(_ query: String, from devices: [SimulatorInfo]) throws -> SimulatorInfo {
        let needle = query.trimmingCharacters(in: .whitespaces)
        let booted = devices.filter(\.isBooted)
        if needle.lowercased() == "booted" {
            switch booted.count {
            case 1: return booted[0]
            case 0:
                throw RPCError(code: RPCErrorCode.failed, message: "No simulator is booted. Boot one with `macos-harness sim boot \"<name>\"`; `macos-harness sim list` shows them.")
            default:
                throw RPCError(code: RPCErrorCode.failed, message: "\(booted.count) simulators are booted; name one: \(describe(booted)).")
            }
        }
        if let match = devices.first(where: { $0.udid.caseInsensitiveCompare(needle) == .orderedSame }) {
            return match
        }
        let named = devices.filter { $0.name.caseInsensitiveCompare(needle) == .orderedSame }
        if named.count == 1 { return named[0] }
        if named.count > 1 {
            let bootedNamed = named.filter(\.isBooted)
            if bootedNamed.count == 1 { return bootedNamed[0] }
            throw RPCError(code: RPCErrorCode.failed, message: "\(named.count) simulators are called “\(needle)”; use a UDID: \(describe(named)).")
        }
        let similar = devices.filter { $0.name.lowercased().contains(needle.lowercased()) }
        let hint = similar.isEmpty ? "`macos-harness sim list` shows them." : "Did you mean \(describe(Array(similar.prefix(5))))?"
        throw RPCError(code: RPCErrorCode.failed, message: "No simulator matches “\(needle)”. \(hint)")
    }

    static func describe(_ devices: [SimulatorInfo]) -> String {
        devices.map { "\($0.name) (\($0.runtime), \($0.udid))" }.joined(separator: "; ")
    }

    /// Simulators in `simctl list devices --json` output, booted first, then newest OS and by name.
    public static func parseDevices(_ data: Data, deviceTypeNames: [String: String] = [:]) throws -> [SimulatorInfo] {
        struct Listing: Decodable {
            struct Device: Decodable {
                var udid: String
                var name: String
                var state: String
                var isAvailable: Bool?
                var deviceTypeIdentifier: String?
            }
            var devices: [String: [Device]]
        }
        let listing = try JSONDecoder().decode(Listing.self, from: data)
        var result: [SimulatorInfo] = []
        for (runtime, devices) in listing.devices {
            let name = runtimeName(runtime)
            for device in devices where device.isAvailable != false {
                result.append(SimulatorInfo(
                    udid: device.udid, name: device.name, runtime: name, state: device.state,
                    deviceType: device.deviceTypeIdentifier.map { deviceTypeNames[$0] ?? $0 }
                ))
            }
        }
        return result.sorted { a, b in
            if a.isBooted != b.isBooted { return a.isBooted }
            if a.runtime != b.runtime { return a.runtime.compare(b.runtime, options: .numeric) == .orderedDescending }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// `iOS 27.0` for `com.apple.CoreSimulator.SimRuntime.iOS-27-0`.
    public static func runtimeName(_ identifier: String) -> String {
        let last = identifier.split(separator: ".").last.map(String.init) ?? identifier
        let parts = last.split(separator: "-").map(String.init)
        guard let os = parts.first, parts.count > 1 else { return last }
        return "\(os) \(parts.dropFirst().joined(separator: "."))"
    }
}
