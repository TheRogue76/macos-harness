import Foundation
import HarnessProtocol

public final class MCPServer {
    public static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    private var connection: HarnessConnection?

    public init() {}

    /// Handles one JSON-RPC message; returns the encoded reply, or nil for notifications.
    public func handle(_ line: String) -> Data? {
        guard let message = try? HarnessJSON.decoder.decode(JSONValue.self, from: Data(line.utf8)),
              case .object(let fields) = message else {
            return encode(["jsonrpc": .string("2.0"), "id": .null, "error": error(-32700, "parse error")])
        }
        let id = fields["id"]
        let method = fields["method"]?.stringValue ?? ""
        let params = fields["params"]
        guard let id, id != .null else { return nil }  // notifications need no reply

        let result: JSONValue
        switch method {
        case "initialize":
            let requested = params?["protocolVersion"]?.stringValue ?? ""
            result = .object([
                "protocolVersion": .string(Self.supportedVersions.contains(requested) ? requested : Self.supportedVersions[0]),
                "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                "serverInfo": .object([
                    "name": .string("macos-harness"), "title": .string("macOS Harness"),
                    "version": .string(HarnessVersion.string),
                ]),
                "instructions": .string(MCPTools.instructions),
            ])
        case "ping":
            result = .object([:])
        case "tools/list":
            result = .object(["tools": .array(MCPTools.definitions)])
        case "tools/call":
            let name = params?["name"]?.stringValue ?? ""
            let arguments = params?["arguments"] ?? .object([:])
            result = call(name, MCPArguments(arguments))
        default:
            return encode(["jsonrpc": .string("2.0"), "id": id, "error": error(-32601, "method not found: \(method)")])
        }
        return encode(["jsonrpc": .string("2.0"), "id": id, "result": result])
    }

    private func call(_ tool: String, _ arguments: MCPArguments) -> JSONValue {
        do {
            let content = try withConnection { try MCPTools.call(tool, arguments, connection: $0) }
            return .object(["content": .array(content), "isError": .bool(false)])
        } catch let error as RPCError {
            return toolError(error.message)
        } catch let error as HarnessClientError {
            return toolError(error.description)
        } catch {
            return toolError(String(describing: error))
        }
    }

    /// Reuses one helper connection, reconnecting once if the helper restarted.
    private func withConnection<T>(_ body: (HarnessConnection) throws -> T) throws -> T {
        if connection == nil { connection = try HarnessConnection.open() }
        do {
            return try body(connection!)
        } catch let error as SocketError {
            connection = try HarnessConnection.open()
            _ = error
            return try body(connection!)
        } catch HarnessClientError.protocolError(let detail) where detail.contains("closed") {
            connection = try HarnessConnection.open()
            return try body(connection!)
        }
    }

    private func toolError(_ message: String) -> JSONValue {
        .object(["content": .array([MCPTools.text(message)]), "isError": .bool(true)])
    }

    private func error(_ code: Int, _ message: String) -> JSONValue {
        .object(["code": .number(Double(code)), "message": .string(message)])
    }

    private func encode(_ object: [String: JSONValue]) -> Data {
        (try? HarnessJSON.encoder.encode(JSONValue.object(object))) ?? Data()
    }
}

/// Typed access to a tool call's arguments.
public struct MCPArguments {
    var raw: JSONValue

    public init(_ raw: JSONValue) {
        self.raw = raw
    }

    func string(_ key: String) -> String? {
        if case .object(let object) = raw, case .string(let value)? = object[key] { return value }
        return nil
    }

    func requiredString(_ key: String) throws -> String {
        guard let value = string(key) else {
            throw RPCError(code: RPCErrorCode.invalidParams, message: "Missing required argument “\(key)”.")
        }
        return value
    }

    func number(_ key: String) -> Double? {
        if case .object(let object) = raw, case .number(let value)? = object[key] { return value }
        return nil
    }

    func int(_ key: String) -> Int? { number(key).map { Int($0) } }

    func bool(_ key: String) -> Bool? {
        if case .object(let object) = raw, case .bool(let value)? = object[key] { return value }
        return nil
    }

