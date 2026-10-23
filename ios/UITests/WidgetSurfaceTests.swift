import XCTest

@MainActor
final class WidgetSurfaceTests: XCTestCase {
    func testFixtureWidgetDoubleTapNextQuestionAndExactTextRoute() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["AGENTINBOX_WIDGET_EXPERIENCE_FIXTURE"] == "1", let file = env["AGENTINBOX_WIDGET_PROBE_CONFIG_FILE"] else { throw XCTSkip("仅隔离模拟器的合成 Widget 体验验收") }
        let probe = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: file))) as? [String: Any])
        let origin = try XCTUnwrap(probe["serverURL"] as? String)
        let base = try XCTUnwrap(URL(string: origin))
        XCTAssertEqual(base.host, "127.0.0.1")
        guard base.host == "127.0.0.1", let keyFile = probe["tokenFile"] as? String,
              try String(contentsOfFile: keyFile, encoding: .utf8) == "public-widget-fixture-only-never-provision" else { XCTFail("仅允许公开合成 fixture，不能操作真实任务"); return }
        func control(_ path: String, post: Bool = false) async throws -> [String: Any] {
            var request = URLRequest(url: try XCTUnwrap(URL(string: path, relativeTo: base)))
            if post { request.httpMethod = "POST"; request.httpBody = Data("{}".utf8) }
            let (data, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        func shot(_ name: String, _ app: XCUIApplication) {
            let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        _ = try await control("/fixture/reset", post: true)
        let initial = try await control("/fixture/state")
        let requests = try XCTUnwrap(initial["requests"] as? [[String: Any]])
        let ids = try requests.map { try XCTUnwrap($0["requestId"] as? String) }
        let app = XCUIApplication(); app.launchEnvironment["AGENTINBOX_WIDGET_PROBE_CONFIG_FILE"] = file; app.launch()
        if app.alerts.buttons["稍后"].waitForExistence(timeout: 2) { app.alerts.buttons["稍后"].tap() }
        XCTAssertTrue(app.buttons["request.\(ids[0])"].waitForExistence(timeout: 12))
        XCUIDevice.shared.press(.home)
        let home = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // Add medium Widget on a clean dedicated simulator, or reuse its existing one.
        if !home.buttons["widget.refresh"].waitForExistence(timeout: 3) {
            let icon = home.icons["Agent 收件箱"]
            XCTAssertTrue(icon.waitForExistence(timeout: 5)); icon.press(forDuration: 1.5)
            let medium = home.buttons["中尺寸小组件"]
            XCTAssertTrue(medium.waitForExistence(timeout: 5)); medium.tap()
        }
        let refresh = home.buttons["widget.refresh"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 15)); refresh.tap()
        if let family = env["AGENTINBOX_WIDGET_FIXTURE_FAMILY"], ["small", "large"].contains(family) {
            let title = home.staticTexts["第一题"]
            XCTAssertTrue(title.waitForExistence(timeout: 10)); title.press(forDuration: 1.5)
            let size = home.buttons[family == "small" ? "小型小组件" : "大尺寸小组件"]
            XCTAssertTrue(size.waitForExistence(timeout: 5)); size.tap()
            XCTAssertTrue(refresh.waitForExistence(timeout: 10)); refresh.tap()
        }
        let initialArm = home.buttons["widget.arm.\(ids[0])"]
        if initialArm.waitForExistence(timeout: 2) { initialArm.tap() }
        let first = home.buttons["widget.option.\(ids[0]).1.beta"]
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        let oldFrame = first.frame
        shot("widget-first-pending-count-wait-sync", home)
        first.doubleTap()
        XCTAssertNotEqual(app.state, .runningForeground)
        let sending = home.staticTexts["widget.sendingStatus"]
        XCTAssertTrue(sending.waitForExistence(timeout: 3), "主屏必须有清楚可辨的发送中反馈")
        shot("widget-sending", home)
        let nextArm = home.buttons["widget.arm.\(ids[1])"]
        XCTAssertTrue(nextArm.waitForExistence(timeout: 20))
        XCTAssertFalse(home.buttons["widget.option.\(ids[1]).1.beta"].exists)
        XCTAssertLessThan(nextArm.frame.maxY, oldFrame.minY, "展开入口必须离开旧答案的点击区域")
        shot("widget-next-collapsed", home)
        var status = try await control("/fixture/state")
        XCTAssertEqual((status["posts"] as? [Any])?.count, 1)
        // Repeated taps at the former answer coordinate cannot answer the next item.
        home.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: oldFrame.midX, dy: oldFrame.midY)).doubleTap()
        status = try await control("/fixture/state")
        XCTAssertEqual((status["posts"] as? [Any])?.count, 1)
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(nextArm.waitForExistence(timeout: 8))
        nextArm.tap()
        let second = home.buttons["widget.option.\(ids[1]).1.alpha"]
        XCTAssertTrue(second.waitForExistence(timeout: 15)); second.tap()
        let textLink = home.descendants(matching: .any).matching(identifier: "widget.open.\(ids[2])").firstMatch
        XCTAssertTrue(textLink.waitForExistence(timeout: 20))
        shot("widget-text-exact-request", home)
        textLink.tap()
        XCTAssertTrue(app.navigationBars["请求详情"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["文字原题"].exists)
        XCTAssertFalse(app.staticTexts["第一题"].exists)
        status = try await control("/fixture/state")
        let posts = try XCTUnwrap(status["posts"] as? [[String: Any]])
        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(posts.map { $0["requestId"] as? String }, Array(ids.prefix(2)))
        XCTAssertEqual(posts[0]["optionIds"] as? [String], ["beta"])
        XCTAssertEqual(posts[1]["optionIds"] as? [String], ["alpha"])
        _ = try await control("/fixture/offline", post: true)
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(refresh.waitForExistence(timeout: 8)); refresh.tap()
        XCTAssertTrue(home.staticTexts["连接暂不可用，请稍后刷新"].waitForExistence(timeout: 15))
        shot("widget-sync-failed-preserves-last-success", home)
    }

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
