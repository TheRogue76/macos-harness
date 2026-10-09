import Foundation
import HarnessProtocol

/// The `simulator` method: lifecycle, apps, buttons and settings of iOS Simulators.
public enum SimulatorService {
    public static func run(_ params: SimulatorMethod.Params) async throws -> SimulatorMethod.Result {
        if params.action == .list {
            let devices = try await Simctl.devices()
            let booted = devices.filter(\.isBooted).count
            return .init(performed: "\(devices.count) simulators, \(booted) booted", devices: devices)
        }
        let device = try await Simctl.device(params.device ?? "booted")
        let udid = device.udid
        switch params.action {
        case .list:
            return .init(performed: "")
        case .boot:
            return try await boot(device)
        case .shutdown:
            guard device.isBooted else { return .init(performed: "\(device.name) was already shut down", device: device) }
            try await Simctl.run(["shutdown", udid], timeout: 120)
            return .init(performed: "shut down \(device.name)", device: try await Simctl.device(udid))
        case .install:
            let path = try required(params.path, "install needs the .app to install")
            let expanded = (path as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else {
                throw RPCError(code: RPCErrorCode.invalidParams, message: "No app at \(expanded).")
            }
            try await requireBooted(device)
            try await Simctl.run(["install", udid, expanded], timeout: 300)
            let bundle = Bundle(path: expanded)?.bundleIdentifier
            return .init(performed: "installed \(bundle ?? (expanded as NSString).lastPathComponent) on \(device.name)", device: device)
        case .uninstall:
            let bundle = try required(params.bundleIdentifier, "uninstall needs a bundle ID")
            try await requireBooted(device)
            try await Simctl.run(["uninstall", udid, bundle], timeout: 120)
            return .init(performed: "uninstalled \(bundle) from \(device.name)", device: device)
        case .launch:
            return try await launch(params, device: device)
        case .terminate:
            let bundle = try required(params.bundleIdentifier, "terminate needs a bundle ID")
            try await requireBooted(device)
            do {
                try await Simctl.run(["terminate", udid, bundle], timeout: 60)
            } catch let error as RPCError where error.message.contains("found nothing to terminate") {
                return .init(performed: "\(bundle) wasn't running on \(device.name)", device: device)
            }
            return .init(performed: "terminated \(bundle) on \(device.name)", device: device)
        case .openURL:
            let url = try required(params.url, "open-url needs a URL")
            try await requireBooted(device)
            try await Simctl.run(["openurl", udid, url], timeout: 60)
            return .init(performed: "opened \(url) on \(device.name)", device: device)
        case .button:
            let button = try required(params.button, "button needs which: \(SimulatorButton.allCases.map(\.rawValue).joined(separator: ", "))")
            try await requireBooted(device)
            let (hub, window) = try await SimulatorScreens.shared.resolve(device: udid, window: nil)
            let performed = try await SimulatorInput.press(button, window: window, hub: hub)
            return .init(performed: "\(performed) on \(device.name)", device: device)
        case .privacy:
            return try await privacy(params, device: device)
        case .push:
            let bundle = try required(params.bundleIdentifier, "push needs the app's bundle ID")
            let payload = try required(params.payload, "push needs the notification payload as JSON")
            guard (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) != nil else {
                throw RPCError(code: RPCErrorCode.invalidParams, message: "The push payload isn't valid JSON.")
            }
            try await requireBooted(device)
            try await Simctl.run(["push", udid, bundle, "-"], input: Data(payload.utf8), timeout: 60)
            return .init(performed: "sent a push notification to \(bundle) on \(device.name)", device: device)
        case .location:
            try await requireBooted(device)
            if params.operation == "clear" {
                try await Simctl.run(["location", udid, "clear"], timeout: 60)
                return .init(performed: "cleared \(device.name)'s simulated location", device: device)
            }
            guard let latitude = params.latitude, let longitude = params.longitude else {
                throw RPCError(code: RPCErrorCode.invalidParams, message: "location needs a latitude and longitude, or clear.")
            }
            try await Simctl.run(["location", udid, "set", "\(latitude),\(longitude)"], timeout: 60)
            return .init(performed: "set \(device.name)'s location to \(latitude), \(longitude)", device: device)
        case .appearance:
            let appearance = try required(params.appearance, "appearance needs light or dark").lowercased()
            guard ["light", "dark"].contains(appearance) else {
                throw RPCError(code: RPCErrorCode.invalidParams, message: "appearance is light or dark.")
            }
            try await requireBooted(device)
            try await Simctl.run(["ui", udid, "appearance", appearance], timeout: 60)
            return .init(performed: "switched \(device.name) to \(appearance) mode", device: device)
        case .statusBar:
            return try await statusBar(params, device: device)
        case .pasteboard:
            try await requireBooted(device)
            if params.operation == "get" {
                let text = try await Simctl.run(["pbpaste", udid], timeout: 30)
                return .init(performed: "read \(device.name)'s pasteboard", device: device, text: text)
            }
            let text = try required(params.text, "pasteboard set needs the text")
            try await Simctl.run(["pbcopy", udid], input: Data(text.utf8), timeout: 30)
            return .init(performed: "copied \(text.count) characters onto \(device.name)'s pasteboard", device: device)
        }
    }

    /// Boots the device, waits until it has finished starting, then shows it in Device Hub and
    /// waits for its home screen there. Device Hub only sees the screens of simulators that were
    /// already running when it started, so when it's open with no simulator running it's quit
    /// first (that loses nothing) and opened again after the boot.
    static func boot(_ device: SimulatorInfo) async throws -> SimulatorMethod.Result {
        var notices: [Notice] = []
        var hubStale = false
        if !device.isBooted {
            if await MainActor.run(body: { SimulatorScreens.runningHub() != nil }) {
                if try await Simctl.devices().contains(where: \.isBooted) {
                    hubStale = true
                } else if await SimulatorScreens.quitDeviceHub() {
                    notices.append(Notice(
                        kind: "deviceHubRestarted",
                        message: "Restarted Device Hub (no simulator was running): it only sees the screens of simulators that were running when it started."
                    ))
                } else {
                    hubStale = true
                }
            }
            try await Simctl.run(["boot", device.udid], timeout: 300)
        }
        try await Simctl.run(["bootstatus", device.udid], timeout: 600)
        do {
            let (_, window) = try await SimulatorScreens.shared.resolve(device: device.udid, window: nil)
            if !(await SimulatorScreens.waitForContent(window, timeout: hubStale || device.isBooted ? 30 : 180)) {
                notices.append(Notice(
                    kind: "simulatorLoading",
                    message: "Device Hub doesn't list the elements on \(device.name)'s screen. It only sees simulators that were running when it started; quitting Device Hub fixes it but shuts down its simulators, so ask the user before doing that, then run `macos-harness sim boot` again."
                ))
            }
        } catch let error as RPCError {
            notices.append(Notice(kind: "deviceHub", message: "Booted, but Device Hub couldn't show it yet: \(error.message)"))
        }
        let performed = device.isBooted ? "\(device.name) was already booted" : "booted \(device.name)"
        return .init(performed: performed, device: try await Simctl.device(device.udid), notices: notices)
    }

    static func launch(_ params: SimulatorMethod.Params, device: SimulatorInfo) async throws -> SimulatorMethod.Result {
        let bundle = try required(params.bundleIdentifier, "launch needs a bundle ID")
        try await requireBooted(device)
        let environment = Dictionary(uniqueKeysWithValues: params.environment.map { ("SIMCTL_CHILD_\($0.key)", $0.value) })
        let output = try await Simctl.run(
            ["launch", "--terminate-running-process", device.udid, bundle] + params.arguments, environment: environment, timeout: 120
        )
        let pid = output.split(separator: ":").last.flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return .init(performed: "launched \(bundle) on \(device.name)", device: device, pid: pid)
    }

    static let privacyOperations = ["grant", "revoke", "reset"]

    static func privacy(_ params: SimulatorMethod.Params, device: SimulatorInfo) async throws -> SimulatorMethod.Result {
        let operation = try required(params.operation, "privacy needs grant, revoke or reset")
        guard privacyOperations.contains(operation) else {
            throw RPCError(code: RPCErrorCode.invalidParams, message: "privacy takes grant, revoke or reset.")
        }
        let service = try required(params.service, "privacy needs a service, e.g. photos, location, camera, contacts or all")
        if operation != "reset", params.bundleIdentifier == nil {
            throw RPCError(code: RPCErrorCode.invalidParams, message: "privacy \(operation) needs the app's bundle ID.")
        }
        try await requireBooted(device)
        try await Simctl.run(["privacy", device.udid, operation, service] + [params.bundleIdentifier].compactMap { $0 }, timeout: 60)
        let app = params.bundleIdentifier.map { " for \($0)" } ?? ""
        return .init(performed: "\(operation == "reset" ? "reset" : operation + "ed") \(service)\(app) on \(device.name)", device: device)
    }

    static func statusBar(_ params: SimulatorMethod.Params, device: SimulatorInfo) async throws -> SimulatorMethod.Result {
        try await requireBooted(device)
        if params.operation == "clear" {
            try await Simctl.run(["status_bar", device.udid, "clear"], timeout: 60)
            return .init(performed: "cleared \(device.name)'s status bar overrides", device: device)
        }
        guard let overrides = params.statusBar, !overrides.isEmpty else {
            throw RPCError(code: RPCErrorCode.invalidParams, message: "status-bar needs at least one value to show (time, battery, bars…), or clear.")
        }
        var arguments = ["status_bar", device.udid, "override"]
        if let time = overrides.time { arguments += ["--time", time] }
        if let level = overrides.batteryLevel { arguments += ["--batteryLevel", "\(level)"] }
        if let state = overrides.batteryState { arguments += ["--batteryState", state] }
        if let bars = overrides.wifiBars { arguments += ["--wifiMode", "active", "--wifiBars", "\(bars)"] }
        if let bars = overrides.cellularBars { arguments += ["--cellularMode", "active", "--cellularBars", "\(bars)"] }
        if let network = overrides.dataNetwork { arguments += ["--dataNetwork", network] }
        if let name = overrides.operatorName { arguments += ["--operatorName", name] }
        try await Simctl.run(arguments, timeout: 60)
        return .init(performed: "overrode \(device.name)'s status bar", device: device)
    }

    static func requireBooted(_ device: SimulatorInfo) async throws {
        guard device.isBooted else {
            throw RPCError(
                code: RPCErrorCode.failed,
                message: "\(device.name) (\(device.runtime)) isn't booted. Boot it with `macos-harness sim boot \"\(device.name)\"`."
            )
        }
    }

    static func required<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw RPCError(code: RPCErrorCode.invalidParams, message: message) }
        return value
    }
}
