import Foundation
import Network
import SwiftUI

@MainActor
final class TailnetStore: ObservableObject {
    static let shared = TailnetStore()
    @Published private(set) var machines: [DiscoveredMachine] = []
    @Published private(set) var account: String?
    @Published private(set) var importedAt: Date?
    @Published private(set) var connectedAtImport: Bool?
    @Published private(set) var refreshing = false
    @Published private(set) var pendingImport: TailnetImportSnapshot?
    @Published private(set) var apiTailnetID: String?
    @Published private(set) var apiError: String?
    @Published private(set) var linking = false
    @Published var presentLink = false
    @Published var presentImport = false
    @Published var message: String?
    @Published private(set) var status = "尚未关联 Tailscale"
    private let storage: TailnetImportStorage
    private let credentialRepository: TailnetCredentialRepository
    private let api: TailnetAPI
    private let fetchDevices: (TailnetAPICredentials) async throws -> [TailnetAPIDevice]
    private var apiCredentials: TailnetAPICredentials?
    private var catalog = TailnetCatalog()
    private var foreground = true
    private var generation = 0
    private var probeOffset = 0
    private var monitor: NWPathMonitor?
    private var session: URLSession
    private let probe: ((DiscoveredMachine) async -> DaemonProbeResult)?
    private let readCredential: () -> String?
    private let configuredRelay: () -> String
    private let authorizedHosts: () async throws -> [HostStatus]

