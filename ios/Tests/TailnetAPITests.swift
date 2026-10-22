import XCTest
@testable import AgentInbox

final class TailnetAPITests: XCTestCase {
    let credential = try! TailnetAPICredentials(tailnetID: "TfixtureCNTRL", clientSecret: "tskey-client-fixture-secret")
    func api() -> TailnetAPI {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TailnetAPIProtocol.self]
        return TailnetAPI(session: URLSession(configuration: config))
    }
    override func tearDown() { TailnetAPIProtocol.handle = nil; super.tearDown() }
    func testDeviceNotFoundExplainsTailnetIDWithoutEchoingServerBody() async throws {
        TailnetAPIProtocol.handle = { request in
            if request.url?.path == "/api/v2/oauth/token" {
                return (200, #"{"access_token":"fixture-access","token_type":"Bearer","expires_in":3600}"#)
            }
            return (404, "tskey-client-fixture-secret")
        }
        do { _ = try await api().devices(credentials: credential); XCTFail("Unknown tailnet must fail") }
        catch {
            XCTAssertTrue(error.localizedDescription.contains("Tailnet ID"))
            XCTAssertTrue(error.localizedDescription.contains("Client ID"))
            XCTAssertFalse(error.localizedDescription.contains("tskey-"))
        }
    }
    func testTokenEndpointNotFoundDoesNotMisidentifyTailnet() async throws {
        TailnetAPIProtocol.handle = { _ in (404, "tskey-client-fixture-secret") }
        do { _ = try await api().devices(credentials: credential); XCTFail("Missing endpoint must fail") }
        catch {
            XCTAssertFalse(error.localizedDescription.contains("Tailnet ID"))
            XCTAssertFalse(error.localizedDescription.contains("tskey-"))
        }
    }
    func testRejectsUnsafeTailnetIDsAndNonClientCredentials() throws {
        for id in ["", "../x", "a/b", "a?fields=all", "https://example.com", "a#b", "a\nb", "-"] {
            XCTAssertThrowsError(try TailnetAPICredentials(tailnetID: id, clientSecret: "tskey-client-fixture-secret"))
        }
        XCTAssertThrowsError(try TailnetAPICredentials(tailnetID: "Tfixture", clientSecret: "tskey-auth-fixture"))
    }
    func testReadOnlyExchangeCachesTokenAndMapsStableIdentity() async throws {
        var exchanges = 0; var reads = 0
        TailnetAPIProtocol.handle = { request in
            XCTAssertEqual(request.url?.scheme, "https"); XCTAssertEqual(request.url?.host, "api.tailscale.com")
            if request.url?.path == "/api/v2/oauth/token" {
                exchanges += 1; XCTAssertEqual(request.httpMethod, "POST")
                let body = TailnetAPIProtocol.body(request)
                XCTAssertTrue(body.contains("scope=devices%3Acore%3Aread"))
                XCTAssertTrue(body.contains("client_secret=tskey-client-fixture-secret"))
                XCTAssertFalse(body.contains("auth_keys")); XCTAssertFalse(body.contains("tags="))
                return (200, #"{"access_token":"fixture-access","token_type":"Bearer","expires_in":3600,"scope":"devices:core:read"}"#)
            }
            reads += 1
            XCTAssertEqual(request.url?.path, "/api/v2/tailnet/TfixtureCNTRL/devices")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-access")
            XCTAssertNil(request.httpBody)
            return (200, #"{"devices":[{"id":"123","nodeId":"nStable","hostname":"renamed","name":"renamed.tailfixture.ts.net","addresses":["100.100.1.3"],"os":"linux","clientVersion":"1.104.1","connectedToControl":false}]}"#)
        }
        let client = api()
        let first = try await client.devices(credentials: credential)
        _ = try await client.devices(credentials: credential)
        XCTAssertEqual(exchanges, 1); XCTAssertEqual(reads, 2)
        XCTAssertEqual(first.first?.id, "nStable")
        XCTAssertEqual(first.first?.name, "renamed")
        XCTAssertEqual(first.first?.os, "linux")
        XCTAssertEqual(first.first?.clientVersion, "1.104.1")
        XCTAssertEqual(first.first?.connectedToControl, false)
    }
    func testUnauthorizedReadRenewsOnlyOnceAndErrorsNeverEchoSecrets() async throws {
        var exchanges = 0; var reads = 0
        TailnetAPIProtocol.handle = { request in
            if request.url?.path == "/api/v2/oauth/token" {
                exchanges += 1
                return (200, #"{"access_token":"fixture-access","token_type":"Bearer","expires_in":3600}"#)
            }
            reads += 1
            return (401, "tskey-client-fixture-secret")
        }
        do { _ = try await api().devices(credentials: credential); XCTFail("Must reject revoked access") }
        catch { XCTAssertFalse(error.localizedDescription.contains("tskey-")) }
        XCTAssertEqual(exchanges, 2); XCTAssertEqual(reads, 2)
    }
    func testInvalidationDuringTokenExchangeCannotRestoreTokenOrReadDevices() async throws {
        let started = expectation(description: "exchange started")
        let release = DispatchSemaphore(value: 0)
        var reads = 0
        TailnetAPIProtocol.handle = { request in
            if request.url?.path == "/api/v2/oauth/token" {
                started.fulfill(); _ = release.wait(timeout: .now() + 10)
                return (200, #"{"access_token":"fixture-access","token_type":"Bearer","expires_in":3600}"#)
            }
            reads += 1; return (200, #"{"devices":[]}"#)
        }
        let client = api()
        let operation = Task { try await client.devices(credentials: credential) }
        await fulfillment(of: [started], timeout: 5)
        await client.invalidate(); release.signal()
        do { _ = try await operation.value; XCTFail("Invalidated exchange must not continue") } catch {}
        XCTAssertEqual(reads, 0)
    }
    func testExpiringTokenRenewsBeforeNextDeviceRead() async throws {
        var date = Date(timeIntervalSince1970: 1_000); var exchanges = 0
        TailnetAPIProtocol.handle = { request in
            if request.url?.path == "/api/v2/oauth/token" {
                exchanges += 1; return (200, #"{"access_token":"fixture-access","token_type":"Bearer","expires_in":3600}"#)
            }
            return (200, #"{"devices":[]}"#)
        }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [TailnetAPIProtocol.self]
        let client = TailnetAPI(session: URLSession(configuration: config), now: { date })
        _ = try await client.devices(credentials: credential)
        date = date.addingTimeInterval(3550)
        _ = try await client.devices(credentials: credential)
        XCTAssertEqual(exchanges, 2)
    }
    func testPermissionRateLimitMalformedAndOversizedResponsesAreRejected() async throws {
        for status in [403, 429, 500, 302] {
            TailnetAPIProtocol.handle = { _ in (status, "tskey-client-fixture-secret") }
            do { _ = try await api().devices(credentials: credential); XCTFail("Must reject HTTP status") }
            catch { XCTAssertFalse(error.localizedDescription.contains("tskey-")) }
        }
        for response in [#"{"devices":[{"nodeId":"n","hostname":"bad","addresses":["127.0.0.1"]}]}"#, String(repeating: " ", count: 2_100_000)] {
            TailnetAPIProtocol.handle = { request in
                if request.url?.path == "/api/v2/oauth/token" { return (200, #"{"access_token":"fixture","token_type":"Bearer","expires_in":3600}"#) }
                return (200, response)
            }
            do { _ = try await api().devices(credentials: credential); XCTFail("Must reject invalid response") } catch {}
        }
    }
}

private final class TailnetAPIProtocol: URLProtocol {
    static var handle: ((URLRequest) throws -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    static func body(_ request: URLRequest) -> String {
        if let data = request.httpBody { return String(decoding: data, as: UTF8.self) }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open(); defer { stream.close() }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n)) }
        return String(decoding: data, as: UTF8.self)
    }
    override func startLoading() {
        do {
            guard let handle = Self.handle else { throw URLError(.badServerResponse) }
            let (status, text) = try handle(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8)); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
