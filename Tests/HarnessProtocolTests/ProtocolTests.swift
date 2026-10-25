import Foundation
import HarnessProtocol
import Testing

struct JSONValueTests {
    @Test func roundTripsEveryKind() throws {
        let value: JSONValue = .object([
            "null": .null, "bool": .bool(true), "number": .number(1.5),
            "string": .string("a\nb"), "array": .array([.number(1), .string("x")]),
        ])
        let data = try HarnessJSON.encoder.encode(value)
        #expect(try HarnessJSON.decoder.decode(JSONValue.self, from: data) == value)
    }

    @Test func boolsStayBools() throws {
        let decoded = try HarnessJSON.decoder.decode(JSONValue.self, from: Data("[true, 1]".utf8))
        #expect(decoded == .array([.bool(true), .number(1)]))
    }

    @Test func convertsTypedValues() throws {
        let params = AppsMethod.Params(includeBackground: true)
        let json = try JSONValue(encoding: params)
        #expect(json == .object(["includeBackground": .bool(true)]))
        #expect(try json.decode(as: AppsMethod.Params.self).includeBackground)
    }
}

struct RPCTests {
    @Test func encodedRequestIsOneLine() throws {
        let request = RPCRequest(id: 7, method: "apps", params: .object(["text": .string("line1\nline2")]))
        let data = try HarnessJSON.encoder.encode(request)
        #expect(!data.contains(0x0A))
        #expect(try HarnessJSON.decoder.decode(RPCRequest.self, from: data) == request)
    }

    @Test func responseCarriesResultOrError() throws {
        let ok = try HarnessJSON.encoder.encode(RPCResponse(id: 1, result: .bool(true)))
        let failed = try HarnessJSON.encoder.encode(RPCResponse(id: 2, error: RPCError(code: 1001, message: "no")))
        #expect(String(decoding: ok, as: UTF8.self) == #"{"id":1,"jsonrpc":"2.0","result":true}"#)
        #expect(String(decoding: failed, as: UTF8.self) == #"{"error":{"code":1001,"message":"no"},"id":2,"jsonrpc":"2.0"}"#)
    }
}

struct PathTests {
    #if os(macOS)
    @Test func socketLivesInApplicationSupport() {
        let path = HarnessPaths.socketPath(for: .dev, home: "/Users/someone")
        #expect(path == "/Users/someone/Library/Application Support/macos-harness/dev.sock")
    }

    @Test func longHomesFallBackToTmp() {
        let home = "/Users/" + String(repeating: "x", count: 80)
        let path = HarnessPaths.socketPath(for: .release, home: home)
        #expect(path.hasPrefix("/tmp/macos-harness-"))
        #expect(path.hasSuffix("/release.sock"))
        #expect(path.utf8.count < 104)
    }

    @Test func logsLiveInTheLibrary() {
        #expect(HarnessPaths.journalDirectory(for: .dev, home: "/Users/someone") == "/Users/someone/Library/Logs/macos-harness/journal-dev")
        #expect(HarnessPaths.policyFile(home: "/Users/someone") == "/Users/someone/.config/macos-harness/policy.yaml")
    }
    #else
    @Test func socketLivesInTheRuntimeDirectory() {
        let path = HarnessPaths.socketPath(for: .dev, home: "/home/someone", environment: ["XDG_RUNTIME_DIR": "/run/user/1000"])
        #expect(path == "/run/user/1000/macos-harness/dev.sock")
    }

    @Test func socketFallsBackToTmpWithoutARuntimeDirectory() {
        for environment in [[:], ["XDG_RUNTIME_DIR": "relative"], ["XDG_RUNTIME_DIR": "/" + String(repeating: "x", count: 90)]] {
            let path = HarnessPaths.socketPath(for: .release, home: "/home/someone", environment: environment)
            #expect(path.hasPrefix("/tmp/macos-harness-"))
            #expect(path.hasSuffix("/release.sock"))
        }
    }

    @Test func stateAndConfigFollowTheXDGDirectories() {
        let home = "/home/someone"
        #expect(HarnessPaths.journalDirectory(for: .dev, home: home, environment: [:]) == "/home/someone/.local/state/macos-harness/journal-dev")
        #expect(HarnessPaths.journalDirectory(for: .release, home: home, environment: ["XDG_STATE_HOME": "/state"]) == "/state/macos-harness/journal")
        #expect(HarnessPaths.policyFile(home: home, environment: [:]) == "/home/someone/.config/macos-harness/policy.yaml")
        #expect(HarnessPaths.policyFile(home: home, environment: ["XDG_CONFIG_HOME": "/config"]) == "/config/macos-harness/policy.yaml")
        #expect(HarnessPaths.policyFile(home: home, environment: ["XDG_CONFIG_HOME": "relative"]) == "/home/someone/.config/macos-harness/policy.yaml")
    }
    #endif