    func strings(_ key: String) -> [String] {
        if case .object(let object) = raw, case .array(let values)? = object[key] { return values.compactMap(\.stringValueForMCP) }
        return []
    }

    func dictionary(_ key: String) -> [String: String] {
        if case .object(let object) = raw, case .object(let values)? = object[key] {
            return values.compactMapValues(\.stringValueForMCP)
        }
        return [:]
    }

    var target: Target {
        get throws { Target(app: try requiredString("app"), window: int("window").map { UInt32($0) }) }
    }

    var selector: ElementSelector? {
        let selector = ElementSelector(ref: string("ref"), text: string("text"), role: string("role"), identifier: string("id"), exact: bool("exact") ?? false)
        return selector.isEmpty ? nil : selector
    }
}

private extension JSONValue {
    var stringValueForMCP: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

public enum MCPTools {
    static let instructions = """
        macOS Harness lets you see and operate Mac apps. Typical loop: `apps` or `windows` to find the app, \
        `snapshot` to get its UI as refs (like k12) with click points, then `act` on a ref (press, set-value, type, key…). \
        Every action reports what changed, so you rarely need a new snapshot. Use `menu_select` for menu commands, \
        `screenshot` to look, `wait` for things that take time. Refs end when the app or the helper restarts. \
        Actions work through accessibility and don't move the user's cursor. The user can stop you from the menu bar; \
        if a call says you were stopped, ask them to resume.
        """

    static func text(_ string: String) -> JSONValue {
        .object(["type": .string("text"), "text": .string(string)])
    }

    // MARK: Schemas

    private static func property(_ type: String, _ description: String) -> JSONValue {
        .object(["type": .string(type), "description": .string(description)])
    }

