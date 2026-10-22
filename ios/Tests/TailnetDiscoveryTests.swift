import XCTest
@testable import AgentInbox

final class TailnetDiscoveryTests: XCTestCase {
    func testDemoAndHostedTestsDisableAutomaticNetworkDiscovery() {
        XCTAssertFalse(TailnetRuntime.allowed(arguments: ["AgentInbox", "--demo"], environment: [:]))
        XCTAssertFalse(TailnetRuntime.allowed(arguments: [], environment: ["XCTestConfigurationFilePath": "fixture"]))
        XCTAssertFalse(TailnetRuntime.allowed(arguments: [], environment: ["XCTestBundlePath": "fixture"]))
        XCTAssertTrue(TailnetRuntime.allowed(arguments: ["AgentInbox"], environment: [:]))
    }
    func testSystemDiscoveryHasOnlyTailnetIPHTTPExceptions() throws {
        let widgetURL = try XCTUnwrap(Bundle.main.builtInPlugInsURL).appendingPathComponent("AgentInboxWidget.appex")
        let widget = try XCTUnwrap(Bundle(url: widgetURL))
        for bundle in [Bundle.main, widget] {
            let ats = try XCTUnwrap(bundle.infoDictionary?["NSAppTransportSecurity"] as? [String: Any])
            XCTAssertNotEqual(ats["NSAllowsArbitraryLoads"] as? Bool, true)
            let domains = try XCTUnwrap(ats["NSExceptionDomains"] as? [String: [String: Any]])
            XCTAssertEqual(Set(domains.keys), ["100.64.0.0/10", "fd7a:115c:a1e0::/48"])
            for settings in domains.values { XCTAssertEqual(settings["NSExceptionAllowsInsecureHTTPLoads"] as? Bool, true) }
        }
    }
    func testRealSystemDiscoveryCanReachExplicitReadOnlyFixture() async throws {
        guard let address = ProcessInfo.processInfo.environment["AGENTINBOX_DISCOVERY_FIXTURE_ADDRESS"] else { throw XCTSkip("Requires explicit read-only Tailnet fixture") }
        XCTAssertTrue(DaemonDiscovery.isTailnetAddress(address))
        let config = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let machine = DiscoveredMachine(id: "transport-fixture", name: "transport-fixture", os: "unknown", addresses: [address], online: nil, state: .checking)
        let result = await DaemonDiscovery.probe(machine, session: session)
        XCTAssertEqual(result.state, .pairingRequired)
        XCTAssertEqual(result.daemon?.hostId, "ats-transport-fixture")
    }
    func testDiscoverySeparatesOfflineDenialUnavailableAndNeedsPairing() throws {
        let metadata = Data(#"{"product":"agentinbox","protocolVersion":1,"hostId":"host-1","hostName":"host","os":"linux","version":"0.1.0","relayURL":"https://relay.example.com","schemaVersion":1}"#.utf8)
        XCTAssertEqual(try DaemonDiscovery.classify(status: 200, data: metadata).state, .pairingRequired)
        XCTAssertEqual(try DaemonDiscovery.classify(status: 403, data: Data()).state, .permissionDenied)
        XCTAssertEqual(try DaemonDiscovery.classify(status: 503, data: Data()).state, .serviceUnavailable)
        XCTAssertEqual(try DaemonDiscovery.classify(status: 404, data: Data()).state, .notDetected)
        let wrong = Data(#"{"product":"other","protocolVersion":1,"hostId":"x","hostName":"host","os":"linux","version":"1","relayURL":"https://example.com","schemaVersion":1}"#.utf8)
        XCTAssertThrowsError(try DaemonDiscovery.classify(status: 200, data: wrong))
    }
    func testOnlyTailnetAddressesBecomeProbeTargets() {
        XCTAssertEqual(DaemonDiscovery.probeURL(address: "100.100.1.2")?.absoluteString, "http://100.100.1.2:8788/v1/discovery")
        XCTAssertNotNil(DaemonDiscovery.probeURL(address: "fd7a:115c:a1e0::1"))
        for address in ["127.0.0.1", "192.168.1.1", "example.com", "100.100.1.2@evil.com", "fd7a:115c:a1e0:evil"] {
            XCTAssertNil(DaemonDiscovery.probeURL(address: address))
        }
    }
    func testDiscoveryRejectsCredentialDestinationsAndLoopbackRelay() {
        for origin in ["http://evil.example", "https://user:secret@example.com", "http://127.0.0.1:8787", "https://example.com/path", "https://example.com?token=secret"] {
            XCTAssertFalse(DaemonDiscovery.validRelayOrigin(origin), origin)
        }
        XCTAssertTrue(DaemonDiscovery.validRelayOrigin("https://relay.example.com:8443"))
    }
    func testProbeReportsProtocolIncompatibilityRatherThanNetworkFailure() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DiscoveryHTTPFixture.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let machine = DiscoveredMachine(id: "fixture", name: "fixture", os: "linux", addresses: ["100.100.1.2"], online: true, state: .checking)
        let result = await DaemonDiscovery.probe(machine, session: session)
        XCTAssertEqual(result.state, .incompatible)
        XCTAssertNil(result.daemon)
    }
    func testSystemVPNTransportPreservesAuthenticationStatus() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DiscoveryHTTPFixture.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let network = InboxNetwork(system: session)
        do {
            _ = try await InboxAPI(baseURL: "http://100.100.1.2:8787", token: "fixture-device-key", network: network).hosts()
            XCTFail("Revoked credentials must not appear authorized")
        } catch APIError.httpStatus(401) {} catch { XCTFail("Lost authentication classification: \(error)") }
    }
}

private final class DiscoveryHTTPFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let discovery = request.url?.path == "/v1/discovery"
        let version = request.url?.host == "100.100.1.3" ? 1 : 99
        let body = discovery ? "{\"product\":\"agentinbox\",\"protocolVersion\":\(version),\"schemaVersion\":1,\"hostId\":\"fixture\",\"hostName\":\"fixture\",\"os\":\"linux\",\"version\":\"1\",\"relayURL\":\"https://relay.example.com\"}" : "{}"
        let status = discovery ? (request.value(forHTTPHeaderField: "Authorization") == nil ? 200 : 403) : 401
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
