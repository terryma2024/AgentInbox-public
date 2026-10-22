import XCTest
@testable import AgentInbox

final class ProtocolTests: XCTestCase {
    func testHTTPPolicyAllowsOnlyLoopbackAndTailscale() throws {
        for address in ["http://127.0.0.1:8787", "http://100.100.1.1:8787", "https://relay.example.com"] {
            XCTAssertNoThrow(try InboxAPI(baseURL: address).validatedURL("/v1/requests"))
        }
        for address in ["http://example.com", "http://192.168.1.1", "file:///private/tmp"] {
            XCTAssertThrowsError(try InboxAPI(baseURL: address).validatedURL("/v1/requests"))
        }
    }
    func testPermissionWidgetCanAnswerWhileTextAndMultiselectOpenApp() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(DecisionRequest.demo)) as? [String: Any])
        json["kind"] = "permission"; json["operationSummary"] = "运行测试"; json["body"] = "运行测试"
        var request = try JSONDecoder().decode(DecisionRequest.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(request.canAnswerInWidget)
        json["kind"] = "text"; json["options"] = []
        request = try JSONDecoder().decode(DecisionRequest.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(request.canAnswerInWidget)
        json["kind"] = "choice"; json["options"] = [["id": "o1", "label": "检查"]]; json["multiSelect"] = true
        request = try JSONDecoder().decode(DecisionRequest.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(request.canAnswerInWidget)
    }
    func testLaunchSurfaceOptionalCodableCompatibility() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(DecisionRequest.demo)) as? [String: Any])
        json.removeValue(forKey: "launchSurface")
        let legacy = try JSONDecoder().decode(DecisionRequest.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.launchSurface)
        json["launchSurface"] = "unknown"
        let native = try JSONDecoder().decode(DecisionRequest.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(native.launchSurface, "unknown")
        XCTAssertEqual(native.sessionId, legacy.sessionId)
        XCTAssertEqual(native.nativeRequestId, legacy.nativeRequestId)
        XCTAssertEqual(try JSONDecoder().decode(DecisionRequest.self, from: JSONEncoder().encode(native)).launchSurface, "unknown")
    }
    func testOptionalProjectAndSessionLabelsPreserveCanonicalIdentity() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(DecisionRequest.demo)) as? [String: Any])
        json.removeValue(forKey: "projectPath"); json.removeValue(forKey: "sessionLabel")
        let legacy = try JSONDecoder().decode(DecisionRequest.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.projectPath); XCTAssertNil(legacy.sessionLabel)
        XCTAssertEqual(legacy.sessionDisplayLabel, String(try XCTUnwrap(legacy.sessionId).prefix(8)))
        json["projectPath"] = "/Users/example/work/同名项目"; json["sessionLabel"] = "显式测试会话"
        let described = try JSONDecoder().decode(DecisionRequest.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(described.projectBasename, "同名项目"); XCTAssertEqual(described.sessionDisplayLabel, "显式测试会话")
        XCTAssertEqual(described.sessionId, legacy.sessionId); XCTAssertEqual(described.nativeRequestId, legacy.nativeRequestId)
        let roundTrip = try JSONDecoder().decode(DecisionRequest.self, from: JSONEncoder().encode(described))
        XCTAssertEqual(roundTrip.projectPath, "/Users/example/work/同名项目"); XCTAssertEqual(roundTrip.sessionLabel, "显式测试会话")
        json["projectPath"] = "/Users/example/other/同名项目"
        let second = try JSONDecoder().decode(DecisionRequest.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(second.projectBasename, described.projectBasename); XCTAssertNotEqual(second.projectPath, described.projectPath)
    }
    func testStateLabelsAndFinality() {
        XCTAssertEqual(RequestState.adopted.label, "原任务已采用")
        for state in RequestState.allCases where state != .pending { var request = DecisionRequest.demo; request.state = state; XCTAssertFalse(request.canAnswer()) }
    }
    func testExpiryRejectsAnswerAndWidget() {
        XCTAssertFalse(DecisionRequest.demo.canAnswer(at: Date().addingTimeInterval(7200)))
        var request = DecisionRequest.demo; request.state = .unknown; XCTAssertFalse(request.canAnswerInWidget)
    }
    func testResponseRoundTripPreservesBindingAndChinese() throws {
        let original = DecisionResponse(responseId: "stable-id", requestId: "request-one", revision: 7, optionIds: ["o2"], text: "请先检查差异", answers: ["question-one": .init(optionIds: ["a", "b"], text: nil)])
        let decoded = try JSONDecoder().decode(DecisionResponse.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.revision, 7)
    }
    func testRequestRoundTripAndExactDeepLink() throws {
        let request = try JSONDecoder().decode(DecisionRequest.self, from: JSONEncoder().encode(DecisionRequest.demo))
        XCTAssertEqual(RequestRoute.requestID(from: request.deepLink), request.id)
        XCTAssertNil(RequestRoute.requestID(from: URL(string: "https://example.com/request/demo")!))
        XCTAssertNil(RequestRoute.requestID(from: URL(string: "agentinbox://request/one/two")!))
    }
    func testJournalKeepsStableResponseAndRevisionIsolation() throws {
        let request = DecisionRequest.demoFixture(id: UUID().uuidString, title: "Journal", kind: "choice", options: [.init(id: "test", label: "Test"), .init(id: "inspect", label: "Inspect")])
        InboxConfiguration.defaults.removeObject(forKey: "response.\(request.id).\(request.revision)")
        let answer = DecisionResponse(responseId: UUID().uuidString, requestId: request.id, revision: request.revision, optionIds: ["test"], text: nil, answers: [:])
        try ResponseJournal.save(answer)
        XCTAssertEqual(ResponseJournal.pending(for: request), answer)
        try ResponseJournal.save(answer)
        let conflict = DecisionResponse(responseId: "another-id", requestId: request.id, revision: request.revision, optionIds: ["inspect"], text: nil, answers: [:])
        XCTAssertThrowsError(try ResponseJournal.save(conflict))
        XCTAssertEqual(ResponseJournal.pending(for: request), answer)
        InboxConfiguration.defaults.removeObject(forKey: "response.\(request.id).\(request.revision)")
    }
}
