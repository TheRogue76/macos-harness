import ArgumentParser
#if canImport(AVFoundation)
@preconcurrency @unsafe import AVFoundation
import UniformTypeIdentifiers
#endif
import Foundation
import HarnessClient
import HarnessProtocol

struct RecordCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record",
        abstract: "Record an app's windows to a movie, and pull stills out of it.",
        subcommands: [RecordStart.self, RecordStop.self, RecordFrames.self]
    )
}

struct RecordStart: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Start recording an app's windows (only that app's) until `record stop` or the time limit."
    )

    @OptionGroup var target: TargetOptions

    @Option(help: "Where to write the movie: .mov, or on Linux also .mp4, .webm or .mkv (default: recording-<app>-<time>.mov here).")
    var out: String?

    @Option(help: "Stop on its own after this many seconds.")
    var maxSeconds: Double = 600

    @Option(name: .customLong("max"), help: .hidden)
    var deprecatedMax: Double?

    @OptionGroup var output: OutputOptions

    func run() throws {
        let path = URL(fileURLWithPath: out ?? Self.defaultName(target.app)).standardizedFileURL.path
        if deprecatedMax != nil { Output.note("--max is now --max-seconds; the old name goes away in 2.0.") }
        try reportingErrors(json: output.json) {
            let result = try HarnessConnection.openAnnouncingPairing().call(
                RecordStartMethod.self, .init(target: target.target, path: path, maxSeconds: deprecatedMax ?? maxSeconds)
            )
            output.json ? try Output.json(result) : print("Recording \(result.app.name) as \(result.id) to \(result.path); stop with `record stop \(result.id)`.")
        }
    }

    static func defaultName(_ app: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let slug = app.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: "-")
        return "recording-\(slug)-\(formatter.string(from: Date())).mov"
    }
}

struct RecordStop: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop a recording (or all of yours) and finish the file."
    )

    @Argument(help: "Recording ID from `record start`; omit to stop all of yours.")
    var id: String?

    @OptionGroup var output: OutputOptions

    func run() throws {
        try reportingErrors(json: output.json) {
            let result = try HarnessConnection.openAnnouncingPairing().call(RecordStopMethod.self, .init(id: id), timeout: 30)
            if output.json { return try Output.json(result) }
            guard !result.recordings.isEmpty else { return print("No recordings were running.") }
            for recording in result.recordings {
                print("\(recording.id): \(recording.path) (\(recording.seconds) s, \(ByteCountFormatter.string(fromByteCount: Int64(recording.bytes), countStyle: .file)))")
            }
        }
    }
}

struct RecordFrames: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "frames",
        abstract: "Save stills from a movie as PNGs, one every --every seconds."
    )

    @Argument(help: "The movie file.")
    var movie: String

    @Option(help: "Seconds between stills.")
    var every: Double = 1

    @Option(help: "Folder for the PNGs (default: next to the movie).")
    var out: String?

    func run() throws {
        let url = URL(fileURLWithPath: movie).standardizedFileURL
        let folder = out ?? url.deletingPathExtension().path + "-frames"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let written = try FrameExtractor.extract(from: url, every: Swift.max(every, 0.1), into: folder)
        print("Saved \(written) still\(written == 1 ? "" : "s") to \(folder)")
    }
}

#if canImport(AVFoundation)
/// Pulls stills out of a movie with AVFoundation.
enum FrameExtractor {
    /// Writes a PNG every `every` seconds into `folder` and returns how many it wrote.
    static func extract(from url: URL, every: Double, into folder: String) throws -> Int {
        let outcome = OutcomeBox()
        let done = DispatchSemaphore(value: 0)
        Task {
            do {
                outcome.value = .success(try await extractFrames(from: url, every: every, into: folder))
            } catch {
                outcome.value = .failure(error)
            }
            done.signal()
        }
        done.wait()
        return try outcome.value!.get()
    }

    static func extractFrames(from url: URL, every: Double, into folder: String) async throws -> Int {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        var written = 0
        var time = 0.0
        while time < duration {
            let (image, _) = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
            let stamp = time.fixed(2)
            let path = (folder as NSString).appendingPathComponent("frame-\(String(repeating: "0", count: Swift.max(0, 6 - stamp.count)))\(stamp).png")
            guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw ValidationError("Can't write \(path)")
            }
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
            written += 1
            time += every
        }
        return written
    }
}

private final class OutcomeBox: @unchecked Sendable {
    var value: Result<Int, Error>?
}
#else
/// Pulls stills out of a movie with GStreamer, where AVFoundation doesn't exist.
enum FrameExtractor {
    /// Writes a PNG every `every` seconds into `folder` and returns how many it wrote.
    static func extract(from url: URL, every: Double, into folder: String) throws -> Int {
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":")
            .map { "\($0)/gst-launch-1.0" }.first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let gst = path else {
            throw ValidationError("`record frames` needs GStreamer: install gstreamer1.0-tools (gst-launch-1.0) and its good plugins.")
        }
        let rate = Swift.max(1, Int((1000 / every).rounded()))
        let quote = { (text: String) in "\"" + text.replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let pipeline = "filesrc location=\(quote(url.path)) ! decodebin ! videoconvert ! videorate ! video/x-raw,framerate=\(rate)/1000 ! pngenc ! multifilesink location=\(quote(folder + "/frame-%04d.png"))"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gst)
        process.arguments = ["-q"] + pipeline.split(separator: " ").map(String.init)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ValidationError("GStreamer couldn't read \(url.lastPathComponent).") }
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.hasPrefix("frame-") && $0.hasSuffix(".png") }.count
    }
}
#endif
