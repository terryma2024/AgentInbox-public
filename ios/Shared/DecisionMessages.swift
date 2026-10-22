import Foundation
import CoreFoundation

/// Turn the preserved decision envelope into readable messages without changing
/// the source used for binding or dropping unfamiliar tool parameters.
enum DecisionMessages {
    private static let labels = [
        "tool_name": "工具", "command": "原始命令", "cwd": "工作目录", "reason": "请求原因",
        "environmentId": "执行环境", "kind": "操作类型", "commandActions": "命令中的操作",
        "additionalPermissions": "请求权限", "networkApprovalContext": "网络访问",
        "proposedExecpolicyAmendment": "命令策略调整", "proposedNetworkPolicyAmendments": "网络策略调整",
        "description": "说明", "timeout": "超时", "multiSelect": "允许多选", "allowText": "允许文字回复",
        "isOther": "允许其他答案", "isSecret": "敏感输入", "host": "目标主机", "port": "端口", "protocol": "协议"
    ]
    private static let order = ["tool_name", "command", "cwd", "reason", "environmentId", "kind", "commandActions", "additionalPermissions", "networkApprovalContext", "proposedExecpolicyAmendment", "proposedNetworkPolicyAmendments"]

    static func parts(from original: String) -> [DecisionOriginalPart] {
        guard let data = original.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return [.init(id: "original", title: "原始消息", text: original)]
        }
        guard let fields = value as? [String: Any] else {
            return [.init(id: "original", title: "原始消息", text: text(value))]
        }
        var result: [DecisionOriginalPart] = []
        append(fields, prefix: "", questionsAreNative: fields["tool_name"] == nil, unwrapInput: true, to: &result)
        return result.isEmpty ? [.init(id: "original", title: "原始消息", text: "（无）")] : result
    }

    /// Only decode the legacy adapter's exact generated envelope. User messages
    /// and JSON appearing inside a genuine question remain unchanged.
    static func legacyToolParts(from body: String) -> [DecisionOriginalPart]? {
        guard body.hasPrefix("工具："),
              let cwd = body.range(of: "\n工作目录："),
              let input = body.range(of: "\n参数：", range: cwd.upperBound..<body.endIndex),
              let data = String(body[input.upperBound...]).data(using: .utf8),
              let parameters = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        let fields: [String: Any] = ["tool_name": String(body[body.index(body.startIndex, offsetBy: 3)..<cwd.lowerBound]),
                                     "cwd": String(body[cwd.upperBound..<input.lowerBound]), "tool_input": parameters]
        var result: [DecisionOriginalPart] = []
        append(fields, prefix: "", questionsAreNative: false, unwrapInput: true, to: &result)
        return result
    }

    private static func append(_ fields: [String: Any], prefix: String, questionsAreNative: Bool, unwrapInput: Bool = false, to result: inout [DecisionOriginalPart]) {
        let specialized = (questionsAreNative ? ["questions"] : []) + (unwrapInput ? ["tool_input"] : [])
        for key in order + fields.keys.filter({ !order.contains($0) && !specialized.contains($0) }).sorted() {
            guard let value = fields[key] else { continue }
            let id = key == "command" && !result.contains(where: { $0.id == "command" }) ? "command" : prefix + key
            result.append(.init(id: id, title: labels[key] ?? key, text: text(value)))
        }
        if questionsAreNative, let questions = fields["questions"] as? [Any] {
            for (index, value) in questions.enumerated() {
                let id = prefix + "question-\(index)"
                guard var question = value as? [String: Any] else {
                    result.append(.init(id: id, title: "问题 \(index + 1)", text: text(value))); continue
                }
                let header = (question["header"] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                if header != nil { question.removeValue(forKey: "header") }
                let promptKey = question["question"] != nil ? "question" : "prompt"
                result.append(.init(id: id, title: "问题 \(index + 1)" + (header.map { " · \($0)" } ?? ""), text: text(question.removeValue(forKey: promptKey))))
                if let options = question.removeValue(forKey: "options") {
                    if let options = options as? [Any] {
                        for (optionIndex, value) in options.enumerated() {
                            var optionText = text(value)
                            if var option = value as? [String: Any] {
                                optionText = text(option.removeValue(forKey: "label"))
                                if let description = option.removeValue(forKey: "description") { optionText += "\n" + text(description) }
                                if !option.isEmpty { optionText += "\n" + text(option) }
                            }
                            result.append(.init(id: id + "-option-\(optionIndex)", title: "选项 \(optionIndex + 1)", text: optionText))
                        }
                    } else {
                        result.append(.init(id: id + "-options", title: "选项", text: text(options)))
                    }
                }
                question.removeValue(forKey: "id") // Native routing identity, not message content.
                if !question.isEmpty { result.append(.init(id: id + "-details", title: "问题 \(index + 1) 的补充信息", text: text(question))) }
            }
        } else if questionsAreNative, let questions = fields["questions"] {
            result.append(.init(id: prefix + "questions", title: "原始问题", text: text(questions)))
        }
        if unwrapInput, let input = fields["tool_input"] as? [String: Any] {
            append(input, prefix: prefix + "input-", questionsAreNative: fields["tool_name"] as? String == "AskUserQuestion", to: &result)
        } else if unwrapInput, let input = fields["tool_input"] {
            result.append(.init(id: prefix + "input", title: "工具参数", text: text(input)))
        }
    }

    private static func text(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "未知" }
        if let string = value as? String { return string.isEmpty ? "（空）" : string }
        if let number = value as? NSNumber {
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "是" : "否") : number.stringValue
        }
        if let values = value as? [Any] {
            return values.isEmpty ? "（无）" : values.enumerated().map { "\($0.offset + 1). " + text($0.element).replacingOccurrences(of: "\n", with: "\n   ") }.joined(separator: "\n")
        }
        if let fields = value as? [String: Any] {
            return fields.isEmpty ? "（无）" : fields.keys.sorted().map { (labels[$0] ?? $0) + "：\n" + text(fields[$0]).components(separatedBy: "\n").map { "  " + $0 }.joined(separator: "\n") }.joined(separator: "\n")
        }
        return "未知"
    }
}
