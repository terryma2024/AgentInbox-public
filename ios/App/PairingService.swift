import Foundation
import Darwin

// Neither errors nor diagnostics contain the pairing code or device credential.
enum PairingFailure: String, Error, LocalizedError {
    case invalidFile, unsafeFile, expired, invalidDestination, invalidCode, alreadyPaired, inProgress, networkUnknown, localStorage, serverRejected, invalidReceipt
    var errorDescription: String? {
        switch self {
        case .alreadyPaired: return "此设备已有配对身份，已保留原密钥；不会自动替换。"
        case .inProgress: return "配对正在进行，请等待结果。"
        case .networkUnknown: return "配对结果未知，已停止自动重试；请先核对服务器设备状态。"
        case .serverRejected: return "配对被服务拒绝，请检查配对码有效期。"
        case .localStorage: return "设备身份保存失败，已停止；请先核对服务器设备状态。"
        default: return "配对资料无效或已过期（\(rawValue)）。"
        }
    }
}
@MainActor final class PairingService {
    static let shared = PairingService(readSecret: { DeviceSecret.read() }, readDeviceID: { InboxConfiguration.defaults.string(forKey: "deviceId") }, saveSecret: { try DeviceSecret.save($0) }, configure: { url, id in
        InboxConfiguration.serverURL = url
        InboxConfiguration.defaults.set(id, forKey: "deviceId")
    }, request: { url, code, name in try await InboxAPI(baseURL: url, token: nil).pair(code: code, name: name) })
    private let readSecret: () -> String?
    private let readDeviceID: () -> String?
    private let saveSecret: (String) throws -> Void
    private let configure: (String, String) -> Void
    private let request: (String, String, String) async throws -> PairingReceipt
    private var inFlight = false
    var hasIdentity: Bool { !(readSecret() ?? "").isEmpty || !(readDeviceID() ?? "").isEmpty }
    init(readSecret: @escaping () -> String?, readDeviceID: @escaping () -> String?, saveSecret: @escaping (String) throws -> Void, configure: @escaping (String, String) -> Void, request: @escaping (String, String, String) async throws -> PairingReceipt) {
        self.readSecret = readSecret; self.readDeviceID = readDeviceID; self.saveSecret = saveSecret; self.configure = configure; self.request = request
    }
    func pair(serverURL: String, code: String) async throws -> PairingReceipt {
        guard !hasIdentity else { throw PairingFailure.alreadyPaired }
        guard !inFlight else { throw PairingFailure.inProgress }
        guard !code.isEmpty else { throw PairingFailure.invalidCode }
        _ = try InboxAPI(baseURL: serverURL, token: nil).validatedURL("/v1/pair")
        inFlight = true; defer { inFlight = false }
        let receipt: PairingReceipt
        do { receipt = try await request(serverURL, code, "iPhone") }
        catch is URLError { throw PairingFailure.networkUnknown }
        catch is DecodingError { throw PairingFailure.networkUnknown }
        catch { throw PairingFailure.serverRejected }
        guard !receipt.deviceId.isEmpty, !receipt.token.isEmpty else { throw PairingFailure.invalidReceipt }
        // Recheck after suspension; never silently overwrite an identity created elsewhere.
        guard !hasIdentity else { throw PairingFailure.alreadyPaired }
        do { try saveSecret(receipt.token) } catch { throw PairingFailure.localStorage }
        configure(serverURL, receipt.deviceId)
        return receipt
    }
}
#if DEBUG
struct PairingFilePayload: Decodable { let serverURL: String; let code: String; let expiresAt: Double }
struct PairingDiagnostic: Codable { let keychainPresent: Bool; let deviceId: String?; let authenticatedInbox: Bool; let notificationAuthorizationStatus: Int; let deliveredPushRequestIds: [String] }
struct PairingImportResult: Codable { let state: String; let errorCategory: String?; let deviceId: String? }
enum PairingFileImport {
    static let inputFilename = "agentinbox-pairing.json"
    static let resultFilename = "agentinbox-pairing-result.json"
    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static func consume(from directory: URL, now: Date = Date()) throws -> PairingFilePayload {
        let file = directory.appendingPathComponent(inputFilename)
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw PairingFailure.unsafeFile }
        defer { close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_mode & 0o777 == 0o600, metadata.st_uid == geteuid(),
              metadata.st_size > 0, metadata.st_size <= 4096 else { throw PairingFailure.unsafeFile }
        var bytes = [UInt8](repeating: 0, count: 4097)
        var count = 0
        while count < bytes.count {
            let n = bytes.withUnsafeMutableBytes { buffer in Darwin.read(fd, buffer.baseAddress!.advanced(by: count), buffer.count - count) }
            if n == 0 { break }; guard n > 0 else { throw PairingFailure.invalidFile }; count += n
        }
        guard count == metadata.st_size, count <= 4096 else { throw PairingFailure.invalidFile }
        let data = Data(bytes.prefix(count))
        guard String(data: data, encoding: .utf8) != nil, let value = try? JSONDecoder().decode(PairingFilePayload.self, from: data) else { throw PairingFailure.invalidFile }
        guard value.code.count == 32, value.code.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }) else { throw PairingFailure.invalidCode }
        guard value.expiresAt.isFinite, value.expiresAt > now.timeIntervalSince1970, value.expiresAt - now.timeIntervalSince1970 <= 600 else { throw PairingFailure.expired }
        var allowed = value.serverURL == "https://relay.example.ts.net:8443"
        #if targetEnvironment(simulator)
        if let url = URLComponents(string: value.serverURL), ["http", "https"].contains(url.scheme ?? ""), ["127.0.0.1", "localhost", "::1"].contains(url.host ?? ""), url.user == nil, url.password == nil, url.path.isEmpty, url.query == nil, url.fragment == nil { allowed = true }
        #endif
        guard allowed else { throw PairingFailure.invalidDestination }
        var current = stat()
        guard lstat(file.path, &current) == 0, current.st_dev == metadata.st_dev, current.st_ino == metadata.st_ino,
              unlink(file.path) == 0 else { throw PairingFailure.unsafeFile }
        return value // Unlink succeeded before any network request may start.
    }
    static func writeResult(_ result: PairingImportResult, to directory: URL) throws {
        let file = directory.appendingPathComponent(resultFilename)
        let data = try JSONEncoder().encode(result)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600, .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
    }
}
#endif
