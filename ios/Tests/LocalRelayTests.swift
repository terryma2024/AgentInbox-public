import XCTest
@testable import AgentInbox

final class LocalRelayTests: XCTestCase {
    func testOriginalCodexSingleQuestionAdoption() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let keyFile = env["AGENTINBOX_TEST_KEY_FILE"], let bindingFile = env["AGENTINBOX_NATIVE_BINDING_FILE"] else { throw XCTSkip("未提供专用 Codex 原任务请求") }
        let token = try String(contentsOfFile: keyFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let api = InboxAPI(baseURL: "http://127.0.0.1:8787", token: token)
        let bindingData = try Data(contentsOf: URL(fileURLWithPath: bindingFile))
        let expected = try JSONDecoder().decode(DecisionRequest.self, from: bindingData)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: bindingData) as? [String: Any])
        let native = try XCTUnwrap(raw["native"] as? [String: Any]); let callback = try XCTUnwrap(native["callback"] as? [String: Any])
        guard callback["method"] as? String == "item/tool/requestUserInput" else { XCTFail("不可批准真实工具操作"); return }
        let requestID = expected.id
        guard requestID != "e53d435e-8bc2-4e16-8a3b-92b707e395d3" else { XCTFail("旧过期产品绑定禁止继承"); return }
        let current = try await api.request(requestID)
        guard current.engine == "codex", current.kind == "choice", current.body == "AGENTINBOX_CHOOSE_ROUTE", current.questions?.count == 1,
              current.revision == expected.revision, current.hostId == expected.hostId, current.runtimeId == expected.runtimeId,
              current.sessionId == expected.sessionId, current.turnId == expected.turnId,
              current.nativeRequestId == expected.nativeRequestId, current.itemId == expected.itemId, current.canAnswer() else {
            XCTFail("不是已核对的独立无操作测试题"); return
        }
        let question = try XCTUnwrap(current.questions?.first)
        let beta = try XCTUnwrap(question.options.first { $0.label == "Beta" })
        let answer = ReplyDraft.make(request: current, optionIds: [], text: nil, questionAnswers: [question.id: .init(optionIds: [beta.id], text: nil)])
        XCTAssertEqual(answer.optionIds, [beta.id]); XCTAssertTrue(answer.answers.isEmpty)
        let receipt = try await ReplySubmission.send(answer, using: api)
        XCTAssertEqual(receipt.responseId, answer.responseId)
        var adopted = try await api.request(requestID)
        for _ in 0..<30 where adopted.state == .submitting {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            adopted = try await api.request(requestID)
        }
        XCTAssertEqual(adopted.state, .adopted)
        struct Proof: Codable { let requestId: String; let responseId: String; let sessionId: String?; let turnId: String?; let nativeRequestId: String?; let state: String; let client: String }
        let proof = Proof(requestId: current.id, responseId: answer.responseId, sessionId: current.sessionId, turnId: current.turnId, nativeRequestId: current.nativeRequestId, state: adopted.state.rawValue, client: "iOS simulator shared ReplyDraft + ReplySubmission")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(proof).write(to: URL(fileURLWithPath: env["AGENTINBOX_NATIVE_PROOF_FILE"] ?? FileManager.default.temporaryDirectory.appendingPathComponent("ios-codex-adoption.json").path))
    }
    func testIsolatedRelayFixtureBindingAndIdempotency() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let keyFile = env["AGENTINBOX_TEST_KEY_FILE"], let requestID = env["AGENTINBOX_TEST_REQUEST_ID"] else { throw XCTSkip("隔离 relay fixture 未启用；仅显式指定测试请求时提交") }
        let token = try String(contentsOfFile: keyFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let api = InboxAPI(baseURL: env["AGENTINBOX_TEST_URL"] ?? "http://127.0.0.1:8787", token: token)
        let requests = try await api.requests()
        XCTAssertTrue(requests.contains { $0.id == requestID })
        let current = try await api.request(requestID)
        XCTAssertTrue(current.canAnswer())
        guard let option = current.options.first else { XCTFail("测试请求必须是单选 fixture"); return }
        let answer = DecisionResponse(responseId: UUID().uuidString.lowercased(), requestId: current.id, revision: current.revision, optionIds: [option.id], text: nil, answers: [:])
        let receipt = try await api.submit(answer)
        XCTAssertEqual(receipt.requestId, current.id)
        XCTAssertEqual(receipt.responseId, answer.responseId)
        XCTAssertEqual(receipt.state, .submitting)
        let repeated = try await api.submit(answer)
        XCTAssertEqual(repeated.responseId, answer.responseId)
        XCTAssertNotEqual(repeated.state, .adopted)
        let conflict = DecisionResponse(responseId: answer.responseId, requestId: current.id, revision: current.revision, optionIds: [], text: "改写", answers: [:])
        do { _ = try await api.submit(conflict); XCTFail("同 responseId 改写必须拒绝") } catch { XCTAssertEqual(error.localizedDescription, "请求已变化或已被处理，请刷新") }
        let updated = try await api.request(current.id)
        XCTAssertEqual(updated.state, .submitting)
    }
}
