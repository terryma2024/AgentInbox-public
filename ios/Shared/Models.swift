import Foundation

enum RequestState: String, Codable, CaseIterable {
    case pending, submitting, adopted, handledLocally, expired, invalidated, unknown
    var label: String {
        switch self {
        case .pending: return "待回答"
        case .submitting: return "提交中"
        case .adopted: return "原任务已采用"
        case .handledLocally: return "已在本机处理"
        case .expired: return "已过期"
        case .invalidated: return "已失效"
        case .unknown: return "结果未知"
        }
    }
}
struct DecisionOption: Codable, Identifiable, Equatable { let id: String; let label: String }
struct DecisionQuestion: Codable, Identifiable {
    let id: String
    let header: String?
    let prompt: String
    let options: [DecisionOption]
    let multiSelect: Bool
    let allowText: Bool
}
struct DecisionRequest: Codable, Identifiable {
    var id: String { requestId }
    let requestId: String
    let revision: Int
    let expiresAt: Double
    var state: RequestState
    let kind: String
    let hostId: String
    let engine: String
    let runtimeId: String?
    let sessionId: String?
    let turnId: String?
    let nativeRequestId: String?
    let itemId: String?
    let title: String
    let body: String
    let options: [DecisionOption]
    let multiSelect: Bool
    let createdAt: Double
    let updatedAt: Double
    let questions: [DecisionQuestion]?
    var projectPath: String? = nil
    var sessionLabel: String? = nil
    var launchSurface: String? = nil
    var operationSummary: String? = nil
    var allowText: Bool? = nil
    var responseId: String? = nil
    var bindingDigest: String? = nil
    var replyProgress: ReplyProgress? = nil
    func canAnswer(at date: Date = Date()) -> Bool { state == .pending && expiresAt > date.timeIntervalSince1970 }
    var shortSessionID: String? { sessionId.flatMap { $0.isEmpty ? nil : String($0.prefix(8)) } }
    var sessionDisplayLabel: String? { sessionLabel.flatMap { $0.isEmpty ? nil : $0 } ?? shortSessionID }
    var projectBasename: String? { projectPath.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0).lastPathComponent } }
    var displayState: RequestState { state == .pending && !canAnswer() ? .expired : state }
    var canAnswerInWidget: Bool {
        guard canAnswer(), !multiSelect, ["choice", "approval", "permission"].contains(kind),
              !options.isEmpty, options.count <= 3, options.allSatisfy({ $0.label.count <= 16 }),
              title.count <= 24, body.count <= 60, body.split(separator: "\n").count <= 2,
              (questions?.count ?? 0) <= 1 else { return false }
        if let question = questions?.first {
            guard !question.multiSelect, question.prompt == body else { return false }
        }
        if ["permission", "approval"].contains(kind) {
            guard let summary = operationSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !summary.isEmpty, summary.count <= 60, body.contains(summary) else { return false }
        }
        return true
    }
    var deepLink: URL { URL(string: "agentinbox://request/\(requestId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? requestId)")! }
    static var demo: Self {
        Self(requestId: "demo-choice", revision: 1, expiresAt: Date().addingTimeInterval(3600).timeIntervalSince1970, state: .pending, kind: "choice", hostId: "mac-mini", engine: "codex", runtimeId: "demo", sessionId: "demo-session", turnId: "demo-turn", nativeRequestId: "demo-native", itemId: nil, title: "选择下一步", body: "这项任务需要你的决定。请选择下一步处理方式。", options: [.init(id: "inspect", label: "先查看差异"), .init(id: "test", label: "运行测试")], multiSelect: false, createdAt: Date().timeIntervalSince1970, updatedAt: Date().timeIntervalSince1970, questions: nil)
    }
    static func demoFixture(id: String, title: String, kind: String, options: [DecisionOption], multiSelect: Bool = false, questions: [DecisionQuestion]? = nil, allowText: Bool? = nil) -> Self {
        Self(requestId: id, revision: 1, expiresAt: Date().addingTimeInterval(3600).timeIntervalSince1970, state: .pending, kind: kind, hostId: "mac-mini", engine: "claude", runtimeId: "demo", sessionId: "demo-session", turnId: "demo-turn", nativeRequestId: "demo-native", itemId: nil, title: title, body: kind == "text" ? "请用中文说明你希望采用的处理方式。" : "请选择希望执行的检查，可选择多项。", options: options, multiSelect: multiSelect, createdAt: Date().timeIntervalSince1970, updatedAt: Date().timeIntervalSince1970, questions: questions, allowText: allowText)
    }

}
struct QuestionAnswer: Codable, Equatable { let optionIds: [String]; let text: String? }
struct DecisionResponse: Codable, Equatable {
    let responseId: String
    let requestId: String
    let revision: Int
    let optionIds: [String]
    let text: String?
    let answers: [String: QuestionAnswer]
    var bindingDigest: String? = nil
}
struct ResponseReceipt: Codable { let requestId: String; let responseId: String; let state: RequestState; var bindingDigest: String? = nil; var replyProgress: ReplyProgress? = nil }
struct HostStatus: Codable, Identifiable { var id: String { hostId }; let hostId: String; let name: String; let online: Bool; let lastSeen: Double }
struct RequestList: Codable { let requests: [DecisionRequest] }
struct HostList: Codable { let hosts: [HostStatus] }
enum RequestRoute {
    static func requestID(from url: URL) -> String? {
        guard url.scheme == "agentinbox", url.host == "request", url.pathComponents.count == 2 else { return nil }
        return url.lastPathComponent.removingPercentEncoding
    }
}

