#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import HarnessCore
import HarnessDBus
import HarnessImaging
import HarnessProtocol
import HarnessWayland
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Records a Linux desktop app's window, or an Android screen, to a movie file, one recording
/// per request, each stopping on its own after its maximum length. GStreamer encodes it: from
/// frames the harness grabs on Sway, and from a ScreenCast portal stream on GNOME and KDE.
public actor LinuxRecording {
    public static let shared = LinuxRecording()

    enum Capture {
        case frames(Task<Void, Never>, writeEnd: Int32, SpawnedProcess)
        case portal(ScreenCastSession, SpawnedProcess)
        case android(AndroidRecording)
    }

    struct Active {
        var id: String
        var path: String
        var owner: String
        var started: Date
        var capture: Capture
    }

    private var active: [String: Active] = [:]
    private var counter = 0

    static let framesPerSecond = 10

    public func start(_ params: RecordStartMethod.Params, owner: String) async throws -> RecordStartMethod.Result {
        guard (params.path as NSString).isAbsolutePath else {
            throw RPCError(code: RPCErrorCode.invalidParams, message: "Give an absolute path ending in .mov, .mp4, .webm or .mkv.")
        }
        if let query = params.target.androidDevice {
            let recording = try await AndroidRecording.start(query, path: params.path, maxSeconds: params.maxSeconds)
            let id = register(path: params.path, owner: owner, capture: .android(recording), maxSeconds: Double(recording.seconds))
            return RecordStartMethod.Result(id: id, path: params.path, app: AppRef(name: recording.deviceName, bundleIdentifier: nil, pid: recording.pid))
        }
        let encoding = try await Encoding.choose(for: params.path)
        let compositor = try await Compositors.required(for: "record")
        let place = try await LinuxDesktop.place(params.target)
        guard let placed = place.placed else {
            throw RPCError(code: RPCErrorCode.failed, message: "\(compositor.name) doesn't show \(place.ref.name)'s window, so there's nothing to record.")
        }
        let url = URL(fileURLWithPath: params.path)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let capture: Capture
        if let sway = compositor as? SwayCompositor {
            capture = try await startFrames(of: placed, socket: sway.socket, encoding: encoding, path: params.path)
        } else {
            capture = try await startPortal(of: placed, encoding: encoding, path: params.path)
        }
        let id = register(path: params.path, owner: owner, capture: capture, maxSeconds: params.maxSeconds)
        return RecordStartMethod.Result(id: id, path: params.path, app: place.ref)
    }

    /// Grabs the window's part of its output with screen copy and pipes the pixels to GStreamer.
    func startFrames(of window: CompositorWindow, socket: String, encoding: Encoding, path: String) async throws -> Capture {
        let outputs = try SwayIPC.outputs(socket: socket)
        guard let layout = outputs.first(where: { $0.name == window.output }) ?? outputs.first else {
            throw RPCError(code: RPCErrorCode.failed, message: "Sway shows the window on no output it lists.")
        }
        let connection = try WaylandConnection.connect()
        let capture = try await WaylandCapture.make(on: connection)
        guard let output = capture.outputs.first(where: { $0.name == layout.name }) ?? capture.outputs.first else {
            connection.close()
            throw RPCError(code: RPCErrorCode.failed, message: "The compositor offers no output to record.")
        }
        let first = try await capture.capture(output)
        let scale = Double(first.width) / max(layout.width, 1)
        let x = max(0, Int(((window.frame.minX - layout.x) * scale).rounded()))
        let y = max(0, Int(((window.frame.minY - layout.y) * scale).rounded()))
        let width = min(Int((window.frame.width * scale).rounded()), first.width - x) / 2 * 2
        let height = min(Int((window.frame.height * scale).rounded()), first.height - y) / 2 * 2
        guard width >= 2, height >= 2 else {
            connection.close()
            throw RPCError(code: RPCErrorCode.failed, message: "The window is off its output, so there's nothing to record.")
        }
        let (readEnd, writeEnd) = try UnixPipe.make()
        let source = "fdsrc fd=0 ! rawvideoparse format=rgba width=\(width) height=\(height) framerate=\(Self.framesPerSecond)/1"
        let process: SpawnedProcess
        do {
            process = try Spawn.process(encoding.gst, arguments: encoding.arguments(source: source, path: path), stdin: readEnd, log: Self.logPath)
        } catch {
            UnixPipe.close(readEnd)
            UnixPipe.close(writeEnd)
            connection.close()
            throw error
        }
        UnixPipe.close(readEnd)
        let interval = Duration.milliseconds(1000 / Self.framesPerSecond)
        let task = Task.detached {
            defer { connection.close() }
            var next = ContinuousClock.now
            while !Task.isCancelled {
                guard let image = try? await capture.capture(output),
                      let frame = Bitmap(width: image.width, height: image.height, pixels: image.rgba).cropped(x: x, y: y, width: width, height: height),
                      Self.send(frame.pixels, to: writeEnd) else { break }
                next += interval
                try? await Task.sleep(until: next, clock: .continuous)
            }
        }
        return .frames(task, writeEnd: writeEnd, process)
    }

    /// Records the window's part of its monitor from a ScreenCast portal stream.
    func startPortal(of window: CompositorWindow, encoding: Encoding, path: String) async throws -> Capture {
        let session: ScreenCastSession
        do {
            session = try await ScreenCastSession.start()
        } catch let error as RPCError where error.code == RPCErrorCode.permissionMissing {
            throw await LinuxPermissions.missing(
                "recording", "\(LinuxPermissions.Desktop.current().label) didn't allow screen recording. Run `macos-harness permissions grant recording` and allow it."
            )
        }
        let stream = session.stream
        let left = max(0, Int((window.frame.minX - stream.x).rounded()))
        let top = max(0, Int((window.frame.minY - stream.y).rounded()))
        let width = min(Int(window.frame.width.rounded()), Int(stream.width) - left) / 2 * 2
        let height = min(Int(window.frame.height.rounded()), Int(stream.height) - top) / 2 * 2
        guard width >= 2, height >= 2 else {
            await session.close()
            throw RPCError(code: RPCErrorCode.failed, message: "The window is off the recorded monitor, so there's nothing to record.")
        }
        let source = [
            "pipewiresrc fd=3 path=\(stream.node) do-timestamp=true keepalive-time=1000 always-copy=true",
            "videoconvert", "videoscale", "video/x-raw,width=\(Int(stream.width)),height=\(Int(stream.height))",
            "videocrop left=\(left) top=\(top) right=\(Int(stream.width) - left - width) bottom=\(Int(stream.height) - top - height)",
            "videorate", "video/x-raw,framerate=\(Self.framesPerSecond)/1",
        ].joined(separator: " ! ")
        let process: SpawnedProcess
        do {
            process = try Spawn.process(
                encoding.gst, arguments: encoding.arguments(source: source, path: path), descriptors: [3: session.pipewire], log: Self.logPath
            )
        } catch {
            await session.close()
            throw error
        }
        return .portal(session, process)
    }

    /// Where GStreamer's output goes, for when a recording fails.
    static var logPath: String {
        let state = ProcessInfo.processInfo.environment["XDG_STATE_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? "\(HarnessPaths.homeDirectory)/.local/state"
        try? FileManager.default.createDirectory(atPath: "\(state)/macos-harness", withIntermediateDirectories: true)
        return "\(state)/macos-harness/recording.log"
    }

    /// Writes a frame to GStreamer; false once it has stopped reading.
    static func send(_ bytes: [UInt8], to fd: Int32) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBufferPointer { buffer in
                unsafe write(fd, buffer.baseAddress! + offset, bytes.count - offset)
            }
            if written < 0, errno == EINTR { continue }
            guard written > 0 else { return false }
            offset += written
        }
        return true
    }

    func register(path: String, owner: String, capture: Capture, maxSeconds: Double) -> String {
        counter += 1
        let id = "rec-\(counter)"
        active[id] = Active(id: id, path: path, owner: owner, started: Date(), capture: capture)
        let limit = max(1, maxSeconds)
        Task {
            try? await Task.sleep(for: .seconds(limit))
            _ = try? await self.stop(id: id, owner: nil)
        }
        return id
    }

    /// Stops recording `id`, or every recording `owner` started, and waits for the files to finish.
    /// A nil owner (the time limit) may stop any recording.
    public func stop(id: String?, owner: String?) async throws -> [RecordStopMethod.Recording] {
        let chosen = active.values.filter { recording in
            (id == nil || recording.id == id) && (owner == nil || recording.owner == owner)
        }
        if let id, chosen.isEmpty {
            throw RPCError(code: RPCErrorCode.failed, message: "No recording \(id) is running (it may have reached its time limit).")
        }
        var stopped: [RecordStopMethod.Recording] = []
        for recording in chosen.sorted(by: { $0.started < $1.started }) {
            active.removeValue(forKey: recording.id)
            switch recording.capture {
            case .frames(let task, let writeEnd, let process):
                task.cancel()
                _ = await task.value
                UnixPipe.close(writeEnd)
                if await !process.wait(timeout: .seconds(15)) { process.signal(SIGINT) }
                _ = await process.wait(timeout: .seconds(5))
            case .portal(let session, let process):
                process.signal(SIGINT)
                if await !process.wait(timeout: .seconds(15)) { process.signal(SIGKILL) }
                await session.close()
            case .android(let android):
                await android.finish(to: recording.path)
            }
            let bytes = (try? FileManager.default.attributesOfItem(atPath: recording.path)[.size] as? Int) ?? 0
            stopped.append(.init(
                id: recording.id, path: recording.path,
                seconds: (Date().timeIntervalSince(recording.started) * 10).rounded() / 10, bytes: bytes
            ))
        }
        return stopped
    }
}

