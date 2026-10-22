import SwiftUI
import UserNotifications
import WidgetKit

@main
struct AgentInboxApp: App {
    @UIApplicationDelegateAdaptor(NotificationDelegate.self) var notifications
    @StateObject private var store = InboxStore()
    @StateObject private var tailnet = TailnetStore.shared
    var body: some Scene { WindowGroup { InboxRootView().environmentObject(store).environmentObject(tailnet).onOpenURL { url in
        #if DEBUG
        InteractionDiagnostics.record(.appOpenedURL, requestID: RequestRoute.requestID(from: url))
        #endif
        if url.scheme == "agentinbox", url.host == "tailnet-import" {
            store.openedRequestID = nil
            tailnet.presentImport = true
        } else { store.open(url) }
    } } }
}
final class NotificationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        if InboxConfiguration.notificationsEnabled { application.registerForRemoteNotifications() }
        return true
    }
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { do { try await InboxAPI().registerAPNs(token); InboxConfiguration.defaults.set("已注册，待真实推送验证", forKey: "pushStatus") } catch { InboxConfiguration.defaults.set("注册失败：\(error.localizedDescription)", forKey: "pushStatus") } }
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        InboxConfiguration.defaults.set("注册失败：\(error.localizedDescription)", forKey: "pushStatus")
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if let id = response.notification.request.content.userInfo["requestId"] as? String,
           let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), let url = URL(string: "agentinbox://request/\(encoded)") {
            await MainActor.run { UIApplication.shared.open(url) }
        }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound, .list] }
}

