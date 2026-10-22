import XCTest
@testable import AgentInbox

@MainActor
final class TailscaleVPNGuidanceTests: XCTestCase {
    func testOnlyActiveTunnelWithTailnetAddressCountsAsConnected() {
        XCTAssertEqual(TailscaleVPNDetector.status(interfaces: [.init(name: "utun4", address: "100.100.1.2", isUp: true)]), .unknown, "Shared IPv4 space alone cannot identify which VPN owns the tunnel")
        XCTAssertEqual(TailscaleVPNDetector.status(interfaces: [.init(name: "utun7", address: "fd7a:115c:a1e0::1234", isUp: true)]), .connected)
        for item in [VPNInterface(name: "en0", address: "100.100.1.2", isUp: true),
                     .init(name: "utun1", address: "10.8.0.2", isUp: true),
                     .init(name: "utun1", address: "100.100.1.2", isUp: false),
                     .init(name: "utun1", address: "fd7a:115c:a1e1::1", isUp: true)] {
            XCTAssertEqual(TailscaleVPNDetector.status(interfaces: [item]), .disconnected)
        }
        XCTAssertEqual(TailscaleVPNDetector.status(interfaces: []), .disconnected)
        XCTAssertEqual(TailscaleVPNDetector.status(interfaces: nil), .unknown)
    }
    func testDisconnectedPromptsOncePerForegroundVisitAndConnectedDoesNotPrompt() async {
        var status = TailscaleVPNStatus.connected
        let guide = TailscaleVPNGuidance(readStatus: { status }, settle: {})
        await guide.checkOnActivation()
        XCTAssertFalse(guide.showPrompt)
        status = .disconnected
        await guide.checkOnActivation()
        XCTAssertTrue(guide.showPrompt)
        guide.showPrompt = false
        await guide.checkOnActivation()
        XCTAssertFalse(guide.showPrompt, "Dismissal must survive inactive/active caused by system alerts")
        guide.enteredBackground()
        await guide.checkOnActivation()
        XCTAssertTrue(guide.showPrompt)
    }
    func testUnknownAndReconnectingTunnelDoNotPrompt() async {
        let unknown = TailscaleVPNGuidance(readStatus: { .unknown }, settle: {})
        await unknown.checkOnActivation()
        XCTAssertFalse(unknown.showPrompt)
        var status = TailscaleVPNStatus.disconnected
        let reconnecting = TailscaleVPNGuidance(readStatus: { status }, settle: { status = .connected })
        await reconnecting.checkOnActivation()
        XCTAssertFalse(reconnecting.showPrompt)
    }
    func testBackgroundOrCancellationDiscardsPendingDetection() async {
        var guide: TailscaleVPNGuidance!
        guide = TailscaleVPNGuidance(readStatus: { .disconnected }, settle: { guide.enteredBackground() })
        await guide.checkOnActivation()
        XCTAssertFalse(guide.showPrompt)
        let cancelled = TailscaleVPNGuidance(readStatus: { .disconnected }, settle: { throw CancellationError() })
        await cancelled.checkOnActivation()
        XCTAssertFalse(cancelled.showPrompt)
    }
    func testConfirmationOpensOfficialStoreWithoutDeviceSigningDeeplink() async {
        var opened: [String] = []
        let guide = TailscaleVPNGuidance(open: { url in opened.append(url.absoluteString); return true })
        await guide.openTailscaleStore()
        XCTAssertEqual(opened, ["itms-apps://itunes.apple.com/app/id1470499037"])
    }
    func testUnavailableNativeStoreOpensWebProductPage() async {
        var opened: [String] = []
        let guide = TailscaleVPNGuidance(open: { url in opened.append(url.absoluteString); return url.scheme == "https" })
        await guide.openTailscaleStore()
        XCTAssertEqual(opened, ["itms-apps://itunes.apple.com/app/id1470499037", "https://apps.apple.com/app/id1470499037"])
        XCTAssertNil(guide.launchError)
    }
    func testUnavailableStoreFallsBackToWebAndReportsFailureWithoutSecrets() async {
        var opened: [String] = []
        let guide = TailscaleVPNGuidance(open: { url in opened.append(url.absoluteString); return false })
        await guide.openTailscaleStore()
        XCTAssertEqual(opened, ["itms-apps://itunes.apple.com/app/id1470499037", "https://apps.apple.com/app/id1470499037"])
        XCTAssertNotNil(guide.launchError)
    }
}
