import XCTest
@testable import AgentInbox

final class WidgetInteractionTests: XCTestCase {
    private func request(_ id: String) -> DecisionRequest {
        .demoFixture(id: id, title: "选择路线", kind: "choice", options: [.init(id: "alpha", label: "甲"), .init(id: "beta", label: "乙")])
    }
    func testSwitchRequiresExplicitArmingAndOldTapNeverAnswersNewQuestion() throws {
        var state = WidgetInteractionState()
        let first = request("fixture-first"), second = request("fixture-second")
        let old = try XCTUnwrap(state.present(first))
        XCTAssertTrue(old.isArmed)
        try state.begin(old, request: first, optionID: "beta", responseID: "fixture-response")
        state.finish(responseID: "fixture-response", phase: .submitted)
        let next = try XCTUnwrap(state.present(second))
        XCTAssertFalse(next.isArmed)
        XCTAssertThrowsError(try state.begin(old, request: second, optionID: "beta", responseID: "fixture-wrong"))
        XCTAssertThrowsError(try state.begin(next, request: second, optionID: "beta", responseID: "fixture-unarmed"))
        try state.arm(next, request: second)
        // An old unlock cannot re-arm a later presentation or submit an answer.
        XCTAssertThrowsError(try state.arm(next, request: second))
        let armed = try XCTUnwrap(state.present(second))
        try state.begin(armed, request: second, optionID: "alpha", responseID: "fixture-next-response")
        XCTAssertEqual(state.submissions.map(\.responseID), ["fixture-response", "fixture-next-response"])
    }
    func testDoubleTapAndOppositeOptionAreRejectedBeforeNetwork() throws {
        var state = WidgetInteractionState()
        let request = request("fixture-double")
        let screen = try XCTUnwrap(state.present(request))
        try state.begin(screen, request: request, optionID: "alpha", responseID: "fixture-once")
        XCTAssertThrowsError(try state.begin(screen, request: request, optionID: "alpha", responseID: "fixture-once"))
        XCTAssertThrowsError(try state.begin(screen, request: request, optionID: "beta", responseID: "fixture-opposite"))
        XCTAssertEqual(state.submissions.count, 1)
        XCTAssertEqual(state.submissions.first?.optionID, "alpha")
    }
    func testExternalSwitchEmptyInboxAndSwitchBackCannotReuseOldPresentation() throws {
        var state = WidgetInteractionState()
        let a = request("fixture-a"), b = request("fixture-b")
        let original = try XCTUnwrap(state.present(a))
        XCTAssertFalse(try XCTUnwrap(state.present(b)).isArmed)
        _ = state.present(nil)
        let returning = try XCTUnwrap(state.present(a))
        XCTAssertFalse(returning.isArmed)
        XCTAssertNotEqual(original.id, returning.id)
        XCTAssertThrowsError(try state.begin(original, request: a, optionID: "alpha", responseID: "fixture-old"))
    }
    func testSendingAndUnknownSurviveOldCanonicalPendingListAndRestart() throws {
        var state = WidgetInteractionState()
        let request = request("fixture-overlay")
        let now = Date()
        try state.begin(try XCTUnwrap(state.present(request)), request: request, optionID: "beta", responseID: "fixture-overlay-response", at: now)
        state = try JSONDecoder().decode(WidgetInteractionState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(state.displayRequests([request], at: now).first?.state, .submitting)
        // Process termination cannot leave a permanent 'sending' claim.
        XCTAssertEqual(state.displayRequests([request], at: now.addingTimeInterval(61)).first?.state, .unknown)
        XCTAssertThrowsError(try state.begin(try XCTUnwrap(state.present(request)), request: request, optionID: "beta", responseID: "fixture-retry", at: now.addingTimeInterval(61)))
        state.finish(responseID: "fixture-overlay-response", phase: .unknown)
        XCTAssertEqual(state.displayRequests([request]).first?.state, .unknown)
        var terminal = request; terminal.state = .handledLocally
        XCTAssertEqual(state.displayRequests([terminal]).first?.state, .handledLocally)
    }
    func testFailedPreflightAllowsExplicitRetryAndFingerprintIgnoresReceipts() throws {
        var state = WidgetInteractionState()
        let request = request("fixture-preflight")
        let screen = try XCTUnwrap(state.present(request))
        try state.begin(screen, request: request, optionID: "beta", responseID: "fixture-failed")
        state.finish(responseID: "fixture-failed", phase: .failed)
        XCTAssertTrue(state.displayRequests([request]).first!.canAnswer())
        XCTAssertThrowsError(try state.begin(screen, request: request, optionID: "beta", responseID: "fixture-old-tap"))
        let retry = try XCTUnwrap(state.present(request))
        XCTAssertFalse(retry.isArmed)
        try state.arm(retry, request: request)
        try state.begin(try XCTUnwrap(state.present(request)), request: request, optionID: "beta", responseID: "fixture-retry")
        var updated = request; updated.state = .submitting; updated.responseId = "fixture-retry"
        XCTAssertEqual(request.widgetFingerprint, updated.widgetFingerprint)
        updated.projectPath = "/srv/another-example"
        XCTAssertNotEqual(request.widgetFingerprint, updated.widgetFingerprint)
    }
    func testExpiredAndMissingOptionCannotBeClaimed() throws {
        var state = WidgetInteractionState()
        let request = request("fixture-expiry")
        let screen = try XCTUnwrap(state.present(request))
        XCTAssertThrowsError(try state.begin(screen, request: request, optionID: "missing", responseID: "fixture-missing"))
        XCTAssertThrowsError(try state.begin(screen, request: request, optionID: "alpha", responseID: "fixture-expired", at: Date(timeIntervalSince1970: request.expiresAt + 1)))
        XCTAssertTrue(state.submissions.isEmpty)
    }
    func testStoreSerializesIndependentInstancesAndScopesPairing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = WidgetInteractionStore(directory: directory), second = WidgetInteractionStore(directory: directory)
        let scope = ReplyJournalContext(serverURL: "https://example.invalid", connectionRevision: "fixture-connection", pairingGeneration: "fixture-pairing")
        let request = request("fixture-store")
        let screen = try first.update(context: scope) { try XCTUnwrap($0.present(request)) }
        try first.update(context: scope) { try $0.begin(screen, request: request, optionID: "alpha", responseID: "fixture-store-response") }
        XCTAssertThrowsError(try second.update(context: scope) { try $0.begin(screen, request: request, optionID: "beta", responseID: "fixture-store-opposite") })
        XCTAssertEqual(try second.update(context: scope) { $0.submissions.count }, 1)
        let newScope = ReplyJournalContext(serverURL: scope.serverURL, connectionRevision: scope.connectionRevision, pairingGeneration: "fixture-new-pairing")
        XCTAssertThrowsError(try second.update(context: newScope) { try $0.begin(screen, request: request, optionID: "alpha", responseID: "fixture-repaired") })
        XCTAssertEqual(try second.update(context: newScope) { $0.submissions.count }, 0)
    }
    func testMultilineAndLongLabelsOpenAppRatherThanHideDecisionText() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request("fixture-layout"))) as? [String: Any])
        json["body"] = "执行？\n仅测试"
        let multiline = try JSONDecoder().decode(DecisionRequest.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(WidgetAnswerLayout.fits(multiline, compact: true, large: false))
        XCTAssertFalse(WidgetAnswerLayout.fits(multiline, compact: false, large: false))
        json["body"] = "选择路线"
        json["title"] = "操作\n完整说明"
        let title = try JSONDecoder().decode(DecisionRequest.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(WidgetAnswerLayout.fits(title, compact: false, large: true))
        json["title"] = "选择路线"
        json["options"] = [["id": "alpha", "label": "先检查\n再执行"]]
        let option = try JSONDecoder().decode(DecisionRequest.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(WidgetAnswerLayout.fits(option, compact: false, large: true))
        json["options"] = [["id": "alpha", "label": "这项操作包含长说明必须完整阅读"]]
        let long = try JSONDecoder().decode(DecisionRequest.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(WidgetAnswerLayout.fits(long, compact: true, large: false))
        XCTAssertFalse(WidgetAnswerLayout.fits(long, compact: false, large: false))
    }
    func testCorruptPersistentStateFailsClosed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WidgetInteractionStore(directory: directory)
        let scope = ReplyJournalContext(serverURL: "https://example.invalid", connectionRevision: "fixture-corrupt", pairingGeneration: "fixture-pairing")
        _ = try store.update(context: scope) { $0.present(request("fixture-corrupt")) }
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first { $0.pathExtension == "json" })
        try Data("broken".utf8).write(to: file)
        XCTAssertThrowsError(try store.update(context: scope) { $0.present(request("fixture-corrupt")) })
    }
    func testConcurrentIndependentStoresHaveExactlyOneWinner() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = ReplyJournalContext(serverURL: "https://example.invalid", connectionRevision: "fixture-concurrent", pairingGeneration: "fixture-pairing")
        let request = request("fixture-concurrent")
        let screen = try WidgetInteractionStore(directory: directory).update(context: scope) { try XCTUnwrap($0.present(request)) }
        let resultLock = NSLock()
        var winners = 0
        DispatchQueue.concurrentPerform(iterations: 12) { index in
            do {
                try WidgetInteractionStore(directory: directory).update(context: scope) { state in
                    Thread.sleep(forTimeInterval: 0.005)
                    try state.begin(screen, request: request, optionID: index.isMultiple(of: 2) ? "alpha" : "beta", responseID: "fixture-concurrent-\(index)")
                }
                resultLock.lock(); winners += 1; resultLock.unlock()
            } catch {}
        }
        XCTAssertEqual(winners, 1)
        XCTAssertEqual(try WidgetInteractionStore(directory: directory).update(context: scope) { $0.submissions.count }, 1)
    }
}
