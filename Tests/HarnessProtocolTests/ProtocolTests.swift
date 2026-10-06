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

    @Test func variantsRoundTripBundleIdentifiers() {
        for variant in HarnessVariant.allCases {
            #expect(HarnessVariant(bundleIdentifier: variant.bundleIdentifier) == variant)
        }
        #expect(HarnessVariant(bundleIdentifier: "com.example.other") == nil)
    }
}
