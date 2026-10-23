import XCTest
@testable import AgentInbox

final class DiagnosticsTests: XCTestCase {
    func testDiagnosticNotificationRoutesToTheExactTest() throws {
        let url = try XCTUnwrap(DiagnosticRoute.notificationURL(["diagnosticTestId": "fixture-test", "requestId": "fixture-request"]))
        XCTAssertEqual(DiagnosticRoute(url: url)?.id, "fixture-test")
        XCTAssertNil(DiagnosticRoute.notificationURL(["diagnosticTestId": "../private"]))
        XCTAssertNil(DiagnosticRoute(url: URL(string: "agentinbox://diagnostics/a/b")!))
    }
    func snapshot(_ host: [String: Any] = [:]) throws -> DiagnosticSnapshot {
        let body: [String: Any] = ["schemaVersion": 1, "checkedAt": 1000, "hosts": host.isEmpty ? [] : [host], "pushRegistered": true, "pushProviderConfigured": true, "recentTestIds": [], "secret": "fixture-sensitive-body"]
        return try JSONDecoder().decode(DiagnosticSnapshot.self, from: JSONSerialization.data(withJSONObject: body))
    }
    func testHostHeartbeatDoesNotProveAdapterOrCapture() throws {
        let host: [String: Any] = ["hostId": "fixture-private-host", "lastSeen": 999, "online": true]
        let stages = DiagnosticReport.checks(snapshot: try snapshot(host), sync: .passed, now: 1001)
        XCTAssertEqual(stages.first { $0.stage == .host }?.state, .passed)
        XCTAssertEqual(stages.first { $0.stage == .capture }?.state, .unknown)
        XCTAssertEqual(stages.first { $0.stage == .capture }?.reason, .observationMissing)
        var staleHost = host; staleHost["lastSeen"] = 960
        let stale = DiagnosticReport.checks(snapshot: try snapshot(staleHost), sync: .passed, now: 1001)
        XCTAssertEqual(stale.first { $0.stage == .host }?.state, .failed)
    }
    func testExportContainsOnlyWhitelistEvenWithUnknownServerStrings() throws {
        let host: [String: Any] = ["hostId": "fixture-private-host", "lastSeen": 999, "online": true, "observedAt": 999, "observation": ["codex": "https://fixture-private.example.invalid", "claude": "fixture-sensitive-body", "scanAt": 999, "nativeProof": true, "reconciled": true, "draining": false], "token": "REPLACE_LOCALLY_DEVICE_SECRET", "path": "/absolute/private/fixture"]
        let report = DiagnosticReport(stages: DiagnosticReport.checks(snapshot: try snapshot(host), sync: .failed, now: 1001), appVersion: "1.2.3.fixture-private-host", osMajor: 26)
        let exported = try report.shareText()
        for value in ["fixture-private-host", "fixture-sensitive-body", "https://", "REPLACE_LOCALLY", "/absolute/", "token", "hostId"] { XCTAssertFalse(exported.contains(value), value) }
        XCTAssertTrue(exported.contains("schemaVersion"))
        XCTAssertEqual(report.appVersionComponents, [1, 2, 3])
    }
    func testPushAndLegacyAdoptedNeverPassTheReplyLoop() throws {
        let body: [String: Any] = ["testId": "fixture-test", "hostId": "fixture-host", "createdAt": 1000, "expiresAt": 1180, "phase": "ready", "mode": "reply", "push": "accepted", "submitted": true, "received": true, "continued": true]
        let test = try JSONDecoder().decode(DiagnosticTest.self, from: JSONSerialization.data(withJSONObject: body))
        let stages = test.checks(expectedResponseID: "fixture-answer", now: 1001, notificationObserved: true)
        XCTAssertEqual(stages.first { $0.stage == .push }?.state, .passed)
        XCTAssertEqual(stages.first { $0.stage == .received }?.state, .unknown)
        XCTAssertEqual(stages.first { $0.stage == .continued }?.state, .unknown)
    }
    func testReceiptForAnotherAnswerDoesNotPassDiagnostic() throws {
        let q = try ReplyProgressTests().fixture(state: .adopted, received: true, continued: true)
        let test = DiagnosticTest(testId: "fixture-test", hostId: "fixture-host", createdAt: 1000, expiresAt: 1180, phase: "ready", code: nil, mode: "reply", request: q, push: "accepted")
        XCTAssertEqual(test.checks(expectedResponseID: "losing-answer", now: 1004, notificationObserved: false).first { $0.stage == .received }?.state, .unknown)
        XCTAssertEqual(test.checks(expectedResponseID: "original-answer", now: 1004, notificationObserved: false).first { $0.stage == .received }?.state, .passed)
        XCTAssertEqual(test.checks(expectedResponseID: "original-answer", now: 1004, notificationObserved: false).first { $0.stage == .push }?.state, .unknown)
    }
    func testUnsupportedAndTimeoutHaveDistinctCauses() {
        let unsupported = DiagnosticTest(testId: "fixture-test", hostId: "fixture-host", createdAt: 1000, expiresAt: 1180, phase: "unsupported", code: "nativeUnavailable", mode: "reply", request: nil, push: "unobserved")
        XCTAssertEqual(unsupported.checks(expectedResponseID: nil, now: 1001, notificationObserved: false).first { $0.stage == .received }?.state, .unsupported)
        let expired = DiagnosticTest(testId: "fixture-test", hostId: "fixture-host", createdAt: 1000, expiresAt: 1180, phase: "expired", code: "https://fixture-secret.example.invalid", mode: "reply", request: nil, push: "accepted")
        XCTAssertEqual(expired.checks(expectedResponseID: nil, now: 1181, notificationObserved: false).first { $0.stage == .received }?.reason, .testExpired)
    }