@MainActor
final class InboxStore: ObservableObject {
    @Published var requests: [DecisionRequest] = InboxCache.load().requests
    @Published var hosts: [HostStatus] = []
    @Published var error: String?
    @Published var busy = false
    @Published var pairingStatus: String?
    private var consumedPairingFile = false
    private var connectionGeneration = 0
    @Published var openedRequestID: String?
    @Published var lastRefresh: Date = InboxCache.load().refreshedAt
    let isDemo = ProcessInfo.processInfo.arguments.contains("--demo")
    var runsTailnetDiscovery: Bool { TailnetRuntime.allowed(arguments: ProcessInfo.processInfo.arguments, environment: ProcessInfo.processInfo.environment) }
    init() {
        #if DEBUG
        if let probeFile = ProcessInfo.processInfo.environment["AGENTINBOX_WIDGET_PROBE_CONFIG_FILE"] {
            struct Probe: Decodable { let serverURL: String; let tokenFile: String; let requestId: String? }
            if let data = try? Data(contentsOf: URL(fileURLWithPath: probeFile)), let probe = try? JSONDecoder().decode(Probe.self, from: data), let token = try? String(contentsOfFile: probe.tokenFile, encoding: .utf8) {
                try? DeviceSecret.save(token.trimmingCharacters(in: .whitespacesAndNewlines))
                InboxConfiguration.serverURL = probe.serverURL
                InboxConfiguration.widgetRequestID = probe.requestId
                InboxConfiguration.defaults.removeObject(forKey: "widgetProbeStatus")
            }
        }
        #endif
        if isDemo { requests = [.demo]; lastRefresh = Date(); InboxConfiguration.defaults.removeObject(forKey: "response.demo-choice.1"); if ProcessInfo.processInfo.arguments.contains("--demo-detail") { openedRequestID = "demo-choice" }
            if ProcessInfo.processInfo.arguments.contains("--demo-more") {
                requests.append(.demoFixture(id: "demo-native-choice", title: "选择或输入回复", kind: "choice", options: [.init(id: "native-test", label: "运行测试")], questions: [.init(id: "native-question", header: "处理方式", prompt: "请选择选项或输入中文回复。", options: [.init(id: "native-test", label: "运行测试")], multiSelect: false, allowText: true)], allowText: true))
                requests.append(.demoFixture(id: "demo-text", title: "说明处理方式", kind: "text", options: []))
                requests.append(.demoFixture(id: "demo-multi", title: "选择需要的检查", kind: "choice", options: [.init(id: "unit", label: "单元测试"), .init(id: "lint", label: "代码检查")], multiSelect: true))
                for request in requests { InboxConfiguration.defaults.removeObject(forKey: "response.\(request.id).\(request.revision)") }
            }
            if ProcessInfo.processInfo.arguments.contains("--demo-context") { requests = [.contextDemo]; openedRequestID = "demo-context" }
        } }
    func consumePairingFileIfRequested() async {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--consume-pairing-file"), !consumedPairingFile else { return }
        consumedPairingFile = true
        let directory = PairingFileImport.documents
        do {
            guard !PairingService.shared.hasIdentity else { throw PairingFailure.alreadyPaired }
            let payload = try PairingFileImport.consume(from: directory)
            let receipt = try await PairingService.shared.pair(serverURL: payload.serverURL, code: payload.code)
            pairingStatus = "设备已配对"
            try PairingFileImport.writeResult(.init(state: "paired", errorCategory: nil, deviceId: receipt.deviceId), to: directory)
            await refresh()
            // The normal OS permission sheet remains visible; no permission is bypassed.
            await enableNotifications()
        } catch {
            let failure = (error as? PairingFailure) ?? .localStorage
            pairingStatus = failure.localizedDescription
            try? PairingFileImport.writeResult(.init(state: "stopped", errorCategory: failure.rawValue, deviceId: nil), to: directory)
        }
        #endif
    }
    func writeDiagnosticsIfRequested() async {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--write-diagnostics") else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
        let pushIDs = delivered.compactMap { notification -> String? in
            guard notification.request.trigger is UNPushNotificationTrigger else { return nil }
            return notification.request.content.userInfo["requestId"] as? String
        }.sorted()
        var authenticated = false
        if DeviceSecret.read() != nil { do { _ = try await InboxAPI().requests(); authenticated = true } catch {} }
        let value = PairingDiagnostic(keychainPresent: DeviceSecret.read() != nil, deviceId: InboxConfiguration.defaults.string(forKey: "deviceId"), authenticatedInbox: authenticated, notificationAuthorizationStatus: settings.authorizationStatus.rawValue, deliveredPushRequestIds: pushIDs)
        if let data = try? JSONEncoder().encode(value) {
            let file = PairingFileImport.documents.appendingPathComponent("agentinbox-diagnostics.json")
            try? data.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600, .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
        }
        #endif
    }
    func enableNotifications() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            InboxConfiguration.notificationsEnabled = granted
            if granted { UIApplication.shared.registerForRemoteNotifications() }
            pairingStatus = granted ? "设备已配对；已授权，正在注册 APNs" : "设备已配对；通知未授权，可在系统设置中开启"
        } catch { pairingStatus = "设备已配对；通知授权未完成" }
    }
    func refresh() async {
        if isDemo { return }
        let connection = InboxConfiguration.relayConnection
        let origin = connection.url
        let generation = connectionGeneration
        let api = InboxAPI(baseURL: origin)
        busy = true
        defer { if generation == connectionGeneration { busy = false } }
        async let widgetRegistration: Void = WidgetPushRegistration.reconcile()
        do {
            let updated = try await api.requests()
            guard !Task.isCancelled, generation == connectionGeneration, connection == InboxConfiguration.relayConnection else { return }
            requests = updated; error = nil; lastRefresh = Date()
            InboxCache.save(CachedInbox(requests: requests, refreshedAt: lastRefresh, error: nil), for: connection)
            WidgetCenter.shared.reloadAllTimelines()
            let updatedHosts = (try? await api.hosts()) ?? []
            guard !Task.isCancelled, generation == connectionGeneration, connection == InboxConfiguration.relayConnection else { return }
            hosts = updatedHosts
        } catch { if !Task.isCancelled, generation == connectionGeneration, connection == InboxConfiguration.relayConnection { self.error = error.localizedDescription } }
        await widgetRegistration
    }
    func relayDidChange() {
        connectionGeneration += 1
        requests = []; hosts = []; openedRequestID = nil; error = nil; busy = false; lastRefresh = .distantPast
        InboxCache.save(.init(requests: [], refreshedAt: .distantPast, error: nil))
        InboxConfiguration.widgetRequestID = nil
        WidgetCenter.shared.reloadAllTimelines()
        if InboxConfiguration.notificationsEnabled { UIApplication.shared.registerForRemoteNotifications() }
    }
    func open(_ url: URL) {
        guard let id = RequestRoute.requestID(from: url) else { return }
        openedRequestID = id
        Task { await refresh() }
    }
    func submit(_ response: DecisionResponse) async throws {
        if isDemo {
            guard let request = requests.first(where: { $0.id == response.requestId }) else { throw APIError.message("演示请求不存在") }
            try ReplyValidation.validate(response, for: request)
            if let index = requests.firstIndex(where: { $0.id == response.requestId }) { requests[index].state = .submitting }
            return
        }
        let connection = InboxConfiguration.relayConnection
        let result = try await ReplySubmission.send(response, using: InboxAPI())
        guard connection == InboxConfiguration.relayConnection else { return }
        if let index = requests.firstIndex(where: { $0.id == response.requestId }) { requests[index].state = result.state; requests[index].responseId = result.responseId; requests[index].replyProgress = result.replyProgress }
        await refresh()
    }
}

