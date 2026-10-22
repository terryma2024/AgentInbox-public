import Foundation
import Security
import Darwin
import CryptoKit

struct InboxConfiguration {
    static let appGroup = Bundle.main.object(forInfoDictionaryKey: "AgentInboxAppGroup") as? String ?? "group.dev.matianyi.agentinbox"
    static let keychainGroup = Bundle.main.object(forInfoDictionaryKey: "AgentInboxKeychainGroup") as? String
    static var defaults: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }
    static var serverURL: String {
        get { defaults.string(forKey: "serverURL") ?? "http://127.0.0.1:8787" }
        set {
            if newValue != serverURL { defaults.set(UUID().uuidString, forKey: "relayConnectionRevision") }
            defaults.set(newValue, forKey: "serverURL")
        }
    }
    static var replyPairingGeneration: String {
        if let value = defaults.string(forKey: "replyPairingGeneration") { return value }
        let value = UUID().uuidString; defaults.set(value, forKey: "replyPairingGeneration"); defaults.synchronize(); return value
    }
    static func rotateReplyPairingGeneration() { defaults.set(UUID().uuidString, forKey: "replyPairingGeneration"); defaults.synchronize() }
    static var relayConnection: RelayConnectionIdentity {
        .init(url: serverURL, revision: defaults.string(forKey: "relayConnectionRevision") ?? "initial")
    }
    static var widgetRequestID: String? {
        get { defaults.string(forKey: "widgetRequestID") }
        set { defaults.set(newValue, forKey: "widgetRequestID") }
    }
    static var notificationsEnabled: Bool {
        get { defaults.bool(forKey: "notificationsEnabled") }
        set { defaults.set(newValue, forKey: "notificationsEnabled") }
    }
}
enum DeviceSecret {
    static func query() -> [String: Any] {
        var value: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "AgentInbox", kSecAttrAccount as String: "device-key"]
        if let group = InboxConfiguration.keychainGroup, !group.isEmpty { value[kSecAttrAccessGroup as String] = group }
        return value
    }
    static func read() -> String? {
        var value = query(); value[kSecReturnData as String] = true; value[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(value as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ key: String) throws {
        let value = query()
        let changesIdentity = read() != (key.isEmpty ? nil : key)
        if key.isEmpty {
            let status = SecItemDelete(value as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw APIError.message("无法移除设备密钥（\(status)）") }
            if changesIdentity { InboxConfiguration.rotateReplyPairingGeneration() }
            return
        }
        let changes: [String: Any] = [kSecValueData as String: Data(key.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(value as CFDictionary, changes as CFDictionary)
        if status == errSecSuccess { if changesIdentity { InboxConfiguration.rotateReplyPairingGeneration() }; return }
        guard status == errSecItemNotFound else { throw APIError.message("无法更新设备密钥；原密钥已保留（\(status)）") }
        let insert = value.merging(changes) { _, new in new }
        let added = SecItemAdd(insert as CFDictionary, nil)
        guard added == errSecSuccess else { throw APIError.message("无法保存设备密钥（\(added)）") }
        if changesIdentity { InboxConfiguration.rotateReplyPairingGeneration() }
    }
}
struct RelayConnectionIdentity: Equatable { let url: String; let revision: String; var pairingGeneration: String = InboxConfiguration.replyPairingGeneration }
struct CachedInbox: Codable {
    var requests: [DecisionRequest]; var refreshedAt: Date; var error: String?
    var serverURL: String? = nil
    var connectionRevision: String? = nil
    var pairingGeneration: String? = nil
    func matches(_ connection: RelayConnectionIdentity) -> Bool { serverURL == connection.url && connectionRevision == connection.revision && pairingGeneration == connection.pairingGeneration }
}
enum InboxCache {
    static func load() -> CachedInbox {
        let connection = InboxConfiguration.relayConnection
        guard let data = InboxConfiguration.defaults.data(forKey: "inbox"), let inbox = try? JSONDecoder().decode(CachedInbox.self, from: data), inbox.matches(connection) else {
            return CachedInbox(requests: [], refreshedAt: .distantPast, error: nil, serverURL: connection.url, connectionRevision: connection.revision, pairingGeneration: connection.pairingGeneration)
        }
        return inbox
    }
    static func save(_ inbox: CachedInbox, for connection: RelayConnectionIdentity = InboxConfiguration.relayConnection) {
        guard connection == InboxConfiguration.relayConnection else { return }
        var bound = inbox; bound.serverURL = connection.url; bound.connectionRevision = connection.revision; bound.pairingGeneration = connection.pairingGeneration
        if let data = try? JSONEncoder().encode(bound), connection == InboxConfiguration.relayConnection {
            InboxConfiguration.defaults.set(data, forKey: "inbox")
        }
    }
}
// The context contains no credential or credential digest.
struct ReplyJournalContext: Codable, Equatable {
    let serverURL: String
    let connectionRevision: String
    let pairingGeneration: String
    static var current: Self { let c = InboxConfiguration.relayConnection; return .init(serverURL: c.url, connectionRevision: c.revision, pairingGeneration: c.pairingGeneration) }
}
struct SavedReply: Codable { let context: ReplyJournalContext; let answer: DecisionResponse; let requestDigest: String? }
enum ResponseJournal {
    private static var directory: URL { (FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: InboxConfiguration.appGroup) ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]).appendingPathComponent("reply-journal-v1", isDirectory: true) }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func file(_ id: String, _ revision: Int, _ context: ReplyJournalContext) throws -> URL {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(context); data.append(Data("|\(id)|\(revision)".utf8))
        return directory.appendingPathComponent(digest(data) + ".json")
    }
    private static func requestDigest(_ request: DecisionRequest) throws -> String {
        if let digest = request.bindingDigest { return digest }
        var value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String: Any]
        for field in ["state", "updatedAt", "responseId", "replyProgress", "bindingDigest"] { value.removeValue(forKey: field) }
        return digest(try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
    }
    private static func withLock<T>(_ operation: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = open(directory.appendingPathComponent("responses.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw APIError.message("无法保护回复记录") }; defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw APIError.message("无法锁定回复记录") }; defer { flock(descriptor, LOCK_UN) }
        InboxConfiguration.defaults.synchronize()
        return try operation()
    }
    static func legacy(for request: DecisionRequest) -> DecisionResponse? {
        guard let data = InboxConfiguration.defaults.data(forKey: "response.\(request.id).\(request.revision)"), let answer = try? JSONDecoder().decode(DecisionResponse.self, from: data), answer.requestId == request.id, answer.revision == request.revision else { return nil }
        return answer
    }
    static func pending(for request: DecisionRequest) -> DecisionResponse? {
        try? withLock {
            let context = ReplyJournalContext.current
            let data = try Data(contentsOf: file(request.id, request.revision, context))
            let saved = try JSONDecoder().decode(SavedReply.self, from: data)
            guard saved.context == context, saved.answer.requestId == request.id, saved.answer.revision == request.revision,
                  saved.requestDigest == nil ? request.bindingDigest == nil : saved.requestDigest == (try requestDigest(request)) else { return nil }
            return saved.answer
        }
    }
    static func save(_ answer: DecisionResponse, for request: DecisionRequest? = nil, context: ReplyJournalContext = .current) throws {
        try withLock {
            guard context == ReplyJournalContext.current else { throw APIError.message("连接或配对已变化，原答案未重新提交") }
            if let request { try ReplyValidation.validate(answer, for: request) }
            let path = try file(answer.requestId, answer.revision, context)
            let requestDigest = try request.map { try self.requestDigest($0) }
            if FileManager.default.fileExists(atPath: path.path) {
                let existing = try JSONDecoder().decode(SavedReply.self, from: Data(contentsOf: path))
                guard existing.answer == answer, existing.context == context,
                      requestDigest == nil || existing.requestDigest == requestDigest else { throw APIError.message("此请求已有提交记录，请刷新查看回执") }
                return
            }
            let data = try JSONEncoder().encode(SavedReply(context: context, answer: answer, requestDigest: requestDigest))
            let temporary = directory.appendingPathComponent("temporary-" + UUID().uuidString)
            let fd = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { throw APIError.message("无法保存原答案") }; defer { close(fd); try? FileManager.default.removeItem(at: temporary) }
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    guard count > 0 else { throw APIError.message("无法完整保存原答案") }; offset += count
                }
            }
            guard fsync(fd) == 0, rename(temporary.path, path.path) == 0 else { throw APIError.message("无法持久保存原答案") }
            let dir = open(directory.path, O_RDONLY); guard dir >= 0 else { throw APIError.message("无法确认原答案记录") }; defer { close(dir) }
            guard fsync(dir) == 0 else { throw APIError.message("无法确认原答案记录") }
        }
    }
}

#if DEBUG
// Bounded development metadata only. Never records question bodies, answers or credentials.
enum InteractionDiagnostics {
    enum Event: String { case widgetRefreshBegin, widgetRefreshEnd, widgetAnswerBegin, widgetAnswerEnd, appViewStarted, appOpenedURL, appBecameActive, appBecameBackground, appRefreshPollActive, widgetPushHandler, widgetPushRegistered, widgetPushRetryLater, widgetProviderBegin, widgetProviderEnd }
    private static let writerLock = NSLock()
    static func record(_ event: Event, requestID: String? = nil, revision: Int? = nil) {
        writerLock.lock(); defer { writerLock.unlock() }
        // Separate keys per process avoid cross-process read/modify/write conflicts.
        let key = "interactionTrace.\(getpid())"
        let defaults = InboxConfiguration.defaults
        var events = defaults.array(forKey: key) as? [[String: Any]] ?? []
        guard events.count < 64 else { return }
        var value: [String: Any] = ["event": event.rawValue, "time": Date().timeIntervalSince1970, "processId": Int(getpid()), "bundleId": Bundle.main.bundleIdentifier ?? "unknown"]
        if let requestID, UUID(uuidString: requestID) != nil { value["requestId"] = requestID }
        if let revision, revision > 0 { value["revision"] = revision }
        events.append(value)
        defaults.set(events, forKey: key)
        defaults.synchronize()
    }
}
#endif
