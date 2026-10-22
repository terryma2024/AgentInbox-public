import XCTest
@testable import AgentInbox

actor TestDecisionTransport: DecisionTransport {
    var current: DecisionRequest
    var failFirstPost = false
    var posted: [DecisionResponse] = []
    init(_ current: DecisionRequest, failFirstPost: Bool = false) { self.current = current; self.failFirstPost = failFirstPost }
    func request(_ id: String) async throws -> DecisionRequest { current }
    func submit(_ answer: DecisionResponse) async throws -> ResponseReceipt {
        posted.append(answer)
        if failFirstPost { failFirstPost = false; throw URLError(.cannotConnectToHost) }
        current.state = .submitting
        return .init(requestId: answer.requestId, responseId: answer.responseId, state: .submitting)
    }
    func setState(_ state: RequestState) { current.state = state }
}
final class SubmissionTests: XCTestCase {
    func fixture(kind: String = "choice", questions: [[String: Any]]? = nil) throws -> DecisionRequest {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(DecisionRequest.demo)) as? [String: Any])
        json["requestId"] = UUID().uuidString; json["kind"] = kind; json["questions"] = questions
        if let questions, questions.count == 1, kind != "questions" { json["allowText"] = questions[0]["allowText"] }
        if kind == "permission" { json["body"] = "Bash: /bin/echo 测试"; json["operationSummary"] = "/bin/echo 测试" }
        return try JSONDecoder().decode(DecisionRequest.self, from: JSONSerialization.data(withJSONObject: json))
    }
    func testNativeSingleQuestionBuildsCanonicalTopLevelAnswer() throws {
        let request = try fixture(questions: [["id": "native-question", "header": "策略", "prompt": DecisionRequest.demo.body, "options": [["id":"test", "label":"运行测试"]], "allowText": true, "multiSelect": false]])
        let answer = ReplyDraft.make(request: request, optionIds: [], text: nil, questionAnswers: ["native-question": .init(optionIds: ["test"], text: nil)], responseID: "stable")
        XCTAssertEqual(answer.optionIds, ["test"]); XCTAssertNil(answer.text); XCTAssertTrue(answer.answers.isEmpty)
    }
    func testMixedChoiceAndChineseTextRejectsBeforeSavingJournal() async throws {
        let request = try fixture(questions: [["id": "native-question", "prompt": DecisionRequest.demo.body, "options": [["id":"test", "label":"运行测试"]], "allowText": true, "multiSelect": false]])
        let mixed = ReplyDraft.make(request: request, optionIds: [], text: nil, questionAnswers: ["native-question": .init(optionIds: ["test"], text: "请先检查差异")])
        let transport = TestDecisionTransport(request)
        do { _ = try await ReplySubmission.send(mixed, using: transport); XCTFail("混合答案必须在 journal 前拒绝") } catch { XCTAssertEqual(error.localizedDescription, "请选择选项或输入文字，两者不能同时提交") }
        XCTAssertNil(ResponseJournal.pending(for: request))
        let sent = await transport.posted; XCTAssertTrue(sent.isEmpty)
    }
    func testInvalidOptionAndEmptyAnswerNeverPoisonJournal() async throws {
        let request = try fixture()
        let transport = TestDecisionTransport(request)
        for ids in [["unknown"], ["test", "test"], [String]()] {
            let answer = DecisionResponse(responseId: UUID().uuidString, requestId: request.id, revision: request.revision, optionIds: ids, text: nil, answers: [:])
            do { _ = try await ReplySubmission.send(answer, using: transport); XCTFail("非法答案必须拒绝") } catch {}
            XCTAssertNil(ResponseJournal.pending(for: request))
        }
        let sent = await transport.posted; XCTAssertTrue(sent.isEmpty)
    }
    func testWidgetPermissionAndRecoverableNetworkFailureReuseSameResponse() async throws {
        let request = try fixture(kind: "permission")
        XCTAssertTrue(request.canAnswerInWidget)
        let transport = TestDecisionTransport(request, failFirstPost: true)
        do { _ = try await WidgetReplySubmission.send(cached: request, optionID: "test", responseID: "original-response", using: transport); XCTFail("第一次网络失败") } catch { XCTAssertTrue(error is URLError) }
        let receipt = try await WidgetReplySubmission.send(cached: request, optionID: "test", responseID: "new-widget-snapshot", using: transport)
        XCTAssertEqual(receipt.responseId, "original-response")
        XCTAssertEqual(receipt.state, .submitting)
        let calls = await transport.posted
        XCTAssertEqual(calls.count, 2); XCTAssertEqual(calls[0], calls[1])
    }
    func testUnknownAndSubmittingNeverDispatch() async throws {
        let request = try fixture()
        let transport = TestDecisionTransport(request)
        let answer = ReplyDraft.make(request: request, optionIds: ["test"], text: nil, questionAnswers: [:])
        for state in [RequestState.unknown, .submitting, .adopted, .handledLocally, .invalidated, .expired] {
            await transport.setState(state)
            do { _ = try await ReplySubmission.send(answer, using: transport); XCTFail("终态/未知不可提交") } catch {}
        }
        let calls = await transport.posted; XCTAssertTrue(calls.isEmpty)
    }
    func testWidgetLongQuestionsAndUnknownPermissionSummaryOpenApp() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(DecisionRequest.demo)) as? [String: Any])
        json["body"] = String(repeating: "这是一个完整审批操作。", count: 9)
        var request = try JSONDecoder().decode(DecisionRequest.self, from: JSONSerialization.data(withJSONObject: json)); XCTAssertFalse(request.canAnswerInWidget)
        json["body"] = "等待审批"; json["kind"] = "permission"
        request = try JSONDecoder().decode(DecisionRequest.self, from: JSONSerialization.data(withJSONObject: json)); XCTAssertFalse(request.canAnswerInWidget)
        json["kind"] = "choice"; json["questions"] = [["id":"q1","prompt":"第一题","options":[],"allowText":true,"multiSelect":false],["id":"q2","prompt":"第二题","options":[],"allowText":true,"multiSelect":false]]
        request = try JSONDecoder().decode(DecisionRequest.self, from: JSONSerialization.data(withJSONObject: json)); XCTAssertFalse(request.canAnswerInWidget)
    }
}


