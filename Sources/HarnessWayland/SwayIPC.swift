import Foundation
import HarnessProtocol
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A window as Sway's tree shows it, in layout coordinates.
public struct SwayWindow: Sendable, Equatable {
    public var id: Int
    public var pid: Int32?
    public var appID: String?
    public var title: String
    /// Where the window's content is: its container's rectangle plus the window's place in it.
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var focused: Bool
    public var visible: Bool
    public var output: String?
}

/// An output as Sway lays it out.
public struct SwayOutput: Sendable, Equatable {
    public var name: String
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var scale: Double
}

/// Sway's IPC: i3's protocol of a magic string, a length, a type and a JSON payload.
public enum SwayIPC {
    static let magic = Array("i3-ipc".utf8)
    static let getTree: UInt32 = 4
    static let getOutputs: UInt32 = 3
    static let command: UInt32 = 0

    /// Sway's socket, from `SWAYSOCK`.
    public static func socketPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        environment["SWAYSOCK"].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// A request's bytes.
    static func encode(type: UInt32, payload: String) -> [UInt8] {
        let body = Array(payload.utf8)
        var bytes = magic
        WaylandWire.append(UInt32(body.count), to: &bytes)
        WaylandWire.append(type, to: &bytes)
        return bytes + body
    }

    /// Sends one request and returns the reply's JSON.
    public static func request(_ type: UInt32, _ payload: String = "", socket path: String) throws -> Any {
        let socket = try LineSocket.connect(path: path)
        socket.setReadTimeout(5)
        let request = encode(type: type, payload: payload)
        try write(request, to: socket.fd)
        let header = try read(14, from: socket.fd)
        guard Array(header.prefix(6)) == magic else { throw WaylandError.malformed("Sway's reply has no i3-ipc header") }
        let length = Int(WaylandWire.word(header[...], at: 6))
        let body = try read(length, from: socket.fd)
        return try JSONSerialization.jsonObject(with: Data(body))
    }

    /// The windows in Sway's tree, with their content rectangles.
    public static func windows(socket path: String) throws -> [SwayWindow] {
        windows(inTree: try request(getTree, socket: path))
    }

    static func windows(inTree tree: Any) -> [SwayWindow] {
        var found: [SwayWindow] = []
        func visit(_ node: [String: Any], output: String?, visible: Bool) {
            let type = node["type"] as? String
            let currentOutput = type == "output" ? node["name"] as? String : output
            let shown = visible && (node["visible"] as? Bool ?? true)
            if node["pid"] != nil, let rect = node["rect"] as? [String: Any], let window = node["window_rect"] as? [String: Any] {
                func number(_ map: [String: Any], _ key: String) -> Double { (map[key] as? NSNumber)?.doubleValue ?? 0 }
                found.append(SwayWindow(
                    id: (node["id"] as? NSNumber)?.intValue ?? 0, pid: (node["pid"] as? NSNumber).map { Int32(truncating: $0) },
                    appID: node["app_id"] as? String, title: node["name"] as? String ?? "",
                    x: number(rect, "x") + number(window, "x"), y: number(rect, "y") + number(window, "y"),
                    width: number(window, "width"), height: number(window, "height"),
                    focused: node["focused"] as? Bool ?? false, visible: node["visible"] as? Bool ?? shown, output: currentOutput
                ))
            }
            for key in ["nodes", "floating_nodes"] {
                for child in node[key] as? [[String: Any]] ?? [] { visit(child, output: currentOutput, visible: shown) }
            }
        }
        if let root = tree as? [String: Any] { visit(root, output: nil, visible: true) }
        return found
    }

    /// Sway's active outputs.
    public static func outputs(socket path: String) throws -> [SwayOutput] {
        outputs(inReply: try request(getOutputs, socket: path))
    }

    static func outputs(inReply reply: Any) -> [SwayOutput] {
        (reply as? [[String: Any]] ?? []).compactMap { output in
            guard output["active"] as? Bool ?? true, let name = output["name"] as? String, let rect = output["rect"] as? [String: Any] else {
                return nil
            }
            func number(_ key: String) -> Double { (rect[key] as? NSNumber)?.doubleValue ?? 0 }
            return SwayOutput(
                name: name, x: number("x"), y: number("y"), width: number("width"), height: number("height"),
                scale: (output["scale"] as? NSNumber)?.doubleValue ?? 1
            )
        }
    }

    private static func write(_ bytes: [UInt8], to fd: Int32) throws {
        var offset = 0
        while offset < bytes.count {
            let sent = bytes.withUnsafeBytes { raw in unsafe POSIX.send(fd, raw.baseAddress! + offset, raw.count - offset) }
            if sent < 0, errno == EINTR { continue }
            guard sent > 0 else { throw WaylandError.closed }
            offset += sent
        }
    }

    private static func read(_ count: Int, from fd: Int32) throws -> [UInt8] {
        var bytes: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while bytes.count < count {
            let got = unsafe Glibc.read(fd, &chunk, min(chunk.count, count - bytes.count))
            if got < 0, errno == EINTR { continue }
            guard got > 0 else { throw got == 0 ? WaylandError.closed : WaylandError.timedOut }
            bytes += chunk[0..<got]
        }
        return bytes
    }
}
