import Foundation

// App and Widget use the system VPN path provided by the independent Tailscale App.
actor InboxNetwork {
    static let shared = InboxNetwork()
    private let system: URLSession
    init(system: URLSession? = nil) {
        self.system = system ?? URLSession(configuration: .ephemeral, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await system.data(for: request)
    }
}

final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