/// How a recording is encoded, chosen by the file's extension from the GStreamer elements
/// installed: H.264 in QuickTime or MP4, VP8 in WebM, either in Matroska.
struct Encoding: Equatable {
    var gst: String
    var encoder: String
    var muxer: String

    static func choose(
        for path: String, gst: String? = Spawn.which("gst-launch-1.0"), has: (String) async -> Bool = Encoding.installed
    ) async throws -> Encoding {
        guard let gst else {
            throw RPCError(code: RPCErrorCode.failed, message: "Recording needs GStreamer: install gstreamer1.0-tools (gst-launch-1.0) and its good plugins.")
        }
        let suffix = (path as NSString).pathExtension.lowercased()
        let h264: String?
        if await has("x264enc") {
            h264 = "x264enc tune=zerolatency speed-preset=veryfast key-int-max=30"
        } else if await has("openh264enc"), await has("h264parse") {
            h264 = "openh264enc ! h264parse"
        } else {
            h264 = nil
        }
        let vp8 = await has("vp8enc") ? "vp8enc deadline=1 cpu-used=8" : nil
        switch suffix {
        case "mov", "mp4":
            guard let h264 else {
                throw RPCError(
                    code: RPCErrorCode.failed,
                    message: "No H.264 encoder is installed for .\(suffix) (GStreamer's x264enc or openh264enc); record to .webm instead, or install one."
                )
            }
            return Encoding(gst: gst, encoder: h264, muxer: suffix == "mov" ? "qtmux" : "mp4mux")
        case "webm":
            guard let vp8 else { throw RPCError(code: RPCErrorCode.failed, message: "GStreamer's vp8enc isn't installed; install its good plugins.") }
            return Encoding(gst: gst, encoder: vp8, muxer: "webmmux")
        case "mkv":
            guard let codec = h264 ?? vp8 else { throw RPCError(code: RPCErrorCode.failed, message: "No video encoder is installed for GStreamer.") }
            return Encoding(gst: gst, encoder: codec, muxer: "matroskamux")
        default:
            throw RPCError(code: RPCErrorCode.invalidParams, message: "Give an absolute path ending in .mov, .mp4, .webm or .mkv.")
        }
    }

