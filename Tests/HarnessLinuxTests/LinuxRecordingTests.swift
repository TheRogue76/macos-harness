import Foundation
import HarnessDBus
@testable import HarnessLinux
import HarnessProtocol
import Testing

struct LinuxRecordingTests {
    @Test func picksTheEncoderByExtensionFromWhatsInstalled() async throws {
        let everything: (String) async -> Bool = { _ in true }
        let mov = try await Encoding.choose(for: "/tmp/a.mov", gst: "/usr/bin/gst-launch-1.0", has: everything)
        #expect(mov.encoder.hasPrefix("x264enc"))
        #expect(mov.muxer == "qtmux")
        #expect(try await Encoding.choose(for: "/tmp/a.mp4", gst: "/g", has: everything).muxer == "mp4mux")
        #expect(try await Encoding.choose(for: "/tmp/a.webm", gst: "/g", has: everything).encoder.hasPrefix("vp8enc"))

        let openH264: (String) async -> Bool = { ["openh264enc", "h264parse", "vp8enc"].contains($0) }
        #expect(try await Encoding.choose(for: "/tmp/a.mov", gst: "/g", has: openH264).encoder == "openh264enc ! h264parse")

        let vp8Only: (String) async -> Bool = { $0 == "vp8enc" }
        await #expect(throws: RPCError.self) { try await Encoding.choose(for: "/tmp/a.mov", gst: "/g", has: vp8Only) }
        #expect(try await Encoding.choose(for: "/tmp/a.mkv", gst: "/g", has: vp8Only).muxer == "matroskamux")
        await #expect(throws: RPCError.self) { try await Encoding.choose(for: "/tmp/a.gif", gst: "/g", has: everything) }
        await #expect(throws: RPCError.self) { try await Encoding.choose(for: "/tmp/a.mov", gst: nil, has: everything) }
    }

    @Test func quotesThePathInThePipeline() {
        let encoding = Encoding(gst: "/g", encoder: "vp8enc", muxer: "webmmux")
        let arguments = encoding.arguments(source: "fdsrc fd=0", path: "/tmp/my \"clip\".webm")
        #expect(arguments.prefix(2) == ["-e", "-q"])
        #expect(arguments.joined(separator: " ").hasSuffix("filesink location=\"/tmp/my \\\"clip\\\".webm\""))
    }

    @Test func readsTheStreamFromAScreenCastReply() {
        let streams = DBusValue.array(element: "(ua{sv})", [
            .structure([.uint32(47), .properties([
                "position": .variant(.structure([.int32(1280), .int32(0)])), "size": .variant(.structure([.int32(1920), .int32(1080)])),
            ])]),
        ])
        let stream = ScreenCastSession.stream(in: streams)
        #expect(stream?.node == 47)
        #expect(stream?.x == 1280)
        #expect(stream?.width == 1920)
        #expect(stream?.height == 1080)
        #expect(ScreenCastSession.stream(in: .array(element: "(ua{sv})", [])) == nil)
    }
}