// Shared with the timeline provider so request selection can be regression tested.
enum WidgetInboxSelection {
    static func current(in requests: [DecisionRequest], pinnedID: String? = nil, at date: Date = Date()) -> DecisionRequest? {
        if let pinnedID { return requests.first { $0.id == pinnedID } }
        // A delayed native receipt must not block a different unanswered request.
        // Selection never changes the previous request's canonical state.
        return requests.first { $0.canAnswer(at: date) }
            ?? requests.first { $0.isActiveInboxEntry && $0.state != .pending }
    }
}


struct ReplyMilestone: Codable { let at: Double? }
struct ReplyProgress: Codable {
    let schemaVersion: Int
    let requestId: String
    let responseId: String
    let bindingDigest: String
    let submitted: ReplyMilestone?
    let received: ReplyMilestone?
    let continued: ReplyMilestone?
    let continuationObservation: String
    var nativeObservation: String? = nil
}
struct ReplyStatus {
    let submitted: Bool
    let received: Bool
    let continued: Bool
    let explanation: String
    var label: String { continued ? "任务已继续运行" : (received ? "原调用已接收" : (submitted ? "已提交" : "尚无提交回执")) }
}
extension DecisionRequest {
    var isActiveInboxEntry: Bool { [.pending, .submitting, .unknown].contains(state) || awaitingContinuation || (replyProgress?.nativeObservation == "answerSourceUnconfirmed" && !replyStatus().received) }
    var replyDisplayLabel: String { replyLabel() }
    func replyLabel(for localResponseID: String? = nil) -> String {
        if let localResponseID, let responseId, localResponseID != responseId { return "另一份答案已处理" }
        if state == .pending || [.handledLocally, .expired, .invalidated].contains(state) { return displayState.label }
        let status = replyStatus(for: localResponseID)
        if status.continued || status.received { return status.label }
        if state == .adopted { return replyProgress?.nativeObservation == "answerSourceUnconfirmed" ? "来源未确认" : "旧版采用记录" }
        return status.submitted ? status.label : displayState.label
    }
    var awaitingContinuation: Bool {
        let status = replyStatus()
        return status.received && !status.continued && replyProgress?.continuationObservation == "awaiting"
    }
    func replyStatus(for localResponseID: String? = nil) -> ReplyStatus {
        func status(_ submitted: Bool = false, _ received: Bool = false, _ continued: Bool = false, _ reason: String) -> ReplyStatus { .init(submitted: submitted, received: received, continued: continued, explanation: reason) }
        if let localResponseID, let responseId, localResponseID != responseId { return status(false, false, false, "原请求已由另一份答案处理；这份原答案未获接收证明。") }
        guard let p = replyProgress else {
            let submitted = state != .pending && responseId?.isEmpty == false
            if state == .adopted { return status(submitted, false, false, "旧版采用记录；未提供原调用接收及后续执行的分步证明。") }
            return status(submitted, false, false, submitted ? "服务器已保存这份答案；尚无原调用接收证明。" : "尚未获得可核对的分步回执，请刷新查看。")
        }
        guard p.schemaVersion == 1, p.requestId == id, p.responseId == responseId,
              localResponseID == nil || localResponseID == p.responseId,
              p.bindingDigest == bindingDigest, p.bindingDigest.count == 64,
              p.bindingDigest.allSatisfy({ $0.isHexDigit }),
              p.submitted != nil, p.submitted?.at == nil || (p.submitted?.at?.isFinite == true && p.submitted!.at! >= 0) else { return status(false, false, false, "回执与原请求不匹配，结果未知。") }
        let received = p.received?.at.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let continued = p.continued?.at.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let mayReceive = state == .adopted && received != nil
        let didContinue = mayReceive && continued != nil && continued! >= received! && p.continuationObservation == "confirmed"
        if state == .handledLocally { return status(true, false, false, "原调用已在本机处理；提交的答案未获采用证明。") }
        if p.nativeObservation == "answerSourceUnconfirmed" && !mayReceive { return status(true, false, false, "原调用答案匹配，来源未确认；不能据此认定手机答案被采用。") }
        if didContinue { return status(true, true, true, "已观察到原执行链的后续进展；这不表示整个任务已完成。") }
        if mayReceive { return status(true, true, false, p.continuationObservation == "awaiting" ? "正在等待原执行链的后续进展证明。" : "原调用已接收；后续执行尚无法确认，不会重复派发。") }
        return status(true, false, false, state == .unknown ? "已提交；原调用是否接收仍未知，不会自动重复派发。" : "已提交；尚无原调用接收证明。")
    }
}
