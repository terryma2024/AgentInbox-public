import XCTest

@MainActor
final class WidgetSurfaceTests: XCTestCase {
    func testSimulatorWidgetGalleryDiscovery() throws {
        guard ProcessInfo.processInfo.environment["AGENTINBOX_WIDGET_SURFACE_TEST"] == "1" else { throw XCTSkip("仅显式启用模拟器 Widget 主屏幕测试") }
        let app = XCUIApplication()
        if let probe = ProcessInfo.processInfo.environment["AGENTINBOX_WIDGET_PROBE_CONFIG_FILE"] { app.launchEnvironment["AGENTINBOX_WIDGET_PROBE_CONFIG_FILE"] = probe }
        app.launch()
        XCTAssertTrue(app.buttons["request.\(ProcessInfo.processInfo.environment["AGENTINBOX_WIDGET_FIXTURE_ID"] ?? "fixture-widget-shared-choice")"].waitForExistence(timeout: 12))
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let icon = springboard.icons["Agent 收件箱"]
        XCTAssertTrue(icon.waitForExistence(timeout: 10))
        icon.press(forDuration: 1.5)
        _ = springboard.buttons["编辑主屏幕"].waitForExistence(timeout: 5)
        print("WIDGET_CONTEXT_MENU:\n" + String(springboard.debugDescription.prefix(12000)))
        // 本轮已观察的 iOS26.4 原生图标菜单：第三个图标为中号Widget。
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.675, dy: 0.452)).tap()
        _ = springboard.staticTexts[ProcessInfo.processInfo.environment["AGENTINBOX_WIDGET_FIXTURE_TITLE"] ?? "Widget 共享测试"].waitForExistence(timeout: 15)
        print("WIDGET_AFTER_MEDIUM:\n" + String(springboard.debugDescription.prefix(16000)))
        let screenshot = XCTAttachment(screenshot: springboard.screenshot()); screenshot.name = "ios-widget-gallery-discovery"; screenshot.lifetime = .keepAlways; add(screenshot)
    }
    func testActualWidgetChoiceUsesSharedKeyAndKeepsAppClosed() throws {
        guard ProcessInfo.processInfo.environment["AGENTINBOX_WIDGET_SURFACE_TEST"] == "1", let probe = ProcessInfo.processInfo.environment["AGENTINBOX_WIDGET_PROBE_CONFIG_FILE"] else { throw XCTSkip("仅已授权模拟器实际Widget测试") }
        let app = XCUIApplication(); app.launchEnvironment["AGENTINBOX_WIDGET_PROBE_CONFIG_FILE"] = probe; app.launch()
        XCTAssertTrue(app.buttons["request.\(ProcessInfo.processInfo.environment["AGENTINBOX_WIDGET_FIXTURE_ID"] ?? "fixture-widget-shared-choice")"].waitForExistence(timeout: 12))
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let fixtureID = ProcessInfo.processInfo.environment["AGENTINBOX_WIDGET_FIXTURE_ID"] ?? "fixture-widget-shared-choice"
        let beta = springboard.buttons["widget.option.\(fixtureID).1.widget-beta"]
        XCTAssertTrue(beta.waitForExistence(timeout: 15))
        beta.tap()
        XCTAssertNotEqual(app.state, .runningForeground)
        let screenshot = XCTAttachment(screenshot: springboard.screenshot()); screenshot.name = "ios-widget-direct-choice"; screenshot.lifetime = .keepAlways; add(screenshot)
    }

    func testActualWidgetBetaReturnsToExactOriginalCodexTask() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["AGENTINBOX_WIDGET_SURFACE_TEST"] == "1", let probe = env["AGENTINBOX_WIDGET_PROBE_CONFIG_FILE"], let bindingFile = env["AGENTINBOX_NATIVE_BINDING_FILE"], let tokenFile = env["AGENTINBOX_TEST_KEY_FILE"] else { throw XCTSkip("仅明确获准的原请求Widget闭环") }
        let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: bindingFile))) as? [String: Any])
        let native = try XCTUnwrap(expected["native"] as? [String: Any]); let callback = try XCTUnwrap(native["callback"] as? [String: Any])
        guard expected["body"] as? String == "AGENTINBOX_CHOOSE_ROUTE", expected["kind"] as? String == "choice", expected["engine"] as? String == "codex", callback["method"] as? String == "item/tool/requestUserInput", let questions = expected["questions"] as? [[String: Any]], questions.count == 1 else { XCTFail("不是获准的无工具操作Beta模板"); return }
        let requestID = try XCTUnwrap(expected["requestId"] as? String); let revision = try XCTUnwrap(expected["revision"] as? Int)
        let options = try XCTUnwrap(expected["options"] as? [[String: Any]])
        let beta = try XCTUnwrap(options.first { $0["label"] as? String == "Beta" }?["id"] as? String)
        let token = try String(contentsOfFile: tokenFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        func latest() async throws -> [String: Any] {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:8787/v1/requests/\(requestID)")!); request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let before = try await latest()
        for field in ["requestId", "revision", "hostId", "runtimeId", "sessionId", "turnId", "nativeRequestId", "itemId"] { XCTAssertEqual(before[field] as? NSObject, expected[field] as? NSObject) }
        guard before["state"] as? String == "pending" else { XCTFail("原题已不待答，禁止点击"); return }
        let app = XCUIApplication(); app.launchEnvironment["AGENTINBOX_WIDGET_PROBE_CONFIG_FILE"] = probe; app.launch()
        XCTAssertTrue(app.buttons["request.\(requestID)"].waitForExistence(timeout: 12))
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let exactBeta = springboard.buttons["widget.option.\(requestID).\(revision).\(beta)"]
        guard exactBeta.waitForExistence(timeout: 20) else { XCTFail("Widget未显示准确request/revision/option，拒绝点击"); return }
        let preClick = try await latest()
        guard preClick["state"] as? String == "pending", preClick["revision"] as? Int == revision else { XCTFail("点击前原题已变化"); return }
        exactBeta.tap()
        XCTAssertNotEqual(app.state, .runningForeground)
        var after = try await latest()
        for _ in 0..<30 where after["state"] as? String == "submitting" || after["state"] as? String == "pending" {
            try await Task.sleep(nanoseconds: 1_000_000_000); after = try await latest()
        }
        XCTAssertEqual(after["state"] as? String, "adopted")
        XCTAssertNotEqual(app.state, .runningForeground)
        let responseID = try XCTUnwrap(after["responseId"] as? String)
        let screenshot = XCTAttachment(screenshot: springboard.screenshot()); screenshot.name = "ios-widget-native-adopted"; screenshot.lifetime = .keepAlways; add(screenshot)
        let proof: [String: Any] = ["requestId":requestID,"responseId":responseID,"revision":revision,"optionId":beta,"nativeRequestId":expected["nativeRequestId"] ?? NSNull(),"sessionId":expected["sessionId"] ?? NSNull(),"turnId":expected["turnId"] ?? NSNull(),"state":"adopted","appForegroundOpened":false,"entry":"actual iOS26.4 Simulator home screen Widget AppIntent","realIPhoneAPNsClaimed":false]
        try JSONSerialization.data(withJSONObject: proof, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: env["AGENTINBOX_WIDGET_PROOF_FILE"] ?? FileManager.default.temporaryDirectory.appendingPathComponent("ios-widget-native-proof.json").path))
    }

}
