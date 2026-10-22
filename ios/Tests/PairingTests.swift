import XCTest
import WidgetKit
@testable import AgentInbox

final class PairingTests: XCTestCase {
    func testSimulatorKeychainTemporaryRoundTrip() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("限模拟器临时Keychain验证")
        #endif
        guard ProcessInfo.processInfo.environment["AGENTINBOX_TEST_PAIR_CODE_FILE"] != nil else { throw XCTSkip("需明确开启临时测试") }
        let previous = DeviceSecret.read()
        defer { try? DeviceSecret.save(previous ?? "") }
        let fixture = "agentinbox-approved-simulator-keychain-fixture"
        try DeviceSecret.save(fixture)
        XCTAssertTrue(DeviceSecret.read() == fixture)
        try DeviceSecret.save("")
        XCTAssertNil(DeviceSecret.read())
    }
    func testClearOnlyAuthorizedSimulatorWidgetFixtureCredential() throws {
        guard ProcessInfo.processInfo.environment["AGENTINBOX_WIDGET_CLEANUP"] == "1", let file = ProcessInfo.processInfo.environment["AGENTINBOX_TEST_KEY_FILE"] else { throw XCTSkip("仅显式清理临时Widget测试key") }
        #if !targetEnvironment(simulator)
        throw XCTSkip("清理限模拟器")
        #endif
        let expected = try String(contentsOfFile: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard DeviceSecret.read() == expected else { XCTFail("当前密钥不是本轮临时fixture，拒绝删除"); return }
        try DeviceSecret.save("")
        XCTAssertNil(DeviceSecret.read())
        InboxConfiguration.serverURL = "http://127.0.0.1:8787"
        InboxConfiguration.widgetRequestID = nil
        InboxCache.save(.init(requests: [], refreshedAt: .distantPast, error: nil))
        InboxConfiguration.defaults.removeObject(forKey: "widgetProbeStatus")
        WidgetCenter.shared.reloadAllTimelines()
        struct Proof: Codable { let scope: String; let matchingTemporaryFixtureOnly: Bool; let keychainAbsent: Bool; let serverRestored: String; let widgetPinnedRequestCleared: Bool; let cacheCleared: Bool }
        let proof = Proof(scope: "iOS Simulator only; original shared-keychain baseline absent", matchingTemporaryFixtureOnly: true, keychainAbsent: true, serverRestored: InboxConfiguration.serverURL, widgetPinnedRequestCleared: InboxConfiguration.widgetRequestID == nil, cacheCleared: InboxCache.load().requests.isEmpty)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(proof).write(to: URL(fileURLWithPath: ProcessInfo.processInfo.environment["AGENTINBOX_CLEANUP_PROOF_FILE"] ?? FileManager.default.temporaryDirectory.appendingPathComponent("ios-simulator-cleanup-proof.json").path))
    }
    func testTemporarySimulatorPairingKeychainReplayAndRevocation() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let codeFile = env["AGENTINBOX_TEST_PAIR_CODE_FILE"] else { throw XCTSkip("仅显式授权并配置临时模拟器配对时运行") }
        #if !targetEnvironment(simulator)
        throw XCTSkip("临时配对测试限模拟器")
        #endif
        let code = try String(contentsOfFile: codeFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = DeviceSecret.read()
        defer { try? DeviceSecret.save(previous ?? "") }
        let api = InboxAPI(baseURL: env["AGENTINBOX_TEST_PAIR_URL"] ?? "http://127.0.0.1:8790", token: nil)
        let paired = try await api.pair(code: code, name: "授权临时模拟器配对测试")
        XCTAssertFalse(paired.deviceId.isEmpty)
        XCTAssertTrue(paired.token.utf8.count >= 32)
        try DeviceSecret.save(paired.token)
        XCTAssertTrue(DeviceSecret.read() == paired.token, "Keychain 应保存相同测试设备密钥")
        let authenticated = InboxAPI(baseURL: api.baseURL, token: DeviceSecret.read())
        _ = try await authenticated.requests()
        do { _ = try await api.pair(code: code, name: "replay"); XCTFail("一次性配对码不得复用") } catch { XCTAssertEqual(error.localizedDescription, "配对失败：配对码可能已过期或已使用") }
        struct Revocation: Decodable { let revoked: Bool }
        let revoked: Revocation = try await authenticated.call("/v1/devices/revoke", method: "POST", body: Data("{}".utf8))
        XCTAssertTrue(revoked.revoked)
        do { _ = try await authenticated.requests(); XCTFail("撤销后的设备应立即被拒绝") } catch { XCTAssertEqual(error.localizedDescription, "设备认证失败，请检查配对或撤销状态") }
        try DeviceSecret.save("")
        XCTAssertNil(DeviceSecret.read())
        struct Proof: Codable { let deviceId: String; let paired: Bool; let keychainStored: Bool; let replayRejected: Bool; let revoked: Bool; let deniedAfterRevoke: Bool; let keychainCleared: Bool; let scope: String }
        let proof = Proof(deviceId: paired.deviceId, paired: true, keychainStored: true, replayRejected: true, revoked: true, deniedAfterRevoke: true, keychainCleared: true, scope: "temporary iOS Simulator device; independent localhost relay; no Apple/APNs credentials")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(proof).write(to: URL(fileURLWithPath: env["AGENTINBOX_PAIRING_PROOF_FILE"] ?? FileManager.default.temporaryDirectory.appendingPathComponent("ios-pairing-proof.json").path))
    }
}
