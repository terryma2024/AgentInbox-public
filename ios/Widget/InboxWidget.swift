import WidgetKit
import SwiftUI
import AppIntents

struct AnswerDecisionIntent: AppIntent {
    static var title: LocalizedStringResource = "回答 Agent 请求"
    static var description = IntentDescription("把所选答案提交给原任务，并等待原任务回执。")
    static var openAppWhenRun = false
    @Parameter(title: "请求") var requestID: String
    @Parameter(title: "版本") var revision: Int
    @Parameter(title: "选项") var optionID: String
    @Parameter(title: "回复") var responseID: String
    @Parameter(title: "中继连接") var connectionRevision: String?
    @Parameter(title: "配对代次") var pairingGeneration: String?
    init() {}
    init(request: DecisionRequest, option: DecisionOption, responseID: String, connectionRevision: String?) { requestID = request.id; revision = request.revision; optionID = option.id; self.responseID = responseID; self.connectionRevision = connectionRevision; pairingGeneration = InboxConfiguration.replyPairingGeneration }
    func perform() async throws -> some IntentResult {
        #if DEBUG
        InteractionDiagnostics.record(.widgetAnswerBegin, requestID: requestID, revision: revision)
        defer { InteractionDiagnostics.record(.widgetAnswerEnd, requestID: requestID, revision: revision) }
        #endif
        let connection = InboxConfiguration.relayConnection
        guard connectionRevision == connection.revision, pairingGeneration == connection.pairingGeneration else { throw APIError.message("中继已变化，请刷新小组件后重试") }
        let api = InboxAPI(baseURL: connection.url)
        var cache = InboxCache.load()
        guard let cached = cache.requests.first(where: { $0.id == requestID && $0.revision == revision }), cached.canAnswerInWidget,
              cached.options.contains(where: { $0.id == optionID }) else { throw APIError.message("请求已变化，请打开收件箱刷新") }
        do {
            let receipt = try await WidgetReplySubmission.send(cached: cached, optionID: optionID, responseID: responseID, using: api)
            guard connection == InboxConfiguration.relayConnection else { return .result() }
            if let index = cache.requests.firstIndex(where: { $0.id == requestID }) { cache.requests[index].state = receipt.state; cache.requests[index].responseId = receipt.responseId; cache.requests[index].replyProgress = receipt.replyProgress }
            cache.error = nil
        } catch {
            guard connection == InboxConfiguration.relayConnection else { return .result() }
            if let latest = try? await api.request(requestID), let index = cache.requests.firstIndex(where: { $0.id == requestID }) {
                cache.requests[index] = latest
                cache.error = latest.state == .pending ? error.localizedDescription : nil
            } else if ResponseJournal.pending(for: cached) != nil {
                if let index = cache.requests.firstIndex(where: { $0.id == requestID }) { cache.requests[index].state = .unknown }
                cache.error = "提交结果未知，请打开收件箱查看"
            } else { cache.error = "尚未提交，请检查连接后刷新" }
        }
        InboxCache.save(cache, for: connection); WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
struct RefreshInboxIntent: AppIntent {
    static var title: LocalizedStringResource = "刷新待决请求"
    static var openAppWhenRun = false
    func perform() async throws -> some IntentResult {
        #if DEBUG
        InteractionDiagnostics.record(.widgetRefreshBegin)
        defer { InteractionDiagnostics.record(.widgetRefreshEnd) }
        #endif
        _ = await InboxProvider.refreshedInbox()
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
@available(iOS 26.0, *)
struct InboxPushHandler: WidgetPushHandler {
    init() {}
    func pushTokenDidChange(_ pushInfo: WidgetPushInfo, widgets: [WidgetInfo]) {
        #if DEBUG
        InteractionDiagnostics.record(.widgetPushHandler)
        #endif
        // Query the latest OS token AND configurations when this async task executes.
        // A delayed callback must never re-upload its captured obsolete token.
        Task { await WidgetPushRegistration.reconcile() }
    }
}
struct InboxEntry: TimelineEntry {
    let date: Date
    let inbox: CachedInbox
    let responseIDs: [String: String]
    var current: DecisionRequest? {
        guard inbox.matches(InboxConfiguration.relayConnection) else { return nil }
        return WidgetInboxSelection.current(in: inbox.requests, pinnedID: InboxConfiguration.widgetRequestID)
    }
}
struct InboxProvider: TimelineProvider {
    func placeholder(in context: Context) -> InboxEntry {
        let connection = InboxConfiguration.relayConnection
        return .init(date: Date(), inbox: .init(requests: [.demo], refreshedAt: Date(), error: nil, serverURL: connection.url, connectionRevision: connection.revision, pairingGeneration: connection.pairingGeneration), responseIDs: [:])
    }
    func getSnapshot(in context: Context, completion: @escaping (InboxEntry) -> Void) { completion(context.isPreview ? placeholder(in: context) : entry(InboxCache.load())) }
    static func refreshedInbox() async -> CachedInbox {
        let connection = InboxConfiguration.relayConnection
        async let pushRegistration: Void = WidgetPushRegistration.reconcile()
        var cache = InboxCache.load()
        do {
            // A tap can finish just before the original engine acknowledges adoption.
            // Observe only authenticated canonical lists; never submit an answer here.
            let requests = try await WidgetInboxRefresh.fetch(using: { timeout in
                try await InboxAPI(baseURL: connection.url, requestTimeout: timeout).requests()
            })
            guard connection == InboxConfiguration.relayConnection else { return InboxCache.load() }
            cache = CachedInbox(requests: requests, refreshedAt: Date(), error: nil, serverURL: connection.url, connectionRevision: connection.revision, pairingGeneration: connection.pairingGeneration)
            #if DEBUG
            InboxConfiguration.defaults.set("authenticated:\(cache.requests.map(\.id).joined(separator: ","))", forKey: "widgetProbeStatus")
            #endif
        } catch {
            guard connection == InboxConfiguration.relayConnection else { return InboxCache.load() }
            cache.error = "连接暂不可用，请稍后刷新"
        }
        InboxCache.save(cache, for: connection)
        await pushRegistration
        return connection == InboxConfiguration.relayConnection ? cache : InboxCache.load()
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<InboxEntry>) -> Void) {
        Task {
            #if DEBUG
            InteractionDiagnostics.record(.widgetProviderBegin)
            #endif
            let cache = await Self.refreshedInbox()
            #if DEBUG
            let current = WidgetInboxSelection.current(in: cache.requests, pinnedID: InboxConfiguration.widgetRequestID)
            InteractionDiagnostics.record(.widgetProviderEnd, requestID: current?.id, revision: current?.revision)
            #endif
            completion(Timeline(entries: [entry(cache)], policy: .after(Date().addingTimeInterval(300))))
        }
    }
    func entry(_ cache: CachedInbox) -> InboxEntry {
        let current = cache.matches(InboxConfiguration.relayConnection) ? cache : InboxCache.load()
        return .init(date: Date(), inbox: current, responseIDs: Dictionary(uniqueKeysWithValues: current.requests.flatMap { request in request.options.map { ("\(request.id)|\(request.revision)|\($0.id)", UUID().uuidString.lowercased()) } }))
    }
}
struct InboxWidgetView: View {
    let entry: InboxEntry
    @Environment(\.widgetFamily) var family
    private var otherReceiptStatus: String? {
        let others = entry.inbox.requests.filter { $0.id != entry.current?.id }
        let submitting = others.filter { $0.state == .submitting }.count
        let unknown = others.filter { $0.state == .unknown }.count
        var parts: [String] = []
        if submitting > 0 { parts.append("另\(submitting)项提交中") }
        if unknown > 0 { parts.append("另\(unknown)项结果未知") }
        let awaiting = others.filter { $0.awaitingContinuation }.count
        if awaiting > 0 { parts.append("另\(awaiting)项已接收，待后续回执") }
        return parts.isEmpty ? nil : parts.joined(separator: "，")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label("Agent 待决", systemImage: "tray").font(.caption.weight(.semibold))
                Spacer()
                Text(entry.inbox.refreshedAt == .distantPast ? "未连接" : entry.inbox.refreshedAt.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                Button(intent: RefreshInboxIntent()) { Image(systemName: "arrow.clockwise").font(.caption.weight(.semibold)) }
                    .buttonStyle(.plain).accessibilityLabel("刷新待决请求").accessibilityIdentifier("widget.refresh")
            }
            if let request = entry.current {
                Text(request.title).font(.headline).lineLimit(2)
                if family != .systemSmall || request.canAnswerInWidget { Text(request.body).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                if request.canAnswerInWidget && (family != .systemSmall || (request.kind == "choice" && request.body.count <= 18 && request.options.count <= 2 && request.options.allSatisfy { $0.label.count <= 8 })) {
                    HStack {
                        ForEach(request.options) { option in
                            Button(intent: AnswerDecisionIntent(request: request, option: option, responseID: entry.responseIDs["\(request.id)|\(request.revision)|\(option.id)"] ?? UUID().uuidString.lowercased(), connectionRevision: entry.inbox.connectionRevision)) { Text(option.label).font(.caption.weight(.semibold)).lineLimit(1) }.buttonStyle(.bordered).tint(.teal).accessibilityIdentifier("widget.option.\(request.id).\(request.revision).\(option.id)")
                        }
                    }
                } else { Link(destination: request.deepLink) { Label(request.canAnswer() ? "打开并回复" : request.replyLabel(for: ResponseJournal.pending(for: request)?.responseId), systemImage: "arrow.up.right").font(.caption.weight(.semibold)) } }
                if request.replyProgress?.nativeObservation == "answerSourceUnconfirmed" { Text("原答案匹配，来源未确认").font(.caption2).foregroundStyle(.secondary) }
                if let status = otherReceiptStatus { Text(status).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                Spacer(minLength: 0)
                HStack { Text(entry.inbox.error ?? request.hostId).lineLimit(1); Spacer(); Text(request.replyLabel(for: ResponseJournal.pending(for: request)?.responseId)) }.font(.caption2).foregroundStyle(.secondary)
            } else { Spacer(); Text("暂无待决问题").font(.headline); Text(entry.inbox.error ?? "需要你时，会主动提醒").font(.caption).foregroundStyle(.secondary); Spacer() }
        }
        .containerBackground(Color(uiColor: .secondarySystemBackground), for: .widget)
        .widgetURL(entry.current?.deepLink ?? URL(string: "agentinbox://inbox")!)
    }
}
private func inboxConfiguration() -> some WidgetConfiguration {
    StaticConfiguration(kind: WidgetPushRegistration.kind, provider: InboxProvider()) { InboxWidgetView(entry: $0) }
        .configurationDisplayName("Agent 待决")
        .description("查看待决问题，直接回答简短选择。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
}
private struct LegacyInboxWidget: Widget {
    var body: some WidgetConfiguration { inboxConfiguration() }
}
@available(iOS 26.0, *)
private struct PushEnabledInboxWidget: Widget {
    var body: some WidgetConfiguration { inboxConfiguration().pushHandler(InboxPushHandler.self) }
}
@main
struct AgentInboxWidget: WidgetBundle {
    @WidgetBundleBuilder
    var body: some Widget {
        selectedWidgets()
    }
    private func selectedWidgets() -> some Widget {
        if #available(iOS 26.0, *) {
            return WidgetBundleBuilder.buildOptional(WidgetBundleBuilder.buildLimitedAvailability(PushEnabledInboxWidget()))
        } else {
            return WidgetBundleBuilder.buildOptional(WidgetBundleBuilder.buildLimitedAvailability(LegacyInboxWidget()))
        }
    }
}
