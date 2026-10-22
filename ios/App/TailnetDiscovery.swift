import Foundation
import Darwin

enum TailnetRuntime {
    static func allowed(arguments: [String], environment: [String: String]) -> Bool {
        !arguments.contains("--demo") && environment["XCTestConfigurationFilePath"] == nil && environment["XCTestBundlePath"] == nil
    }
}

enum MachineConnectionState: Equatable {
    case checking, offline, unreachable, serviceUnavailable, permissionDenied, incompatible, notDetected, pairingRequired, awaitingHeartbeat, paired
    var label: String {
        switch self {
        case .checking: return "正在识别服务"
        case .offline: return "机器离线"
        case .unreachable: return "连接受限或服务不可达（原因未确认）"
        case .serviceUnavailable: return "服务不可用"
        case .permissionDenied: return "权限不足（服务明确拒绝）"
        case .incompatible: return "发现服务协议不兼容"
        case .notDetected: return "未识别到 AgentInbox daemon"
        case .pairingRequired: return "已发现 daemon，待应用授权"
        case .awaitingHeartbeat: return "设备认证通过，等待主机连接中转"
        case .paired: return "已配对，应用认证通过"
        }
    }
}

struct DiscoveredMachine: Identifiable {
    let id: String
    var name: String
    var os: String
    var addresses: [String]
    var online: Bool?
    var state: MachineConnectionState
    var daemon: DaemonDescriptor?
    var tailscaleVersion: String? = nil
    var connectedToControl: Bool? = nil
    var dnsName: String? = nil
}

struct TailnetCatalog {
    private(set) var machines: [DiscoveredMachine] = []
    mutating func replace(with snapshot: TailnetImportSnapshot, preservingProbeState: Bool = false) {
        let previous = Dictionary(uniqueKeysWithValues: machines.map { ($0.id, $0) })
        machines = snapshot.devices.map { device in
            var machine = DiscoveredMachine(id: snapshot.machineID(for: device), name: device.name,
                os: device.os.flatMap { $0.isEmpty ? nil : $0 } ?? "系统未知", addresses: device.addresses,
                online: device.isOnline, state: .checking, tailscaleVersion: device.tailscaleVersion,
                connectedToControl: device.connectedToControl, dnsName: device.magicDNSAddress)
            if preservingProbeState, let old = previous[machine.id], Set(old.addresses) == Set(machine.addresses) {
                machine.state = old.state; machine.daemon = old.daemon
                if let os = old.daemon?.os, !os.isEmpty { machine.os = os }
            }
            return machine
        }
    }
    mutating func apply(_ result: DaemonProbeResult, to id: String) {
        guard let index = machines.firstIndex(where: { $0.id == id }) else { return }
        machines[index].state = result.state
        machines[index].daemon = result.daemon
        if let os = result.daemon?.os, !os.isEmpty { machines[index].os = os }
    }
}

struct DaemonDescriptor: Decodable {
    let product: String
    let protocolVersion: Int
    let schemaVersion: Int
    let hostId: String
    let hostName: String
    let os: String
    let version: String
    let relayURL: String
}
struct DaemonProbeResult {
    var state: MachineConnectionState
    var daemon: DaemonDescriptor? = nil
}

enum DaemonDiscovery {
    static func isTailnetAddress(_ address: String) -> Bool {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, address, &ipv4) == 1 {
            let bytes = withUnsafeBytes(of: ipv4) { Array($0) }
            return bytes[0] == 100 && (64...127).contains(bytes[1])
        }
        var ipv6 = in6_addr()
        guard inet_pton(AF_INET6, address, &ipv6) == 1 else { return false }
        let bytes = withUnsafeBytes(of: ipv6) { Array($0) }
        return Array(bytes.prefix(6)) == [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0]
    }
    static func probeURL(address: String) -> URL? {
        guard isTailnetAddress(address) else { return nil }
        let host = address.contains(":") ? "[\(address)]" : address
        return URL(string: "http://\(host):8788/v1/discovery")
    }
    static func validRelayOrigin(_ origin: String) -> Bool {
        guard let parts = URLComponents(string: origin), let host = parts.host?.lowercased(),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              !["localhost", "127.0.0.1", "::1", "[::1]", "0.0.0.0", "[::]"].contains(host),
              parts.port == nil || (1...65535).contains(parts.port!) else { return false }
        return parts.scheme == "https" || (parts.scheme == "http" && (isTailnetAddress(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))) || host.hasSuffix(".ts.net")))
    }
    static func classify(status: Int, data: Data) throws -> DaemonProbeResult {
        switch status {
        case 401, 403: return .init(state: .permissionDenied)
        case 500...599: return .init(state: .serviceUnavailable)
        case 200:
            guard data.count <= 8192 else { throw APIError.message("发现响应过大") }
            let value = try JSONDecoder().decode(DaemonDescriptor.self, from: data)
            guard value.product == "agentinbox", value.protocolVersion == 1, value.schemaVersion == 1,
                  !value.hostId.isEmpty, value.hostId.utf8.count <= 256,
                  !value.version.isEmpty, value.version.utf8.count <= 64,
                  value.hostName.utf8.count <= 256, value.os.utf8.count <= 64,
                  validRelayOrigin(value.relayURL) else { throw APIError.message("发现服务协议不匹配") }
            return .init(state: .pairingRequired, daemon: value)
        default: return .init(state: .notDetected)
        }
    }
    static func probe(_ machine: DiscoveredMachine, session: URLSession) async -> DaemonProbeResult {
        var last = DaemonProbeResult(state: .unreachable)
        for address in machine.addresses {
            guard let url = probeURL(address: address) else { continue }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            do {
                // No product credentials are ever included in a discovery probe.
                let (bytes, response) = try await session.bytes(for: request)
                guard let response = response as? HTTPURLResponse else { continue }
                var data = Data()
                for try await byte in bytes {
                    guard data.count < 8192 else { throw APIError.message("发现响应过大") }
                    data.append(byte)
                }
                last = try classify(status: response.statusCode, data: data)
                if last.daemon != nil || last.state == .permissionDenied { return last }
            } catch is DecodingError { last = .init(state: .notDetected) }
            catch is APIError { last = .init(state: .incompatible) }
            catch { if Task.isCancelled { return .init(state: .unreachable) } }
        }
        return last
    }
}