    /// Whether GStreamer has an element.
    static func installed(_ element: String) async -> Bool {
        guard let inspect = Spawn.which("gst-inspect-1.0") else { return false }
        return (try? await ToolRunner.run(inspect, ["--exists", element], timeout: 10))?.status == 0
    }

    /// `gst-launch-1.0`'s arguments for a pipeline from `source` to the file.
    func arguments(source: String, path: String) -> [String] {
        let quoted = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let pipeline = "\(source) ! videoconvert ! video/x-raw,format=I420 ! \(encoder) ! \(muxer) ! filesink location=\"\(quoted)\""
        return ["-e", "-q"] + pipeline.split(separator: " ").map(String.init)
    }
}

/// A ScreenCast portal session streaming a monitor, restored without asking after the first time.
final class ScreenCastSession: Sendable {
    static let screenCast = "org.freedesktop.portal.ScreenCast"

    /// The monitor's stream: its PipeWire node and where it sits in the layout.
    struct Stream: Sendable {
        var node: Int
        var x: Double
        var y: Double
        var width: Double
        var height: Double
    }

    let connection: DBusConnection
    let session: String
    let stream: Stream
    /// The PipeWire remote the stream is read from.
    let pipewire: Int32

    init(connection: DBusConnection, session: String, stream: Stream, pipewire: Int32) {
        self.connection = connection
        self.session = session
        self.stream = stream
        self.pipewire = pipewire
    }