enum InboxPalette {
    static let ink = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.55, green: 0.90, blue: 0.80, alpha: 1)
            : UIColor(red: 0.12, green: 0.32, blue: 0.28, alpha: 1)
    })
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.45, green: 0.85, blue: 0.75, alpha: 1)
            : UIColor(red: 0.16, green: 0.36, blue: 0.32, alpha: 1)
    })
}

struct InboxRootView: View {
    @EnvironmentObject var store: InboxStore
    @EnvironmentObject var tailnet: TailnetStore
    @Environment(\.scenePhase) var phase
    @State private var selectedTab = 0
    @StateObject private var vpnGuidance = TailscaleVPNGuidance()
    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { InboxListView(history: false) }.tabItem { Label("待决", systemImage: "tray") }.tag(0)
            NavigationStack { InboxListView(history: true) }.tabItem { Label("历史", systemImage: "clock") }.tag(1)
            NavigationStack { HostsView() }.tabItem { Label("机器", systemImage: "desktopcomputer") }.tag(2)
            NavigationStack { SettingsView() }.tabItem { Label("设置", systemImage: "gearshape") }.tag(3)
        }
        .tint(InboxPalette.accent)
        .alert(vpnGuidance.launchError == nil ? "尚未接入 Tailscale 网络" : "无法打开 App Store", isPresented: $vpnGuidance.showPrompt) {
            if vpnGuidance.launchError == nil {
                Button("前往 App Store") { Task { await vpnGuidance.openTailscaleStore() } }
                Button("稍后", role: .cancel) {}
            } else {
                Button("好", role: .cancel) {}
            }
        } message: {
            Text(vpnGuidance.launchError ?? "未检测到此 iPhone 的 Tailscale VPN 连接。请打开 Tailscale App，连接网络后返回。也可前往 App Store，已安装时点“打开”，否则安装。")
        }
        .task(id: phase) {
            guard store.runsTailnetDiscovery else { return }
            if phase == .active { await vpnGuidance.checkOnActivation() }
            else if phase == .background { vpnGuidance.enteredBackground() }
        }
        .task {
            #if DEBUG
            InteractionDiagnostics.record(.appViewStarted)
            #endif
            await store.consumePairingFileIfRequested(); await store.refresh(); await store.writeDiagnosticsIfRequested()
        }
        .task {
            if store.runsTailnetDiscovery { await tailnet.restore() }
        }
        .task(id: phase) {
            // A task without an identity retains the phase captured at launch.
            // Restart when the scene activates so detail views keep receiving progress.
            guard phase == .active else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard !Task.isCancelled else { return }
                #if DEBUG
                InteractionDiagnostics.record(.appRefreshPollActive)
                #endif
                await store.refresh()
            }
        }
        .task {
            guard store.runsTailnetDiscovery else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard !Task.isCancelled else { return }
                if phase == .active { await tailnet.refresh() }
            }
        }
        .onChange(of: phase) {
            #if DEBUG
            if phase == .active { InteractionDiagnostics.record(.appBecameActive) }
            if phase == .background { InteractionDiagnostics.record(.appBecameBackground) }
            #endif
            if store.runsTailnetDiscovery { Task { await tailnet.setForeground(phase != .background) } }
            if phase == .active { Task { await store.refresh() } }
        }
        .onChange(of: tailnet.presentImport) {
            if tailnet.presentImport { selectedTab = 2; store.openedRequestID = nil }
        }
        .sheet(isPresented: $tailnet.presentLink, onDismiss: { Task { await tailnet.cancelLink() } }) { TailnetLinkView() }
        .sheet(isPresented: $tailnet.presentImport, onDismiss: { tailnet.cancelImport() }) { TailnetImportView() }
        .sheet(item: Binding(get: { store.openedRequestID.map(RequestID.init) }, set: { store.openedRequestID = $0?.id })) { selected in
            NavigationStack { RequestDestination(id: selected.id).toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { store.openedRequestID = nil } } } }
        }
    }
    struct RequestID: Identifiable { let id: String }
}
struct InboxListView: View {
    @EnvironmentObject var store: InboxStore
    let history: Bool
    var visible: [DecisionRequest] { store.requests.filter { history ? !$0.isActiveInboxEntry : $0.isActiveInboxEntry }.sorted { $0.createdAt > $1.createdAt } }
    var body: some View {
        List {
            Section {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(history ? "每个决定，都有回执" : "让任务继续向前").font(.title3.weight(.semibold))
                        Text(history ? "分别核对提交、原调用接收和后续执行。" : "\(visible.filter { $0.canAnswer() }.count) 项等待你决定").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: history ? "checkmark.seal" : "sparkle").font(.largeTitle).foregroundStyle(.teal)
                }.padding(.vertical, 10)
            }
            if store.isDemo { Section { Label("演示数据 · 不会发送至 Agent", systemImage: "testtube.2").font(.footnote).foregroundStyle(.secondary) } }
            if let error = store.error { Section { Label(error, systemImage: "wifi.exclamationmark").font(.footnote).foregroundStyle(.orange) } }
            if visible.isEmpty {
                Section { ContentUnavailableView(history ? "暂无历史" : "暂时没有待决问题", systemImage: history ? "clock" : "tray", description: Text(history ? "已采用和失效的请求会保留在这里。" : "Agent 需要你时，会发来提醒。")) }
            } else {
                Section(history ? "最近请求" : "待处理") {
                    ForEach(visible) { request in
                        NavigationLink { DecisionDetailView(requestID: request.id) } label: { DecisionRow(request: request) }.accessibilityIdentifier("request.\(request.id)")
                    }
                }
            }
            Section {
                HStack { Text("最近刷新"); Spacer(); Text(store.lastRefresh == .distantPast ? "尚未连接" : store.lastRefresh.formatted(date: .omitted, time: .shortened)).foregroundStyle(.secondary) }.font(.footnote)
            }
        }
        .navigationTitle(history ? "历史" : "决策收件箱")
        .refreshable { await store.refresh() }
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("刷新收件箱") } }
    }
}
struct DecisionRow: View {
    let request: DecisionRequest
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack { Text(request.engine.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary); Spacer(); Text(request.replyLabel(for: ResponseJournal.pending(for: request)?.responseId)).font(.caption).foregroundStyle(request.state == .pending ? InboxPalette.ink : .secondary) }
            Text(request.title).font(.headline)
            Text(request.body).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            HStack(spacing: 6) {
                Label(request.hostId, systemImage: "desktopcomputer")
                if let project = request.projectBasename { Text("·"); Text(project).lineLimit(1) }
                if let session = request.shortSessionID { Text("·"); Text(session).font(.caption.monospaced()) }
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 8)
    }
}
struct RequestDestination: View {
    @EnvironmentObject var store: InboxStore
    let id: String
    @State var missing: DecisionRequest?
    @State var error: String?
    var body: some View {
        Group {
            if store.requests.contains(where: { $0.id == id }) { DecisionDetailView(requestID: id) }
            else if let missing { DecisionDetailContent(request: missing) }
            else { ContentUnavailableView("请求暂不可用", systemImage: "questionmark.folder", description: Text(error ?? "正在读取通知对应的请求…")) }
        }.task { let connection = InboxConfiguration.relayConnection; do { let result = try await InboxAPI().request(id); guard connection == InboxConfiguration.relayConnection, result.id == id else { return }; missing = result } catch { if connection == InboxConfiguration.relayConnection { self.error = error.localizedDescription } } }
    }
}
struct DecisionDetailView: View {
    @EnvironmentObject var store: InboxStore
    let requestID: String
    var body: some View {
        if let request = store.requests.first(where: { $0.id == requestID }) { DecisionDetailContent(request: request) }
        else { ContentUnavailableView("请求暂不可用", systemImage: "questionmark.folder", description: Text("请刷新收件箱后重试。")) }
    }
}
struct DecisionDetailContent: View {
    @EnvironmentObject var store: InboxStore
    let request: DecisionRequest
    @State private var selected: Set<String> = []
    @State private var text = ""
    @State private var questionSelections: [String: Set<String>] = [:]
    @State private var questionTexts: [String: String] = [:]
    @State private var sending = false
    @State private var uncertain = false
    @State private var error: String?
    @State private var retryAvailable = false
    var hasDraft: Bool {
        if let questions = request.questions, !questions.isEmpty { return questions.allSatisfy { !(questionSelections[$0.id] ?? []).isEmpty || !(questionTexts[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
        return !selected.isEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var body: some View {
        Form {
            Section {
                Text(request.title).font(.title2.weight(.semibold))
                Text(request.decisionPreview).font(.body)
                Text("摘要 · 完整问题、命令及参数见下方原文").font(.caption).foregroundStyle(.secondary)
                NavigationLink {
                    DecisionOriginalView(request: request)
                } label: {
                    Label("查看完整原文", systemImage: "doc.text.magnifyingglass")
                }.accessibilityIdentifier("decision-original")
            }
            Section("决策上下文") {
                contextField("机器", value: request.hostId, id: "machine")
                contextField("项目", value: request.projectPath, id: "project")
                contextField("任务目标", value: request.decisionContext?.taskGoal, id: "goal")
                contextField("阻塞原因", value: request.decisionContext?.blockingReason, id: "reason")
                contextField("影响范围", value: request.decisionContext?.impactScope, id: "scope")
                contextField("引擎", value: request.engine, id: "engine")
                contextField("会话", value: request.sessionDisplayLabel, id: "session")
                if request.launchSurface == nil || request.launchSurface == "unknown" { Text("终端来源：未知").font(.footnote).foregroundStyle(.secondary) }
                if !request.hasOriginalContent { Text("独立原文：未知；可查看此请求保存的全部题面。").font(.footnote).foregroundStyle(.secondary) }
            }
            Section("当前状态") {
                let status = request.replyStatus(for: store.isDemo ? nil : ResponseJournal.pending(for: request)?.responseId)
                Text(request.replyLabel(for: ResponseJournal.pending(for: request)?.responseId)).foregroundStyle(.secondary).accessibilityIdentifier("request-state")
                milestone("已提交", confirmed: status.submitted, id: "submitted")
                milestone("原调用已接收", confirmed: status.received, id: "received")
                milestone("任务已继续运行", confirmed: status.continued, id: "continued")
                Text(status.explanation).font(.footnote).foregroundStyle(.secondary)
                if uncertain && !status.submitted { Text("发送结果未知，原答案已保存；不会自动重新提交。").font(.footnote).foregroundStyle(.orange) }
                if !request.canAnswer() && request.state == .pending { Text("这项请求已过期，请刷新。").foregroundStyle(.orange) }
            }
            if let legacy = ResponseJournal.legacy(for: request), !store.isDemo {
                Section("旧版原答案 · 仅供核对") {
                    Text(savedAnswerDescription(legacy))
                    Text("旧记录未绑定中继与配对代次，无法确认来源，不会用它重试。请核对原任务及服务器状态。").font(.footnote).foregroundStyle(.secondary)
                }
            }
            if uncertain, let saved = ResponseJournal.pending(for: request) {
                Section("已保存的原答案") {
                    Text(savedAnswerDescription(saved)).font(.body)
                    Text("保留原回复编号；重试前检查这项请求仍待回答且版本一致。").font(.footnote).foregroundStyle(.secondary)
                    if retryAvailable && request.canAnswer() {
                        Button("重试原答案") { Task { await retrySavedAnswer(saved) } }.disabled(sending).accessibilityIdentifier("retry-original-answer")
                    }
                    Button("检查最新状态") { Task { await checkRecovery() } }.disabled(sending)
                }
            }
            if request.canAnswer() && !uncertain && (store.isDemo || ResponseJournal.legacy(for: request) == nil) {
                if let questions = request.questions, !questions.isEmpty {
                    ForEach(questions) { question in
                        Section(question.header ?? "你的选择") {
                            Text(question.prompt)
                            ForEach(question.options) { option in
                                optionButton(option, selected: questionSelections[question.id, default: []].contains(option.id)) {
                                    var values = questionSelections[question.id, default: []]
                                    if question.multiSelect { if !values.insert(option.id).inserted { values.remove(option.id) } }
                                    else { values = [option.id] }
                                    questionSelections[question.id] = values
                                    questionTexts[question.id] = ""
                                }
                            }
                            if question.allowText { TextField("输入你的回复", text: Binding(get: { questionTexts[question.id] ?? "" }, set: { questionTexts[question.id] = $0; if !$0.isEmpty { questionSelections[question.id] = [] } }), axis: .vertical).lineLimit(3...8).accessibilityIdentifier("reply-text.\(question.id)") }
                        }
                    }
                } else {
                    if !request.options.isEmpty {
                        Section(request.multiSelect ? "选择一项或多项" : "选择一项") {
                            ForEach(request.options) { option in optionButton(option, selected: selected.contains(option.id)) {
                                text = ""
                                if request.multiSelect { if !selected.insert(option.id).inserted { selected.remove(option.id) } }
                                else { selected = [option.id] }
                            } }
                        }
                    }
                    if request.kind == "text" || request.kind == "questions" || request.allowText == true { Section("文字回复") { TextField("输入你的回复", text: Binding(get: { text }, set: { text = $0; if !$0.isEmpty { selected = [] } }), axis: .vertical).lineLimit(4...10).accessibilityIdentifier("reply-text") } }
                }
                Section {
                    Button { Task { await submit() } } label: { HStack { Spacer(); if sending { ProgressView() }; Text(sending ? "正在提交…" : "提交决定").fontWeight(.semibold); Spacer() } }.disabled(sending || !hasDraft).accessibilityIdentifier("submit-decision")
                }
            }
            if let error { Section { Text(error).foregroundStyle(.orange) } }
            Section("请求信息") {
                LabeledContent("版本", value: "\(request.revision)")
                    .accessibilityElement(children: .ignore).accessibilityLabel("版本")
                    .accessibilityValue("\(request.revision)").accessibilityIdentifier("request-revision")
                LabeledContent("有效期", value: Date(timeIntervalSince1970: request.expiresAt).formatted(date: .omitted, time: .standard))
                Text(request.requestId).font(.caption.monospaced()).textSelection(.enabled)
            }
        }
        .navigationTitle("请求详情").navigationBarTitleDisplayMode(.inline)
        .task { if !store.isDemo && ResponseJournal.pending(for: request) != nil && request.state == .pending { uncertain = true; await checkRecovery() } }
        .toolbar {
            Button("显示在小组件") { InboxConfiguration.widgetRequestID = request.id; WidgetCenter.shared.reloadAllTimelines() }.font(.caption)
            Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("刷新请求")
        }
    }
    func contextField(_ title: String, value: String?, id: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(verbatim: DecisionRequest.contextValue(value)).textSelection(.enabled)
                .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("decision-context.\(id)")
        }
    }
    func milestone(_ title: String, confirmed: Bool, id: String) -> some View {
        HStack {
            Label(title, systemImage: confirmed ? "checkmark.circle.fill" : "circle.dotted")
            Spacer()
            Text(confirmed ? "已确认" : "待确认").font(.caption)
        }.foregroundStyle(confirmed ? InboxPalette.ink : .secondary)
            .accessibilityElement(children: .ignore).accessibilityLabel(title).accessibilityValue(confirmed ? "已确认" : "未确认").accessibilityIdentifier("reply-step.\(id)")
    }
    func optionButton(_ option: DecisionOption, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { HStack { Text(option.label).foregroundStyle(.primary); Spacer(); Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? .teal : .secondary) } }.accessibilityIdentifier("option.\(option.id)").accessibilityValue(selected ? "已选择" : "未选择").disabled(sending)
    }
    func submit() async {
        guard request.canAnswer(), !sending, !uncertain else { return }
        sending = true; defer { sending = false }
        let answers = Dictionary(uniqueKeysWithValues: (request.questions ?? []).map { ($0.id, QuestionAnswer(optionIds: (questionSelections[$0.id] ?? []).sorted(), text: questionTexts[$0.id].flatMap { $0.isEmpty ? nil : $0 })) })
        let response = ReplyDraft.make(request: request, optionIds: selected.sorted(), text: text.isEmpty ? nil : text, questionAnswers: answers)
        do { try await store.submit(response) } catch { self.error = error.localizedDescription; uncertain = ResponseJournal.pending(for: request) != nil; await store.refresh(); if uncertain { await checkRecovery() } }
    }
    func savedAnswerDescription(_ response: DecisionResponse) -> String {
        let allOptions = request.options + (request.questions ?? []).flatMap(\.options)
        let labels = response.optionIds.compactMap { id in allOptions.first { $0.id == id }?.label }
        let groups = response.answers.values.flatMap { value in value.optionIds.compactMap { id in allOptions.first { $0.id == id }?.label } + [value.text].compactMap { $0 } }
        return (labels + [response.text].compactMap { $0 } + groups).joined(separator: "、")
    }
    func checkRecovery() async {
        retryAvailable = false
        guard let saved = ResponseJournal.pending(for: request) else { return }
        let connection = InboxConfiguration.relayConnection
        do {
            let latest = try await InboxAPI().request(request.id)
            guard connection == InboxConfiguration.relayConnection else { return }
            retryAvailable = latest.id == request.id && latest.revision == saved.revision && latest.bindingDigest == saved.bindingDigest && latest.canAnswer()
            await store.refresh()
        } catch { self.error = error.localizedDescription }
    }
    func retrySavedAnswer(_ saved: DecisionResponse) async {
        guard retryAvailable, !sending else { return }
        sending = true; defer { sending = false }
        do { try await store.submit(saved); retryAvailable = false; error = nil }
        catch { self.error = error.localizedDescription; await checkRecovery() }
    }
}
struct DecisionOriginalView: View {
    let request: DecisionRequest
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                Text(request.title).font(.headline)
                Text(verbatim: "机器：\(DecisionRequest.contextValue(request.hostId))\n项目：\(DecisionRequest.contextValue(request.projectPath))")
                    .font(.footnote).foregroundStyle(.secondary)
                if !request.hasOriginalContent {
                    Text("独立原文：未知。以下为旧版请求保存的全部正文、问题及选项，无法确认是否包含全部原生参数。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(request.originalParts) { part in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(part.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(part.displayLines.enumerated()), id: \.offset) { index, line in
                                Text(verbatim: line.isEmpty ? " " : line)
                                    .font(part.id == "command" ? .system(.body, design: .monospaced) : .body).textSelection(.enabled)
                                    .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("decision-original.\(part.id).\(index)")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding()
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("完整原文").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("复制完整原文") { UIPasteboard.general.string = request.originalCopyText }
                .accessibilityIdentifier("copy-decision-original")
        }
    }
}

struct HostsView: View {
    @EnvironmentObject var store: InboxStore
    @EnvironmentObject var tailnet: TailnetStore
    var body: some View {
        List {
            TailnetAccountSection()
            if !tailnet.machines.isEmpty {
                Section(tailnet.apiTailnetID == nil ? "历史设备快照" : "Tailscale 设备") {
                    ForEach(tailnet.machines) { machine in
                        NavigationLink { TailnetMachineView(machineID: machine.id) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                if let dnsName = machine.dnsName, !dnsName.isEmpty {
                                    Text(dnsName).font(.headline).foregroundStyle(.primary).lineLimit(nil)
                                        .fixedSize(horizontal: false, vertical: true)
                                } else {
                                    Text("Tailscale 域名未提供").foregroundStyle(.secondary)
                                }
                                ForEach(machine.addresses, id: \.self) { address in
                                    Text("\(address.contains(":") ? "IPv6" : "IPv4") · \(address)")
                                        .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(nil)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                if machine.addresses.isEmpty { Text("IP 未提供").font(.caption).foregroundStyle(.secondary) }
                            }.padding(.vertical, 4)
                        }.accessibilityIdentifier("tailnet-machine.\(machine.id)")
                    }
                }
            }
            Section("已授权中转中的主机") {
                if store.hosts.isEmpty { Text("主机完成应用授权并连接中转后会显示在这里。").font(.footnote).foregroundStyle(.secondary) }
                ForEach(store.hosts) { host in HStack { Image(systemName: host.online ? "circle.fill" : "circle").foregroundStyle(host.online ? .teal : .secondary); VStack(alignment: .leading) { Text(host.name); Text(host.hostId).font(.caption).foregroundStyle(.secondary) }; Spacer(); Text(host.online ? "在线" : "离线").font(.caption) } }
            }
        }.navigationTitle("执行机器").refreshable { if store.runsTailnetDiscovery { await tailnet.refresh() }; await store.refresh() }
    }
}
struct SettingsView: View {
    @EnvironmentObject var store: InboxStore
    @State private var url = InboxConfiguration.serverURL
    @State private var key = ""
    @State private var pairingCode = ""
    @State private var pairing = false
    @State private var message: String?
    var body: some View {
        Form {
            Section("连接服务") {
                TextField("服务地址", text: $url).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("server-url")
                TextField("一次性配对码", text: $pairingCode).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("pairing-code")
                Button(pairing ? "正在配对…" : "配对此 iPhone") { Task { await pair() } }.disabled(pairing || pairingCode.isEmpty).accessibilityIdentifier("pair-device")
                DisclosureGroup("本地开发配置") {
                    SecureField("测试设备密钥", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("device-key")
                    Button("保存测试连接") { saveDevelopmentConnection() }.accessibilityIdentifier("save-connection")
                }
                Text(DeviceSecret.read() == nil ? "尚未配对" : "设备密钥已存入 Keychain").font(.footnote).foregroundStyle(.secondary)
                Text("在中转服务生成一个短期、单次使用的配对码。设备密钥会自动保存在本机，不需要粘贴私钥。").font(.footnote).foregroundStyle(.secondary)
            }
            Section("主动提醒") {
                Button("启用推送通知") { Task { await store.enableNotifications() } }
                Text(InboxConfiguration.defaults.string(forKey: "pushStatus") ?? "尚未验证真实 APNs 推送").font(.footnote).foregroundStyle(.secondary)
                Text(InboxConfiguration.defaults.string(forKey: "widgetPushStatus") ?? "Widget 专用推送尚未注册").font(.footnote).foregroundStyle(.secondary)
            }
            Section("主屏幕小组件") { Button("显示最新待决请求") { InboxConfiguration.widgetRequestID = nil; WidgetCenter.shared.reloadAllTimelines(); message = "小组件将显示最新待决请求" }; Text("长按主屏幕添加“Agent 待决”。简短单选可直接回答；文字和多选会打开准确请求页。小组件刷新有系统延迟，推送和收件箱独立可用。").font(.footnote).foregroundStyle(.secondary) }
            Section("设备安全") { Button("移除此设备密钥", role: .destructive) { do { try DeviceSecret.save(""); InboxConfiguration.defaults.removeObject(forKey: "deviceId"); message = "本机密钥已移除；服务器端撤销仍需执行。" } catch { message = "本机密钥未移除" } } }
            if let status = store.pairingStatus { Section { Text(status).font(.footnote).accessibilityIdentifier("pairing-status") } }
            if let message { Section { Text(message).font(.footnote) } }
        }.navigationTitle("设置").onAppear { url = InboxConfiguration.serverURL }
    }
    func saveDevelopmentConnection() {
        do {
            let api = InboxAPI(baseURL: url.trimmingCharacters(in: .whitespacesAndNewlines))
            _ = try api.validatedURL("/v1/requests")
            if !key.isEmpty { try DeviceSecret.save(key); key = "" }
            InboxConfiguration.serverURL = api.baseURL; message = "连接已保存"
            Task { await store.refresh() }
        } catch { message = error.localizedDescription }
    }
    func pair() async {
        pairing = true; defer { pairing = false }
        do {
            _ = try await PairingService.shared.pair(serverURL: url.trimmingCharacters(in: .whitespacesAndNewlines), code: pairingCode.trimmingCharacters(in: .whitespacesAndNewlines))
            pairingCode = ""; message = "设备已配对"
            await store.refresh()
        } catch { message = error.localizedDescription }
    }
}
