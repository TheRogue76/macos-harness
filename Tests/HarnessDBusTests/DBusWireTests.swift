import Testing
@testable import HarnessDBus

struct DBusWireTests {
    private func bytes(_ values: DBusValue...) throws -> [UInt8] {
        var writer = DBusWriter()
        for value in values { try writer.write(value) }
        return writer.bytes
    }

    @Test func writesIntegersLittleEndianAndAligned() throws {
        #expect(try bytes(.byte(1), .int32(-2)) == [1, 0, 0, 0, 0xFE, 0xFF, 0xFF, 0xFF])
        #expect(try bytes(.byte(1), .uint16(0x0203)) == [1, 0, 3, 2])
        #expect(try bytes(.boolean(true)) == [1, 0, 0, 0])
        #expect(try bytes(.byte(9), .uint64(1)) == [9, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0])
    }

    @Test func writesStringsAndSignaturesWithTheirTerminators() throws {
        #expect(try bytes(.string("ab")) == [2, 0, 0, 0, 97, 98, 0])
        #expect(try bytes(.signature("ai")) == [2, 97, 105, 0])
    }

    @Test func leavesThePaddingAfterAnArrayLengthOutOfTheLength() throws {
        #expect(try bytes(.array(element: "i", [.int32(1), .int32(2)])) == [8, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0])
        #expect(try bytes(.array(element: "x", [.int64(3)])) == [8, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0])
        #expect(try bytes(.array(element: "x", [])) == [0, 0, 0, 0, 0, 0, 0, 0])
    }

    @Test func writesVariantsAsASignatureThenTheValue() throws {
        #expect(try bytes(.variant(.int32(7))) == [1, 105, 0, 0, 7, 0, 0, 0])
    }

    @Test func refusesAnArrayOfMixedTypes() {
        #expect(throws: DBusError.self) { try bytes(.array(element: "i", [.string("no")])) }
    }

    @Test func readsBackWhatItWrites() throws {
        let values: [DBusValue] = [
            .byte(200), .boolean(false), .int16(-3), .uint16(4), .int32(-5), .uint32(6), .int64(-7), .uint64(8),
            .double(2.5), .string("héllo"), .objectPath("/org/a11y/atspi/accessible/root"), .signature("a{sv}"),
            .array(element: "(so)", [.structure([.string(":1.5"), .objectPath("/a")])]),
            .properties(["x": .int32(1), "name": .string("Files")]),
            .variant(.variant(.array(element: "u", [.uint32(1), .uint32(2)]))),
        ]
        var writer = DBusWriter()
        for value in values { try writer.write(value) }
        var reader = DBusReader(writer.bytes)
        for value in values {
            #expect(try reader.read(value.signature) == value)
        }
        #expect(reader.offset == writer.bytes.count)
    }

    @Test func readsBigEndianIntegers() throws {
        var reader = DBusReader([0, 0, 1, 2], bigEndian: true)
        #expect(try reader.read("u") == .uint32(0x0102))
    }

    @Test func refusesValuesThatRunPastTheEnd() {
        var shortString = DBusReader([9, 0, 0, 0, 97])
        #expect(throws: DBusError.self) { try shortString.read("s") }
        var longArray = DBusReader([64, 0, 0, 0, 1, 0, 0, 0])
        #expect(throws: DBusError.self) { try longArray.read("ai") }
    }

    @Test func splitsSignaturesIntoCompleteTypes() throws {
        #expect(try DBusSignature.split("") == [])
        #expect(try DBusSignature.split("sa{sv}(iu)av") == ["s", "a{sv}", "(iu)", "av"])
        #expect(try DBusSignature.split("a((so)(so)ao)") == ["a((so)(so)ao)"])
        for bad in ["a", "(", "()", "{s}", "a{sv", "z"] {
            #expect(throws: DBusError.self) { try DBusSignature.split(bad) }
        }
    }

    @Test func roundTripsAMethodCall() throws {
        var message = DBusMessage(
            kind: .methodCall, path: "/org/a11y/atspi/cache", interface: "org.a11y.atspi.Cache", member: "GetItems",
            destination: ":1.259", body: [.string("x"), .uint32(1)]
        )
        message.serial = 42
        let encoded = try message.encoded()
        #expect(encoded.prefix(4) == [UInt8(ascii: "l"), 1, 0, 1])
        #expect(try DBusMessage.length(of: encoded[...]) == encoded.count)
        #expect(try DBusMessage.length(of: encoded.prefix(15)) == nil)
        #expect(try DBusMessage.decode(encoded) == message)
    }

    @Test func saysHowManyDescriptorsAMessageCarries() throws {
        var message = DBusMessage(
            kind: .methodReturn, destination: ":1.7", body: [.unixFD(0)]
        )
        message.replySerial = 3
        message.serial = 9
        message.fds = [21]
        let decoded = try DBusMessage.decode(try message.encoded())
        #expect(decoded.unixFDCount == 1)
        #expect(decoded.body == [.unixFD(0)])
        #expect(decoded.fds.isEmpty)
    }

    @Test func roundTripsAnErrorReply() throws {
        var message = DBusMessage(kind: .error, destination: ":1.1", body: [.string("nope")])
        message.errorName = "org.freedesktop.DBus.Error.UnknownMethod"
        message.replySerial = 7
        message.serial = 8
        #expect(try DBusMessage.decode(try message.encoded()) == message)
    }

    @Test func readsTheValuesAPIsReturn() throws {
        let properties = DBusValue.properties(["count": .uint32(3), "label": .string("OK")])
        #expect(properties.dictionary?["count"]?.int == 3)
        #expect(properties.dictionary?["label"]?.string == "OK")
        #expect(DBusValue.variant(.int32(4)).double == 4)
        #expect(DBusValue.structure([.boolean(true)]).fields?.first?.bool == true)
    }

    @Test func findsTheSocketPathsInAnAddress() {
        #expect(DBusConnection.socketPaths(in: "unix:path=/run/user/1000/bus") == ["/run/user/1000/bus"])
        #expect(
            DBusConnection.socketPaths(in: "unix:abstract=/tmp/x,guid=1;unix:path=/run/a%20b/bus,guid=2")
                == ["/run/a b/bus"]
        )
        #expect(DBusConnection.socketPaths(in: "tcp:host=localhost,port=1") == [])
    }

    @Test func findsTheSessionBus() {
        #expect(DBusConnection.sessionBusAddress(environment: ["DBUS_SESSION_BUS_ADDRESS": "unix:path=/x"]) == "unix:path=/x")
        #expect(DBusConnection.sessionBusAddress(environment: ["XDG_RUNTIME_DIR": "/run/user/5"]) == "unix:path=/run/user/5/bus")
        #expect(DBusConnection.sessionBusAddress(environment: [:]) == nil)
    }
}
