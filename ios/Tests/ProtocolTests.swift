import XCTest
@testable import AgentInbox

final class ProtocolTests: XCTestCase {
    func testDecisionContextSurvivesDecodeAndCacheRoundTrip() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(DecisionRequest.demo)) as? [String: Any])
        let original = String(repeating: "完整命令行\n", count: 800) + "末尾关键参数"
        json["decisionContext"] = ["taskGoal": "核对示例项目", "blockingReason": "等待权限", "impactScope": "示例输出文件", "originalContent": original]
        let decoded = try JSONDecoder().decode(DecisionRequest.self, from: JSONSerialization.data(withJSONObject: json))
        let cached = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        let context = try XCTUnwrap(cached["decisionContext"] as? [String: String])
        XCTAssertEqual(context["originalContent"], original)
        XCTAssertEqual(context["taskGoal"], "核对示例项目")
        XCTAssertEqual(context["blockingReason"], "等待权限")
        XCTAssertEqual(context["impactScope"], "示例输出文件")
    }
    func testLegacyContextIsUnknownAndKeepsAllQuestionsAfterAnswering() throws {
        XCTAssertEqual(DecisionRequest.contextValue(nil), "未知")
        XCTAssertEqual(DecisionRequest.contextValue(" \n\t"), "未知")
        XCTAssertEqual(DecisionRequest.contextValue("  原文\n末尾  "), "  原文\n末尾  ")
        let questions: [DecisionQuestion] = [
            .init(id: "fixture-one", header: nil, prompt: "第一题", options: [.init(id: "a", label: "保留选项")], multiSelect: false, allowText: true),
            .init(id: "fixture-two", header: nil, prompt: "第二题末尾", options: [], multiSelect: false, allowText: true)
        ]
        var request = DecisionRequest.demoFixture(id: "fixture-context", title: "Fixture", kind: "questions", options: [], questions: questions)
        request.state = .adopted
        XCTAssertFalse(request.hasOriginalContent)
        XCTAssertTrue(request.originalParts.contains { $0.text == "第二题末尾" })
        XCTAssertTrue(request.originalParts.contains { $0.text == "保留选项" })
    }
    func testAnsweredLegacyChoiceKeepsTopLevelOptionsInOriginal() {
        var request = DecisionRequest.demo
        request.state = .adopted
        XCTAssertTrue(request.originalParts.contains { $0.text.contains("先查看差异") && $0.text.contains("运行测试") })
    }
    func testWidgetOpensAppForUnshownDecisionContext() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(DecisionRequest.demo)) as? [String: Any])
        json["kind"] = "permission"; json["operationSummary"] = "echo fixture"; json["body"] = "echo fixture"
        json["decisionContext"] = ["originalContent": #"{"command":"echo fixture","additionalPermissions":{"network":true}}"#]
        func decode() throws -> DecisionRequest { try JSONDecoder().decode(DecisionRequest.self, from: JSONSerialization.data(withJSONObject: json)) }
        XCTAssertFalse(try decode().canAnswerInWidget)
        json["decisionContext"] = ["originalContent": #"{"command":"echo fixture"}"#]
        XCTAssertTrue(try decode().canAnswerInWidget)
        json["decisionContext"] = ["blockingReason": "访问网络目标 example.invalid", "originalContent": #"{"command":"echo fixture"}"#]
        XCTAssertFalse(try decode().canAnswerInWidget)
        json["kind"] = "choice"; json["body"] = "选择检查"
        json["decisionContext"] = ["originalContent": #"{"questions":[{"id":"fixture-q","question":"选择检查","options":[{"label":"先查看差异","description":"会修改远程示例"},{"label":"运行测试"}]}]}"#]
        XCTAssertFalse(try decode().canAnswerInWidget)
        json["decisionContext"] = ["originalContent": #"{"questions":[{"id":"fixture-q","question":"选择检查","options":[{"label":"先查看差异"},{"label":"运行测试"}]}]}"#]
        XCTAssertTrue(try decode().canAnswerInWidget)
        json["decisionContext"] = ["originalContent": #"{"questions":[{"id":"fixture-q","header":"示例生产环境","question":"选择检查","options":[{"label":"先查看差异"},{"label":"运行测试"}]}]}"#]
        XCTAssertFalse(try decode().canAnswerInWidget)
    }
    func testLongOriginalLayoutKeepsEveryCharacterIncludingUnicodeTail() {
        let raw = String(repeating: "echo 示例\\n", count: 800) + "末尾参数🙂"
        let part = DecisionOriginalPart(id: "fixture", title: "Fixture", text: raw)
        XCTAssertTrue(part.displayLines.allSatisfy { $0.count <= 240 })
        XCTAssertEqual(part.displayLines.joined(), raw)
        XCTAssertEqual(part.text, raw)
        XCTAssertTrue(part.displayLines.last?.hasSuffix("末尾参数🙂") == true)
    }
    func testNativeCommandAndParametersRenderAndCopyAsMessages() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(DecisionRequest.demo)) as? [String: Any])
        let raw = #"{"command":"echo fixture\necho 末尾参数","cwd":"/srv/example-project"}"#
        json["decisionContext"] = ["originalContent": raw]
        let request = try JSONDecoder().decode(DecisionRequest.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(request.originalParts.contains { $0.text == "echo fixture\necho 末尾参数" })
        XCTAssertTrue(request.originalParts.contains { $0.text == "/srv/example-project" })
        XCTAssertEqual(request.originalCopyText, "原始命令\necho fixture\necho 末尾参数\n\n工作目录\n/srv/example-project")
        XCTAssertEqual(request.decisionContext?.originalContent, raw)
    }
    func testQuestionMessagesKeepEveryPromptHeaderAndOptionDescription() {
        var request = DecisionRequest.demo
        request.decisionContext = .init(originalContent: #"{"questions":[{"id":"fixture-one","header":"范围","question":"第一题\n末尾内容","options":[{"label":"Alpha","description":"仅查看示例\n保留完整说明"}]},{"id":"fixture-two","question":"第二题末尾","options":[]}]}"#)
        let message = request.originalCopyText
        for content in ["范围", "第一题\n末尾内容", "Alpha", "仅查看示例\n保留完整说明", "第二题末尾"] { XCTAssertTrue(message.contains(content)) }
        XCTAssertFalse(message.contains(#""questions":"#))
        XCTAssertFalse(message.contains("fixture-one"))
    }
    func testToolMessagesKeepNestedParametersAndUnknownFields() {
        var request = DecisionRequest.demo
        request.decisionContext = .init(originalContent: #"{"tool_name":"Bash","cwd":"/srv/example-project","tool_input":{"command":"echo fixture","timeout":3000,"futureField":{"hosts":["example.invalid"],"enabled":true,"missing":null}}}"#)
        let message = request.originalCopyText
        for content in ["Bash", "/srv/example-project", "echo fixture", "3000", "futureField", "hosts", "example.invalid", "是", "未知"] { XCTAssertTrue(message.contains(content)) }
        XCTAssertFalse(message.contains(#""tool_input":"#))
    }
    func testGenericToolQuestionArgumentsAreNotTreatedAsNativeQuestions() {
        var request = DecisionRequest.demo
        request.decisionContext = .init(originalContent: #"{"tool_name":"mcp__fixture__update_survey","tool_input":{"questions":[{"id":"fixture-target-resource","header":"Target header","question":"Replace question wording","prompt":"fixture-required-prompt"}],"tool_input":{"id":"fixture-nested-target"}}}"#)
        for content in ["fixture-target-resource", "Target header", "Replace question wording", "fixture-required-prompt", "fixture-nested-target"] {
            XCTAssertTrue(request.originalCopyText.contains(content), "Missing tool argument: \(content)")
        }
    }
    func testNativeQuestionKeepsAlternatePromptAndUnknownFields() {
        var request = DecisionRequest.demo
        request.decisionContext = .init(originalContent: #"{"questions":[{"id":"fixture-route","question":"Question text","prompt":"Additional prompt","future":"Additional context"}]}"#)
        for content in ["Question text", "Additional prompt", "Additional context"] { XCTAssertTrue(request.originalCopyText.contains(content)) }
    }
    func testClaudeNativeQuestionsRenderPromptAndOptionDescriptions() {
        var request = DecisionRequest.demo
        request.decisionContext = .init(originalContent: #"{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"header":"Scope","question":"Question text","options":[{"label":"Alpha","description":"Full option description"}]}]}}"#)
        XCTAssertTrue(request.originalParts.contains { $0.title == "问题 1 · Scope" && $0.text == "Question text" })
        XCTAssertTrue(request.originalParts.contains { $0.text == "Alpha\nFull option description" })
    }
    func testLegacyToolBodyRendersParametersAsMessages() throws {
        let body = "工具：Bash\n工作目录：/srv/example-project\n参数：{\"command\":\"echo fixture\\necho tail\",\"timeout\":3000}"
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(DecisionRequest.demo)) as? [String: Any])
        json["body"] = body; json["kind"] = "permission"
        let request = try JSONDecoder().decode(DecisionRequest.self, from: JSONSerialization.data(withJSONObject: json))
        for content in ["Bash", "/srv/example-project", "echo fixture\necho tail", "3000"] { XCTAssertTrue(request.originalCopyText.contains(content)) }
        XCTAssertFalse(request.originalCopyText.contains(#""command":"#))
        XCTAssertFalse(request.hasOriginalContent)
    }
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
