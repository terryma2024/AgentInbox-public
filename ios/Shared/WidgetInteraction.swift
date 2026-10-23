import Foundation
import CryptoKit
import Darwin

extension DecisionRequest {
    // Include the complete decision and native binding, including legacy requests
    // without a relay digest. Mutable receipt fields do not change the question.
    var widgetFingerprint: String {
        guard var object = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as? [String: Any] else { return "" }
        for field in ["state", "updatedAt", "responseId", "replyProgress"] { object.removeValue(forKey: field) }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct WidgetPresentation: Codable, Equatable {
    let id: String
    let fingerprint: String
    var isArmed: Bool
}
enum WidgetSubmissionPhase: String, Codable { case sending, submitted, unknown, failed }
struct WidgetLocalSubmission: Codable {
    let requestID: String
    let fingerprint: String
    let optionID: String
    let responseID: String
    let startedAt: Date
    var phase: WidgetSubmissionPhase
    func effectivePhase(at date: Date) -> WidgetSubmissionPhase {
        // A killed extension or wall-clock rollback requires reconciliation in App.
        phase == .sending && (date.timeIntervalSince(startedAt) > 45 || date < startedAt) ? .unknown : phase
    }
}

struct WidgetInteractionState: Codable {
    private(set) var presentation: WidgetPresentation?
    private var hasPresented = false
    private(set) var submissions: [WidgetLocalSubmission] = []

    mutating func present(_ request: DecisionRequest?) -> WidgetPresentation? {
        guard let request else { presentation = nil; return nil }
        let fingerprint = request.widgetFingerprint
        guard !fingerprint.isEmpty else { presentation = nil; return nil }
        if presentation?.fingerprint != fingerprint {
            presentation = .init(id: UUID().uuidString, fingerprint: fingerprint, isArmed: !hasPresented)
            hasPresented = true
        }
        return presentation
    }
    private func validate(_ screen: WidgetPresentation, request: DecisionRequest, at date: Date) throws {
        guard presentation == screen, !screen.fingerprint.isEmpty, screen.fingerprint == request.widgetFingerprint,
              request.canAnswer(at: date), request.canAnswerInWidget else { throw APIError.message("组件内容已变化，请刷新并查看本题") }
        guard !submissions.contains(where: { $0.effectivePhase(at: date) == .sending }) else { throw APIError.message("答案正在发送，请稍候") }
        guard !submissions.contains(where: { $0.fingerprint == screen.fingerprint && $0.phase != .failed }) else { throw APIError.message("本题已有提交记录，请进入 App 核对") }
    }
    mutating func arm(_ screen: WidgetPresentation, request: DecisionRequest, at date: Date = Date()) throws {
        try validate(screen, request: request, at: date)
        guard !screen.isArmed else { throw APIError.message("请查看当前题目") }
        // Rotate the token: a queued unlock from the collapsed card is now stale.
        presentation = .init(id: UUID().uuidString, fingerprint: screen.fingerprint, isArmed: true)
    }
    mutating func begin(_ screen: WidgetPresentation, request: DecisionRequest, optionID: String, responseID: String, at date: Date = Date()) throws {
        try validate(screen, request: request, at: date)
        guard screen.isArmed, !responseID.isEmpty, request.options.contains(where: { $0.id == optionID }) else { throw APIError.message("请先查看并展开本题选项") }
        submissions.removeAll { $0.fingerprint == screen.fingerprint && $0.phase == .failed }
        submissions.append(.init(requestID: request.id, fingerprint: screen.fingerprint, optionID: optionID, responseID: responseID, startedAt: date, phase: .sending))
        presentation = .init(id: UUID().uuidString, fingerprint: screen.fingerprint, isArmed: false)
    }
    mutating func finish(responseID: String, phase: WidgetSubmissionPhase) {
        guard let index = submissions.firstIndex(where: { $0.responseID == responseID }) else { return }
        submissions[index].phase = phase
    }
    func submission(for request: DecisionRequest) -> WidgetLocalSubmission? {
        submissions.last { $0.requestID == request.id && $0.fingerprint == request.widgetFingerprint }
    }
    func displayRequests(_ requests: [DecisionRequest], at date: Date = Date()) -> [DecisionRequest] {
        requests.map { request in
            guard request.canAnswer(at: date), let submission = submission(for: request) else { return request }
            var visible = request
            switch submission.effectivePhase(at: date) {
            case .sending, .submitted: visible.state = .submitting
            case .unknown: visible.state = .unknown
            case .failed: break
            }
            return visible
        }
    }
    func sendingCount(at date: Date = Date()) -> Int { submissions.filter { $0.effectivePhase(at: date) == .sending }.count }
    func status(for request: DecisionRequest, at date: Date = Date()) -> String? {
        guard let submission = submission(for: request) else { return nil }
        switch submission.effectivePhase(at: date) {
        case .sending: return request.state == .pending || request.state == .submitting ? "正在发送…" : nil
        case .unknown: return request.state == .pending || request.state == .unknown ? "提交结果未知，请进 App 核对" : nil
        case .submitted: return [.pending, .submitting].contains(request.state) && request.replyProgress == nil ? "已提交，等待回执" : nil
        case .failed: return request.canAnswer(at: date) ? "尚未提交，请展开后重试" : nil
        }
    }
}

// App and Widget may run in different processes. A file lock makes claiming a
// presentation atomic; a UserDefaults read/modify/write cannot protect this.
struct WidgetInteractionStore {
    let directory: URL
    static var shared: Self {
        let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: InboxConfiguration.appGroup)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return .init(directory: root.appendingPathComponent("widget-interaction-v1", isDirectory: true))
    }
    private struct Saved: Codable { let context: ReplyJournalContext; let state: WidgetInteractionState }
    func update<T>(context: ReplyJournalContext, _ operation: (inout WidgetInteractionState) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(directory.appendingPathComponent("interaction.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw APIError.message("无法保护组件操作，请进入 App") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw APIError.message("无法锁定组件操作，请进入 App") }
        defer { flock(fd, LOCK_UN) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let scope = SHA256.hash(data: try encoder.encode(context)).map { String(format: "%02x", $0) }.joined()
        let file = directory.appendingPathComponent(scope + ".json")
        var state = WidgetInteractionState()
        if FileManager.default.fileExists(atPath: file.path) {
            // Corrupt/unreadable state must fail closed, never reset consumed taps.
            let saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: file))
            if saved.context == context { state = saved.state }
        }
        let result = try operation(&state)
        try JSONEncoder().encode(Saved(context: context, state: state)).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return result
    }
}

enum WidgetAnswerLayout {
    static func fits(_ request: DecisionRequest, compact: Bool, large: Bool) -> Bool {
        guard request.canAnswerInWidget else { return false }
        // Character counts do not bound rendered lines when explicit separators
        // are present. Never hide a qualifier while offering a direct answer.
        guard ([request.title, request.body] + request.options.map(\.label)).allSatisfy({
            $0.rangeOfCharacter(from: .newlines) == nil
        }) else { return false }
        if compact { return request.kind == "choice" && request.title.count <= 8 && request.body.count <= 9 && request.options.count <= 2 && request.options.allSatisfy { $0.label.count <= 4 } }
        return large || (request.title.count <= 16 && request.body.count <= 42 && request.options.allSatisfy { $0.label.count <= 10 } && request.options.reduce(0) { $0 + $1.label.count } <= 18)
    }
}