    private static func stringList(_ description: String) -> JSONValue {
        .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string(description)])
    }

    private static func choice(_ values: [String], _ description: String) -> JSONValue {
        .object(["type": .string("string"), "enum": .array(values.map(JSONValue.string)), "description": .string(description)])
    }

    private static let app = property("string", "App name, bundle ID or pid.")
    private static let window = property("integer", "Window ID from `windows`; defaults to the focused window.")
    private static let elementProperties: [String: JSONValue] = [
        "ref": property("string", "Ref from snapshot or find, e.g. k12."),
        "text": property("string", "Instead of a ref: match label, value or identifier containing this."),
        "role": property("string", "Instead of a ref: role such as button, textfield, switch, tab, menuitem."),
        "id": property("string", "Instead of a ref: exact accessibility identifier."),
        "exact": property("boolean", "text must match the whole label, value or identifier."),
    ]

    private static func tool(
        _ name: String, _ title: String, _ description: String, _ properties: [String: JSONValue], required: [String] = [],
        readOnly: Bool = false
    ) -> JSONValue {
        .object([
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object(properties),
                "required": .array(required.map(JSONValue.string)),
            ]),
            "annotations": .object(["readOnlyHint": .bool(readOnly), "openWorldHint": .bool(false)]),
        ])
    }

    public static let definitions: [JSONValue] = [
        tool("doctor", "Check setup", "Check that the macOS Harness helper runs, has its permissions, and whether you're paired or stopped.", [:], readOnly: true),
        tool("apps", "List apps", "Running apps, frontmost first, with window counts.",
             ["all": property("boolean", "Include menu bar agents and background processes.")], readOnly: true),
        tool("windows", "List windows", "Windows with IDs, titles, sizes and state. Omit app for all apps.",
             ["app": app], readOnly: true),
        tool("snapshot", "Read UI", "The window's UI as an indented tree: `ref role \"label\" = value id=… @x,y`. @x,y is the click point in window points. Use the refs with act.",
             ["app": app, "window": window, "root": property("string", "Ref of a node marked \"+N more\" to expand."),
              "max_nodes": property("integer", "Most elements to show (default 250).")],
             required: ["app"], readOnly: true),
        tool("find", "Find elements", "Elements by text, role or id, including ones scrolled out of view.",
             ["app": app, "window": window, "text": property("string", "Label, value or identifier contains this."),
              "role": property("string", "Role, e.g. button."), "id": property("string", "Exact identifier."),
              "exact": property("boolean", "Whole-text match."), "limit": property("integer", "Most matches (default 20).")],
             required: ["app"], readOnly: true),
        tool("screenshot", "Look at a window", "A PNG of one window (never other apps). labels=true draws refs on actionable elements; element crops to a ref.",
             ["app": app, "window": window, "element": property("string", "Ref to crop to."),
              "labels": property("boolean", "Draw refs on the image."),
              "max_size": property("integer", "Longest edge in pixels (default 1280; 0 = full).")],
             required: ["app"], readOnly: true),
        tool("menu", "Read menus", "An app's menu bar, or one menu by path, with shortcuts and enabled state.",
             ["app": app, "path": stringList("Menu titles to descend, e.g. [\"File\"]."), "depth": property("integer", "Levels below the path (default 1).")],
             required: ["app"], readOnly: true),
        tool("act", "Act on an element", "Press, set-value, focus, select, increment, decrement, scroll-to, type (text at the cursor) or key (e.g. cmd+s, return). Through accessibility; the user's cursor stays put. Returns what changed.",
             ["app": app, "window": window,
              "action": choice(ElementAction.allCases.map(\.rawValue), "What to do."),
              "value": property("string", "Value for set-value, text for type, combination for key."),
              "count": property("integer", "Repeat count for increment/decrement."),
              "diff": property("boolean", "Report what changed (default true).")].merging(elementProperties) { $1 },
             required: ["app", "action"]),
        tool("menu_select", "Choose a menu item", "Choose a menu item by path, e.g. [\"Format\", \"Font\", \"Bold\"]. Brings the app to the front first unless activate=false.",
             ["app": app, "path": stringList("Menu titles down to the item."), "activate": property("boolean", "Bring the app to the front first (default true).")],
             required: ["app", "path"]),
        tool("window", "Manage a window", "Activate, move, resize, minimize, restore, fullscreen, exit-fullscreen or close a window.",
             ["app": app, "window": window, "action": choice(WindowActionMethod.Action.allCases.map(\.rawValue), "What to do."),
              "x": property("number", "Left edge for move (global points)."), "y": property("number", "Top edge for move."),
              "width": property("number", "Width for resize."), "height": property("number", "Height for resize.")],
             required: ["app", "action"]),
        tool("launch", "Launch an app", "Launch an app in the background (unless activate) and wait for its first window; optionally open files with it.",
             ["app": property("string", "App name, bundle ID or path to an .app."), "open": stringList("Files to open with it."),
              "args": stringList("Launch arguments."), "env": .object(["type": .string("object"), "description": .string("Environment variables."), "additionalProperties": .object(["type": .string("string")])]),
              "activate": property("boolean", "Bring it to the front."), "timeout": property("number", "Seconds to wait for a window (default 15).")],
             required: ["app"]),
        tool("quit", "Quit an app", "Ask an app to quit (force=true kills it; unsaved work is lost).",
             ["app": app, "force": property("boolean", "Kill instead of asking.")], required: ["app"]),
        tool("wait", "Wait for an element", "Wait until an element appears, or with gone=true disappears.",
             ["app": app, "window": window, "gone": property("boolean", "Wait for it to disappear."),
              "timeout": property("number", "Seconds before giving up (default 10).")].merging(elementProperties) { $1 },
             required: ["app"], readOnly: true),
    ]

    // MARK: Calls

    static func call(_ tool: String, _ arguments: MCPArguments, connection: HarnessConnection) throws -> [JSONValue] {
        switch tool {
        case "doctor":
            let report = try connection.call(DoctorMethod.self, .init(), timeout: 10)
            return [text(Render.doctor(report, socketPath: connection.location.socketPath))]
        case "apps":
            let result = try connection.call(AppsMethod.self, .init(includeBackground: arguments.bool("all") ?? false))
            return [text(result.apps.map { app in
                "\(app.name)\(app.bundleIdentifier.map { " [\($0)]" } ?? ""): pid \(app.pid), \(app.windowCount) window\(app.windowCount == 1 ? "" : "s")\(app.active ? ", frontmost" : "")"
            }.joined(separator: "\n"))]
        case "windows":
            return [text(Render.windows(try connection.call(WindowsMethod.self, .init(app: arguments.string("app")))))]
        case "snapshot":
            let result = try connection.call(SnapshotMethod.self, .init(
                target: try arguments.target, root: arguments.string("root"), maxNodes: arguments.int("max_nodes") ?? 250
            ))
            return [text(Render.snapshot(result))]
        case "find":
            let result = try connection.call(FindMethod.self, .init(
                target: try arguments.target, text: arguments.string("text"), role: arguments.string("role"),
                identifier: arguments.string("id"), exact: arguments.bool("exact") ?? false, limit: arguments.int("limit") ?? 20
            ))
            return [text(Render.find(result))]
        case "screenshot":
            let result = try connection.call(ScreenshotMethod.self, .init(
                target: try arguments.target, element: arguments.string("element"),
                maxSize: arguments.int("max_size") ?? 1280, labels: arguments.bool("labels") ?? false
            ))
            var summary = "\(result.width)x\(result.height) px, scale \(result.scale) px per window point, window \(result.window.id) “\(result.window.title)”."
            if let crop = result.crop { summary += " Cropped to window-relative (\(Int(crop.x)),\(Int(crop.y)))." }
            if !result.labeledRefs.isEmpty { summary += " Labeled: \(result.labeledRefs.prefix(60).joined(separator: " "))." }
            summary += result.notices.filter { $0.kind != "notFrontmost" }.map { " \($0.message)" }.joined()
            return [
                .object(["type": .string("image"), "data": .string(result.pngBase64), "mimeType": .string("image/png")]),
                text(summary),
            ]
        case "menu":
            let path = arguments.strings("path")
            let result = try connection.call(MenuMethod.self, .init(app: try arguments.requiredString("app"), path: path, depth: arguments.int("depth") ?? 1))
            return [text(Render.menu(result, path: path))]
        case "act":
            guard let action = arguments.string("action").flatMap(ElementAction.init(rawValue:)) else {
                throw RPCError(code: RPCErrorCode.invalidParams, message: "action must be one of \(ElementAction.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            let result = try connection.call(ActMethod.self, .init(
                target: try arguments.target, element: arguments.selector, action: action, value: arguments.string("value"),
                count: arguments.int("count") ?? 1, diff: arguments.bool("diff") ?? true
            ))
            return [text(Render.action(result))]
        case "menu_select":
            let result = try connection.call(MenuSelectMethod.self, .init(
                app: try arguments.requiredString("app"), path: arguments.strings("path"), activate: arguments.bool("activate") ?? true
            ))
            return [text(Render.action(result))]
        case "window":
            guard let action = arguments.string("action").flatMap(WindowActionMethod.Action.init(rawValue:)) else {
                throw RPCError(code: RPCErrorCode.invalidParams, message: "action must be one of \(WindowActionMethod.Action.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            let result = try connection.call(WindowActionMethod.self, .init(
                target: try arguments.target, action: action, x: arguments.number("x"), y: arguments.number("y"),
                width: arguments.number("width"), height: arguments.number("height")
            ))
            return [text(Render.action(result))]
        case "launch":
            let result = try connection.call(LaunchMethod.self, .init(
                app: try arguments.requiredString("app"), arguments: arguments.strings("args"),
                environment: arguments.dictionary("env"),
                open: arguments.strings("open").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).path },
                activate: arguments.bool("activate") ?? false, timeout: arguments.number("timeout") ?? 15
            ))
            return [text(Render.launch(result))]
        case "quit":
            let result = try connection.call(QuitMethod.self, .init(app: try arguments.requiredString("app"), force: arguments.bool("force") ?? false))
            return [text(result.message)]
        case "wait":
            guard let selector = arguments.selector else {
                throw RPCError(code: RPCErrorCode.invalidParams, message: "Say what to wait for: ref, text, role or id.")
            }
            let gone = arguments.bool("gone") ?? false
            let result = try connection.call(WaitMethod.self, .init(
                target: try arguments.target, element: selector, gone: gone, timeout: arguments.number("timeout") ?? 10
            ))
            return [text(Render.wait(result, gone: gone))]
        default:
            throw RPCError(code: RPCErrorCode.methodNotFound, message: "Unknown tool \(tool).")
        }
    }
}
