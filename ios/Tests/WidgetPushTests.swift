import XCTest
@testable import AgentInbox

final class FalseSynchronizeWidgetDefaults: UserDefaults, @unchecked Sendable {
    override func synchronize() -> Bool { false }
}
actor WidgetTokenTransportFixture {
    var bodies: [WidgetTokenRegistration] = []
    var failures = 0
    var revision: Int64 = 0
    var gateFirst = false
    var gate: CheckedContinuation<Void, Never>?
    init(failures: Int = 0, gateFirst: Bool = false) { self.failures = failures; self.gateFirst = gateFirst }
    func send(_ body: WidgetTokenRegistration) async throws {
        bodies.append(body)
        if gateFirst && bodies.count == 1 { await withCheckedContinuation { gate = $0 } }
        if failures > 0 { failures -= 1; throw URLError(.notConnectedToInternet) }
        revision = max(revision, body.registrationRevision)
    }
    func serverRevision() -> Int64 { revision }
    func failNext() { failures += 1 }
    func count() -> Int { bodies.count }
    func snapshot() -> [WidgetTokenRegistration] { bodies }
    func release() { gate?.resume(); gate = nil }
}
actor WidgetConflictFixture {
    var highest: Int64 = 1
    var bodies: [WidgetTokenRegistration] = []
    func readRevision() -> Int64 { highest }
    func send(_ body: WidgetTokenRegistration) throws {
        bodies.append(body)
        if bodies.count == 1 { highest = 2; throw WidgetPushRegistrationError.conflict }
        highest = body.registrationRevision
    }
    func revisions() -> [Int64] { bodies.map(\.registrationRevision) }
}
actor WidgetUnknownThenConflictFixture {
    var highest: Int64 = 0
    var bodies: [WidgetTokenRegistration] = []
    func readRevision() -> Int64 { highest }
    func send(_ body: WidgetTokenRegistration) throws {
        bodies.append(body)
        highest = max(highest, body.registrationRevision)
        if bodies.count == 2 { throw URLError(.timedOut) }
        if bodies.count == 3 { throw WidgetPushRegistrationError.conflict }
    }
    func revisions() -> [Int64] { bodies.map(\.registrationRevision) }
}
final class WidgetPendingFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var value: WidgetTokenRegistrationPending?
    func read() -> WidgetTokenRegistrationPending? { lock.lock(); defer { lock.unlock() }; return value }
    func save(_ value: WidgetTokenRegistrationPending?) { lock.lock(); defer { lock.unlock() }; self.value = value }
}
actor WidgetOSSnapshotFixture {
    var value: WidgetTokenRegistration
    init(_ value: WidgetTokenRegistration) { self.value = value }
    func set(_ value: WidgetTokenRegistration) { self.value = value }
    func get() -> WidgetTokenRegistration { value }
}
final class WidgetPushTests: XCTestCase {
    let tokenA = String(repeating: "a", count: 64)
    let tokenB = String(repeating: "b", count: 64)
    let tokenC = String(repeating: "c", count: 64)
    let deviceKey = "public-nonauthorizing-existing-device-key-fixture"
    func defaults() -> UserDefaults { UserDefaults(suiteName: "AgentInbox.WidgetPushTests.\(UUID().uuidString)")! }
    func coordinator(_ transport: WidgetTokenTransportFixture, defaults: UserDefaults? = nil, widgetSecret: @escaping (String?) throws -> Void = { _ in }) -> WidgetPushCoordinator {
        WidgetPushCoordinator(defaults: defaults ?? self.defaults(), readDeviceKey: { self.deviceKey }, readStoredWidgetToken: { nil }, saveWidgetToken: widgetSecret, send: { _, _, body in try await transport.send(body) })
    }
    func candidate(_ token: String, active: Bool = true) -> WidgetTokenRegistration { .init(token: token, environment: "sandbox", active: active) }
    func testRegistrationJSONIncludesDistinctTokenEnvironmentAndActive() throws {
        let body = candidate(tokenA, active: false)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as! [String: Any]
        XCTAssertEqual(Set(json.keys), ["token", "environment", "active", "registrationRevision"])
        XCTAssertEqual(json["active"] as? Bool, false)
        XCTAssertEqual(json["registrationRevision"] as? Int64, 1)
        XCTAssertEqual(json["environment"] as? String, "sandbox")
        XCTAssertTrue(json["token"] as? String == tokenA)
    }
    func testAuthenticatedRequestUsesWidgetRouteAndPreservesDeviceAuthorization() throws {
        let api = InboxAPI(baseURL: "https://relay.example.ts.net:8443", token: deviceKey)
        let request = try api.widgetTokenRegistrationRequest(candidate(tokenA))
        XCTAssertEqual(request.url?.path, "/v1/devices/widget-token")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(deviceKey)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 12)
    }
    func testMissingIdentityAndInvalidTokenOrEnvironmentRejectBeforeNetworking() throws {
        XCTAssertThrowsError(try InboxAPI(baseURL: "https://relay.example.ts.net:8443", token: nil).widgetTokenRegistrationRequest(candidate(tokenA)))
        let api = InboxAPI(baseURL: "https://relay.example.ts.net:8443", token: deviceKey)
        for token in ["", "not-hex", String(repeating: "a", count: 31), String(repeating: "a", count: 257)] { XCTAssertThrowsError(try api.widgetTokenRegistrationRequest(candidate(token))) }
        XCTAssertThrowsError(try api.widgetTokenRegistrationRequest(.init(token: tokenA, environment: "wrong", active: true)))
    }
    func testNilPushInfoDoesNotDeactivateAnActiveWidget() {
        XCTAssertNil(WidgetTokenRegistration.resolve(currentToken: nil, storedToken: tokenA, hasWidget: true, environment: "sandbox"))
        XCTAssertNil(WidgetTokenRegistration.resolve(currentToken: nil, storedToken: tokenA, hasWidget: nil, environment: "sandbox"))
        XCTAssertEqual(WidgetTokenRegistration.resolve(currentToken: nil, storedToken: tokenA, hasWidget: false, environment: "sandbox"), candidate(tokenA, active: false))
    }
    func testSameRegistrationIsDeduplicatedAcrossCoordinatorInstances() async throws {
        let transport = WidgetTokenTransportFixture(), storage = defaults()
        _ = await coordinator(transport, defaults: storage).update(candidate(tokenA), serverURL: "https://relay.example", observedAt: 100)
        _ = await coordinator(transport, defaults: storage).update(candidate(tokenA), serverURL: "https://relay.example", observedAt: 101)
        let calls = await transport.count(); XCTAssertEqual(calls, 1)
    }
    func testFailureBackoffDoesNotSaveTokenOrChangeExistingDeviceKey() async throws {
        let transport = WidgetTokenTransportFixture(failures: 1), storage = defaults()
        var saved: String?
        let registrar = coordinator(transport, defaults: storage, widgetSecret: { saved = $0 })
        let failed = await registrar.update(candidate(tokenA), serverURL: "https://relay.example", observedAt: 100, now: 100)
        XCTAssertEqual(failed, .retryLater); XCTAssertNil(saved)
        _ = await registrar.update(candidate(tokenA), serverURL: "https://relay.example", observedAt: 101, now: 101)
        let before = await transport.count(); XCTAssertEqual(before, 1)
        _ = await registrar.update(candidate(tokenA), serverURL: "https://relay.example", observedAt: 140, now: 140)
        let after = await transport.count(); XCTAssertEqual(after, 2)
        XCTAssertTrue(saved == tokenA); XCTAssertEqual(deviceKey, "public-nonauthorizing-existing-device-key-fixture")
    }
    func testActiveChangeAndTokenRotationEachRegisterButSameSnapshotDoesNot() async throws {
        let transport = WidgetTokenTransportFixture(), registrar = coordinator(transport)
        for (index, value) in [candidate(tokenA), candidate(tokenA, active: false), candidate(tokenB, active: false), candidate(tokenB, active: false)].enumerated() {
            _ = await registrar.update(value, serverURL: "https://relay.example", observedAt: Double(100 + index))
        }
        let bodies = await transport.snapshot(); XCTAssertEqual(bodies.count, 3)
        guard bodies.count == 3 else { return }
        XCTAssertFalse(bodies[1].active); XCTAssertTrue(bodies[2].token == tokenB)
    }
    func testConcurrentUpdatesCoalesceNewestSnapshotAndRejectOldObservations() async throws {
        let transport = WidgetTokenTransportFixture(gateFirst: true), registrar = coordinator(transport)
        let initial = Task { await registrar.update(self.candidate(self.tokenA), serverURL: "https://relay.example", observedAt: 100) }
        for _ in 0..<100 { if await transport.count() == 1 { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        _ = await registrar.update(candidate(tokenB), serverURL: "https://relay.example", observedAt: 101)
        _ = await registrar.update(candidate(tokenC, active: false), serverURL: "https://relay.example", observedAt: 102)
        _ = await registrar.update(candidate(tokenB), serverURL: "https://relay.example", observedAt: 99)
        await transport.release(); _ = await initial.value
        let bodies = await transport.snapshot(); XCTAssertEqual(bodies.count, 2)
        XCTAssertTrue(bodies.last?.token == tokenC); XCTAssertEqual(bodies.last?.active, false)
    }
    func testUnpairedDeviceCannotRegisterOrCreateReplacementIdentity() async throws {
        let transport = WidgetTokenTransportFixture()
        let registrar = WidgetPushCoordinator(defaults: defaults(), readDeviceKey: { nil }, readStoredWidgetToken: { nil }, saveWidgetToken: { _ in }, send: { _, _, body in try await transport.send(body) })
        let status = await registrar.update(candidate(tokenA), serverURL: "https://relay.example", observedAt: 100)
        XCTAssertEqual(status, .unpaired)
        let calls = await transport.count(); XCTAssertEqual(calls, 0)
    }
    func testUploadLeaseSerializesSeparateFileDescriptionsAndReleases() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try WidgetPushUploadLease.acquire(in: directory)
        XCTAssertThrowsError(try WidgetPushUploadLease.acquire(in: directory))
        first.release()
        let next = try WidgetPushUploadLease.acquire(in: directory)
        next.release()
    }

    func testUnknownRegistrationRetryRetainsExactRevisionAndBody() async throws {
        let transport = WidgetTokenTransportFixture(failures: 1), pending = WidgetPendingFixture()
        let registrar = WidgetPushCoordinator(defaults: defaults(), readDeviceKey: { self.deviceKey }, readStoredWidgetToken: { nil }, saveWidgetToken: { _ in }, readServerRevision: { _, _ in 0 }, readPending: { pending.read() }, savePending: { pending.save($0) }, send: { _, _, body in try await transport.send(body) })
        _ = await registrar.update(candidate(tokenA), serverURL: "https://relay.example", observedAt: 100, now: 100)
        XCTAssertNotNil(pending.read())
        _ = await registrar.update(candidate(tokenA), serverURL: "https://relay.example", observedAt: 140, now: 140)
        let bodies = await transport.snapshot(); XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies.first, bodies.last)
        XCTAssertNil(pending.read())
    }
    func testServerRevisionIsReadAndLocalCounterAllocatesMonotonically() async throws {
        let transport = WidgetTokenTransportFixture()
        let registrar = WidgetPushCoordinator(defaults: defaults(), readDeviceKey: { self.deviceKey }, readStoredWidgetToken: { nil }, saveWidgetToken: { _ in }, readServerRevision: { _, _ in 41 }, send: { _, _, body in try await transport.send(body) })
        _ = await registrar.update(candidate(tokenA), serverURL: "https://relay.example", observedAt: 100)
        _ = await registrar.update(candidate(tokenB), serverURL: "https://relay.example", observedAt: 101)
        let bodies = await transport.snapshot(); XCTAssertEqual(bodies.map(\.registrationRevision), [42, 43])
    }
    func testRevisionExhaustionStopsBeforePostOrPendingCredentialWrite() async throws {
        let transport = WidgetTokenTransportFixture()
        let registrar = WidgetPushCoordinator(defaults: defaults(), readDeviceKey: { self.deviceKey }, readStoredWidgetToken: { nil }, saveWidgetToken: { _ in XCTFail("Must not save") }, readServerRevision: { _, _ in Int64.max }, savePending: { _ in XCTFail("Must not save pending at exhaustion") }, send: { _, _, body in try await transport.send(body) })
        let status = await registrar.update(candidate(tokenA), serverURL: "https://relay.example", observedAt: 100)
        XCTAssertEqual(status, .retryLater)
        let calls = await transport.count(); XCTAssertEqual(calls, 0)
    }
    func testRevisionGetRequestUsesSameDeviceAuthWithoutUploadingAToken() throws {
        let request = try InboxAPI(baseURL: "https://relay.example", token: deviceKey).widgetTokenRevisionRequest()
        XCTAssertEqual(request.httpMethod, "GET"); XCTAssertEqual(request.url?.path, "/v1/devices/widget-token")
        XCTAssertNil(request.httpBody); XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(deviceKey)")
        for revision in [Int64(0), Int64(-1)] { XCTAssertThrowsError(try InboxAPI(baseURL: "https://relay.example", token: deviceKey).widgetTokenRegistrationRequest(.init(token: tokenA, environment: "sandbox", registrationRevision: revision))) }
    }
    func testIndependentCoordinatorsShareLeaseAndResampleLatestOSAfterOlderUpload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = WidgetTokenTransportFixture(gateFirst: true), storage = defaults(), pending = WidgetPendingFixture()
        let os = WidgetOSSnapshotFixture(candidate(tokenA, active: false))
        func registrar() -> WidgetPushCoordinator {
            WidgetPushCoordinator(defaults: storage, readDeviceKey: { self.deviceKey }, readStoredWidgetToken: { nil }, saveWidgetToken: { _ in }, acquireLease: { try await WidgetPushUploadLease.acquireEventually(in: directory) }, resample: { await os.get() }, readServerRevision: { _, _ in await transport.serverRevision() }, readPending: { pending.read() }, savePending: { pending.save($0) }, send: { _, _, body in try await transport.send(body) })
        }
        let first = registrar(), second = registrar()
        let older = Task { await first.update(self.candidate(self.tokenA, active: false), serverURL: "https://relay.example", observedAt: 100) }
        for _ in 0..<100 { if await transport.count() == 1 { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        await os.set(candidate(tokenB, active: true))
        // Deliberately pass a stale snapshot: the second process must replace it AFTER its lease.
        let newer = Task { await second.update(self.candidate(self.tokenA, active: false), serverURL: "https://relay.example", observedAt: 101) }
        try await Task.sleep(nanoseconds: 30_000_000)
        let blockedCount = await transport.count(); XCTAssertEqual(blockedCount, 1)
        await transport.release(); _ = await older.value; _ = await newer.value
        let bodies = await transport.snapshot(); XCTAssertEqual(bodies.count, 2)
        XCTAssertTrue(bodies.last?.token == tokenB); XCTAssertEqual(bodies.last?.active, true)
        XCTAssertEqual(bodies.map(\.registrationRevision), [1, 2])
    }

    func testUnknownDifferentSnapshotCannotBeHiddenByAnOldSuccessFingerprint() async throws {
        let transport = WidgetTokenTransportFixture(), pending = WidgetPendingFixture()
        let registrar = WidgetPushCoordinator(defaults: defaults(), readDeviceKey: { self.deviceKey }, readStoredWidgetToken: { nil }, saveWidgetToken: { _ in }, readServerRevision: { _, _ in await transport.serverRevision() }, readPending: { pending.read() }, savePending: { pending.save($0) }, send: { _, _, body in try await transport.send(body) })
        _ = await registrar.update(candidate(tokenA, active: true), serverURL: "https://relay.example", observedAt: 100, now: 100)
        await transport.failNext()
        _ = await registrar.update(candidate(tokenA, active: false), serverURL: "https://relay.example", observedAt: 101, now: 101)
        XCTAssertNotNil(pending.read())
        _ = await registrar.update(candidate(tokenA, active: true), serverURL: "https://relay.example", observedAt: 102, now: 102)
        let bodies = await transport.snapshot(); XCTAssertEqual(bodies.count, 3)
        XCTAssertEqual(bodies.map(\.registrationRevision), [1, 2, 3])
        XCTAssertEqual(bodies.last?.active, true)
        XCTAssertNil(pending.read())
    }

    func testConflictRefreshesServerRevisionRatherThanRetryingConflictingPendingBody() async throws {
        let server = WidgetConflictFixture(), pending = WidgetPendingFixture()
        let registrar = WidgetPushCoordinator(defaults: defaults(), readDeviceKey: { self.deviceKey }, readStoredWidgetToken: { nil }, saveWidgetToken: { _ in }, readServerRevision: { _, _ in await server.readRevision() }, readPending: { pending.read() }, savePending: { pending.save($0) }, send: { _, _, body in try await server.send(body) })
        _ = await registrar.update(candidate(tokenA), serverURL: "https://relay.example", observedAt: 100, now: 100)
        _ = await registrar.update(candidate(tokenA), serverURL: "https://relay.example", observedAt: 140, now: 140)
        let revisions = await server.revisions(); XCTAssertEqual(revisions, [2, 3])
    }

    func testConflictAfterUnknownForcesResyncInsteadOfRestoringAnOlderSuccessCache() async throws {
        let server = WidgetUnknownThenConflictFixture(), pending = WidgetPendingFixture()
        let registrar = WidgetPushCoordinator(defaults: defaults(), readDeviceKey: { self.deviceKey }, readStoredWidgetToken: { nil }, saveWidgetToken: { _ in }, readServerRevision: { _, _ in await server.readRevision() }, readPending: { pending.read() }, savePending: { pending.save($0) }, send: { _, _, body in try await server.send(body) })
        _ = await registrar.update(candidate(tokenA), serverURL: "https://relay.example", observedAt: 100, now: 100)
        _ = await registrar.update(candidate(tokenA, active: false), serverURL: "https://relay.example", observedAt: 101, now: 101)
        _ = await registrar.update(candidate(tokenA), serverURL: "https://relay.example", observedAt: 102, now: 102)
        _ = await registrar.update(candidate(tokenA), serverURL: "https://relay.example", observedAt: 140, now: 140)
        let revisions = await server.revisions(); XCTAssertEqual(revisions, [1, 2, 3, 4])
    }

    func testDebugDiagnosticLocatesPendingKeychainFailureWithoutSecretOrDescription() async throws {
        let storage = defaults(), transport = WidgetTokenTransportFixture()
        let registrar = WidgetPushCoordinator(defaults: storage, readDeviceKey: { self.deviceKey }, readStoredWidgetToken: { nil }, saveWidgetToken: { _ in XCTFail("Must not confirm") }, savePending: { _ in throw NSError(domain: NSOSStatusErrorDomain, code: -34018, userInfo: [NSLocalizedDescriptionKey: "PUBLIC_FIXTURE_DESCRIPTION_MUST_NOT_BE_RECORDED"]) }, send: { _, _, body in try await transport.send(body) })
        let status = await registrar.update(candidate(tokenA), serverURL: "https://relay.example", observedAt: 100)
        XCTAssertEqual(status, .retryLater)
        let diagnostic = try XCTUnwrap(storage.dictionary(forKey: "widgetPushRegistrationDiagnostic.\(getpid())"))
        let failure = try XCTUnwrap(diagnostic["lastFailure"] as? [String: Any])
        XCTAssertEqual(failure["stage"] as? String, "savePending")
        XCTAssertEqual(failure["category"] as? String, "keychain")
        XCTAssertEqual(failure["osStatus"] as? Int, -34018)
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: diagnostic), as: UTF8.self)
        for forbidden in [tokenA, deviceKey, "PUBLIC_FIXTURE_DESCRIPTION_MUST_NOT_BE_RECORDED", "fingerprint", "body"] { XCTAssertFalse(encoded.contains(forbidden)) }
        let calls = await transport.count(); XCTAssertEqual(calls, 0)
    }

    func testCounterSynchronizationFalseStillPersistsExactPendingBeforeOnePost() async throws {
        let storage = FalseSynchronizeWidgetDefaults(suiteName: "AgentInbox.FalseSync.\(UUID().uuidString)")!
        let transport = WidgetTokenTransportFixture(), pending = WidgetPendingFixture()
        var order: [String] = []
        let registrar = WidgetPushCoordinator(defaults: storage, readDeviceKey: { self.deviceKey }, readStoredWidgetToken: { nil }, saveWidgetToken: { _ in order.append("confirmToken") }, readServerRevision: { _, _ in 41 }, readPending: { pending.read() }, savePending: { value in pending.save(value); order.append(value == nil ? "clearPending" : "savePending") }, send: { _, _, body in
            XCTAssertEqual(pending.read()?.body, body, "Durable pending must exist before the first HTTP attempt")
            order.append("post")
            try await transport.send(body)
        })
        let status = await registrar.update(candidate(tokenA), serverURL: "https://relay.example", observedAt: 100)
        XCTAssertEqual(status, .registered)
        XCTAssertEqual(order, ["savePending", "post", "confirmToken", "clearPending"])
        let bodies = await transport.snapshot(); XCTAssertEqual(bodies.count, 1)
        XCTAssertEqual(bodies.first?.registrationRevision, 42)
        XCTAssertNil(pending.read())
        let diagnostic = try XCTUnwrap(storage.dictionary(forKey: "widgetPushRegistrationDiagnostic.\(getpid())"))
        XCTAssertEqual(diagnostic["counterSynchronizationReturned"] as? Bool, false)
    }
    func testCounterSynchronizationFalseDoesNotBypassPendingKeychainFailure() async throws {
        let storage = FalseSynchronizeWidgetDefaults(suiteName: "AgentInbox.FalseSyncFailure.\(UUID().uuidString)")!
        let transport = WidgetTokenTransportFixture()
        let registrar = WidgetPushCoordinator(defaults: storage, readDeviceKey: { self.deviceKey }, readStoredWidgetToken: { nil }, saveWidgetToken: { _ in XCTFail("Must not confirm") }, savePending: { _ in throw NSError(domain: NSOSStatusErrorDomain, code: -34018) }, send: { _, _, body in try await transport.send(body) })
        let status = await registrar.update(candidate(tokenA), serverURL: "https://relay.example", observedAt: 100)
        XCTAssertEqual(status, .retryLater)
        let calls = await transport.count(); XCTAssertEqual(calls, 0)
        let diagnostic = try XCTUnwrap(storage.dictionary(forKey: "widgetPushRegistrationDiagnostic.\(getpid())"))
        let failure = try XCTUnwrap(diagnostic["lastFailure"] as? [String: Any])
        XCTAssertEqual(failure["stage"] as? String, "savePending")
        XCTAssertEqual(failure["osStatus"] as? Int, -34018)
    }

}
