import Foundation

enum TailnetAPIError: LocalizedError {
    case invalidTailnet, invalidCredential, unauthorized, forbidden, tailnetNotFound, rateLimited, unavailable, invalidResponse, network, storage
    var errorDescription: String? {
        switch self {
        case .invalidTailnet: return "请输入有效的 Tailnet ID，不能填写网址"
        case .invalidCredential: return "请输入以 tskey-client- 开头的 OAuth Client Secret"
        case .unauthorized: return "Tailscale 凭据已失效，请重新关联"
        case .forbidden: return "Tailscale API 权限不足，请启用 Devices → Core → Read"
        case .tailnetNotFound: return "找不到此 Tailnet，请从 General 页面复制 Tailnet ID（不是 Client ID），并确认凭据属于同一账号"
        case .rateLimited: return "Tailscale 请求过于频繁，请稍后刷新"
        case .unavailable: return "Tailscale 服务暂不可用，请稍后刷新"
        case .invalidResponse: return "Tailscale 返回的设备信息无效，原列表已保留"
        case .network: return "无法连接 Tailscale API，请检查网络后刷新"
        case .storage: return "无法访问本机 Tailscale 凭据，原应用配对已保留"
        }
    }
}
struct TailnetAPIDevice: Equatable {
    let id: String
    let name: String
    let addresses: [String]
    let dnsName: String?
    let os: String?
    let clientVersion: String?
    let connectedToControl: Bool?
}
actor TailnetAPI {
    private var generation = 0
    private let session: URLSession
    private let now: () -> Date
    private var token: (credentials: TailnetAPICredentials, value: String, expires: Date)?
    init(session: URLSession? = nil, now: @escaping () -> Date = Date.init) {
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 30
            config.httpCookieStorage = nil; config.urlCache = nil; config.httpShouldSetCookies = false
            self.session = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
        }
        self.now = now
    }
    func invalidate() { generation += 1; token = nil }
    private func request(_ request: URLRequest, maximum: Int) async throws -> (Data, Int) {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse, response.url?.host == "api.tailscale.com",
                  response.url?.scheme == "https" else { throw TailnetAPIError.invalidResponse }
            // Never read or expose an error response that could echo credentials.
            guard response.statusCode == 200 else { return (Data(), response.statusCode) }
            guard response.expectedContentLength <= maximum else { throw TailnetAPIError.invalidResponse }
            var data = Data()
            for try await byte in bytes {
                guard data.count < maximum else { throw TailnetAPIError.invalidResponse }
                data.append(byte)
            }
            return (data, response.statusCode)
        } catch let error as TailnetAPIError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw TailnetAPIError.network }
    }
    private func check(_ status: Int) throws {
        switch status {
        case 200: return
        case 400, 401: throw TailnetAPIError.unauthorized
        case 403: throw TailnetAPIError.forbidden
        case 429: throw TailnetAPIError.rateLimited
        case 500...599: throw TailnetAPIError.unavailable
        default: throw TailnetAPIError.invalidResponse
        }
    }
    private func accessToken(_ credential: TailnetAPICredentials, operation: Int) async throws -> String {
        if let token, token.credentials == credential, token.expires > now().addingTimeInterval(60) { return token.value }
        var req = URLRequest(url: URL(string: "https://api.tailscale.com/api/v2/oauth/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let values = [("grant_type", "client_credentials"), ("client_secret", credential.clientSecret), ("scope", "devices:core:read")]
        req.httpBody = Data(values.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed)!)" }.joined(separator: "&").utf8)
        let (data, status) = try await request(req, maximum: 65_536)
        guard operation == generation, !Task.isCancelled else { throw CancellationError() }
        try check(status)
        struct Token: Decodable { let access_token: String; let token_type: String; let expires_in: Double; let scope: String? }
        guard let result = try? JSONDecoder().decode(Token.self, from: data), result.token_type.lowercased() == "bearer",
              !result.access_token.isEmpty, result.access_token.utf8.count <= 4096,
              !result.access_token.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              result.expires_in.isFinite, result.expires_in > 0,
              result.scope == nil || result.scope?.split(separator: " ").map(String.init) == ["devices:core:read"] else { throw TailnetAPIError.invalidResponse }
        token = (credential, result.access_token, now().addingTimeInterval(min(result.expires_in, 3600)))
        return result.access_token
    }
    func devices(credentials: TailnetAPICredentials) async throws -> [TailnetAPIDevice] {
        let operation = generation
        for attempt in 0..<2 {
            guard operation == generation, !Task.isCancelled else { throw CancellationError() }
            let access = try await accessToken(credentials, operation: operation)
            guard operation == generation, !Task.isCancelled else { throw CancellationError() }
            var req = URLRequest(url: URL(string: "https://api.tailscale.com/api/v2/tailnet/\(credentials.tailnetID)/devices")!)
            req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, status) = try await request(req, maximum: 2_097_152)
            guard operation == generation, !Task.isCancelled else { throw CancellationError() }
            if status == 401 { token = nil; if attempt == 0 { continue } }
            if status == 404 { throw TailnetAPIError.tailnetNotFound }
            try check(status)
            return try Self.decodeDevices(data)
        }
        throw TailnetAPIError.unauthorized
    }
    static func decodeDevices(_ data: Data) throws -> [TailnetAPIDevice] {
        struct Envelope: Decodable { let devices: [Device] }
        struct Device: Decodable {
            let nodeId: String?; let id: String?; let hostname: String?; let name: String?
            let addresses: [String]?; let os: String?; let clientVersion: String?; let connectedToControl: Bool?
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.devices.count <= 512 else { throw TailnetAPIError.invalidResponse }
        func safe(_ value: String, maximum: Int = 256) -> Bool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= maximum && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
        var unique: [String: TailnetAPIDevice] = [:]
        for device in envelope.devices {
            guard let id = device.nodeId ?? device.id, safe(id),
                  let name = device.hostname.flatMap({ $0.isEmpty ? nil : $0 }) ?? device.name, safe(name),
                  device.addresses?.allSatisfy(DaemonDiscovery.isTailnetAddress) ?? true,
                  device.os.map({ $0.isEmpty || safe($0, maximum: 64) }) ?? true,
                  device.clientVersion.map({ $0.isEmpty || safe($0, maximum: 64) }) ?? true else { throw TailnetAPIError.invalidResponse }
            let result = TailnetAPIDevice(id: id, name: name, addresses: device.addresses ?? [], dnsName: device.name,
                                         os: device.os, clientVersion: device.clientVersion, connectedToControl: device.connectedToControl)
            if let previous = unique[id], previous != result { throw TailnetAPIError.invalidResponse }
            unique[id] = result
        }
        return unique.values.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }
}