    @Test func variantsRoundTripBundleIdentifiers() {
        for variant in HarnessVariant.allCases {
            #expect(HarnessVariant(bundleIdentifier: variant.bundleIdentifier) == variant)
        }
        #expect(HarnessVariant(bundleIdentifier: "com.example.other") == nil)
    }
}

struct DragDestinationTests {
    private let finder = AppRef(name: "Finder", bundleIdentifier: "com.apple.finder", pid: 10)

    @Test func olderClientsWithoutADestinationTargetStillDecode() throws {
        let json = #"{"target":{"app":"Finder"},"action":"drag","point":{"x":1,"y":2},"toPoint":{"x":3,"y":4},"modifiers":[],"dx":0,"dy":0,"hold":0.3,"duration":0.6,"diff":true}"#
        let params = try HarnessJSON.decoder.decode(PointerMethod.Params.self, from: Data(json.utf8))
        #expect(params.toTarget == nil)
        #expect(params.toPoint == Point(x: 3, y: 4))
    }

    @Test func destinationTargetRoundTrips() throws {
        let params = PointerMethod.Params(
            target: Target(app: "Finder"), action: .drag, element: ElementSelector(text: "a.txt"),
            to: ElementSelector(ref: "t4"), toTarget: Target(app: "TextEdit", window: 455)
        )
        let decoded = try HarnessJSON.decoder.decode(PointerMethod.Params.self, from: try HarnessJSON.encoder.encode(params))
        #expect(decoded.toTarget == Target(app: "TextEdit", window: 455))
        #expect(decoded.to == ElementSelector(ref: "t4"))
    }

    @Test func resultsWithoutADestinationStillDecode() throws {
        let json = #"{"app":{"name":"Finder","pid":10},"performed":"dragged","via":"real input","changes":[],"moreChanges":0,"settledMilliseconds":0,"notices":[]}"#
        let result = try HarnessJSON.decoder.decode(ActionResult.self, from: Data(json.utf8))
        #expect(result.destination?.window == nil)
    }

    @Test func aWindowAloneKeepsTheApp() {
        let source = Target(app: "Finder", window: 3)
        #expect(source.drop(app: nil, window: nil) == nil)
        #expect(source.drop(app: nil, window: 7) == Target(app: "Finder", window: 7))
        #expect(source.drop(app: "TextEdit", window: nil) == Target(app: "TextEdit"))
    }

    @Test func windowsAreNamedWithTheirAppWhenItDiffers() {
        let textEdit = AppRef(name: "TextEdit", bundleIdentifier: "com.apple.TextEdit", pid: 20)
        var window = WindowInfo(
            id: 455, app: textEdit, title: "Untitled", frame: Rect(x: 0, y: 0, width: 400, height: 300), onScreen: true,
            minimized: false, focused: true, main: true, subrole: nil, hasSheet: false
        )
        #expect(window.name(besides: finder) == "TextEdit window 455 “Untitled”")
        #expect(window.name(besides: textEdit) == "window 455 “Untitled”")
        window.title = ""
        #expect(window.name(besides: finder) == "TextEdit window 455")
    }
}

struct LineSocketTests {
    @Test func linesTravelBothWaysOverAUnixSocket() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("ls-\(UUID().uuidString.prefix(8)).sock").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let listener = try Self.listener(at: path)
        defer { close(listener) }
        let client = try LineSocket.connect(path: path)
        let server = LineSocket(fd: accept(listener, nil, nil))
        try client.writeLine(Data("hello".utf8))
        #expect(try server.readLine() == Data("hello".utf8))
        try server.writeLine(Data("{\"ok\":true}".utf8))
        #expect(try client.readLine() == Data("{\"ok\":true}".utf8))
    }

    @Test func connectingToAMissingSocketSaysSo() {
        #expect(throws: SocketError.self) { try LineSocket.connect(path: "/nonexistent-\(UUID().uuidString)/x.sock") }
        do {
            _ = try LineSocket.connect(path: "/nonexistent-\(UUID().uuidString)/x.sock")
        } catch let error as SocketError {
            #expect(error.errnoCode == ENOENT)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func pathsTooLongForASocketAreRefused() {
        #expect(throws: SocketError.self) { try LineSocket.makeAddress("/" + String(repeating: "x", count: 200)) }
    }

    static func listener(at path: String) throws -> Int32 {
        #if canImport(Glibc)
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        let pointer = UnsafeMutablePointer<sockaddr_un>.allocate(capacity: 1)
        defer { unsafe pointer.deallocate() }
        unsafe pointer.initialize(to: try LineSocket.makeAddress(path))
        let bound = unsafe pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            unsafe bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
        guard fd >= 0, bound == 0, listen(fd, 1) == 0 else { throw SocketError.system("listen", errno) }
        return fd
    }
}