final class WidgetInboxRefreshTests: XCTestCase {
    private func request(_ id: String, state: RequestState) -> DecisionRequest {
        var value = DecisionRequest.demoFixture(id: id, title: id, kind: "choice", options: [.init(id: "beta", label: "Beta")])
        value.state = state
        return value
    }
    func testSubmittingConvergesToFullCanonicalListIncludingNewQuestion() async throws {
        let submitting = request("original", state: .submitting)
        let adopted = request("original", state: .adopted)
        let newQuestion = request("new-question", state: .pending)
        var reads = 0
        var now = 100.0
        let result = try await WidgetInboxRefresh.fetch(using: { _ in
            reads += 1
            return reads < 3 ? [submitting] : [newQuestion, adopted]
        }, pause: { now += $0 }, uptime: { now })
        XCTAssertEqual(result.map(\.id), ["new-question", "original"])
        XCTAssertEqual(result.map(\.state), [.pending, .adopted])
        XCTAssertEqual(reads, 3)
    }
    func testNoFollowupForListWithoutSubmittingIncludingUnknown() async throws {
        for state in [RequestState.pending, .adopted, .handledLocally, .expired, .invalidated, .unknown] {
            var reads = 0
            var pauses = 0
            let result = try await WidgetInboxRefresh.fetch(using: { timeout in
                XCTAssertEqual(timeout, 12)
                reads += 1
                return [self.request("original", state: state)]
            }, pause: { _ in pauses += 1 }, uptime: { 100 })
            XCTAssertEqual(result.map(\.state), [state])
            XCTAssertEqual(reads, 1)
            XCTAssertEqual(pauses, 0)
        }
    }
    func testInitialFetchFailurePropagatesWithoutFollowup() async {
        var reads = 0
        do {
            _ = try await WidgetInboxRefresh.fetch(using: { _ in
                reads += 1
                throw URLError(.notConnectedToInternet)
            }, pause: { _ in XCTFail("初次读取失败不能开始轮询") }, uptime: { 100 })
            XCTFail("初次错误必须交由现有缓存错误路径处理")
        } catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
        XCTAssertEqual(reads, 1)
    }
    func testFollowupFailureKeepsLastSuccessfulFullListAndState() async throws {
        var reads = 0
        var now = 100.0
        let result = try await WidgetInboxRefresh.fetch(using: { _ in
            reads += 1
            if reads == 1 { return [self.request("original", state: .submitting)] }
            if reads == 2 { return [self.request("new-question", state: .pending), self.request("original", state: .submitting)] }
            throw URLError(.timedOut)
        }, pause: { now += $0 }, uptime: { now })
        XCTAssertEqual(result.map(\.id), ["new-question", "original"])
        XCTAssertEqual(result.map(\.state), [.pending, .submitting])
        XCTAssertEqual(reads, 3)
    }
    func testUnknownStopsWithoutInferringAdoption() async throws {
        var reads = 0
        var now = 100.0
        let result = try await WidgetInboxRefresh.fetch(using: { _ in
            reads += 1
            return [self.request("original", state: reads == 1 ? .submitting : .unknown)]
        }, pause: { now += $0 }, uptime: { now })
        XCTAssertEqual(result.map(\.state), [.unknown])
        XCTAssertEqual(reads, 2)
    }
    func testSeparateUnknownDoesNotPreventSubmittingRequestConvergence() async throws {
        var reads = 0
        var now = 100.0
        let result = try await WidgetInboxRefresh.fetch(using: { _ in
            reads += 1
            return [self.request("uncertain", state: .unknown), self.request("original", state: reads == 1 ? .submitting : .adopted)]
        }, pause: { now += $0 }, uptime: { now })
        XCTAssertEqual(result.map(\.state), [.unknown, .adopted])
        XCTAssertEqual(reads, 2)
    }
    func testPersistentSubmittingHasAtMostFourAdditionalReads() async throws {
        var timeouts: [TimeInterval] = []
        var now = 100.0
        let result = try await WidgetInboxRefresh.fetch(using: { timeout in
            timeouts.append(timeout)
            return [self.request("original", state: .submitting)]
        }, pause: { now += $0 }, uptime: { now })
        XCTAssertEqual(timeouts, [12, 1.25, 1.25, 1.25, 1.25])
        XCTAssertEqual(now, 103)
        XCTAssertEqual(result.map(\.state), [.submitting])
    }
    func testInitialLatencyDoesNotConsumeFollowupBudgetAndTimeoutIsClipped() async throws {
        var timeouts: [TimeInterval] = []
        var now = 100.0
        let result = try await WidgetInboxRefresh.fetch(using: { timeout in
            timeouts.append(timeout)
            if timeouts.count == 1 { now += 20 }
            if timeouts.count == 2 { now += 3.25 }
            return [self.request("original", state: timeouts.count == 3 ? .adopted : .submitting)]
        }, pause: { now += $0 }, uptime: { now })
        XCTAssertEqual(timeouts, [12, 1.25, 0.25])
        XCTAssertEqual(result.map(\.state), [.adopted])
    }
    func testResponseAfterDeadlineCannotOverrideLastConfirmedList() async throws {
        var reads = 0
        var now = 100.0
        let result = try await WidgetInboxRefresh.fetch(using: { _ in
            reads += 1
            if reads > 1 { now += 5 }
            return [self.request("original", state: reads == 1 ? .submitting : .adopted)]
        }, pause: { now += $0 }, uptime: { now })
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(result.map(\.state), [.submitting])
    }
    func testPauseOvershootingDeadlineDoesNotStartAnotherRead() async throws {
        var reads = 0
        var now = 100.0
        let result = try await WidgetInboxRefresh.fetch(using: { _ in
            reads += 1
            return [self.request("original", state: .submitting)]
        }, pause: { _ in now += 5.1 }, uptime: { now })
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(result.map(\.state), [.submitting])
    }
    func testCancelledPauseReturnsLastConfirmedList() async throws {
        var reads = 0
        let result = try await WidgetInboxRefresh.fetch(using: { _ in
            reads += 1
            return [self.request("original", state: .submitting)]
        }, pause: { _ in throw CancellationError() }, uptime: { 100 })
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(result.map(\.state), [.submitting])
    }
    func testTaskCancellationDoesNotStartFollowupOrAcceptLateState() async throws {
        let work = Task {
            var reads = 0
            let result = try await WidgetInboxRefresh.fetch(using: { _ in
                reads += 1
                if reads > 1 { withUnsafeCurrentTask { $0?.cancel() } }
                return [self.request("original", state: reads == 1 ? .submitting : .adopted)]
            }, pause: { _ in }, uptime: { 100 })
            return (result, reads)
        }
        let (result, reads) = try await work.value
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(result.map(\.state), [.submitting])
    }
}

