import XCTest
@testable import AgentInbox

@MainActor
final class RelaySelectionTests: XCTestCase {
    func testOldRelayCacheCannotReplaceCurrentCacheAfterSwitchOrSwitchBack() throws {
        let defaults = InboxConfiguration.defaults
        let keys = ["serverURL", "relayConnectionRevision", "inbox"]
        let original = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, original) { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        InboxConfiguration.serverURL = "https://old-cache-fixture.ts.net:8443"
        let old = InboxConfiguration.relayConnection
        let stale = CachedInbox(requests: [.demo], refreshedAt: Date(), error: nil)
        InboxCache.save(stale, for: old)
        XCTAssertEqual(InboxCache.load().requests.count, 1)
        InboxConfiguration.serverURL = "https://new-cache-fixture.ts.net:8443"
        XCTAssertTrue(InboxCache.load().requests.isEmpty)
        InboxCache.save(.init(requests: [], refreshedAt: Date(), error: nil))
        InboxCache.save(stale, for: old)
        XCTAssertTrue(InboxCache.load().requests.isEmpty)
        InboxConfiguration.serverURL = "https://old-cache-fixture.ts.net:8443"
        XCTAssertNotEqual(InboxConfiguration.relayConnection, old)
        InboxCache.save(stale, for: old)
        XCTAssertTrue(InboxCache.load().requests.isEmpty)
    }
    func testCandidateReplacesOnlyDomainAndRejectsInjectedOrigins() throws {
        XCTAssertEqual(try RelaySelectionService.candidateURL(dnsName: "host.tailfixture.ts.net", currentURL: "https://old.tailfixture.ts.net:8443"), "https://host.tailfixture.ts.net:8443")
        XCTAssertEqual(try RelaySelectionService.candidateURL(dnsName: "HOST.tailfixture.ts.net.", currentURL: "http://127.0.0.1:8787"), "http://host.tailfixture.ts.net:8787")
        for domain in ["", "host.example.com", "host.ts.net@evil.example", "https://host.ts.net", "host.ts.net/path", "a..ts.net", "-host.ts.net"] {
            XCTAssertThrowsError(try RelaySelectionService.candidateURL(dnsName: domain, currentURL: "https://old.ts.net:8443"))
        }
        for origin in ["file:///tmp", "https://user:secret@old.ts.net", "https://old.ts.net/path", "https://old.ts.net?token=x", "https://old.ts.net#fragment"] {
            XCTAssertThrowsError(try RelaySelectionService.candidateURL(dnsName: "host.ts.net", currentURL: origin))
        }
    }
    func testOnlySuccessfulAuthenticatedProbeCommitsNewOrigin() async {
        var saved = "https://old.ts.net:8443"
        var probed = false
        let service = RelaySelectionService(readURL: { saved }, writeURL: { saved = $0 }, readToken: { "public-app-fixture" }, probe: { url, token in
            XCTAssertEqual(saved, "https://old.ts.net:8443", "Must not save before verification")
            XCTAssertEqual(url, "https://host.ts.net:8443")
            XCTAssertEqual(token, "public-app-fixture")
            probed = true
        })
        let success = await service.select(dnsName: "host.ts.net", stillCurrent: { true })
        XCTAssertTrue(success); XCTAssertTrue(probed)
        XCTAssertEqual(saved, "https://host.ts.net:8443")
    }
    func testFailureAndMissingPairingKeepSavedOrigin() async {
        for error in [RelaySelectionError.authentication, .network, .notRelay] {
            var saved = "https://old.ts.net:8443"
            let service = RelaySelectionService(readURL: { saved }, writeURL: { saved = $0 }, readToken: { "public-app-fixture" }, probe: { _, _ in throw error })
            let success = await service.select(dnsName: "host.ts.net", stillCurrent: { true })
            XCTAssertFalse(success); XCTAssertEqual(saved, "https://old.ts.net:8443")
        }
        let service = RelaySelectionService(readURL: { "https://old.ts.net:8443" }, writeURL: { _ in XCTFail("Must preserve origin") }, readToken: { nil }, probe: { _, _ in XCTFail("No credential: do not probe") })
        let success = await service.select(dnsName: "host.ts.net", stillCurrent: { true })
        XCTAssertFalse(success)
    }
    func testChangedConfigurationOrRemovedDeviceCannotCommitLateProbe() async {
        var saved = "https://old.ts.net:8443"
        let service = RelaySelectionService(readURL: { saved }, writeURL: { _ in XCTFail("Do not overwrite a newer selection") }, readToken: { "fixture" }, probe: { _, _ in saved = "https://newer.ts.net:8443" })
        let success = await service.select(dnsName: "host.ts.net", stillCurrent: { true })
        XCTAssertFalse(success); XCTAssertEqual(saved, "https://newer.ts.net:8443")
        let removed = RelaySelectionService(readURL: { saved }, writeURL: { _ in XCTFail("Device disappeared") }, readToken: { "fixture" }, probe: { _, _ in })
        let removedSuccess = await removed.select(dnsName: "host.ts.net", stillCurrent: { false })
        XCTAssertFalse(removedSuccess)
    }
    func testCancelledProbeCannotCommit() async {
        let service = RelaySelectionService(readURL: { "https://old.ts.net:8443" }, writeURL: { _ in XCTFail("Cancelled probe must not commit") }, readToken: { "fixture" }, probe: { _, _ in
            try await Task.sleep(nanoseconds: 10_000_000_000)
        })
        let task = Task { await service.select(dnsName: "host.ts.net", stillCurrent: { true }) }
        while !service.isChecking { await Task.yield() }
        task.cancel()
        let success = await task.value
        XCTAssertFalse(success)
    }
    func testProbeUsesSelectedOriginAndOnlyApplicationCredential() async throws {
        let session = session()
        RelayProbeProtocol.handle = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://host.ts.net:8443/v1/hosts")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer public-app-fixture")
            XCTAssertNil(request.httpBody)
            return (200, #"{"hosts":[{"hostId":"fixture","name":"host","online":true,"lastSeen":1}]}"#)
        }
        try await RelayConnectionProbe(session: session).verify(url: "https://host.ts.net:8443", token: "public-app-fixture")
    }
    func testProbeRejectsAuthFailureRedirectMalformedAndOversizedResponses() async {
        for (status, body) in [(401, "public-app-fixture"), (403, "public-app-fixture"), (302, ""), (404, ""), (200, "{}"), (200, String(repeating: " ", count: 2_097_153))] {
            RelayProbeProtocol.handle = { _ in (status, body) }
            do {
                try await RelayConnectionProbe(session: session()).verify(url: "https://host.ts.net:8443", token: "public-app-fixture")
                XCTFail("Must not accept incompatible response")
            } catch { XCTAssertFalse(error.localizedDescription.contains("public-app-fixture")) }
        }
    }
    func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RelayProbeProtocol.self]
        return URLSession(configuration: config)
    }
    override func tearDown() { RelayProbeProtocol.handle = nil; super.tearDown() }
}
private final class RelayProbeProtocol: URLProtocol {
    static var handle: ((URLRequest) -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let (status, body) = Self.handle?(request) else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
