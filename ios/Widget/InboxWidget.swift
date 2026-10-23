import WidgetKit
import SwiftUI
import AppIntents

// Every parameter comes from the rendered entry, never from a newly selected item.
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
    @Parameter(title: "展示代次") var presentationID: String?
    @Parameter(title: "内容指纹") var fingerprint: String?
    init() {}
    init(request: DecisionRequest, option: DecisionOption, responseID: String, inbox: CachedInbox, screen: WidgetPresentation) {
        requestID = request.id; revision = request.revision; optionID = option.id; self.responseID = responseID
        connectionRevision = inbox.connectionRevision; pairingGeneration = inbox.pairingGeneration
        presentationID = screen.id; fingerprint = screen.fingerprint
    }
    func perform() async throws -> some IntentResult {
        #if DEBUG
        InteractionDiagnostics.record(.widgetAnswerBegin, requestID: requestID, revision: revision)
        defer { InteractionDiagnostics.record(.widgetAnswerEnd, requestID: requestID, revision: revision) }
        #endif
        defer { WidgetCenter.shared.reloadAllTimelines() }
        let connection = InboxConfiguration.relayConnection
        guard connectionRevision == connection.revision, pairingGeneration == connection.pairingGeneration,
              let presentationID, let fingerprint else { throw APIError.message("组件已变化，请刷新后查看原题") }
        let context = ReplyJournalContext.current
        let cache = InboxCache.load()
        guard let cached = cache.requests.first(where: { $0.id == requestID && $0.revision == revision }),
              cached.widgetFingerprint == fingerprint else { throw APIError.message("请求已变化，请刷新后查看原题") }
        let screen = WidgetPresentation(id: presentationID, fingerprint: fingerprint, isArmed: true)
        try WidgetInteractionStore.shared.update(context: context) { state in
            guard context == ReplyJournalContext.current else { throw APIError.message("连接已变化，请刷新组件") }
            try state.begin(screen, request: cached, optionID: optionID, responseID: responseID)
        }
        WidgetCenter.shared.reloadAllTimelines()
        do {
            _ = try await WidgetReplySubmission.send(cached: cached, optionID: optionID, responseID: responseID, using: InboxAPI(baseURL: connection.url))
            guard context == ReplyJournalContext.current else { return .result() }
            try WidgetInteractionStore.shared.update(context: context) { $0.finish(responseID: responseID, phase: .submitted) }
        } catch {
            guard context == ReplyJournalContext.current else { return .result() }
            let phase: WidgetSubmissionPhase = ResponseJournal.pending(for: cached) == nil ? .failed : .unknown
            try WidgetInteractionStore.shared.update(context: context) { $0.finish(responseID: responseID, phase: phase) }
        }
        // Canonical data is fetched by the provider. Never overwrite a newer App
        // refresh with the pre-network cache captured at the start of this intent.
        return .result()
    }
}
struct ArmWidgetQuestionIntent: AppIntent {
    static var title: LocalizedStringResource = "展开本题选项"
    static var openAppWhenRun = false
    @Parameter(title: "请求") var requestID: String
    @Parameter(title: "展示代次") var presentationID: String
    @Parameter(title: "内容指纹") var fingerprint: String
    @Parameter(title: "中继连接") var connectionRevision: String
    @Parameter(title: "配对代次") var pairingGeneration: String
    init() {}
    init(request: DecisionRequest, screen: WidgetPresentation, inbox: CachedInbox) {
        requestID = request.id; presentationID = screen.id; fingerprint = screen.fingerprint
        connectionRevision = inbox.connectionRevision ?? ""; pairingGeneration = inbox.pairingGeneration ?? ""
    }
    func perform() async throws -> some IntentResult {
        defer { WidgetCenter.shared.reloadAllTimelines() }
        let context = ReplyJournalContext.current
        guard context.connectionRevision == connectionRevision, context.pairingGeneration == pairingGeneration,
              let request = InboxCache.load().requests.first(where: { $0.id == requestID }) else { throw APIError.message("请求已变化，请刷新组件") }
        try WidgetInteractionStore.shared.update(context: context) { state in
            guard context == ReplyJournalContext.current else { throw APIError.message("连接已变化，请刷新组件") }
            try state.arm(.init(id: presentationID, fingerprint: fingerprint, isArmed: false), request: request)
        }
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
    var interaction = WidgetInteractionState()
    var screen: WidgetPresentation? = nil
    var requests: [DecisionRequest] { interaction.displayRequests(inbox.requests, at: date) }
    var pendingCount: Int { requests.filter { $0.canAnswer(at: date) }.count }
    var current: DecisionRequest? {
        guard inbox.matches(InboxConfiguration.relayConnection) else { return nil }
        // Freeze selection to this entry's date. Expiry must not swap the target
        // under the buttons of an already rendered entry.
        return WidgetInboxSelection.current(in: requests, pinnedID: InboxConfiguration.widgetRequestID, at: date)
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
            let local = entry(InboxCache.load())
            if local.interaction.sendingCount() > 0 {
                completion(Timeline(entries: [local], policy: .after(Date().addingTimeInterval(2))))
                return
            }
            let cache = await Self.refreshedInbox()
            #if DEBUG
            let current = WidgetInboxSelection.current(in: cache.requests, pinnedID: InboxConfiguration.widgetRequestID)
            InteractionDiagnostics.record(.widgetProviderEnd, requestID: current?.id, revision: current?.revision)
            #endif
            completion(Timeline(entries: [entry(cache)], policy: .after(Date().addingTimeInterval(300))))
        }
    }
    func entry(_ cache: CachedInbox) -> InboxEntry {
        var current = cache.matches(InboxConfiguration.relayConnection) ? cache : InboxCache.load()
        let date = Date()
        let context = ReplyJournalContext.current
        var interaction = WidgetInteractionState()
        var screen: WidgetPresentation?
        do {
            interaction = try WidgetInteractionStore.shared.update(context: context) { state in
                guard context == ReplyJournalContext.current else { throw APIError.message("连接已变化，请刷新组件") }
                let visible = state.displayRequests(current.requests, at: date)
                screen = state.present(WidgetInboxSelection.current(in: visible, pinnedID: InboxConfiguration.widgetRequestID, at: date))
                return state
            }
        } catch { current.error = "组件操作暂不可用，请进入 App" }
        return .init(date: date, inbox: current, responseIDs: Dictionary(uniqueKeysWithValues: current.requests.flatMap { request in request.options.map { ("\(request.id)|\(request.revision)|\($0.id)", UUID().uuidString.lowercased()) } }), interaction: interaction, screen: screen)
    }
}

