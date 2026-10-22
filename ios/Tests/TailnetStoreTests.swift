import XCTest
@testable import AgentInbox

final class TailnetStoreTests: XCTestCase {
    let raw = #"{"schemaVersion":1,"account":"fixture@example.com","connected":true,"devices":[{"id":"node","name":"fixture","ipv4Address":"100.100.1.3","isOnline":false}]}"#
    func storage() -> TailnetImportStorage { .init(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)) }
    @MainActor func testPreviewDoesNotPersistAndCancellationDoesNotChangeDevices() throws {
        let disk = storage(); defer { try? FileManager.default.removeItem(at: disk.directory) }
        let store = TailnetStore(storage: disk)
        try store.prepareImport(raw)
        XCTAssertTrue(store.machines.isEmpty)
        XCTAssertNil(try disk.load())
        store.cancelImport()
        XCTAssertNil(store.pendingImport)
        XCTAssertFalse(store.presentImport)
    }
    @MainActor func testShortcutIntentOpensPreviewWithoutPersisting() async throws {
        let store = TailnetStore.shared
        let previous = store.machines.map(\.id)
        defer { store.cancelImport() }
        var intent = ImportTailnetDevicesIntent()
        intent.snapshotJSON = raw
        _ = try await intent.perform()
        XCTAssertTrue(store.presentImport)
        XCTAssertEqual(store.pendingImport?.account, "fixture@example.com")
        XCTAssertEqual(store.machines.map(\.id), previous)
        intent.snapshotJSON = "{}"
        do { _ = try await intent.perform(); XCTFail("Invalid shortcut input must be rejected") } catch {}
        XCTAssertNil(store.pendingImport)
        XCTAssertEqual(store.machines.map(\.id), previous)
    }
    @MainActor func testInvalidImportAndStorageFailurePreserveExistingCatalog() throws {
        let disk = storage(); defer { try? FileManager.default.removeItem(at: disk.directory) }
        let store = TailnetStore(storage: disk)
        try store.prepareImport(raw); try store.confirmImport()
        let id = store.machines[0].id
        XCTAssertThrowsError(try store.prepareImport("{}"))
        XCTAssertEqual(store.machines.first?.id, id)
        // Force an actual file error, not a mocked success/failure branch.
        try FileManager.default.removeItem(at: disk.directory)
        try Data().write(to: disk.directory)
        try store.prepareImport(raw.replacingOccurrences(of: "fixture@example.com", with: "other@example.com"))
        XCTAssertThrowsError(try store.confirmImport())
        XCTAssertEqual(store.machines.first?.id, id)
    }
    @MainActor func testRefreshProbesOfflineSnapshotAndAuthenticatesOnlySavedOrigin() async throws {
        let disk = storage(); defer { try? FileManager.default.removeItem(at: disk.directory) }
        var calls = 0
        var origin = "https://other.example.com"
        let store = TailnetStore(storage: disk, probe: { _ in .init(state: .pairingRequired, daemon: Self.daemon) }, readCredential: { "fixture-credential" }, configuredRelay: { origin }, authorizedHosts: { calls += 1; return [.init(hostId: "fixture", name: "fixture", online: true, lastSeen: 0)] })
        try store.prepareImport(raw); try store.confirmImport()
        await store.refresh()
        XCTAssertEqual(store.machines.first?.state, .pairingRequired)
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(store.machines.first?.os, "linux")
        origin = "https://relay.example.com"
        await store.refresh()
        XCTAssertEqual(store.machines.first?.state, .paired)
        XCTAssertEqual(calls, 1)
    }
    @MainActor func testRevokedPairingAndMissingHeartbeatAreDifferentStates() async throws {
        for denied in [true, false] {
            let disk = storage(); defer { try? FileManager.default.removeItem(at: disk.directory) }
            let store = TailnetStore(storage: disk, probe: { _ in .init(state: .pairingRequired, daemon: Self.daemon) }, readCredential: { "fixture" }, configuredRelay: { "https://relay.example.com" }, authorizedHosts: {
                if denied { throw APIError.httpStatus(401) }; return []
            })
            try store.prepareImport(raw); try store.confirmImport(); await store.refresh()
            XCTAssertEqual(store.machines.first?.state, denied ? .permissionDenied : .awaitingHeartbeat)
        }
    }
    @MainActor func testClearWinsOverInFlightProbe() async throws {
        let gate = ProbeGate()
        let disk = storage(); defer { try? FileManager.default.removeItem(at: disk.directory) }
        let store = TailnetStore(storage: disk, probe: { _ in await gate.run() })
        try store.prepareImport(raw); try store.confirmImport()
        let refresh = Task { await store.refresh() }
        await gate.waitForStart()
        try store.clear()
        await gate.finish()
        await refresh.value
        XCTAssertTrue(store.machines.isEmpty)
        XCTAssertNil(try disk.load())
    }
    @MainActor func testReplacementWinsOverOldProbeResult() async throws {
        let gate = ProbeGate()
        let disk = storage(); defer { try? FileManager.default.removeItem(at: disk.directory) }
        let store = TailnetStore(storage: disk, probe: { _ in await gate.run() })
        try store.prepareImport(raw); try store.confirmImport()
        let refresh = Task { await store.refresh() }
        await gate.waitForStart()
        try store.prepareImport(raw.replacingOccurrences(of: "fixture@example.com", with: "other@example.com")); try store.confirmImport()
        await gate.finish(); await refresh.value
        XCTAssertEqual(store.account, "other@example.com")
        XCTAssertNil(store.machines.first?.daemon)
    }
    static var daemon: DaemonDescriptor {
        try! JSONDecoder().decode(DaemonDescriptor.self, from: Data(#"{"product":"agentinbox","protocolVersion":1,"schemaVersion":1,"hostId":"fixture","hostName":"fixture","os":"linux","version":"1","relayURL":"https://relay.example.com"}"#.utf8))
    }
}
private actor ProbeGate {
    var started = false
    var waiter: CheckedContinuation<Void, Never>?
    var continuation: CheckedContinuation<DaemonProbeResult, Never>?
    func run() async -> DaemonProbeResult {
        await withCheckedContinuation { continuation = $0; started = true; waiter?.resume(); waiter = nil }
    }
    func waitForStart() async { if !started { await withCheckedContinuation { waiter = $0 } } }
    func finish() { continuation?.resume(returning: .init(state: .pairingRequired, daemon: TailnetStoreTests.daemon)); continuation = nil }
}
