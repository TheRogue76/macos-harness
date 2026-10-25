import Foundation
import Testing
@testable import HarnessDBus

/// Whether this machine has a session bus to test against; CI's containers don't.
let hasSessionBus: Bool = {
    guard let address = DBusConnection.sessionBusAddress(),
          let path = DBusConnection.socketPaths(in: address).first else { return false }
    return FileManager.default.fileExists(atPath: path)
}()

@Suite(.enabled(if: hasSessionBus, "needs a D-Bus session bus"))
struct DBusConnectionTests {
    @Test func getsANameFromTheBus() async throws {
        let bus = try await DBusConnection.session()
        defer { bus.close() }
        #expect(bus.uniqueName?.hasPrefix(":") == true)
        let id = try await bus.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetId")
        #expect(id.first?.string?.count == 32)
    }

    @Test func pipelinesManyCalls() async throws {
        let bus = try await DBusConnection.session()
        defer { bus.close() }
        let names = try await withThrowingTaskGroup(of: String?.self) { group in
            for _ in 0..<500 {
                group.addTask {
                    try await bus.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetNameOwner", [
                        .string("org.freedesktop.DBus"),
                    ]).first?.string
                }
            }
            return try await group.reduce(into: [String?]()) { $0.append($1) }
        }
        #expect(names.count == 500)
        #expect(Set(names) == ["org.freedesktop.DBus"])
    }

    @Test func reportsThePeersError() async throws {
        let bus = try await DBusConnection.session()
        defer { bus.close() }
        await #expect(throws: DBusError.self) {
            _ = try await bus.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NoSuchMethod")
        }
        do {
            _ = try await bus.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NoSuchMethod")
        } catch DBusError.failed(let name, _) {
            #expect(name == "org.freedesktop.DBus.Error.UnknownMethod")
        }
    }

    @Test func readsProperties() async throws {
        let bus = try await DBusConnection.session()
        defer { bus.close() }
        let features = try await bus.property("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "Features")
        #expect(features.elements != nil)
    }

    @Test func failsPendingCallsWhenClosed() async throws {
        let bus = try await DBusConnection.session()
        bus.close()
        await #expect(throws: DBusError.self) {
            _ = try await bus.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetId")
        }
    }
}
