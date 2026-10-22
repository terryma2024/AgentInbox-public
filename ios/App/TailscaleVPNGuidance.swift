import Darwin
import SwiftUI
import UIKit

enum TailscaleVPNStatus { case connected, disconnected, unknown }
struct VPNInterface {
    let name: String
    let address: String
    let isUp: Bool
}

enum TailscaleVPNDetector {
    static func status(interfaces: [VPNInterface]?) -> TailscaleVPNStatus {
        guard let interfaces else { return .unknown }
        // An arbitrary VPN, cellular CGNAT address, or relay failure is not evidence of Tailscale.
        let tunnels = interfaces.filter { $0.isUp && $0.name.hasPrefix("utun") }
        if tunnels.contains(where: { $0.address.contains(":") && DaemonDiscovery.isTailnetAddress($0.address) }) { return .connected }
        // The shared IPv4 range is also used by other VPN providers. Without Tailscale's
        // IPv6 prefix, avoid claiming either a confirmed Tailscale connection or disconnection.
        if tunnels.contains(where: { DaemonDiscovery.isTailnetAddress($0.address) }) { return .unknown }
        return .disconnected
    }
    static func currentStatus() -> TailscaleVPNStatus {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return .unknown }
        defer { if let head { freeifaddrs(head) } }
        var interfaces: [VPNInterface] = []
        var cursor = head
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr,
                  [AF_INET, AF_INET6].contains(Int32(address.pointee.sa_family)) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            interfaces.append(.init(name: String(cString: entry.pointee.ifa_name), address: String(cString: buffer),
                                    isUp: entry.pointee.ifa_flags & UInt32(IFF_UP) != 0))
        }
        return status(interfaces: interfaces)
    }
}

@MainActor
final class TailscaleVPNGuidance: ObservableObject {
    @Published var showPrompt = false
    @Published private(set) var launchError: String?
    private var promptedThisVisit = false
    private var generation = 0
    private let readStatus: () -> TailscaleVPNStatus
    private let settle: () async throws -> Void
    private let open: @MainActor (URL) async -> Bool

    init(readStatus: @escaping () -> TailscaleVPNStatus = { TailscaleVPNDetector.currentStatus() },
         settle: @escaping () async throws -> Void = { try await Task.sleep(nanoseconds: 1_500_000_000) },
         open: @escaping @MainActor (URL) async -> Bool = { await UIApplication.shared.open($0) }) {
        self.readStatus = readStatus; self.settle = settle; self.open = open
    }
    func checkOnActivation() async {
        let operation = generation
        if readStatus() == .connected { showPrompt = false; promptedThisVisit = false; return }
        guard !promptedThisVisit else { return }
        do { try await settle(); try Task.checkCancellation() } catch { return }
        guard operation == generation else { return }
        switch readStatus() {
        case .connected: showPrompt = false; promptedThisVisit = false
        case .disconnected: promptedThisVisit = true; launchError = nil; showPrompt = true
        case .unknown: break // A failed interface read must not assert that VPN is disconnected.
        }
    }
    func enteredBackground() {
        generation += 1; promptedThisVisit = false; showPrompt = false
    }
    func openTailscaleStore() async {
        showPrompt = false; launchError = nil
        // Tailscale treats its bare custom scheme as a device-signing request. Do not
        // invoke it just to bring the app forward; the official store page offers Open/Install.
        if await open(URL(string: "itms-apps://itunes.apple.com/app/id1470499037")!) { return }
        if await open(URL(string: "https://apps.apple.com/app/id1470499037")!) { return }
        launchError = "无法打开 App Store，请手动打开 Tailscale，或在 App Store 搜索 Tailscale 并安装。"
        showPrompt = true
    }
}
