import Foundation

enum DiagnosticState: String, Codable { case passed, failed, unknown, unsupported, running
    var label: String { switch self { case .passed: return "通过"; case .failed: return "异常"; case .unknown: return "未确认"; case .unsupported: return "未支持"; case .running: return "检查中" } }
}
enum DiagnosticStage: String, Codable {
    case relay, sync, host, adapter, capture, claudeCapture, recovery, push, submitted, received, continued
    var label: String { switch self {
    case .relay: return "中转与认证"; case .sync: return "收件箱同步"; case .host: return "主机心跳"; case .adapter: return "Codex 适配器"; case .capture: return "Codex 采集"; case .claudeCapture: return "Claude hook 采集"; case .recovery: return "启动对账与回传准备"; case .push: return "测试推送到达"; case .submitted: return "测试答案已提交"; case .received: return "原调用已接收"; case .continued: return "测试任务已继续"
    } }
}
enum DiagnosticReason: String, Codable {
    case hookObserved, hookUnobserved, adapterFailed, diagnosticBusy, ok, notChecked, relayUnavailable, authenticationFailed, unsupportedRelay, syncFailed, heartbeatStale, observationMissing, observationStale, adapterDisabled, adapterStarting, captureStale, hostDraining, reconciliationPending, nativeUnavailable, nativeStartFailed, nativeTimeout, testInterrupted, testExpired, awaitingTest, awaitingAnswer, receptionUnconfirmed, continuationUnconfirmed, pushUnregistered, pushNotConfigured, pushQueued, pushAccepted, pushFailed, pushUnobserved, notificationObserved, unknownFailure
    var advice: String { switch self {
    case .hookObserved: return "最近已观察到合法 Claude hook 事件；下一次请求仍需实际验证。"
    case .hookUnobserved: return "近期未观察到 Claude hook 事件；检查 hook 安装、采集范围及是否产生过请求。"
    case .adapterFailed: return "适配器报告异常，检查原生进程与采集接口。"
    case .diagnosticBusy: return "已有进行中的测试或请求已变化；点击一键自检核对现有测试。"
    case .ok: return "本次检查已确认。"
    case .notChecked: return "点击一键自检，获取当前状态。"
    case .relayUnavailable: return "检查 iPhone 网络、Tailscale VPN 与中转服务是否可达。"
    case .authenticationFailed: return "检查此设备配对或服务端撤销状态。"
    case .unsupportedRelay: return "当前中转缺少诊断协议，请升级中转后重试。"
    case .syncFailed: return "中转可访问，但收件箱读取失败；检查同步接口。"
    case .heartbeatStale: return "主机心跳超时；检查主机 daemon 及主机到中转的网络。"
    case .observationMissing: return "主机尚未报告采集诊断；检查 host 版本。"
    case .observationStale: return "采集观测已过时，等待新心跳或检查 host。"
    case .adapterDisabled: return "主机未启用 Codex socket；检查适配器配置。"
    case .adapterStarting: return "适配器初始化未确认，检查原生进程与 socket。"
    case .captureStale: return "最近没有成功完成采集扫描，检查适配器与采集范围。"
    case .hostDraining: return "主机正在排空，暂不接收新测试。"
    case .reconciliationPending: return "启动对账未完成，检查主机到中转的链路及持久回执。"
    case .nativeUnavailable: return "自动原生闭环需要已启用来源扩展的 Codex；当前组合未支持。"
    case .nativeStartFailed: return "原生测试会话启动失败，检查引擎版本与本地测试提供者。"
    case .nativeTimeout: return "原生测试超时；检查采集和原调用回执。"
    case .testInterrupted: return "测试已中断，请只读核对已有结果。"
    case .testExpired: return "测试已到期，未确认步骤保持未确认；可创建新的测试。"
    case .awaitingTest: return "等待主机领取并生成独立测试调用。"
    case .awaitingAnswer: return "请在下方选择测试答案。"
    case .receptionUnconfirmed: return "答案提交不能证明原调用接收；等待绑定本次答案的原生证明。"
    case .continuationUnconfirmed: return "继续运行需要独立的后续原生进展证明。"
    case .pushUnregistered: return "此设备尚无有效推送注册，请启用通知并检查 APNs 注册。"
    case .pushNotConfigured: return "中转未配置 APNs，测试取题与回复可独立进行。"
    case .pushQueued: return "测试通知正在排队，尚未确认 APNs 接受。"
    case .pushAccepted: return "APNs 已接受；尚未在此 iPhone 观察到本次测试通知。"
    case .pushFailed: return "APNs 发送失败，检查推送环境、凭据与设备注册。"
    case .pushUnobserved: return "尚未观察到本次测试通知。"
    case .notificationObserved: return "此 iPhone 已观察到本次测试通知；回复闭环仍需独立确认。"
    case .unknownFailure: return "诊断未完成，重新检查；分享报告仅保留固定错误分类。"
    } }
}
struct DiagnosticCheck: Codable, Identifiable {
    let subject: Int
    let stage: DiagnosticStage
    let state: DiagnosticState
    let reason: DiagnosticReason
    var ageSeconds: Int? = nil
    var id: String { "\(subject).\(stage.rawValue)" }
}
struct DiagnosticObservation: Decodable {
    let codex: String
    let claude: String
    let scanAt: Double?
    let hookAt: Double?
    let reconciled: Bool
    let draining: Bool
    let nativeProof: Bool
}
struct DiagnosticHost: Decodable, Identifiable {
    let hostId: String
    let lastSeen: Double
    let online: Bool
    let observedAt: Double?
    let observation: DiagnosticObservation?
    var id: String { hostId }
}
struct DiagnosticSnapshot: Decodable {
    let schemaVersion: Int
    let checkedAt: Double
    let hosts: [DiagnosticHost]
    let pushRegistered: Bool
    let pushProviderConfigured: Bool?
    let recentTestIds: [String]
}
struct DiagnosticTest: Decodable {
    let testId: String
    let hostId: String
    let createdAt: Double
    let expiresAt: Double
    let phase: String
    let code: String?
    let mode: String
    let request: DecisionRequest?
    let push: String
    // Ignore server summary booleans. The client independently checks the exact
    // request/answer binding through the shared production interpreter.
    func checks(expectedResponseID: String?, now: Double, notificationObserved: Bool, subject: Int = 0) -> [DiagnosticCheck] {
        let status = expectedResponseID.flatMap { id in request?.replyStatus(for: id) }
        let received = status?.received == true
        let continued = status?.continued == true
        let submitted = status?.submitted == true
        let expired = expiresAt <= now || phase == "expired"
        let unsupported = phase == "unsupported" || mode == "push"
        let failure = phase == "failed"
        let safeCode = code.flatMap(DiagnosticReason.init(rawValue:)) ?? .unknownFailure
        let waiting: DiagnosticReason = expired ? .testExpired : (failure ? safeCode : (request == nil ? .awaitingTest : (submitted ? .receptionUnconfirmed : .awaitingAnswer)))
        let pendingState: DiagnosticState = unsupported ? .unsupported : (expired || failure ? .failed : .unknown)
        let pushReason: DiagnosticReason = notificationObserved ? .notificationObserved : ["accepted": .pushAccepted, "failed": .pushFailed, "unregistered": .pushUnregistered, "queued": .pushQueued][push] ?? .pushUnobserved
        return [
            .init(subject: subject, stage: .push, state: notificationObserved ? .passed : (push == "failed" || push == "unregistered" ? .failed : .unknown), reason: pushReason),
            .init(subject: subject, stage: .submitted, state: submitted ? .passed : pendingState, reason: submitted ? .ok : (unsupported ? .nativeUnavailable : waiting)),
            .init(subject: subject, stage: .received, state: received ? .passed : pendingState, reason: received ? .ok : (unsupported ? .nativeUnavailable : waiting)),
            .init(subject: subject, stage: .continued, state: continued ? .passed : pendingState, reason: continued ? .ok : (unsupported ? .nativeUnavailable : (received && !expired && !failure ? .continuationUnconfirmed : waiting)))
        ]
    }
}
struct DiagnosticReport: Encodable {
    let schemaVersion = 1
    let appVersionComponents: [Int]
    let osMajor: Int
    let stages: [DiagnosticCheck]
    init(stages: [DiagnosticCheck], appVersion: String, osMajor: Int) {
        self.stages = stages
        // Numeric components only: arbitrary bundle strings never enter exports.
        self.appVersionComponents = Array(appVersion.split(separator: ".").prefix(4).prefix { !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }.compactMap { Int($0) })
        self.osMajor = max(0, min(1000, osMajor))
    }
    func shareText() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
    static func age(_ timestamp: Double?, now: Double) -> Int? {
        guard let timestamp, timestamp.isFinite, now.isFinite, timestamp > 0, timestamp <= now else { return nil }
        return Int(min(604800, now - timestamp))
    }
    static func checks(snapshot: DiagnosticSnapshot, sync: DiagnosticState, now: Double) -> [DiagnosticCheck] {
        let fresh = age(snapshot.checkedAt, now: now).map { $0 < 30 } == true
        var checks: [DiagnosticCheck] = [
            .init(subject: 0, stage: .relay, state: fresh ? .passed : .unknown, reason: fresh ? .ok : .observationStale),
            .init(subject: 0, stage: .sync, state: fresh ? sync : .unknown, reason: fresh ? (sync == .passed ? .ok : .syncFailed) : .observationStale)
        ]
        for (index, host) in snapshot.hosts.prefix(200).enumerated() {
            let subject = index + 1
            let hostAge = age(host.lastSeen, now: now)
            let online = hostAge.map { $0 < 30 } == true
            checks.append(.init(subject: subject, stage: .host, state: fresh ? (online ? .passed : .failed) : .unknown, reason: fresh ? (online ? .ok : .heartbeatStale) : .observationStale, ageSeconds: hostAge))
            let observedAge = age(host.observedAt, now: now)
            guard fresh, online, let observation = host.observation, observedAge.map({ $0 < 30 }) == true else {
                for stage in [DiagnosticStage.adapter, .capture, .claudeCapture, .recovery] { checks.append(.init(subject: subject, stage: stage, state: .unknown, reason: host.observation == nil ? .observationMissing : .observationStale, ageSeconds: observedAge)) }
                continue
            }
            let hookAge = age(observation.hookAt, now: now)
            let hookObserved = observation.claude == "observed" && hookAge.map { $0 < 300 } == true
            checks.append(.init(subject: subject, stage: .claudeCapture, state: hookObserved ? .passed : .unknown, reason: hookObserved ? .hookObserved : .hookUnobserved, ageSeconds: hookAge))
            let ready = observation.codex == "ready"
            checks.append(.init(subject: subject, stage: .adapter, state: ready ? .passed : (observation.codex == "disabled" ? .unsupported : (observation.codex == "failed" ? .failed : .unknown)), reason: ready ? .ok : (observation.codex == "disabled" ? .adapterDisabled : (observation.codex == "failed" ? .adapterFailed : .adapterStarting))))
            let scanAge = age(observation.scanAt, now: now)
            let scanned = ready && scanAge.map { $0 < 30 } == true
            checks.append(.init(subject: subject, stage: .capture, state: scanned ? .passed : (ready ? .failed : .unknown), reason: scanned ? .ok : (ready ? .captureStale : (observation.codex == "disabled" ? .adapterDisabled : .adapterStarting)), ageSeconds: scanAge))
            checks.append(.init(subject: subject, stage: .recovery, state: observation.draining || !observation.reconciled ? .failed : .passed, reason: observation.draining ? .hostDraining : (!observation.reconciled ? .reconciliationPending : .ok)))
        }
        return checks
    }
}
extension InboxAPI {
    func diagnosticSnapshot() async throws -> DiagnosticSnapshot { try await call("/v1/diagnostics") }
    func startDiagnostic(id: String, host: String, mode: String) async throws -> DiagnosticTest {
        struct Body: Encodable { let testId: String; let hostId: String; let mode: String }
        return try await call("/v1/diagnostics/tests", method: "POST", body: JSONEncoder().encode(Body(testId: id, hostId: host, mode: mode)))
    }
    func diagnosticTest(_ id: String) async throws -> DiagnosticTest {
        guard id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { throw APIError.message("诊断标识无效") }
        return try await call("/v1/diagnostics/tests/\(id)")
    }
}

struct DiagnosticRoute: Identifiable {
    let id: String
    init?(url: URL) {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard url.scheme == "agentinbox", url.host == "diagnostics", parts.count == 1, Self.valid(parts[0]) else { return nil }
        id = parts[0]
    }
    private static func valid(_ id: String) -> Bool { !id.isEmpty && id.count <= 256 && id.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 } }
    static func notificationURL(_ info: [AnyHashable: Any]) -> URL? {
        guard let id = info["diagnosticTestId"] as? String, valid(id) else { return nil }
        return URL(string: "agentinbox://diagnostics/\(id)")
    }
}
