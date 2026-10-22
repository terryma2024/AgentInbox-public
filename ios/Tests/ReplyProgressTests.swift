import XCTest
@testable import AgentInbox

actor WrongReceiptTransport: DecisionTransport {
    let current: DecisionRequest
    init(_ current: DecisionRequest) { self.current = current }
    func request(_ id: String) async throws -> DecisionRequest { current }
    func submit(_ answer: DecisionResponse) async throws -> ResponseReceipt { .init(requestId: "another-request", responseId: answer.responseId, state: .adopted) }
}
final class ReplyProgressTests: XCTestCase {
    func fixture(state: RequestState = .submitting, received: Bool = false, continued: Bool = false) throws -> DecisionRequest {
        var q = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(DecisionRequest.demo)) as? [String: Any])
        q["requestId"] = "progress-fixture"; q["responseId"] = "original-answer"; q["state"] = state.rawValue; q["bindingDigest"] = String(repeating: "a", count: 64)
        var p: [String: Any] = ["schemaVersion": 1, "requestId": "progress-fixture", "responseId": "original-answer", "bindingDigest": String(repeating: "a", count: 64), "submitted": ["at": 1001], "continuationObservation": continued ? "confirmed" : (received ? "awaiting" : "unobserved")]
        if received { p["received"] = ["at": 1002] }; if continued { p["continued"] = ["at": 1003] }
        q["replyProgress"] = p
        return try JSONDecoder().decode(DecisionRequest.self, from: JSONSerialization.data(withJSONObject: q))
    }
    func testThreeMilestonesAdvanceIndependently() throws {
        let submitted = try fixture().replyStatus(for: "original-answer")
        XCTAssertTrue(submitted.submitted); XCTAssertFalse(submitted.received); XCTAssertFalse(submitted.continued)
        let received = try fixture(state: .adopted, received: true).replyStatus(for: "original-answer")
        XCTAssertTrue(received.received); XCTAssertFalse(received.continued)
        XCTAssertTrue(try fixture(state: .adopted, received: true, continued: true).replyStatus(for: "original-answer").continued)
    }
    func testAnotherWinningAnswerNeverAdoptsThisLocalAnswer() throws {
        let status = try fixture(state: .adopted, received: true, continued: true).replyStatus(for: "losing-answer")
        XCTAssertFalse(status.submitted); XCTAssertFalse(status.received); XCTAssertFalse(status.continued)
    }
    func testLegacyAdoptedDoesNotInventNewProof() {
        var q = DecisionRequest.demo; q.state = .adopted
        XCTAssertFalse(q.replyStatus().received); XCTAssertFalse(q.replyStatus().continued)
    }
    func testMismatchedOrNoncausalProgressFailsClosed() throws {
        let good = try fixture(state: .adopted, received: true, continued: true)
        for field in ["requestId", "responseId", "bindingDigest", "schemaVersion"] {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(good)) as? [String: Any])
            var p = try XCTUnwrap(json["replyProgress"] as? [String: Any]); p[field] = field == "schemaVersion" ? 2 : "wrong"; json["replyProgress"] = p
            let q = try JSONDecoder().decode(DecisionRequest.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertFalse(q.replyStatus().received); XCTAssertFalse(q.replyStatus().continued)
        }
        XCTAssertFalse(try fixture(state: .adopted, received: false, continued: true).replyStatus().continued)
    }
    func testIncorrectHTTPReceiptCannotMarkSubmissionSuccess() async throws {
        let q = DecisionRequest.demoFixture(id: UUID().uuidString, title: "Fixture", kind: "choice", options: [.init(id: "a", label: "Alpha")])
        let answer = ReplyDraft.make(request: q, optionIds: ["a"], text: nil, questionAnswers: [:])
        do { _ = try await ReplySubmission.send(answer, using: WrongReceiptTransport(q)); XCTFail("Wrong request receipt must be rejected") } catch {}
        XCTAssertEqual(ResponseJournal.pending(for: q), answer)
    }
    func testJournalSurvivesReadsButCannotCrossRelayOrPairingGeneration() throws {
        let defaults = InboxConfiguration.defaults
        let keys = ["serverURL", "relayConnectionRevision", "replyPairingGeneration"]
        let old = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, old) { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        let q = DecisionRequest.demoFixture(id: UUID().uuidString, title: "Fixture", kind: "choice", options: [.init(id: "a", label: "Alpha")])
        let a = ReplyDraft.make(request: q, optionIds: ["a"], text: nil, questionAnswers: [:])
        try ResponseJournal.save(a, for: q)
        XCTAssertEqual(ResponseJournal.pending(for: q), a)
        InboxConfiguration.serverURL = "https://journal-fixture.ts.net:8443"
        XCTAssertNil(ResponseJournal.pending(for: q))
        try ResponseJournal.save(a, for: q)
        defaults.set(UUID().uuidString, forKey: "replyPairingGeneration")
        XCTAssertNil(ResponseJournal.pending(for: q))
    }
    func testReceivedAwaitingContinuationDoesNotBlockNewWidgetQuestion() throws {
        let awaiting = try fixture(state: .adopted, received: true)
        XCTAssertEqual(WidgetInboxSelection.current(in: [awaiting])?.id, awaiting.id)
        XCTAssertEqual(WidgetInboxSelection.current(in: [awaiting, .demo])?.id, DecisionRequest.demo.id)
    }
    func testPairingChangeInvalidatesCachedInboxAndLateResults() throws {
        let defaults = InboxConfiguration.defaults
        let keys = ["replyPairingGeneration", "inbox"]
        let old = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, old) { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        let connection = InboxConfiguration.relayConnection
        let cache = CachedInbox(requests: [.demo], refreshedAt: Date(), error: nil)
        InboxCache.save(cache, for: connection)
        InboxConfiguration.rotateReplyPairingGeneration()
        XCTAssertTrue(InboxCache.load().requests.isEmpty)
        InboxCache.save(cache, for: connection)
        XCTAssertTrue(InboxCache.load().requests.isEmpty)
    }

    func testLegacyUnknownJournalCannotBeSilentlyReplacedByWidget() async throws {
        let q = DecisionRequest.demoFixture(id: UUID().uuidString, title: "Fixture", kind: "choice", options: [.init(id: "a", label: "Alpha")])
        let old = ReplyDraft.make(request: q, optionIds: ["a"], text: nil, questionAnswers: [:], responseID: "old-answer")
        let key = "response.\(q.id).\(q.revision)"
        InboxConfiguration.defaults.set(try JSONEncoder().encode(old), forKey: key)
        defer { InboxConfiguration.defaults.removeObject(forKey: key) }
        let transport = TestDecisionTransport(q)
        do { _ = try await WidgetReplySubmission.send(cached: q, optionID: "a", responseID: "new-answer", using: transport); XCTFail("Legacy result must be reconciled, not replaced") } catch {}
        let posted = await transport.posted; XCTAssertTrue(posted.isEmpty)
    }

}
