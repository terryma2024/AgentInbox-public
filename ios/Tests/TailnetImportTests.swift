import XCTest
@testable import AgentInbox

final class TailnetImportTests: XCTestCase {
    func payload(account: String = "fixture@example.com", id: String = "node-1", name: String = "before", address: String = "100.100.1.2") -> Data {
        Data("{\"schemaVersion\":1,\"account\":\"\(account)\",\"connected\":true,\"devices\":[{\"id\":\"\(id)\",\"name\":\"\(name)\",\"ipv4Address\":\"\(address)\",\"isOnline\":true}]}".utf8)
    }
    func testShortcutFieldsDecodeAndUnknownFieldsAreNotPersisted() throws {
        let raw = Data(#"{"schemaVersion":1,"account":"fixture@example.com","connected":true,"secret":"discard-me","devices":[{"id":"node-1","name":"host","ipv4Address":"100.100.1.2","ipv6Address":"fd7a:115c:a1e0::1","magicDNSAddress":"host.fixture.ts.net","isOnline":false}]}"#.utf8)
        let value = try TailnetImportSnapshot.decode(raw)
        XCTAssertEqual(value.devices.first?.id, "node-1")
        XCTAssertEqual(value.devices.first?.addresses, ["100.100.1.2", "fd7a:115c:a1e0::1"])
        XCTAssertEqual(value.devices[0].isOnline, false)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(value), as: UTF8.self).contains("discard-me"))
    }
    func testMissingOnlineStatusRemainsUnknown() throws {
        let raw = Data(#"{"schemaVersion":1,"account":"a","connected":true,"devices":[{"id":"node","name":"host","ipv4Address":"100.100.1.2"}]}"#.utf8)
        let snapshot = try TailnetImportSnapshot.decode(raw)
        XCTAssertNil(snapshot.devices.first?.isOnline)
        var catalog = TailnetCatalog(); catalog.replace(with: snapshot)
        XCTAssertNil(catalog.machines.first?.online)
        XCTAssertEqual(catalog.machines.first?.state, .checking)
    }
    func testRejectsInvalidOrMissingIdentityAndWrongTypes() {
        for text in [
            #"{"schemaVersion":2,"account":"a","connected":true,"devices":[]}"#,
            #"{"schemaVersion":1,"account":"","connected":true,"devices":[]}"#,
            #"{"schemaVersion":1,"account":"a","connected":"true","devices":[]}"#,
            #"{"schemaVersion":1,"account":"a","connected":true,"devices":[{"id":"","name":"x","isOnline":true}]}"#
        ] { XCTAssertThrowsError(try TailnetImportSnapshot.decode(Data(text.utf8))) }
        XCTAssertThrowsError(try TailnetImportSnapshot.decode(payload(address: "127.0.0.1")))
        XCTAssertThrowsError(try TailnetImportSnapshot.decode(payload(address: "100.100.1.2@evil.com")))
        XCTAssertThrowsError(try TailnetImportSnapshot.decode(Data(repeating: 32, count: 262145)))
    }
    func testRejectsOversizedDeviceListAndInvalidDNS() throws {
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: payload()) as? [String: Any])
        let device = try XCTUnwrap((value["devices"] as? [[String: Any]])?.first)
        value["devices"] = Array(repeating: device, count: 513)
        XCTAssertThrowsError(try TailnetImportSnapshot.decode(JSONSerialization.data(withJSONObject: value)))
        var bad = device; bad["magicDNSAddress"] = "relay.ts.net@evil.example"
        value["devices"] = [bad]
        XCTAssertThrowsError(try TailnetImportSnapshot.decode(JSONSerialization.data(withJSONObject: value)))
    }
    func testConflictingDuplicateIDsAreRejected() throws {
        let text = #"{"schemaVersion":1,"account":"a","connected":true,"devices":[{"id":"same","name":"one","isOnline":true},{"id":"same","name":"two","isOnline":true}]}"#
        XCTAssertThrowsError(try TailnetImportSnapshot.decode(Data(text.utf8)))
    }
    func testSnapshotReplacementUpdatesStableIDAndSeparatesSameNames() throws {
        var catalog = TailnetCatalog()
        catalog.replace(with: try TailnetImportSnapshot.decode(payload()))
        catalog.replace(with: try TailnetImportSnapshot.decode(payload(name: "after", address: "100.100.1.3")))
        XCTAssertEqual(catalog.machines.count, 1)
        XCTAssertEqual(catalog.machines.first?.name, "after")
        XCTAssertEqual(catalog.machines.first?.addresses, ["100.100.1.3"])
        let id = catalog.machines[0].id
        catalog.replace(with: try TailnetImportSnapshot.decode(payload(account: "other@example.com")))
        XCTAssertNotEqual(catalog.machines[0].id, id)
        catalog.replace(with: try TailnetImportSnapshot.decode(Data(#"{"schemaVersion":1,"account":"a","connected":true,"devices":[{"id":"1","name":"same","isOnline":false},{"id":"2","name":"same","isOnline":false}]}"#.utf8)))
        XCTAssertEqual(catalog.machines.count, 2)
    }
    func testEmptySnapshotClearsOnlyDeviceCatalog() throws {
        var catalog = TailnetCatalog()
        catalog.replace(with: try TailnetImportSnapshot.decode(payload()))
        catalog.replace(with: try TailnetImportSnapshot.decode(Data(#"{"schemaVersion":1,"account":"a","connected":false,"devices":[]}"#.utf8)))
        XCTAssertTrue(catalog.machines.isEmpty)
    }
    func testStorageRoundTripAndInvalidInputDoesNotReplacePreviousSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = TailnetImportStorage(directory: directory)
        let snapshot = try TailnetImportSnapshot.decode(payload())
        let importedAt = Date(timeIntervalSince1970: 100)
        try storage.save(.init(snapshot: snapshot, importedAt: importedAt))
        XCTAssertEqual(try storage.load()?.snapshot.account, "fixture@example.com")
        XCTAssertEqual(try storage.load()?.importedAt, importedAt)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("devices.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["devices.json"])
        XCTAssertThrowsError(try TailnetImportSnapshot.decode(payload(address: "192.168.1.1")))
        XCTAssertEqual(try storage.load()?.snapshot.devices.first?.name, "before")
        try storage.clear()
        XCTAssertNil(try storage.load())
    }
}