    static var tokenPath: String {
        (PortalInput.tokenPath as NSString).deletingLastPathComponent + "/\(LinuxPermissions.Desktop.current() == .kde ? "kde" : "gnome")-screencast-token"
    }

    /// Starts streaming a monitor, asking the user the first time.
    static func start() async throws -> ScreenCastSession {
        let connection = try await SessionBus.shared.connection()
        let created = try await Portal.request(
            screenCast, "CreateSession", [], options: ["session_handle_token": .string("harness\(UInt32.random(in: 0...UInt32.max))")],
            on: connection
        )
        guard let session = created["session_handle"]?.string else {
            throw RPCError(code: RPCErrorCode.failed, message: "The ScreenCast portal made no session.")
        }
        var sources: [String: DBusValue] = ["types": .uint32(1), "multiple": .boolean(false), "cursor_mode": .uint32(2), "persist_mode": .uint32(2)]
        if let token = try? String(contentsOfFile: tokenPath, encoding: .utf8), !token.isEmpty {
            sources["restore_token"] = .string(token.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        do {
            _ = try await Portal.request(screenCast, "SelectSources", [.objectPath(session)], options: sources, on: connection)
            let started = try await Portal.request(
                screenCast, "Start", [.objectPath(session), .string("")], options: [:], on: connection, timeout: .seconds(120)
            )
            if let token = started["restore_token"]?.string {
                try? FileManager.default.createDirectory(atPath: (tokenPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                _ = FileManager.default.createFile(atPath: tokenPath, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600])
            }
            guard let stream = Self.stream(in: started["streams"]) else {
                throw RPCError(code: RPCErrorCode.failed, message: "The ScreenCast portal started no stream.")
            }
            let reply = try await connection.callForReply(
                Portal.destination, Portal.path, screenCast, "OpenPipeWireRemote", [.objectPath(session), .properties([:])]
            )
            guard let index = reply.body.first?.int, index < reply.fds.count else {
                throw RPCError(code: RPCErrorCode.failed, message: "The ScreenCast portal gave no PipeWire remote.")
            }
            return ScreenCastSession(connection: connection, session: session, stream: stream, pipewire: reply.fds[index])
        } catch {
            _ = try? await connection.call(Portal.destination, session, "org.freedesktop.portal.Session", "Close")
            throw error
        }
    }

    /// The first stream in a ScreenCast `Start` reply.
    static func stream(in streams: DBusValue?) -> Stream? {
        guard let first = streams?.elements?.first?.fields, first.count == 2, let node = first[0].int else { return nil }
        let properties = first[1].dictionary ?? [:]
        let position = properties["position"]?.fields?.compactMap(\.int) ?? []
        let size = properties["size"]?.fields?.compactMap(\.int) ?? []
        return Stream(
            node: node, x: Double(position.first ?? 0), y: Double(position.dropFirst().first ?? 0),
            width: Double(size.first ?? 0), height: Double(size.dropFirst().first ?? 0)
        )
    }

    func close() async {
        UnixPipe.close(pipewire)
        _ = try? await connection.call(Portal.destination, session, "org.freedesktop.portal.Session", "Close")
    }
}
