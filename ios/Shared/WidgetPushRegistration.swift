import Foundation
import Security
import CryptoKit
import WidgetKit
import Darwin
import CoreFoundation

struct WidgetTokenRegistration: Codable, Equatable {
    let token: String
    let environment: String
    let active: Bool
    let registrationRevision: Int64
    init(token: String, environment: String, active: Bool = true, registrationRevision: Int64 = 1) { self.token = token; self.environment = environment; self.active = active; self.registrationRevision = registrationRevision }
    func withRevision(_ value: Int64) -> Self { .init(token: token, environment: environment, active: active, registrationRevision: value) }
    static func resolve(currentToken: Data?, storedToken: String?, hasWidget: Bool?, environment: String) -> Self? {
        guard let hasWidget else { return nil }
        let current = currentToken.map { $0.map { String(format: "%02x", $0) }.joined() }
        if hasWidget { return current.map { .init(token: $0, environment: environment, active: true) } }
        return (current ?? storedToken).map { .init(token: $0, environment: environment, active: false) }
    }
    func validate() throws {
        guard (32...256).contains(token.utf8.count), token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }), token.utf8.count % 2 == 0 else { throw WidgetPushRegistrationError.invalidInput }
        guard registrationRevision > 0 else { throw WidgetPushRegistrationError.invalidInput }
        guard ["sandbox", "production"].contains(environment) else { throw WidgetPushRegistrationError.invalidInput }
    }
}
enum WidgetPushRegistrationError: Error { case invalidInput, unpaired, rejected, conflict, notConfirmed, revisionExhausted }
enum WidgetPushRegistrationStatus: String {
    case registered, unchanged, inactive, queued, stale, retryLater, unpaired, waitingForToken, configurationUnknown
    var label: String {
        switch self {
        case .registered, .unchanged: return "小组件推送已连接"
        case .inactive: return "已移除小组件，自动更新已暂停"
        case .retryLater: return "小组件推送暂未连接，将在下次刷新时重试"
        case .unpaired: return "小组件推送等待设备配对"
        case .waitingForToken: return "小组件推送等待系统初始化"
        case .configurationUnknown: return "小组件配置状态暂不可用"
        case .queued, .stale: return "小组件推送正在同步系统状态"
        }
    }
}
// Independent account in the existing shared Keychain. Never updates the device-key account.
enum WidgetPushTokenSecret {
    private static func query(account: String = "widget-push-token") -> [String: Any] {
        var value = DeviceSecret.query(); value[kSecAttrAccount as String] = account; return value
    }
    static func readPending() -> WidgetTokenRegistrationPending? {
        read(account: "widget-push-registration-pending").flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(WidgetTokenRegistrationPending.self, from: $0) }
    }
    static func savePending(_ value: WidgetTokenRegistrationPending?) throws {
        let encoded = try value.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        try save(encoded, account: "widget-push-registration-pending")
    }
    static func read(account: String = "widget-push-token") -> String? {
        var value = query(account: account); value[kSecReturnData as String] = true; value[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(value as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ token: String?, account: String = "widget-push-token") throws {
        let value = query(account: account)
        guard let token else { let status = SecItemDelete(value as CFDictionary); guard status == errSecSuccess || status == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }; return }
        let changes: [String: Any] = [kSecValueData as String: Data(token.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(value as CFDictionary, changes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        let added = SecItemAdd(value.merging(changes) { _, new in new } as CFDictionary, nil)
        guard added == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(added)) }
    }
}
extension InboxAPI {
    func widgetTokenRegistrationRequest(_ body: WidgetTokenRegistration) throws -> URLRequest {
        try body.validate()
        guard let token, !token.isEmpty else { throw WidgetPushRegistrationError.unpaired }
        var request = URLRequest(url: try validatedURL("/v1/devices/widget-token")); request.httpMethod = "POST"
        request.timeoutInterval = 12; request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try JSONEncoder().encode(body)
        return request
    }
    func widgetTokenRevisionRequest() throws -> URLRequest {
        guard let token, !token.isEmpty else { throw WidgetPushRegistrationError.unpaired }
        var request = URLRequest(url: try validatedURL("/v1/devices/widget-token")); request.httpMethod = "GET"; request.timeoutInterval = 12
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }
    func widgetTokenRevision() async throws -> Int64 {
        struct Receipt: Decodable { let registrationRevision: Int64 }
        let (data, response) = try await URLSession.shared.data(for: widgetTokenRevisionRequest())
        guard let http = response as? HTTPURLResponse else { throw WidgetPushRegistrationError.notConfirmed }
        guard (200...299).contains(http.statusCode) else { throw NSError(domain: "AgentInboxWidgetHTTPStatus", code: http.statusCode) }
        guard let result = try? JSONDecoder().decode(Receipt.self, from: data), result.registrationRevision >= 0 else { throw WidgetPushRegistrationError.notConfirmed }
        return result.registrationRevision
    }
    func registerWidgetToken(_ body: WidgetTokenRegistration) async throws {
        struct Receipt: Decodable { let registered: Bool }
        let request = try widgetTokenRegistrationRequest(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WidgetPushRegistrationError.notConfirmed }
        if http.statusCode == 409 { throw WidgetPushRegistrationError.conflict }
        guard (200...299).contains(http.statusCode) else { throw NSError(domain: "AgentInboxWidgetHTTPStatus", code: http.statusCode) }
        guard let result = try? JSONDecoder().decode(Receipt.self, from: data), result.registered else { throw WidgetPushRegistrationError.notConfirmed }
    }
}
#if DEBUG
enum WidgetPushRegistrationStage: String { case acquire, resample, readServerRev, persistCounter, savePending, send, confirm }
enum WidgetPushRegistrationDiagnostics {
    private static let lock = NSLock()
    static func record(_ stage: WidgetPushRegistrationStage, error: Error? = nil, defaults: UserDefaults) {
        lock.lock(); defer { lock.unlock() }
        let key = "widgetPushRegistrationDiagnostic.\(getpid())"
        var value: [String: Any] = ["stage": stage.rawValue, "time": Date().timeIntervalSince1970, "processId": Int(getpid()), "bundleId": Bundle.main.bundleIdentifier ?? "unknown"]
        let previous = defaults.dictionary(forKey: key)
        if stage != .acquire, let returned = previous?["counterSynchronizationReturned"] as? Bool { value["counterSynchronizationReturned"] = returned }
        if let old = previous?["lastFailure"] as? [String: Any] {
            value["lastFailure"] = old.filter { ["stage", "category", "osStatus", "transportCode", "httpStatus", "time"].contains($0.key) }
        }
        if let error {
            let numeric = error as NSError
            var failure: [String: Any] = ["stage": stage.rawValue, "time": Date().timeIntervalSince1970]
            if numeric.domain == NSOSStatusErrorDomain { failure["category"] = "keychain"; failure["osStatus"] = numeric.code }
            else if numeric.domain == NSURLErrorDomain { failure["category"] = "transport"; failure["transportCode"] = numeric.code }
            else if numeric.domain == "AgentInboxWidgetHTTPStatus" { failure["category"] = "httpRejected"; failure["httpStatus"] = numeric.code }
            else if let known = error as? WidgetPushRegistrationError {
                switch known {
                case .invalidInput: failure["category"] = "invalidInput"
                case .unpaired: failure["category"] = "unpaired"
                case .rejected: failure["category"] = "rejected"
                case .conflict: failure["category"] = "revisionConflict"; failure["httpStatus"] = 409
                case .notConfirmed: failure["category"] = "unconfirmed"
                case .revisionExhausted: failure["category"] = "revisionExhausted"
                }
            } else { failure["category"] = "unknown" }
            value["lastFailure"] = failure
        }
        defaults.set(value, forKey: key)
        _ = defaults.synchronize() // Diagnostic best effort only; never participates in control flow.
    }
    static func recordCounterSynchronization(_ returned: Bool, defaults: UserDefaults) {
        lock.lock(); defer { lock.unlock() }
        let key = "widgetPushRegistrationDiagnostic.\(getpid())"
        var value = defaults.dictionary(forKey: key) ?? [:]
        value["counterSynchronizationReturned"] = returned
        defaults.set(value, forKey: key)
        // Do not call synchronize again to obtain or change the observed return value.
    }
}
#endif
// Shared App/extension lease serializes local OS snapshots, counters and registration.
// Server registrationRevision CAS separately rejects HTTP arriving late after a timeout.
final class WidgetPushUploadLease {
    private var descriptor: Int32
    private let lock = NSLock()
    private init(_ descriptor: Int32) { self.descriptor = descriptor }
    static func acquire(in directory: URL) throws -> WidgetPushUploadLease {
        let fd = open(directory.appendingPathComponent("widget-push-registration.lock").path, O_CREAT | O_WRONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw WidgetPushRegistrationError.notConfirmed }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(), metadata.st_mode & 0o777 == 0o600,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw WidgetPushRegistrationError.notConfirmed }
        return WidgetPushUploadLease(fd)
    }
    static func acquireEventually(in directory: URL) async throws -> WidgetPushUploadLease {
        let deadline = Date().addingTimeInterval(14)
        repeat {
            try Task.checkCancellation()
            if let value = try? acquire(in: directory) { return value }
            try await Task.sleep(nanoseconds: 100_000_000)
        } while Date() < deadline
        throw WidgetPushRegistrationError.notConfirmed
    }
    func release() {
        lock.lock(); defer { lock.unlock() }
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN); close(descriptor); descriptor = -1
    }
    deinit { release() }
}
struct WidgetTokenRegistrationPending: Codable { let scope: String; let fingerprint: String; let body: WidgetTokenRegistration }
actor WidgetPushCoordinator {
    static let shared = WidgetPushCoordinator(defaults: InboxConfiguration.defaults, readDeviceKey: { DeviceSecret.read() }, readStoredWidgetToken: { WidgetPushTokenSecret.read() }, saveWidgetToken: { try WidgetPushTokenSecret.save($0) }, acquireLease: {
        guard let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: InboxConfiguration.appGroup) else { throw WidgetPushRegistrationError.notConfirmed }
        return try await WidgetPushUploadLease.acquireEventually(in: directory)
    }, resample: { try await WidgetPushRegistration.currentCandidate() }, readServerRevision: { server, key in try await InboxAPI(baseURL: server, token: key).widgetTokenRevision() }, readPending: { WidgetPushTokenSecret.readPending() }, savePending: { try WidgetPushTokenSecret.savePending($0) }, send: { server, key, body in try await InboxAPI(baseURL: server, token: key).registerWidgetToken(body) })
    private let defaults: UserDefaults
    private let readDeviceKey: () -> String?
    private let readStoredWidgetToken: () -> String?
    private let saveWidgetToken: (String?) throws -> Void
    private let send: (String, String, WidgetTokenRegistration) async throws -> Void
    private let acquireLease: (() async throws -> WidgetPushUploadLease)?
    private let resample: (() async throws -> WidgetTokenRegistration?)?
    private let readServerRevision: (String, String) async throws -> Int64
    private let readPending: () -> WidgetTokenRegistrationPending?
    private let savePending: (WidgetTokenRegistrationPending?) throws -> Void
    private struct Candidate { let body: WidgetTokenRegistration; let server: String; let key: String; let observed: Double; let now: Double }
    private var pending: Candidate?
    private var running = false
    private var newestObservation = -Double.infinity
    init(defaults: UserDefaults, readDeviceKey: @escaping () -> String?, readStoredWidgetToken: @escaping () -> String?, saveWidgetToken: @escaping (String?) throws -> Void, acquireLease: (() async throws -> WidgetPushUploadLease)? = nil, resample: (() async throws -> WidgetTokenRegistration?)? = nil, readServerRevision: @escaping (String, String) async throws -> Int64 = { _, _ in 0 }, readPending: @escaping () -> WidgetTokenRegistrationPending? = { nil }, savePending: @escaping (WidgetTokenRegistrationPending?) throws -> Void = { _ in }, send: @escaping (String, String, WidgetTokenRegistration) async throws -> Void) {
        self.defaults = defaults; self.readDeviceKey = readDeviceKey; self.readStoredWidgetToken = readStoredWidgetToken; self.saveWidgetToken = saveWidgetToken; self.acquireLease = acquireLease; self.resample = resample; self.readServerRevision = readServerRevision; self.readPending = readPending; self.savePending = savePending; self.send = send
    }
    private func hash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    func update(_ body: WidgetTokenRegistration, serverURL: String, observedAt: Double, now: Double = Date().timeIntervalSince1970) async -> WidgetPushRegistrationStatus {
        guard let key = readDeviceKey(), !key.isEmpty else { return status(.unpaired) }
        guard (try? body.validate()) != nil else { return status(.retryLater) }
        guard observedAt >= newestObservation else { return .stale }
        newestObservation = observedAt
        pending = Candidate(body: body, server: serverURL, key: key, observed: observedAt, now: now)
        if running { return .queued }
        running = true; defer { running = false }
        var result: WidgetPushRegistrationStatus = .unchanged
        // A running upload completes first; changes arriving during suspension replace this one pending slot.
        while let current = pending {
            pending = nil
            result = await register(current)
        }
        return status(result)
    }
    private func status(_ value: WidgetPushRegistrationStatus) -> WidgetPushRegistrationStatus {
        defaults.set(value.label, forKey: "widgetPushStatus")
        #if DEBUG
        if value == .registered || value == .inactive { InteractionDiagnostics.record(.widgetPushRegistered) }
        if value == .retryLater { InteractionDiagnostics.record(.widgetPushRetryLater) }
        #endif
        return value
    }
    private func register(_ candidate: Candidate) async -> WidgetPushRegistrationStatus {
        guard readDeviceKey() == candidate.key else { return .unpaired }
        let scope = "widgetRegistration." + hash(candidate.server + "|" + candidate.key)
        var body = candidate.body
        var fingerprint = hash(body.token + "|" + body.environment + "|" + String(body.active))
        var lease: WidgetPushUploadLease?
        defer { lease?.release() }
        #if DEBUG
        var debugStage = WidgetPushRegistrationStage.acquire
        func observe(_ stage: WidgetPushRegistrationStage) { debugStage = stage; WidgetPushRegistrationDiagnostics.record(stage, defaults: defaults) }
        observe(.acquire)
        #endif
        do {
            lease = try await acquireLease?()
            #if DEBUG
            observe(.resample)
            #endif
            // Re-read BOTH token and configuration after the shared cross-process lease.
            if let resample {
                guard let latest = try await resample() else { return .waitingForToken }
                body = latest
                try body.validate()
                fingerprint = hash(body.token + "|" + body.environment + "|" + String(body.active))
            }
            guard readDeviceKey() == candidate.key else { return .unpaired }
            defaults.synchronize()
            let pending = readPending()
            let hasUnresolvedSnapshot = pending?.scope == scope
            if !hasUnresolvedSnapshot, defaults.string(forKey: scope + ".fingerprint") == fingerprint { return body.active ? .unchanged : .inactive }
            if defaults.string(forKey: scope + ".failedFingerprint") == fingerprint && defaults.double(forKey: scope + ".retryAfter") > candidate.now { return .retryLater }
            #if DEBUG
            observe(.readServerRev)
            #endif
            let serverRevision = try await readServerRevision(candidate.server, candidate.key)
            guard serverRevision >= 0 else { throw WidgetPushRegistrationError.notConfirmed }
            #if DEBUG
            observe(.persistCounter)
            #endif
            let stored = defaults.object(forKey: scope + ".revisionCounter")
            let localRevision: Int64
            if let stored { guard let number = stored as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), let parsed = Int64(number.stringValue), parsed >= 0 else { throw WidgetPushRegistrationError.notConfirmed }; localRevision = parsed }
            else { localRevision = 0 }
            if let pending, pending.scope == scope, pending.fingerprint == fingerprint,
               pending.body.registrationRevision >= serverRevision {
                body = pending.body // The exact unresolved revision AND body survive retries/restarts.
            } else {
                let highest = max(localRevision, serverRevision, pending?.scope == scope ? pending!.body.registrationRevision : 0)
                guard highest < Int64.max else { throw WidgetPushRegistrationError.revisionExhausted }
                body = body.withRevision(highest + 1)
            }
            defaults.set(max(localRevision, body.registrationRevision), forKey: scope + ".revisionCounter")
            // Advisory cache only. Durable pending Keychain state must still succeed before HTTP,
            // and the authenticated server revision prevents a late request rolling back newer state.
            let counterSynchronized = defaults.synchronize()
            #if DEBUG
            WidgetPushRegistrationDiagnostics.recordCounterSynchronization(counterSynchronized, defaults: defaults)
            #endif
            _ = counterSynchronized
            #if DEBUG
            observe(.savePending)
            #endif
            try savePending(.init(scope: scope, fingerprint: fingerprint, body: body))
            #if DEBUG
            observe(.send)
            #endif
            try await send(candidate.server, candidate.key, body)
            guard readDeviceKey() == candidate.key else { return .unpaired }
            #if DEBUG
            observe(.confirm)
            #endif
            try saveWidgetToken(body.active ? body.token : nil)
            try savePending(nil)
            defaults.set(fingerprint, forKey: scope + ".fingerprint")
            defaults.removeObject(forKey: scope + ".failedFingerprint"); defaults.removeObject(forKey: scope + ".retryAfter"); defaults.removeObject(forKey: scope + ".failures")
            defaults.synchronize()
            return body.active ? .registered : .inactive
        } catch {
            #if DEBUG
            WidgetPushRegistrationDiagnostics.record(debugStage, error: error, defaults: defaults)
            #endif
            // A confirmed conflict means this revision was rejected, not an unknown apply.
            // Clear only our own pending snapshot while still holding the upload lease.
            if (error as? WidgetPushRegistrationError) == .conflict, let pending = readPending(), pending.scope == scope, pending.body.registrationRevision == body.registrationRevision {
                try? savePending(nil)
                // A conflict also invalidates any older success snapshot for this identity.
                defaults.removeObject(forKey: scope + ".fingerprint")
            }
            let previous = defaults.string(forKey: scope + ".failedFingerprint") == fingerprint ? defaults.integer(forKey: scope + ".failures") : 0
            let failures = min(previous + 1, 6)
            defaults.set(fingerprint, forKey: scope + ".failedFingerprint"); defaults.set(failures, forKey: scope + ".failures")
            defaults.set(candidate.now + min(300, 5 * pow(2, Double(failures))), forKey: scope + ".retryAfter")
            defaults.synchronize()
            return .retryLater
        }
    }
}
enum WidgetPushRegistration {
    static let kind = "AgentInboxWidget"
    static func currentCandidate() async throws -> WidgetTokenRegistration? {
        guard #available(iOS 26.0, *) else { return nil }
        let configurations = try await WidgetCenter.shared.currentConfigurations()
        let info = await WidgetCenter.shared.currentPushInfo
        let environment = Bundle.main.object(forInfoDictionaryKey: "AgentInboxAPNsEnvironment") as? String ?? "sandbox"
        return WidgetTokenRegistration.resolve(currentToken: info?.token, storedToken: WidgetPushTokenSecret.read(), hasWidget: configurations.contains { $0.kind == kind }, environment: environment)
    }
    static func reconcile() async {
        guard #available(iOS 26.0, *) else { return }
        do {
            guard let body = try await currentCandidate() else { InboxConfiguration.defaults.set(WidgetPushRegistrationStatus.waitingForToken.label, forKey: "widgetPushStatus"); return }
            _ = await WidgetPushCoordinator.shared.update(body, serverURL: InboxConfiguration.serverURL, observedAt: ProcessInfo.processInfo.systemUptime)
        } catch { InboxConfiguration.defaults.set(WidgetPushRegistrationStatus.configurationUnknown.label, forKey: "widgetPushStatus") }
    }
}
