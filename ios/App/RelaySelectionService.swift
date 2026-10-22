import Foundation
import SwiftUI

enum RelaySelectionError: Error, LocalizedError {
    case invalidDomain, invalidOrigin, notPaired, authentication, network, notRelay, unavailable, changed
    var errorDescription: String? {
        switch self {
        case .invalidDomain: return "此设备未提供有效的 Tailscale 域名"
        case .invalidOrigin: return "当前中继协议或端口配置无效，请先检查设置"
        case .notPaired: return "请先在设置中完成应用设备配对"
        case .authentication: return "中继已响应，但当前设备配对未通过；原中继地址已保留"
        case .network: return "无法连接此中继，请检查设备上的中继服务、端口及 iPhone 的 Tailscale VPN；原地址已保留"
        case .notRelay: return "此地址未返回兼容的 AgentInbox 中继数据；原地址已保留"
        case .unavailable: return "此中继暂不可用，请稍后重试；原地址已保留"
        case .changed: return "设备或中继配置已变化，请重新选择；原配置未覆盖"
        }
    }
}

@MainActor
final class RelaySelectionService: ObservableObject {
    @Published private(set) var isChecking = false
    @Published private(set) var message: String?
    private let readURL: () -> String
    private let writeURL: (String) -> Void
    private let readToken: () -> String?
    private let probe: (String, String) async throws -> Void

    init(readURL: @escaping () -> String = { InboxConfiguration.serverURL },
         writeURL: @escaping (String) -> Void = { InboxConfiguration.serverURL = $0 },
         readToken: @escaping () -> String? = { DeviceSecret.read() },
         probe: @escaping (String, String) async throws -> Void = { url, token in
             try await RelayConnectionProbe().verify(url: url, token: token)
         }) {
        self.readURL = readURL; self.writeURL = writeURL; self.readToken = readToken; self.probe = probe
    }

    nonisolated static func candidateURL(dnsName: String, currentURL: String) throws -> String {
        var domain = dnsName.lowercased()
        if domain.hasSuffix(".") { domain.removeLast() }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        guard domain.utf8.count <= 253, domain.hasSuffix(".ts.net"), labels.count >= 3,
              labels.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-") && $0.unicodeScalars.allSatisfy(allowed.contains) }) else {
            throw RelaySelectionError.invalidDomain
        }
        guard var components = URLComponents(string: currentURL),
              ["https", "http"].contains(components.scheme ?? ""), components.host?.isEmpty == false,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              components.port == nil || (1...65535).contains(components.port!) else { throw RelaySelectionError.invalidOrigin }
        components.host = domain; components.path = ""
        guard let result = components.url?.absoluteString else { throw RelaySelectionError.invalidOrigin }
        return result
    }

    func select(dnsName: String, stillCurrent: () -> Bool) async -> Bool {
        guard !isChecking else { return false }
        isChecking = true; message = nil
        defer { isChecking = false }
        do {
            let original = readURL()
            let candidate = try Self.candidateURL(dnsName: dnsName, currentURL: original)
            guard let token = readToken(), !token.isEmpty else { throw RelaySelectionError.notPaired }
            try await probe(candidate, token)
            try Task.checkCancellation()
            guard readURL() == original, stillCurrent() else { throw RelaySelectionError.changed }
            writeURL(candidate)
            message = "连接成功，已设置为中继服务器"
            return true
        } catch is CancellationError {
            message = "探测已取消，原中继地址已保留"
        } catch let error as RelaySelectionError {
            message = error.localizedDescription
        } catch {
            message = RelaySelectionError.network.localizedDescription
        }
        return false
    }
}

actor RelayConnectionProbe {
    private let session: URLSession
    init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 5; config.timeoutIntervalForResource = 8
            config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCache = nil
            self.session = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
        }
    }
    func verify(url: String, token: String) async throws {
        guard let components = URLComponents(string: url), let host = components.host,
              try RelaySelectionService.candidateURL(dnsName: host, currentURL: url) == url,
              let endpoint = URL(string: "/v1/hosts", relativeTo: components.url)?.absoluteURL else { throw RelaySelectionError.invalidOrigin }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // This is the selected application's pairing credential; Tailscale OAuth credentials are never used here.
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse, response.url == endpoint else { throw RelaySelectionError.notRelay }
            switch response.statusCode {
            case 200: break
            case 401, 403: throw RelaySelectionError.authentication
            case 429, 500...599: throw RelaySelectionError.unavailable
            default: throw RelaySelectionError.notRelay
            }
            let maximum = 2_097_152
            guard response.expectedContentLength <= maximum else { throw RelaySelectionError.notRelay }
            var data = Data()
            for try await byte in bytes {
                guard data.count < maximum else { throw RelaySelectionError.notRelay }
                data.append(byte)
            }
            guard let _ = try? JSONDecoder().decode(HostList.self, from: data) else { throw RelaySelectionError.notRelay }
        } catch is CancellationError { throw CancellationError() }
        catch let error as RelaySelectionError { throw error }
        catch { throw RelaySelectionError.network }
    }
    deinit { session.invalidateAndCancel() }
}
