import Foundation

/// An Android emulator or phone, as adb (or the emulator's list of virtual devices) reports it.
public struct AndroidDeviceInfo: Codable, Sendable, Equatable {
    /// adb's serial, e.g. `emulator-5554`; empty for an emulator that isn't running.
    public var serial: String
    /// The virtual device's name for an emulator, the model for a phone.
    public var name: String
    /// `emulator` or `phone`.
    public var kind: String
    /// `running`, `stopped` (an emulator that isn't started), `offline` or `unauthorized`.
    public var state: String
    /// e.g. `16`.
    public var androidVersion: String?
    public var apiLevel: Int?
    /// The screen in pixels, as it's turned now.
    public var screen: Size?
    /// Dots per inch.
    public var density: Int?

    public init(
        serial: String, name: String, kind: String, state: String, androidVersion: String? = nil, apiLevel: Int? = nil,
        screen: Size? = nil, density: Int? = nil
    ) {
        self.serial = serial
        self.name = name
        self.kind = kind
        self.state = state
        self.androidVersion = androidVersion
        self.apiLevel = apiLevel
        self.screen = screen
        self.density = density
    }

    public var isRunning: Bool { state == "running" }
    public var isEmulator: Bool { kind == "emulator" }
}

/// Things to do with an Android device other than operating its screen.
public enum AndroidAction: String, Codable, Sendable, CaseIterable {
    case list
    case boot
    case shutdown
    case install
    case uninstall
    case launch
    case terminate
    case openURL = "open-url"
    case button
    case permission
    case location
    case appearance
    case rotate
    case statusBar = "status-bar"

    /// Actions that only read.
    public static let reading: Set<AndroidAction> = [.list]
}

/// Hardware and system buttons of an Android device.
public enum AndroidButton: String, Codable, Sendable, CaseIterable {
    case home
    case back
    case appSwitcher = "app-switcher"
    case power
    case volumeUp = "volume-up"
    case volumeDown = "volume-down"
    case menu
    case notifications
}

/// Lifecycle, apps, buttons and settings of Android emulators and phones, through adb.
public enum AndroidMethod: RPCMethod {
    public static let name = "android"

    public struct Params: Codable, Sendable, Equatable {
        public var action: AndroidAction
        /// A serial, an emulator's name, a phone's model, or `booted` for the only running device.
        public var device: String?
        /// The app's package name.
        public var package: String?
        /// The `.apk` to install.
        public var path: String?
        public var url: String?
        public var button: AndroidButton?
        /// permission: `grant`, `revoke` or `reset`; location and status-bar: `set` or `clear`.
        public var operation: String?
        /// permission: e.g. `android.permission.CAMERA` or `camera`.
        public var permission: String?
        public var latitude: Double?
        public var longitude: Double?
        /// `light` or `dark`.
        public var appearance: String?
        /// `portrait`, `landscape`, `reverse-portrait`, `reverse-landscape` or `auto`.
        public var orientation: String?
        public var statusBar: StatusBarOverrides?
        /// boot: start the emulator without a window.
        public var headless: Bool?

        public init(
            action: AndroidAction, device: String? = nil, package: String? = nil, path: String? = nil, url: String? = nil,
            button: AndroidButton? = nil, operation: String? = nil, permission: String? = nil, latitude: Double? = nil,
            longitude: Double? = nil, appearance: String? = nil, orientation: String? = nil, statusBar: StatusBarOverrides? = nil,
            headless: Bool? = nil
        ) {
            self.action = action
            self.device = device
            self.package = package
            self.path = path
            self.url = url
            self.button = button
            self.operation = operation
            self.permission = permission
            self.latitude = latitude
            self.longitude = longitude
            self.appearance = appearance
            self.orientation = orientation
            self.statusBar = statusBar
            self.headless = headless
        }
    }

    public struct Result: Codable, Sendable {
        public var performed: String
        public var device: AndroidDeviceInfo?
        /// list: every device and emulator.
        public var devices: [AndroidDeviceInfo]?
        public var notices: [Notice]

        public init(performed: String, device: AndroidDeviceInfo? = nil, devices: [AndroidDeviceInfo]? = nil, notices: [Notice] = []) {
            self.performed = performed
            self.device = device
            self.devices = devices
            self.notices = notices
        }
    }
}

extension Target {
    /// The prefix that makes a target an Android device: `android:<serial, name or booted>`.
    public static let androidPrefix = "android:"

    /// The device part of an `android:` target, or nil.
    public var androidDevice: String? { Target.androidDevice(in: app) }

    /// The device part of an `android:` app string, or nil.
    public static func androidDevice(in app: String) -> String? {
        guard app.lowercased().hasPrefix(androidPrefix) else { return nil }
        let device = app.dropFirst(androidPrefix.count).trimmingCharacters(in: .whitespaces)
        return device.isEmpty ? "booted" : device
    }
}

/// Reads `adb devices -l` and picks a device out of a list.
public enum AndroidCatalog {
    /// The devices in `adb devices -l` output, without names or versions yet.
    public static func parseDevices(_ text: String) -> [AndroidDeviceInfo] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard fields.count >= 2, !line.hasPrefix("List of devices"), !line.hasPrefix("*") else { return nil }
            let serial = fields[0]
            let state = switch fields[1] {
            case "device": "running"
            case "unauthorized": "unauthorized"
            default: "offline"
            }
            let model = fields.first { $0.hasPrefix("model:") }.map { String($0.dropFirst(6)).replacingOccurrences(of: "_", with: " ") }
            let kind = serial.hasPrefix("emulator-") ? "emulator" : "phone"
            return AndroidDeviceInfo(serial: serial, name: model ?? serial, kind: kind, state: state)
        }
    }

    /// The device a query picks: a serial, a name (emulator name or phone model), or `booted`
    /// for the only running device.
    public static func pick(_ query: String, from devices: [AndroidDeviceInfo]) throws -> AndroidDeviceInfo {
        let needle = query.trimmingCharacters(in: .whitespaces)
        let running = devices.filter(\.isRunning)
        if needle.lowercased() == "booted" {
            switch running.count {
            case 1: return running[0]
            case 0:
                throw RPCError(code: RPCErrorCode.failed, message: "No Android device is running. Start an emulator with `macos-harness android boot <name>`; `macos-harness android list` shows them.")
            default:
                throw RPCError(code: RPCErrorCode.failed, message: "\(running.count) Android devices are running; name one: \(describe(running)).")
            }
        }
        if let match = devices.first(where: { !$0.serial.isEmpty && $0.serial.caseInsensitiveCompare(needle) == .orderedSame }) {
            return match
        }
        let normalized = needle.replacingOccurrences(of: " ", with: "_").lowercased()
        let named = devices.filter {
            $0.name.lowercased() == needle.lowercased() || $0.name.replacingOccurrences(of: " ", with: "_").lowercased() == normalized
        }
        if let live = named.first(where: \.isRunning) ?? named.first { return live }
        let similar = devices.filter { $0.name.lowercased().contains(needle.lowercased()) }
        let hint = similar.isEmpty ? "`macos-harness android list` shows them." : "Did you mean \(describe(Array(similar.prefix(5))))?"
        throw RPCError(code: RPCErrorCode.failed, message: "No Android device matches “\(needle)”. \(hint)")
    }

    static func describe(_ devices: [AndroidDeviceInfo]) -> String {
        devices.map { "\($0.name) (\($0.serial.isEmpty ? $0.state : $0.serial))" }.joined(separator: "; ")
    }
}
