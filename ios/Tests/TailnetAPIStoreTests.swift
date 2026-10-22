import XCTest
@testable import AgentInbox

@MainActor
final class TailnetAPIStoreTests: XCTestCase {
    func testLinkPersistsAssociationAndAPIMetadataWhilePreservingApplicationIdentity() async throws {
        let repo = MemoryTailnetCredentialRepository()
        let disk = storage(); defer { try? FileManager.default.removeItem(at: disk.directory) }
        let store = TailnetStore(storage: disk, probe: { _ in .init(state: .unreachable) }, readCredential: { "existing-app-key" }, credentialRepository: repo, fetchDevices: { _ in [Self.device] })
        await store.linkAPI(tailnetID: "Tfixture", clientSecret: "tskey-client-fixture-secret")
        XCTAssertEqual(repo.value?.tailnetID, "Tfixture")
        XCTAssertEqual(store.apiTailnetID, "Tfixture")
        XCTAssertEqual(store.machines.first?.name, "fixture-host")
        XCTAssertEqual(store.machines.first?.os, "linux")
        XCTAssertEqual(store.machines.first?.tailscaleVersion, "1.104.1")
        XCTAssertNil(store.machines.first?.online, "Control-plane connection is not peer reachability")
        XCTAssertEqual(store.machines.first?.connectedToControl, true)
        let restored = TailnetStore(storage: disk, credentialRepository: repo, fetchDevices: { _ in [] })
        XCTAssertEqual(restored.apiTailnetID, "Tfixture")
        XCTAssertEqual(restored.machines.first?.name, "fixture-host")
    }
    func testFailedLinkAndRefreshKeepPreviousAssociationAndList() async throws {
        let repo = MemoryTailnetCredentialRepository(); let disk = storage()
        defer { try? FileManager.default.removeItem(at: disk.directory) }
        var fail = false
        let store = TailnetStore(storage: disk, probe: { _ in .init(state: .unreachable) }, credentialRepository: repo, fetchDevices: { _ in
            if fail { throw TailnetAPIError.forbidden }; return [Self.device]
        })
        await store.linkAPI(tailnetID: "Tfirst", clientSecret: "tskey-client-fixture-secret")
        fail = true
        await store.linkAPI(tailnetID: "Tsecond", clientSecret: "tskey-client-fixture-other-secret")
        XCTAssertEqual(store.apiTailnetID, "Tfirst"); XCTAssertEqual(repo.value?.tailnetID, "Tfirst")
        XCTAssertEqual(store.machines.first?.name, "fixture-host")
        XCTAssertNotNil(store.apiError)
        await store.refresh()
        XCTAssertEqual(store.machines.first?.name, "fixture-host")
        XCTAssertNotNil(store.apiError)
    }
    func testUnlinkDiscardsLateListAndDoesNotTouchAppKeychain() async throws {
        let gate = TailnetListGate(); let repo = MemoryTailnetCredentialRepository(); let disk = storage()
        defer { try? FileManager.default.removeItem(at: disk.directory) }
        let store = TailnetStore(storage: disk, credentialRepository: repo, fetchDevices: { _ in await gate.run() })
        let task = Task { await store.linkAPI(tailnetID: "Tfixture", clientSecret: "tskey-client-fixture-secret") }
        await gate.waitForStart()
        try await store.unlinkAPI()
        await gate.finish(); await task.value
        XCTAssertNil(store.apiTailnetID); XCTAssertNil(repo.value)
        XCTAssertTrue(store.machines.isEmpty); XCTAssertNil(try disk.load())
    }
    func testRepositoryFailureDoesNotPublishCandidate() async throws {
        let repo = MemoryTailnetCredentialRepository(); repo.failSave = true
        let disk = storage(); defer { try? FileManager.default.removeItem(at: disk.directory) }
        let store = TailnetStore(storage: disk, credentialRepository: repo, fetchDevices: { _ in [Self.device] })
        await store.linkAPI(tailnetID: "Tfixture", clientSecret: "tskey-client-fixture-secret")
        XCTAssertNil(store.apiTailnetID); XCTAssertNil(repo.value); XCTAssertTrue(store.machines.isEmpty)
    }
    func testCancelledAssociationCannotPersistAfterItsResponseArrives() async throws {
        let gate = TailnetListGate(); let repo = MemoryTailnetCredentialRepository(); let disk = storage()
        defer { try? FileManager.default.removeItem(at: disk.directory) }
        let store = TailnetStore(storage: disk, credentialRepository: repo, fetchDevices: { _ in await gate.run() })
        let task = Task { await store.linkAPI(tailnetID: "Tfixture", clientSecret: "tskey-client-fixture-secret") }
        await gate.waitForStart(); await store.cancelLink()
        await gate.finish(); await task.value
        XCTAssertNil(repo.value); XCTAssertNil(store.apiTailnetID); XCTAssertNil(try disk.load())
    }
    func testRotatingProbeBatchesRetainPreviouslyDiscoveredMachines() async throws {
        let repo = MemoryTailnetCredentialRepository(); let disk = storage()
        defer { try? FileManager.default.removeItem(at: disk.directory) }
        let devices = (0..<20).map { index in
            TailnetAPIDevice(id: "node-\(index)", name: "host-\(index)", addresses: [], dnsName: nil, os: "linux", clientVersion: nil, connectedToControl: true)
        }
        let store = TailnetStore(storage: disk, probe: { _ in .init(state: .notDetected) }, credentialRepository: repo, fetchDevices: { _ in devices })
        await store.linkAPI(tailnetID: "Tfixture", clientSecret: "tskey-client-fixture-secret")
        await store.refresh(); await store.refresh()
        XCTAssertEqual(store.machines.filter { $0.state == .notDetected }.count, 20)
    }
    func testAPIRefreshUpdatesNameAndAddressWithoutDuplicatingStableDevice() async throws {
        let repo = MemoryTailnetCredentialRepository(); let disk = storage()
        defer { try? FileManager.default.removeItem(at: disk.directory) }
        var devices = [Self.device]
        var probed: [String] = []
        let store = TailnetStore(storage: disk, probe: { machine in
            probed.append(contentsOf: machine.addresses); return .init(state: .notDetected)
        }, credentialRepository: repo, fetchDevices: { _ in devices })
        await store.linkAPI(tailnetID: "Tfixture", clientSecret: "tskey-client-fixture-secret")
        await store.refresh()
        let originalID = store.machines.first?.id
        devices = [.init(id: "nStable", name: "renamed-host", addresses: ["100.100.1.4"], dnsName: "renamed-host.tailfixture.ts.net", os: "linux", clientVersion: "1.105.0", connectedToControl: false)]
        await store.refresh()
        XCTAssertEqual(store.machines.count, 1); XCTAssertEqual(store.machines.first?.id, originalID)
        XCTAssertEqual(store.machines.first?.name, "renamed-host")
        XCTAssertEqual(store.machines.first?.addresses, ["100.100.1.4"])
        XCTAssertEqual(store.machines.first?.tailscaleVersion, "1.105.0")
        XCTAssertEqual(probed, ["100.100.1.3", "100.100.1.4"])
    }
    func testSwitchTailnetDiscardsOldInFlightAPIResponse() async throws {
        let repo = MemoryTailnetCredentialRepository(); let disk = storage(); let gate = TailnetListGate()
        defer { try? FileManager.default.removeItem(at: disk.directory) }
        var blockFirst = false
        let store = TailnetStore(storage: disk, probe: { _ in .init(state: .notDetected) }, credentialRepository: repo, fetchDevices: { credential in
            if credential.tailnetID == "Tfirst" {
                return blockFirst ? await gate.run() : [Self.device]
            }
            return [.init(id: "nSecond", name: "second-tailnet-host", addresses: [], dnsName: nil, os: "macOS", clientVersion: nil, connectedToControl: nil)]
        })
        await store.linkAPI(tailnetID: "Tfirst", clientSecret: "tskey-client-fixture-first-secret")
        blockFirst = true
        let stale = Task { await store.refresh() }
        await gate.waitForStart()
        await store.linkAPI(tailnetID: "Tsecond", clientSecret: "tskey-client-fixture-second-secret")
        await gate.finish(); await stale.value
        XCTAssertEqual(store.apiTailnetID, "Tsecond")
        XCTAssertEqual(store.machines.map(\.name), ["second-tailnet-host"])
        XCTAssertEqual(repo.value?.tailnetID, "Tsecond")
        XCTAssertEqual(try disk.load()?.snapshot.account, "Tsecond")
    }
    func storage() -> TailnetImportStorage { .init(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)) }
    nonisolated static var device: TailnetAPIDevice { .init(id: "nStable", name: "fixture-host", addresses: ["100.100.1.3"], dnsName: "fixture-host.tailfixture.ts.net", os: "linux", clientVersion: "1.104.1", connectedToControl: true) }
}
private final class MemoryTailnetCredentialRepository: TailnetCredentialRepository {
    var value: TailnetAPICredentials?; var failSave = false
    func load() throws -> TailnetAPICredentials? { value }
    func save(_ value: TailnetAPICredentials) throws { if failSave { throw TailnetAPIError.storage }; self.value = value }
    func clear() throws { value = nil }
}
private actor TailnetListGate {
    var started = false; var waiting: CheckedContinuation<Void, Never>?
    var pending: CheckedContinuation<[TailnetAPIDevice], Never>?
    func run() async -> [TailnetAPIDevice] { await withCheckedContinuation { pending = $0; started = true; waiting?.resume(); waiting = nil } }
    func waitForStart() async { if !started { await withCheckedContinuation { waiting = $0 } } }
    func finish() { pending?.resume(returning: [TailnetAPIStoreTests.device]); pending = nil }
}