final class WidgetInboxSelectionTests: XCTestCase {
    private func request(_ id: String, _ state: RequestState, expired: Bool = false) throws -> DecisionRequest {
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(DecisionRequest.demo)) as? [String: Any])
        value["requestId"] = id
        value["state"] = state.rawValue
        value["expiresAt"] = expired ? 50.0 : 200.0
        return try JSONDecoder().decode(DecisionRequest.self, from: JSONSerialization.data(withJSONObject: value))
    }
    func testAnotherPendingMachineRemainsActionableWhileReceiptIsSubmitting() throws {
        let requests = [try request("host-a", .submitting), try request("mac", .pending)]
        let current = WidgetInboxSelection.current(in: requests, at: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(current?.id, "mac")
        XCTAssertEqual(requests.map(\.state), [.submitting, .pending], "选择下一题不等于宣称上一题采用")
    }
    func testUnknownDoesNotBlockAnotherPendingRequestOrBecomeAdopted() throws {
        let requests = [try request("uncertain", .unknown), try request("mac", .pending)]
        XCTAssertEqual(WidgetInboxSelection.current(in: requests, at: Date(timeIntervalSince1970: 100))?.id, "mac")
        XCTAssertEqual(requests.first?.state, .unknown)
    }
    func testExpiredPendingCannotBlockLiveQuestion() throws {
        let requests = [try request("old", .pending, expired: true), try request("live", .pending)]
        XCTAssertEqual(WidgetInboxSelection.current(in: requests, at: Date(timeIntervalSince1970: 100))?.id, "live")
    }
    func testExplicitPinNeverSilentlyTargetsAnotherRequest() throws {
        let requests = [try request("host-a", .submitting), try request("mac", .pending)]
        XCTAssertEqual(WidgetInboxSelection.current(in: requests, pinnedID: "host-a")?.id, "host-a")
        XCTAssertNil(WidgetInboxSelection.current(in: requests, pinnedID: "missing"))
    }
    func testWithoutPendingKeepsUncertainStateVisibleAndSkipsTerminal() throws {
        let requests = [try request("complete", .adopted), try request("submitted", .submitting), try request("uncertain", .unknown)]
        XCTAssertEqual(WidgetInboxSelection.current(in: requests)?.id, "submitted")
        XCTAssertNil(WidgetInboxSelection.current(in: [try request("complete", .handledLocally)]))
    }
    func testPendingOrderPreservesCanonicalListOrder() throws {
        let requests = [try request("newest", .pending), try request("older", .pending)]
        XCTAssertEqual(WidgetInboxSelection.current(in: requests, at: Date(timeIntervalSince1970: 100))?.id, "newest")
    }
}
