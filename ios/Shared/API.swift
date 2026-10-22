import Foundation

enum APIError: LocalizedError {
    case message(String)
    case httpStatus(Int)
    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        case .httpStatus(401), .httpStatus(403): return "设备认证失败，请检查配对或撤销状态"
        case .httpStatus(let status): return "服务暂不可用（\(status)）"
        }
    }
}
struct InboxAPI: DecisionTransport {
    var baseURL: String = InboxConfiguration.serverURL
    var token: String? = DeviceSecret.read()
    var requestTimeout: TimeInterval = 12
    var network: InboxNetwork = .shared
    func validatedURL(_ path: String) throws -> URL {
        guard let base = URL(string: baseURL), let host = base.host, let scheme = base.scheme,
              ["http", "https"].contains(scheme), let url = URL(string: path, relativeTo: base) else { throw APIError.message("服务地址无效") }
        if scheme == "http" {
            let components = host.split(separator: ".").compactMap { Int($0) }
            let tailscaleIP = components.count == 4 && components[0] == 100 && (64...127).contains(components[1]) && components.allSatisfy { (0...255).contains($0) }
            guard ["127.0.0.1", "localhost", "::1"].contains(host) || tailscaleIP || host.hasSuffix(".ts.net") || host.hasPrefix("fd7a:115c:a1e0:") else { throw APIError.message("HTTP 仅支持本机或 Tailscale 私网；其他地址请使用 HTTPS") }
        }
        return url
    }
    func call<T: Decodable>(_ path: String, method: String = "GET", body: Data? = nil) async throws -> T {
        guard let token, !token.isEmpty else { throw APIError.message("请先在设置中配对设备") }
        let url = try validatedURL(path)
        var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.timeoutInterval = requestTimeout
        let (data, response) = try await network.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.message("连接状态未知") }
        guard (200...299).contains(http.statusCode) else {
            switch http.statusCode {
            case 401, 403: throw APIError.httpStatus(http.statusCode)
            case 409: throw APIError.message("请求已变化或已被处理，请刷新")
            case 400: throw APIError.message("答案不符合当前请求")
            default: throw APIError.httpStatus(http.statusCode)
            }
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
    func pair(code: String, name: String) async throws -> PairingReceipt {
        var request = URLRequest(url: try validatedURL("/v1/pair")); request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.timeoutInterval = 12
        request.httpBody = try JSONEncoder().encode(PairingRequest(code: code, name: name))
        let (data, response) = try await network.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw APIError.message("配对失败：配对码可能已过期或已使用") }
        return try JSONDecoder().decode(PairingReceipt.self, from: data)
    }
    func replyCapabilities() async throws -> ReplyCapabilities? {
        do { let result: ReplyCapabilities = try await call("/v1/capabilities"); return result }
        catch APIError.httpStatus(404) { return nil }
    }
    func requests() async throws -> [DecisionRequest] { let result: RequestList = try await call("/v1/requests"); return result.requests }
    func request(_ id: String) async throws -> DecisionRequest { try await call("/v1/requests/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)") }
    func hosts() async throws -> [HostStatus] { let result: HostList = try await call("/v1/hosts"); return result.hosts }
    func submit(_ answer: DecisionResponse) async throws -> ResponseReceipt {
        try await call("/v1/requests/\(answer.requestId)/responses", method: "POST", body: JSONEncoder().encode(answer))
    }
    func registerAPNs(_ token: String) async throws {
        struct TokenBody: Encodable { let token: String; let environment: String }
        struct TokenResult: Decodable { let registered: Bool? }
        let result: TokenResult = try await call("/v1/devices/token", method: "POST", body: JSONEncoder().encode(TokenBody(token: token, environment: Bundle.main.object(forInfoDictionaryKey: "AgentInboxAPNsEnvironment") as? String ?? "sandbox")))
        guard result.registered == true else { throw APIError.message("中转服务未确认 APNs 注册") }
    }
}

struct PairingRequest: Encodable { let code: String; let name: String }
struct PairingReceipt: Decodable { let deviceId: String; let token: String }