    init(storage: TailnetImportStorage = .init(), probe: ((DiscoveredMachine) async -> DaemonProbeResult)? = nil,
         readCredential: @escaping () -> String? = { DeviceSecret.read() }, configuredRelay: @escaping () -> String = { InboxConfiguration.serverURL },
         authorizedHosts: @escaping () async throws -> [HostStatus] = { try await InboxAPI().hosts() },
         credentialRepository: TailnetCredentialRepository = TailnetAPIKeychain(),
         fetchDevices: ((TailnetAPICredentials) async throws -> [TailnetAPIDevice])? = nil) {
        self.credentialRepository = credentialRepository
        let client = TailnetAPI(); self.api = client
        self.fetchDevices = fetchDevices ?? { try await client.devices(credentials: $0) }
        self.storage = storage; self.probe = probe; self.readCredential = readCredential; self.configuredRelay = configuredRelay; self.authorizedHosts = authorizedHosts
        session = Self.discoverySession()
        do {
            apiCredentials = try credentialRepository.load(); apiTailnetID = apiCredentials?.tailnetID
            if let record = try storage.load() {
                if let apiTailnetID {
                    if record.source == "api", record.snapshot.account == apiTailnetID { apply(record) }
                } else if record.source != "api" { apply(record) }
            }
            if apiTailnetID != nil { status = "已关联 Tailscale，等待更新设备" }
        } catch { apiError = "无法读取本机 Tailscale 配置，请解锁后重试" }
    }
    private static func discoverySession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4; config.timeoutIntervalForResource = 8
        config.httpCookieStorage = nil; config.urlCache = nil
        return URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }
    func prepareImport(_ text: String) throws {
        // Clear an older preview before validating a new invocation, never confirm stale input after an error.
        guard apiCredentials == nil, !linking else { throw APIError.message("已关联 Tailscale API，请直接刷新设备") }
        pendingImport = nil
        pendingImport = try TailnetImportSnapshot.decode(Data(text.utf8))
        presentImport = true
    }
    func discardPreview() { pendingImport = nil }
    func cancelImport() { pendingImport = nil; presentImport = false }
    func confirmImport() throws {
        guard let pendingImport else { throw APIError.message("请先提供设备快照") }
        let record = TailnetImportRecord(snapshot: pendingImport, importedAt: Date())
        try storage.save(record)
        invalidateRefresh()
        apply(record)
        cancelImport()
        message = "已导入设备；现有应用配对身份保留"
    }
    func clear() throws {
        guard apiCredentials == nil else { throw APIError.message("请使用取消关联清除 API 设备") }
        try storage.clear()
        invalidateRefresh()
        catalog = TailnetCatalog(); machines = []; account = nil; importedAt = nil; connectedAtImport = nil
        cancelImport(); message = nil; status = "设备快照已清除；应用配对身份保留"
    }
    private func apiRecord(_ devices: [TailnetAPIDevice], tailnetID: String) throws -> TailnetImportRecord {
        let imported = devices.map { device in
            TailnetImportDevice(id: device.id, name: device.name,
                ipv4Address: device.addresses.first { !$0.contains(":") }, ipv6Address: device.addresses.first { $0.contains(":") },
                magicDNSAddress: device.dnsName, isOnline: nil, os: device.os,
                tailscaleVersion: device.clientVersion, connectedToControl: device.connectedToControl)
        }
        let snapshot = TailnetImportSnapshot(schemaVersion: 1, account: tailnetID, connected: false, devices: imported)
        let checked = try TailnetImportSnapshot.decode(JSONEncoder().encode(snapshot))
        return .init(snapshot: checked, importedAt: Date(), source: "api")
    }
    func linkAPI(tailnetID: String, clientSecret: String) async {
        guard !linking else { return }
        linking = true; defer { linking = false }
        invalidateRefresh(); let operation = generation
        do {
            let candidate = try TailnetAPICredentials(tailnetID: tailnetID, clientSecret: clientSecret)
            let devices = try await fetchDevices(candidate)
            guard operation == generation, !Task.isCancelled else { return }
            let record = try apiRecord(devices, tailnetID: candidate.tailnetID)
            let previous = try storage.load()
            try storage.save(record)
            do { try credentialRepository.save(candidate) }
            catch {
                if let previous { try? storage.save(previous) } else { try? storage.clear() }
                throw error
            }
            apiCredentials = candidate; apiTailnetID = candidate.tailnetID; apiError = nil
            apply(record); cancelImport(); presentLink = false
            message = "Tailscale 已关联；现有应用配对身份保留"
        } catch {
            guard operation == generation else { return }
            apiError = (error as? TailnetAPIError)?.localizedDescription ?? "无法关联 Tailscale，原配置与应用配对已保留"
        }
    }
    func cancelLink() async {
        presentLink = false
        if linking { invalidateRefresh(); await api.invalidate() }
    }
    func unlinkAPI() async throws {
        try credentialRepository.clear()
        invalidateRefresh(); apiCredentials = nil; apiTailnetID = nil; apiError = nil
        // A stale API cache can never restore without a matching Keychain association.
        try? storage.clear()
        catalog = TailnetCatalog(); machines = []; account = nil; importedAt = nil; connectedAtImport = nil
        cancelImport(); presentLink = false
        status = "尚未关联 Tailscale"; message = "已取消本机关联；现有应用配对身份保留"
        await api.invalidate()
    }
    private func apply(_ record: TailnetImportRecord, preservingProbeState: Bool = false) {
        catalog.replace(with: record.snapshot, preservingProbeState: preservingProbeState); machines = catalog.machines
        account = record.snapshot.account; importedAt = record.importedAt; connectedAtImport = record.snapshot.connected
        status = record.source == "api" ? "已同步 \(machines.count) 台设备；连接以服务探测结果为准" : "历史导入快照：\(machines.count) 台设备；可关联 API 自动更新"
    }
    private func invalidateRefresh() {
        generation += 1; probeOffset = 0
        session.invalidateAndCancel(); session = Self.discoverySession()
    }
    func restore() async {
        if monitor == nil {
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.foreground else { return }
                    await self.refresh()
                }
            }
            monitor.start(queue: DispatchQueue(label: "agentinbox.imported-tailnet.path")); self.monitor = monitor
        }
        await refresh()
    }
    func setForeground(_ active: Bool) async {
        foreground = active
        if active { await refresh() }
    }
    func refresh() async {
        guard foreground, !refreshing, !linking else { return }
        refreshing = true
        defer { refreshing = false }
        let operation = generation
        if let credentials = apiCredentials {
            do {
                let devices = try await fetchDevices(credentials)
                guard generation == operation, foreground, !Task.isCancelled else { return }
                let record = try apiRecord(devices, tailnetID: credentials.tailnetID)
                try storage.save(record); apply(record, preservingProbeState: true); apiError = nil
            } catch {
                guard generation == operation else { return }
                apiError = (error as? TailnetAPIError)?.localizedDescription ?? "无法更新 Tailscale 设备，原列表已保留"
            }
        }
        guard !machines.isEmpty, generation == operation else { return }
        let count = min(16, machines.count)
        let candidates = (0..<count).map { machines[(probeOffset + $0) % machines.count] }
        probeOffset = (probeOffset + count) % machines.count
        let activeSession = session
        for offset in stride(from: 0, to: candidates.count, by: 4) {
            guard generation == operation, foreground, !Task.isCancelled else { return }
            let batch = Array(candidates[offset..<min(offset + 4, candidates.count)])
            let probe = self.probe
            let results = await withTaskGroup(of: (String, DaemonProbeResult).self) { group in
                for machine in batch {
                    group.addTask {
                        let result: DaemonProbeResult
                        if let probe { result = await probe(machine) }
                        else { result = await DaemonDiscovery.probe(machine, session: activeSession) }
                        return (machine.id, result)
                    }
                }
                var results: [(String, DaemonProbeResult)] = []
                for await result in group { results.append(result) }
                return results
            }
            guard generation == operation, foreground else { return }
            for (id, result) in results { catalog.apply(result, to: id) }
            machines = catalog.machines
        }
        // Only the saved origin receives the saved credential; discovery never rewrites it.
        let savedOrigin = configuredRelay().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let associated = machines.filter { $0.daemon?.relayURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == savedOrigin }
        if !associated.isEmpty, readCredential() != nil {
            let outcome: MachineConnectionState
            var authorizedIDs: Set<String> = []
            do { authorizedIDs = Set(try await authorizedHosts().map(\.hostId)); outcome = .paired }
            catch APIError.httpStatus(401), APIError.httpStatus(403) { outcome = .permissionDenied }
            catch APIError.httpStatus(let code) { outcome = (500...599).contains(code) ? .serviceUnavailable : .unreachable }
            catch { outcome = .unreachable }
            guard generation == operation, foreground else { return }
            for machine in associated {
                guard let daemon = machine.daemon else { continue }
                catalog.apply(.init(state: outcome == .paired && !authorizedIDs.contains(daemon.hostId) ? .awaitingHeartbeat : outcome, daemon: daemon), to: machine.id)
            }
            machines = catalog.machines
        }
    }
    func pair(_ machine: DiscoveredMachine, code: String) async {
        guard let current = machines.first(where: { $0.id == machine.id }),
              let daemon = current.daemon, daemon.hostId == machine.daemon?.hostId, daemon.relayURL == machine.daemon?.relayURL,
              current.state == .pairingRequired || current.state == .permissionDenied || current.state == .awaitingHeartbeat else {
            message = "机器信息已变化，请刷新后重新选择"; return
        }
        do {
            _ = try await PairingService.shared.pair(serverURL: daemon.relayURL, code: code.trimmingCharacters(in: .whitespacesAndNewlines))
            message = "应用授权成功，设备身份已保存至 Keychain"
            await refresh()
        } catch { message = error.localizedDescription }
    }
    deinit { monitor?.cancel(); session.invalidateAndCancel() }
}