struct InboxWidgetView: View {
    let entry: InboxEntry
    @Environment(\.widgetFamily) var family
    @Environment(\.dynamicTypeSize) var dynamicTypeSize
    private var fits: Bool {
        dynamicTypeSize <= .large && (entry.current.map { WidgetAnswerLayout.fits($0, compact: family == .systemSmall, large: family == .systemLarge) } ?? false)
    }
    private var needsArming: Bool { fits && entry.screen?.isArmed == false }
    private var otherReceiptStatus: String? {
        let others = entry.requests.filter { $0.id != entry.current?.id }
        let sending = entry.interaction.sendingCount(at: entry.date)
        let submitting = others.filter { $0.state == .submitting && entry.interaction.submission(for: $0)?.effectivePhase(at: entry.date) != .sending }.count
        let unknown = others.filter { $0.state == .unknown }.count
        var parts: [String] = []
        if sending > 0 { parts.append("\(sending)项正在发送…") }
        if submitting > 0 { parts.append("另\(submitting)项待回执") }
        if unknown > 0 { parts.append("另\(unknown)项结果未知") }
        let awaiting = others.filter { $0.awaitingContinuation }.count
        if awaiting > 0 { parts.append("另\(awaiting)项已接收") }
        return parts.isEmpty ? nil : parts.joined(separator: "，")
    }
    private var syncIsStale: Bool { entry.inbox.error != nil || entry.inbox.refreshedAt == .distantPast || entry.date.timeIntervalSince(entry.inbox.refreshedAt) > 300 }
    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 3 : 5) {
            HStack {
                Group {
                    if family == .systemSmall { Text("待办 \(entry.pendingCount)") }
                    else { Label("待办 \(entry.pendingCount)", systemImage: "tray") }
                }.font(.caption.weight(.semibold)).fixedSize().accessibilityIdentifier("widget.pendingCount")
                Spacer()
                if needsArming, let request = entry.current, let screen = entry.screen {
                    Button(intent: ArmWidgetQuestionIntent(request: request, screen: screen, inbox: entry.inbox)) { Text("回答此题").font(.caption.weight(.semibold)) }
                        .buttonStyle(.borderless).tint(.teal).disabled(entry.interaction.sendingCount(at: entry.date) > 0)
                        .accessibilityIdentifier("widget.arm.\(request.id)")
                }
                if family != .systemSmall || !needsArming {
                    Button(intent: RefreshInboxIntent()) { Image(systemName: "arrow.clockwise").font(.caption.weight(.semibold)) }
                        .buttonStyle(.plain).accessibilityLabel("刷新待决请求").accessibilityIdentifier("widget.refresh")
                }
            }
            if let request = entry.current {
                Text(request.title).font(family == .systemSmall ? .subheadline.weight(.semibold) : .headline).lineLimit(fits && family != .systemLarge ? 1 : 2)
                if family != .systemSmall || fits { Text(request.body).font(.caption).foregroundStyle(.secondary).lineLimit(family == .systemLarge ? 4 : (family == .systemSmall ? 1 : 2)) }
                if fits, let screen = entry.screen {
                    if screen.isArmed {
                        if family == .systemLarge { VStack(alignment: .leading, spacing: 3) { options(request, screen: screen) } }
                        else { HStack(spacing: 4) { options(request, screen: screen) } }
                    } else {
                        Text("已切题，请先点右上角").font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    Link(destination: request.deepLink) {
                        Label(entry.interaction.status(for: request, at: entry.date) ?? (request.canAnswer() ? "打开并回复" : request.replyLabel(for: ResponseJournal.pending(for: request)?.responseId)), systemImage: "arrow.up.right").font(.caption.weight(.semibold))
                    }.accessibilityIdentifier("widget.open.\(request.id)")
                }
                if let status = otherReceiptStatus { Text(status).font(.caption2).foregroundStyle(.orange).lineLimit(1).accessibilityIdentifier("widget.sendingStatus") }
                else if let status = entry.interaction.status(for: request, at: entry.date) { Text(status).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                if family == .systemLarge { Text(request.hostId).font(.caption2).foregroundStyle(.secondary); Text(request.replyLabel(for: ResponseJournal.pending(for: request)?.responseId)).font(.caption2).foregroundStyle(.secondary) }
            } else {
                Spacer(minLength: 0)
                Text("暂无待决问题").font(.headline)
                if family != .systemSmall { Text("需要你时，会主动提醒").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
            if family == .systemSmall, let request = entry.current, request.canAnswer(at: entry.date) {
                (Text("等待 ") + Text(Date(timeIntervalSince1970: min(request.createdAt, entry.date.timeIntervalSince1970)), style: .relative))
                    .font(.caption2).foregroundStyle(.secondary).accessibilityIdentifier("widget.waiting")
            }
            HStack(spacing: 3) {
                if family != .systemSmall, let request = entry.current, request.canAnswer(at: entry.date) {
                    (Text("等待 ") + Text(Date(timeIntervalSince1970: min(request.createdAt, entry.date.timeIntervalSince1970)), style: .relative)).accessibilityIdentifier("widget.waiting")
                    Spacer(minLength: 2)
                }
                if entry.inbox.refreshedAt == .distantPast { Text("尚未同步").accessibilityIdentifier("widget.lastSync") }
                else { Text("同步 " + entry.inbox.refreshedAt.formatted(date: .omitted, time: .shortened)).accessibilityIdentifier("widget.lastSync") }
                Spacer(minLength: 0)
                if syncIsStale { Label("滞后", systemImage: "exclamationmark.arrow.triangle.2.circlepath").accessibilityLabel("同步滞后，请刷新") }
                if family == .systemSmall && needsArming {
                    Button(intent: RefreshInboxIntent()) { Image(systemName: "arrow.clockwise").foregroundStyle(.primary) }
                        .buttonStyle(.plain).accessibilityLabel("刷新待决请求").accessibilityIdentifier("widget.refresh")
                }
            }.font(.caption2).foregroundStyle(syncIsStale ? .orange : .secondary)
            if let error = entry.inbox.error { Text(error).font(.caption2).foregroundStyle(.orange).lineLimit(1) }
        }
        .invalidatableContent()
        .containerBackground(Color(uiColor: .secondarySystemBackground), for: .widget)
        .widgetURL(entry.current?.deepLink ?? URL(string: "agentinbox://inbox")!)
    }
    @ViewBuilder private func options(_ request: DecisionRequest, screen: WidgetPresentation) -> some View {
        ForEach(request.options) { option in
            Button(intent: AnswerDecisionIntent(request: request, option: option, responseID: entry.responseIDs["\(request.id)|\(request.revision)|\(option.id)"] ?? UUID().uuidString.lowercased(), inbox: entry.inbox, screen: screen)) {
                Text(option.label).font(.caption.weight(.semibold)).lineLimit(1).padding(.horizontal, 6).padding(.vertical, 5)
                    .frame(minWidth: 44, minHeight: 32)
                    .background(.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            }.buttonStyle(.plain).tint(.teal).accessibilityIdentifier("widget.option.\(request.id).\(request.revision).\(option.id)")
        }
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
