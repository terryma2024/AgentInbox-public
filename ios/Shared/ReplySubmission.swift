import Foundation

protocol DecisionTransport {
    func request(_ id: String) async throws -> DecisionRequest
    func submit(_ answer: DecisionResponse) async throws -> ResponseReceipt
    func replyCapabilities() async throws -> ReplyCapabilities?
}
struct ReplyCapabilities: Codable { let replyProgressVersion: Int; let bindingDigestVersion: Int }
extension DecisionTransport { func replyCapabilities() async throws -> ReplyCapabilities? { nil } }
enum ReplyDraft {
    static func make(request: DecisionRequest, optionIds: [String], text: String?, questionAnswers: [String: QuestionAnswer], responseID: String = UUID().uuidString.lowercased()) -> DecisionResponse {
        // 原生单题保留 questions 提供题面，但 relay 单题协议使用顶层字段。
        if request.kind != "questions", let question = request.questions?.first, let answer = questionAnswers[question.id] {
            return DecisionResponse(responseId: responseID, requestId: request.id, revision: request.revision, optionIds: answer.optionIds.sorted(), text: answer.text, answers: [:], bindingDigest: request.bindingDigest)
        }
        return DecisionResponse(responseId: responseID, requestId: request.id, revision: request.revision, optionIds: optionIds.sorted(), text: text, answers: request.kind == "questions" ? questionAnswers : [:], bindingDigest: request.bindingDigest)
    }
}
enum ReplySubmission {
    static func send(_ answer: DecisionResponse, using transport: any DecisionTransport, validateLatest: (DecisionRequest) throws -> Void = { _ in }) async throws -> ResponseReceipt {
        let context = ReplyJournalContext.current
        let latest = try await transport.request(answer.requestId)
        guard context == ReplyJournalContext.current else { throw APIError.message("连接或配对已变化，请刷新原请求") }
        try validateLatest(latest)
        if latest.bindingDigest != nil {
            let capability = try await transport.replyCapabilities()
            guard capability?.replyProgressVersion == 1, capability?.bindingDigestVersion == 1 else { throw APIError.message("中继分步回执能力未确认，请刷新后重试") }
        }
        guard latest.id == answer.requestId, latest.revision == answer.revision, latest.canAnswer() else { throw APIError.message("请求已变化或已被处理，请刷新") }
        try ReplyValidation.validate(answer, for: latest)
        guard context == ReplyJournalContext.current else { throw APIError.message("连接或配对已变化，请刷新原请求") }
        try ResponseJournal.save(answer, for: latest, context: context)
        // 网络重试仅访问 relay，复用相同 responseId。host 是否派发由持久化事务决定。
        let receipt = try await transport.submit(answer)
        guard context == ReplyJournalContext.current else { throw APIError.message("连接已变化，原提交结果需在原连接核对") }
        guard receipt.requestId == answer.requestId, receipt.responseId == answer.responseId, receipt.state != .pending,
              latest.bindingDigest == nil || receipt.bindingDigest == latest.bindingDigest else { throw APIError.message("回执与原答案不匹配，提交结果未知") }
        return receipt
    }
}
enum WidgetReplySubmission {
    static func send(cached: DecisionRequest, optionID: String, responseID: String, using transport: any DecisionTransport) async throws -> ResponseReceipt {
        guard ResponseJournal.legacy(for: cached) == nil else { throw APIError.message("旧版原答案来源未核对，请打开收件箱查看") }
        guard cached.canAnswerInWidget, cached.options.contains(where: { $0.id == optionID }) else { throw APIError.message("请打开请求详情回复") }
        let answer: DecisionResponse
        if let saved = ResponseJournal.pending(for: cached) {
            guard saved.optionIds == [optionID], saved.text == nil, saved.answers.isEmpty else { throw APIError.message("已有其他原答案，请打开收件箱查看") }
            answer = saved
        } else {
            answer = DecisionResponse(responseId: responseID, requestId: cached.id, revision: cached.revision, optionIds: [optionID], text: nil, answers: [:], bindingDigest: cached.bindingDigest)
        }
        return try await ReplySubmission.send(answer, using: transport) { latest in
            guard !cached.widgetFingerprint.isEmpty, latest.widgetFingerprint == cached.widgetFingerprint,
                  latest.canAnswerInWidget else { throw APIError.message("请求内容已变化，请刷新并查看原题") }
        }
    }
}

enum ReplyValidation {
    static func validate(_ answer: DecisionResponse, for request: DecisionRequest) throws {
        guard answer.requestId == request.id, answer.revision == request.revision, !answer.responseId.isEmpty else { throw APIError.message("答案与当前请求不匹配") }
        guard answer.bindingDigest == request.bindingDigest else { throw APIError.message("请求内容已变化，请刷新原题") }
        if request.kind == "questions" {
            let questions = request.questions ?? []
            guard !questions.isEmpty, answer.optionIds.isEmpty, (answer.text ?? "").isEmpty,
                  Set(answer.answers.keys) == Set(questions.map(\.id)) else { throw APIError.message("请完整回答每一题") }
            for question in questions {
                guard let value = answer.answers[question.id] else { throw APIError.message("缺少问题答案") }
                try validateSelection(value, options: question.options, multiSelect: question.multiSelect, allowText: question.allowText)
            }
        } else {
            guard answer.answers.isEmpty else { throw APIError.message("单题答案格式无效") }
            try validateSelection(.init(optionIds: answer.optionIds, text: answer.text), options: request.options, multiSelect: request.multiSelect, allowText: request.kind == "text" || request.allowText == true)
        }
    }
    private static func validateSelection(_ value: QuestionAnswer, options: [DecisionOption], multiSelect: Bool, allowText: Bool) throws {
        let text = value.text ?? ""
        let available = Set(options.map(\.id))
        guard Set(value.optionIds).count == value.optionIds.count, value.optionIds.allSatisfy({ available.contains($0) }),
              multiSelect || value.optionIds.count <= 1 else { throw APIError.message("所选选项无效") }
        guard text.utf8.count <= 16000, text.isEmpty || allowText else { throw APIError.message("此请求不允许这项文字回复") }
        guard value.optionIds.isEmpty || text.isEmpty else { throw APIError.message("请选择选项或输入文字，两者不能同时提交") }
        guard !value.optionIds.isEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw APIError.message("请先填写答案") }
    }
}


// A submitting receipt can precede the host's native acknowledgement. Read the
// canonical inbox briefly so the Intent-triggered timeline need not stay on it.
// This never retries an answer or infers a state from time or connectivity.
enum WidgetInboxRefresh {
    static func fetch(using fetch: (TimeInterval) async throws -> [DecisionRequest],
                      pause: (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
                      uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) async throws -> [DecisionRequest] {
        // Preserve the ordinary first fetch budget for a cold Tailscale connection.
        var latest = try await fetch(12)
        let deadline = uptime() + 5
        for _ in 0..<4 {
            guard !Task.isCancelled, latest.contains(where: { $0.state == .submitting }) else { break }
            let beforePause = deadline - uptime()
            guard beforePause > 0 else { break }
            do {
                try await pause(min(0.75, beforePause))
                let remaining = deadline - uptime()
                guard !Task.isCancelled, remaining > 0 else { break }
                let candidate = try await fetch(min(1.25, remaining))
                // Cancellation and late delivery must not replace the last confirmed list.
                guard !Task.isCancelled, uptime() < deadline else { break }
                latest = candidate
            } catch { break }
        }
        return latest
    }
}
