import AppKit
import CoreMedia
import Foundation
import HarnessProtocol
@preconcurrency import ScreenCaptureKit

/// Records an app's windows to movie files, one recording per request, each stopping on its own
/// after its maximum length.
public actor RecordingService {
    public static let shared = RecordingService()

    struct Active {
        var id: String
        var path: String
        var owner: String
        var started: Date
        var stream: SCStream
        var finisher: Finisher
    }

    private var active: [String: Active] = [:]
    private var counter = 0

    /// Starts recording the target app's windows on the display its window is on.
    public func start(_ params: RecordStartMethod.Params, owner: String) async throws -> RecordStartMethod.Result {
        guard CGPreflightScreenCaptureAccess() else {
            throw RPCError(code: RPCErrorCode.permissionMissing, message: "macOS Harness doesn't have Screen Recording permission. Run `macos-harness doctor`.")
        }
        guard (params.path as NSString).isAbsolutePath, params.path.hasSuffix(".mov") else {
            throw RPCError(code: RPCErrorCode.invalidParams, message: "Give an absolute path ending in .mov.")
        }
        let app = try await MainActor.run { try AppResolver.resolve(params.target.app) }
        let window = try WindowService.resolve(params.target, app: app)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let scApp = content.applications.first(where: { $0.processID == app.pid }) else {
            throw RPCError(code: RPCErrorCode.failed, message: "\(app.name) has nothing on screen to record.")
        }
        let frame = window.info.frame.cgRect
        guard let display = content.displays.max(by: { $0.frame.intersection(frame).area < $1.frame.intersection(frame).area }) else {
            throw RPCError(code: RPCErrorCode.failed, message: "No display to record.")
        }
        let filter = SCContentFilter(display: display, including: [scApp], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        let scale = min(1, 1440 / max(CGFloat(display.width), 1))
        configuration.width = max(2, Int(CGFloat(display.width) * scale) / 2 * 2)
        configuration.height = max(2, Int(CGFloat(display.height) * scale) / 2 * 2)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        configuration.showsCursor = true

        let url = URL(fileURLWithPath: params.path)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let output = SCRecordingOutputConfiguration()
        output.outputURL = url
        output.outputFileType = .mov
        output.videoCodecType = .h264
        let finisher = Finisher()
        let recording = SCRecordingOutput(configuration: output, delegate: finisher)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addRecordingOutput(recording)
        try await stream.startCapture()

        counter += 1
        let id = "rec-\(counter)"
        active[id] = Active(id: id, path: params.path, owner: owner, started: Date(), stream: stream, finisher: finisher)
        let limit = max(1, params.maxSeconds)
        Task {
            try? await Task.sleep(for: .seconds(limit))
            _ = try? await self.stop(id: id, owner: nil)
        }
        return RecordStartMethod.Result(id: id, path: params.path, app: app)
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
            try? await recording.stream.stopCapture()
            await recording.finisher.waitUntilFinished(timeout: 10)
            let bytes = (try? FileManager.default.attributesOfItem(atPath: recording.path)[.size] as? Int) ?? 0
            stopped.append(.init(
                id: recording.id, path: recording.path,
                seconds: (Date().timeIntervalSince(recording.started) * 10).rounded() / 10, bytes: bytes
            ))
        }
        return stopped
    }
}

/// Learns when a recording's file is complete.
final class Finisher: NSObject, SCRecordingOutputDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        lock.withLock { finished = true }
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        lock.withLock { finished = true }
    }

    func waitUntilFinished(timeout: Double) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !lock.withLock({ finished }), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