    @MainActor func testFailedPreflightDoesNotDisableTheUnsubmittedAnswer() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [DiagnosticURLProtocol.self]
        let api = InboxAPI(baseURL: "https://diagnostic-fixture.example.invalid", token: "public-diagnostic-fixture-only", network: InboxNetwork(system: URLSession(configuration: config)))
        let controller = DiagnosticsController(makeAPI: { api }); controller.resetIfChanged()
        let q = DecisionRequest.demoFixture(id: UUID().uuidString.lowercased(), title: "Fixture", kind: "choice", options: [.init(id: "ok", label: "确认测试")])
        controller.test = DiagnosticTest(testId: "fixture-test", hostId: "fixture-host", createdAt: 1, expiresAt: Date().timeIntervalSince1970 + 180, phase: "ready", code: nil, mode: "reply", request: q, push: "unregistered")
        DiagnosticURLProtocol.handle = { $0.fail() }; defer { DiagnosticURLProtocol.handle = nil }
        await controller.answer(option: q.options[0])
        XCTAssertNil(ResponseJournal.pending(for: q))
        XCTAssertNil(controller.expectedResponseID, "Failed preflight has not sent or saved an answer")
    }
    @MainActor func testLatePollCannotOverwriteAnotherTestOnTheSameConnection() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [DiagnosticURLProtocol.self]
        let api = InboxAPI(baseURL: "https://diagnostic-fixture.example.invalid", token: "public-diagnostic-fixture-only", network: InboxNetwork(system: URLSession(configuration: config)))
        let controller = DiagnosticsController(makeAPI: { api }); controller.resetIfChanged()
        controller.test = DiagnosticTest(testId: "fixture-a", hostId: "fixture-host", createdAt: 1, expiresAt: 9999999999, phase: "ready", code: nil, mode: "reply", request: nil, push: "unregistered")
        let began = expectation(description: "poll began")
        var held: DiagnosticURLProtocol?
        DiagnosticURLProtocol.handle = { proto in held = proto; began.fulfill() }; defer { DiagnosticURLProtocol.handle = nil }
        let task = Task { await controller.poll() }
        await fulfillment(of: [began], timeout: 3)
        controller.test = DiagnosticTest(testId: "fixture-b", hostId: "fixture-host", createdAt: 1, expiresAt: 9999999999, phase: "ready", code: nil, mode: "push", request: nil, push: "unregistered")
        held?.respond(200, #"{"testId":"fixture-a","hostId":"fixture-host","createdAt":1,"expiresAt":9999999999,"phase":"ready","mode":"reply","push":"accepted"}"#)
        await task.value
        XCTAssertEqual(controller.test?.testId, "fixture-b")
    }
    func testOldSnapshotCannotExportCurrentConnectivityOrCaptureSuccess() throws {
        let host: [String: Any] = ["hostId": "fixture-host", "lastSeen": 999, "online": true, "observedAt": 999, "observation": ["codex": "ready", "claude": "unobserved", "scanAt": 999, "nativeProof": true, "reconciled": true, "draining": false]]
        let checks = DiagnosticReport.checks(snapshot: try snapshot(host), sync: .passed, now: 1061)
        XCTAssertNotEqual(checks.first { $0.stage == .relay }?.state, .passed)
        XCTAssertNotEqual(checks.first { $0.stage == .sync }?.state, .passed)
        XCTAssertNotEqual(checks.first { $0.stage == .capture }?.state, .passed)
    }
    @MainActor func testLateAnswerRefreshCannotReplaceChangedRelay() async throws {
        let defaults = InboxConfiguration.defaults
        let keys = ["serverURL", "relayConnectionRevision"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { DiagnosticURLProtocol.handle = nil; for (key, value) in zip(keys, saved) { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        InboxConfiguration.serverURL = "https://diagnostic-old.example.invalid"
        let sessionConfig = URLSessionConfiguration.ephemeral; sessionConfig.protocolClasses = [DiagnosticURLProtocol.self]
        let network = InboxNetwork(system: URLSession(configuration: sessionConfig))
        let api = InboxAPI(baseURL: "https://diagnostic-old.example.invalid", token: "public-diagnostic-fixture-only", network: network)
        let controller = DiagnosticsController(makeAPI: { api }); controller.resetIfChanged()
        let q = DecisionRequest.demoFixture(id: UUID().uuidString.lowercased(), title: "Fixture", kind: "choice", options: [.init(id: "ok", label: "确认测试")])
        controller.test = DiagnosticTest(testId: "fixture-test", hostId: "fixture-host", createdAt: 1, expiresAt: Date().timeIntervalSince1970 + 180, phase: "ready", code: nil, mode: "reply", request: q, push: "unregistered")
        DiagnosticURLProtocol.handle = { proto in
            if proto.request.url!.path.hasPrefix("/v1/diagnostics/tests/") {
                DispatchQueue.main.async {
                    InboxConfiguration.serverURL = "https://diagnostic-new.example.invalid"
                    controller.resetIfChanged()
                    proto.respond(200, #"{"testId":"stale-test","hostId":"fixture-host","createdAt":1,"expiresAt":9999999999,"phase":"ready","mode":"reply","push":"accepted"}"#)
                }
            } else if proto.request.httpMethod == "POST" {
                let answer = try! XCTUnwrap(ResponseJournal.pending(for: q))
                let receipt = ResponseReceipt(requestId: q.id, responseId: answer.responseId, state: .submitting)
                proto.respond(200, String(decoding: try! JSONEncoder().encode(receipt), as: UTF8.self))
            } else { proto.respond(200, String(decoding: try! JSONEncoder().encode(q), as: UTF8.self)) }
        }
        await controller.answer(option: q.options[0])
        XCTAssertNil(controller.test, "A late old-relay response must not repopulate the new connection")
        XCTAssertNil(controller.export)
    }
}

private final class DiagnosticURLProtocol: URLProtocol {
    static var handle: ((DiagnosticURLProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handle?(self) }
    override func stopLoading() {}
    func fail() { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)) }
    func respond(_ status: Int, _ body: String) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
}
