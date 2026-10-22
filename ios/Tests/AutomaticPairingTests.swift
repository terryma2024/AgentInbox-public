import XCTest
import Darwin
@testable import AgentInbox

@MainActor
final class AutomaticPairingTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    let code = String(repeating: "a", count: 32) // Public, non-authorizing test fixture.
    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func fixture(_ directory: URL, server: String = "https://relay.example.ts.net:8443", expires: Double? = nil, mode: Int = 0o600) throws -> URL {
        let file = directory.appendingPathComponent(PairingFileImport.inputFilename)
        let body: [String: Any] = ["serverURL": server, "code": code, "expiresAt": expires ?? now.timeIntervalSince1970 + 300]
        try JSONSerialization.data(withJSONObject: body).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
        return file
    }
    func testConsumeDeletesBeforeRequestAndCannotReplay() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = try fixture(dir)
        let value = try PairingFileImport.consume(from: dir, now: now)
        XCTAssertEqual(value.serverURL, "https://relay.example.ts.net:8443")
        XCTAssertTrue(value.code == code)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertThrowsError(try PairingFileImport.consume(from: dir, now: now))
    }
    func testRejectsExpiredFutureAndUnapprovedDestination() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        for expiry in [now.timeIntervalSince1970 - 1, now.timeIntervalSince1970 + 601] {
            _ = try fixture(dir, expires: expiry)
            XCTAssertThrowsError(try PairingFileImport.consume(from: dir, now: now))
        }
        for server in ["http://relay.example.ts.net:8443", "https://relay.example.ts.net:8443.evil.test", "https://relay.example.ts.net:8443/evil", "https://evil.test"] {
            _ = try fixture(dir, server: server)
            XCTAssertThrowsError(try PairingFileImport.consume(from: dir, now: now))
        }
    }
    func testRejectsPermissionsSymlinkOversizeAndMalformedFile() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = try fixture(dir, mode: 0o644)
        XCTAssertThrowsError(try PairingFileImport.consume(from: dir, now: now))
        try FileManager.default.removeItem(at: file)
        let target = dir.appendingPathComponent("target")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        XCTAssertThrowsError(try PairingFileImport.consume(from: dir, now: now))
        try FileManager.default.removeItem(at: file)
        for data in [Data(repeating: 65, count: 4097), Data([0xff]), Data("{}".utf8)] {
            try data.write(to: file); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            XCTAssertThrowsError(try PairingFileImport.consume(from: dir, now: now))
        }
    }
    func testRejectsBadCodeWithoutExposingIt() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = try fixture(dir)
        let body: [String: Any] = ["serverURL": "https://relay.example.ts.net:8443", "code": "PUBLIC_INVALID_FIXTURE", "expiresAt": now.timeIntervalSince1970 + 60]
        try JSONSerialization.data(withJSONObject: body).write(to: file)
        do { _ = try PairingFileImport.consume(from: dir, now: now); XCTFail("Must reject invalid code") }
        catch { XCTAssertFalse(error.localizedDescription.contains("PUBLIC_INVALID_FIXTURE")) }
    }
    func testServiceSavesAndConfiguresOnlyAfterReceipt() async throws {
        var saved: String?; var configured: String?; var calls = 0
        let service = PairingService(readSecret: { nil }, readDeviceID: { nil }, saveSecret: { saved = $0 }, configure: { _, id in configured = id }, request: { _, _, _ in calls += 1; return PairingReceipt(deviceId: "public-fixture-device", token: "public-fixture-secret") })
        let receipt = try await service.pair(serverURL: "https://relay.example.ts.net:8443", code: code)
        XCTAssertEqual(receipt.deviceId, "public-fixture-device"); XCTAssertEqual(calls, 1)
        XCTAssertTrue(saved == "public-fixture-secret"); XCTAssertEqual(configured, receipt.deviceId)
    }
    func testServiceRefusesExistingIdentityAndPreservesIt() async throws {
        var saved = "existing-public-fixture"; var calls = 0
        let service = PairingService(readSecret: { saved }, readDeviceID: { nil }, saveSecret: { saved = $0 }, configure: { _, _ in XCTFail("Must preserve configuration") }, request: { _, _, _ in calls += 1; throw URLError(.timedOut) })
        do { _ = try await service.pair(serverURL: "https://relay.example.ts.net:8443", code: code); XCTFail("Must refuse replacement") } catch { XCTAssertEqual(error as? PairingFailure, .alreadyPaired) }
        XCTAssertEqual(saved, "existing-public-fixture"); XCTAssertEqual(calls, 0)
    }
    func testUnknownNetworkStopsAfterOneCallWithoutSaving() async throws {
        var calls = 0
        let service = PairingService(readSecret: { nil }, readDeviceID: { nil }, saveSecret: { _ in XCTFail("Must not save") }, configure: { _, _ in XCTFail("Must not configure") }, request: { _, _, _ in calls += 1; throw URLError(.timedOut) })
        do { _ = try await service.pair(serverURL: "https://relay.example.ts.net:8443", code: code); XCTFail("Must stop") } catch { XCTAssertEqual(error as? PairingFailure, .networkUnknown) }
        XCTAssertEqual(calls, 1)
    }
    func testResultContainsNoCodeOrTokenAndIsPrivate() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        try PairingFileImport.writeResult(.init(state: "paired", errorCategory: nil, deviceId: "public-fixture-device"), to: dir)
        let file = dir.appendingPathComponent(PairingFileImport.resultFilename)
        let data = try Data(contentsOf: file)
        let result = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(Set(result.keys), ["state", "deviceId"])
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testDiagnosticIncludesOnlyOpaqueStatusAndDeliveredPushIDs() throws {
        let diagnostic = PairingDiagnostic(keychainPresent: true, deviceId: "public-fixture-device", authenticatedInbox: true, notificationAuthorizationStatus: 2, deliveredPushRequestIds: ["opaque-fixture-request"])
        let result = try JSONSerialization.jsonObject(with: JSONEncoder().encode(diagnostic)) as! [String: Any]
        XCTAssertEqual(Set(result.keys), ["keychainPresent", "deviceId", "authenticatedInbox", "notificationAuthorizationStatus", "deliveredPushRequestIds"])
    }

    func testFIFOIsRejectedWithoutWaitingForWriter() throws {
        let dir = try directory()
        let file = dir.appendingPathComponent(PairingFileImport.inputFilename)
        XCTAssertEqual(mkfifo(file.path, 0o600), 0)
        defer {
            // Also release a regressed blocking open, so a failure cannot strand a test worker.
            let writer = open(file.path, O_WRONLY | O_NONBLOCK)
            if writer >= 0 { close(writer) }
            try? FileManager.default.removeItem(at: dir)
        }
        let finished = expectation(description: "regular-file check must reject FIFO without writer")
        let date = now
        DispatchQueue.global().async {
            do { _ = try PairingFileImport.consume(from: dir, now: date); XCTFail("FIFO must be rejected") }
            catch { XCTAssertEqual(error as? PairingFailure, .unsafeFile) }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 1)
    }
    func testSuccessfulHTTPBodyDecodeFailureIsUnknownWithoutRetryOrSaving() async throws {
        var calls = 0
        let service = PairingService(readSecret: { nil }, readDeviceID: { nil }, saveSecret: { _ in XCTFail("Must not save a partial receipt") }, configure: { _, _ in XCTFail("Must not configure from a partial receipt") }, request: { _, _, _ in
            calls += 1
            // Simulates a successful response body missing its credential; no identity is created.
            return try JSONDecoder().decode(PairingReceipt.self, from: Data("{\"deviceId\":\"public-fixture-device\"}".utf8))
        })
        do { _ = try await service.pair(serverURL: "https://relay.example.ts.net:8443", code: code); XCTFail("Must stop with unknown result") }
        catch { XCTAssertEqual(error as? PairingFailure, .networkUnknown) }
        XCTAssertEqual(calls, 1)
    }

}
