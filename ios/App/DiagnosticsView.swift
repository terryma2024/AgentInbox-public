import SwiftUI
import UserNotifications

@MainActor final class DiagnosticsController: ObservableObject {
    @Published var snapshot: DiagnosticSnapshot?
    @Published var stages: [DiagnosticCheck] = []
    @Published var test: DiagnosticTest?
    @Published var busy = false
    @Published var sending = false
    @Published var failure: DiagnosticReason?
    @Published var checkedAt: Date?
    @Published var notificationObserved = false
    @Published var expectedResponseID: String?
    private var connection: RelayConnectionIdentity?
    private var pendingStart: (id: String, host: String, mode: String)?
    private var generation = UUID()
    private var readFailure: DiagnosticReason?
    private let makeAPI: () -> InboxAPI
    init(makeAPI: @escaping () -> InboxAPI = { InboxAPI() }) { self.makeAPI = makeAPI }
    var isCurrent: Bool { connection == InboxConfiguration.relayConnection }
    func resetIfChanged() {
        guard connection != InboxConfiguration.relayConnection else { return }
        generation = UUID(); readFailure = nil; connection = InboxConfiguration.relayConnection
        snapshot = nil; stages = []; test = nil; failure = nil; checkedAt = nil; notificationObserved = false; expectedResponseID = nil; pendingStart = nil; busy = false; sending = false
    }
    func check() async {
        resetIfChanged()
        guard !busy else { return }
        let current = generation; busy = true; failure = nil; stages = []; snapshot = nil
        defer { if current == generation { busy = false } }
        do {
            let api = makeAPI()
            let result = try await api.diagnosticSnapshot()
            guard !Task.isCancelled, isCurrent, current == generation else { return }
            guard result.schemaVersion == 1 else { throw APIError.httpStatus(404) }
            let sync: DiagnosticState
            do { _ = try await api.requests(); sync = .passed } catch { sync = .failed }
            guard !Task.isCancelled, isCurrent, current == generation else { return }
            readFailure = nil; snapshot = result; stages = DiagnosticReport.checks(snapshot: result, sync: sync, now: Date().timeIntervalSince1970); checkedAt = Date()
            if test == nil, let recent = result.recentTestIds.first, let recovered = try? await api.diagnosticTest(recent) {
                guard !Task.isCancelled, isCurrent, current == generation else { return }
                test = recovered
                if pendingStart?.id == recovered.testId { pendingStart = nil }
                if let q = recovered.request { expectedResponseID = ResponseJournal.pending(for: q)?.responseId }
            }
        } catch {
            guard !Task.isCancelled, isCurrent, current == generation else { return }
            let reason = Self.classify(error)
            failure = reason; readFailure = reason; stages = [.init(subject: 0, stage: .relay, state: reason == .unsupportedRelay ? .unsupported : .failed, reason: reason), .init(subject: 0, stage: .sync, state: .unknown, reason: .notChecked)]
        }
    }
    func start(host: String, mode: String) async {
        resetIfChanged()
        guard !busy, !sending else { return }
        if let existing = test, existing.hostId == host, existing.mode == mode, existing.expiresAt > Date().timeIntervalSince1970, ["queued", "starting", "ready"].contains(existing.phase) { await poll(); return }
        // An uncertain POST is reconciled with the same identity; never silently
        // create a second native test after a lost response.
        if let pendingStart, pendingStart.host != host || pendingStart.mode != mode { failure = .testInterrupted; return }
        if pendingStart == nil { pendingStart = (UUID().uuidString.lowercased(), host, mode) }
        guard let pendingStart else { return }
        let current = generation; busy = true; failure = nil
        defer { if current == generation { busy = false } }
        do {
            let result = try await makeAPI().startDiagnostic(id: pendingStart.id, host: host, mode: mode)
            guard !Task.isCancelled, isCurrent, current == generation else { return }
            test = result; self.pendingStart = nil; notificationObserved = false; expectedResponseID = nil
        } catch { if isCurrent, current == generation { failure = Self.classify(error) } }
    }
    func loadTest(_ id: String) async {
        resetIfChanged(); let current = generation
        do {
            let result = try await makeAPI().diagnosticTest(id)
            guard !Task.isCancelled, isCurrent, current == generation else { return }
            test = result
            if let q = result.request { expectedResponseID = ResponseJournal.pending(for: q)?.responseId }
        } catch { if isCurrent, current == generation { failure = Self.classify(error) } }
    }
    func poll() async {
        resetIfChanged()
        guard let test, !busy, !sending else { return }
        let current = generation
        do {
            let result = try await makeAPI().diagnosticTest(test.testId)
            guard !Task.isCancelled, isCurrent, current == generation, self.test?.testId == test.testId else { return }
            self.test = result; failure = nil; readFailure = nil
            if expectedResponseID == nil, let q = result.request { expectedResponseID = ResponseJournal.pending(for: q)?.responseId }
            await observeNotification()
        } catch { if isCurrent, current == generation, self.test?.testId == test.testId { failure = Self.classify(error); readFailure = failure } }
    }
    func answer(option: DecisionOption) async {
        resetIfChanged()
        guard !sending, !busy, let test, test.mode == "reply", let request = test.request, request.canAnswer() else { return }
        let current = generation; sending = true; failure = nil
        defer { if current == generation { sending = false } }
        do {
            let answer: DecisionResponse
            if let saved = ResponseJournal.pending(for: request) {
                guard saved.optionIds == [option.id] else { failure = .receptionUnconfirmed; return }
                answer = saved
            } else { answer = ReplyDraft.make(request: request, optionIds: [option.id], text: nil, questionAnswers: [:]) }
            expectedResponseID = answer.responseId
            _ = try await ReplySubmission.send(answer, using: makeAPI())
            guard !Task.isCancelled, isCurrent, current == generation else { return }
            let updated = try await makeAPI().diagnosticTest(test.testId)
            guard !Task.isCancelled, isCurrent, current == generation else { return }
            self.test = updated
        } catch { if isCurrent, current == generation, self.test?.testId == test.testId {
            failure = Self.classify(error)
            if ResponseJournal.pending(for: request) == nil { expectedResponseID = nil }
        } }
    }
    func observeNotification() async {
        guard let testID = test?.testId, let request = test?.request else { return }
        let current = generation
        let notifications = await UNUserNotificationCenter.current().deliveredNotifications()
        guard isCurrent, current == generation, test?.testId == testID, test?.request?.id == request.id else { return }
        notificationObserved = notificationObserved || notifications.contains { $0.request.trigger is UNPushNotificationTrigger && $0.request.content.userInfo["requestId"] as? String == request.id } || DiagnosticNotificationObservation.contains(request.id)
    }
    var testStages: [DiagnosticCheck] {
        guard isCurrent, let test else { return [] }
        let subject = snapshot?.hosts.firstIndex { $0.hostId == test.hostId }.map { $0 + 1 } ?? 0
        return test.checks(expectedResponseID: expectedResponseID, now: Date().timeIntervalSince1970, notificationObserved: notificationObserved, subject: subject)
    }
    var currentStages: [DiagnosticCheck] {
        var result = snapshot.map { DiagnosticReport.checks(snapshot: $0, sync: stages.first { $0.stage == .sync }?.state ?? .unknown, now: Date().timeIntervalSince1970) } ?? stages
        if let readFailure {
            result = result.map { check in
                .init(subject: check.subject, stage: check.stage, state: check.stage == .relay ? .failed : .unknown, reason: check.stage == .relay ? readFailure : .observationStale, ageSeconds: check.ageSeconds)
            }
        }
        return result
    }
    var export: String? {
        guard isCurrent, checkedAt != nil || !stages.isEmpty || test != nil else { return nil }
        return try? DiagnosticReport(stages: currentStages + testStages, appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "", osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion).shareText()
    }
    static func classify(_ error: Error) -> DiagnosticReason {
        switch error {
        case APIError.httpStatus(401), APIError.httpStatus(403): return .authenticationFailed
        case APIError.httpStatus(404): return .unsupportedRelay
        case APIError.httpStatus(409): return .diagnosticBusy
        case is URLError: return .relayUnavailable
        default: return .unknownFailure
        }
    }
}
// Bounded process-local observation, never exported or stored in shared defaults.
// Reading the inbox cannot populate it. Only actual APNs delegate callbacks do.
@MainActor enum DiagnosticNotificationObservation {
    private static var requestIDs: [String] = []
    static func record(_ notification: UNNotification) {
        guard notification.request.trigger is UNPushNotificationTrigger, let id = notification.request.content.userInfo["requestId"] as? String else { return }
        requestIDs.append(id); requestIDs = Array(requestIDs.suffix(32))
    }
    static func contains(_ id: String) -> Bool { requestIDs.contains(id) }
}
struct DiagnosticsView: View {
    @EnvironmentObject var store: InboxStore
    @StateObject private var controller = DiagnosticsController()
    var initialTestID: String? = nil
    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { _ in content }
    }
    private var content: some View {
        List {
            Section {
                Button(controller.busy ? "检查中…" : "一键自检") { Task { await controller.check() } }
                    .disabled(controller.busy || controller.sending).accessibilityIdentifier("diagnostics-run")
                if let at = controller.checkedAt { Text("检查时间：\(at.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary) }
                Text("逐段确认收题与回传；通知到达和原调用接收分别验证。").font(.footnote).foregroundStyle(.secondary)
            }
            if let failure = controller.failure { Section { Text(failure.advice).foregroundStyle(.orange).accessibilityIdentifier("diagnostics-failure") } }
            if controller.isCurrent {
                Section("中转与同步") { ForEach(controller.currentStages.filter { $0.subject == 0 }) { checkRow($0) } }
                if let snapshot = controller.snapshot {
                    if snapshot.hosts.isEmpty { Section { Text("中转尚无主机心跳。检查主机是否启动、已授权并连接中转。").font(.footnote) } }
                    ForEach(Array(snapshot.hosts.enumerated()), id: \.element.id) { index, host in
                        Section("主机 \(index + 1) · \(host.hostId)") {
                            ForEach(controller.currentStages.filter { $0.subject == index + 1 }) { checkRow($0) }
                            Button("测试推送") { Task { await controller.start(host: host.hostId, mode: "push") } }.accessibilityIdentifier("diagnostic-host.\(host.hostId).push").disabled(controller.busy || controller.sending)
                            Button("测试原调用回复闭环") { Task { await controller.start(host: host.hostId, mode: "reply") } }.accessibilityIdentifier("diagnostic-host.\(host.hostId).reply").disabled(controller.busy || controller.sending)
                        }
                    }
                    Section("通知配置") {
                        Text(snapshot.pushRegistered ? "设备已注册推送；需实际通知确认到达。" : DiagnosticReason.pushUnregistered.advice)
                        if snapshot.pushProviderConfigured == false { Text(DiagnosticReason.pushNotConfigured.advice).foregroundStyle(.orange) }
                    }.font(.footnote)
                }
                if let test = controller.test {
                    Section(test.mode == "push" ? "测试推送" : "测试回复闭环") {
                        ForEach(controller.testStages) { checkRow($0) }
                        if test.mode == "reply", test.phase == "ready", let request = test.request, request.canAnswer() {
                            Text(request.body)
                            ForEach(request.options) { option in
                                Button(controller.sending ? "正在提交…" : option.label) { Task { await controller.answer(option: option) } }
                                    .disabled(controller.sending || controller.busy || (ResponseJournal.pending(for: request).map { $0.optionIds != [option.id] } ?? false)).accessibilityIdentifier("diagnostic-answer.\(option.id)")
                            }
                        }
                        Button("核对本次测试状态") { Task { await controller.poll() } }.disabled(controller.busy || controller.sending)
                        Text("APNs 接受不代表手机送达；原调用接收和继续运行各自需要对应的原生证明。自动原生测试当前支持来源扩展 Codex，其他组合显示未支持。").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let exported = controller.export {
                    Section("脱敏诊断") {
                        ShareLink(item: exported) { Label("分享脱敏诊断", systemImage: "square.and.arrow.up") }.accessibilityIdentifier("diagnostics-share")
                        Text("仅含阶段状态、固定原因码、版本数字、耗时和本报告内主机编号。").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("自检与诊断")
        .task {
            controller.resetIfChanged()
            if let initialTestID { await controller.loadTest(initialTestID) }
            while !Task.isCancelled {
                if controller.test != nil { await controller.poll() }
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { break }
            }
        }
        .onChange(of: store.requests.count) { _, _ in controller.resetIfChanged() }
    }
    private func checkRow(_ check: DiagnosticCheck) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack { Text(check.stage.label); Spacer(); Text(check.state.label).accessibilityIdentifier("diagnostic-state.\(check.id)").foregroundStyle(check.state == .passed ? .teal : (check.state == .failed ? .orange : .secondary)) }
            Text(check.reason.advice).font(.caption).foregroundStyle(.secondary)
            if let age = check.ageSeconds { Text("观测距今 \(age) 秒").font(.caption2).foregroundStyle(.secondary) }
        }.padding(.vertical, 3)
    }
}
