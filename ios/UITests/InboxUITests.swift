import XCTest

final class InboxUITests: XCTestCase {
    func testTailscaleAssociationValidationAndCancel() {
        let app = XCUIApplication(); app.launchArguments = ["--demo"]; app.launch()
        app.tabBars.buttons["机器"].tap()
        let link = app.buttons["tailnet-link"]
        XCTAssertTrue(link.waitForExistence(timeout: 5)); link.tap()
        let id = app.textFields["tailnet-api-id"]
        XCTAssertTrue(id.waitForExistence(timeout: 5)); id.tap(); id.typeText("bad/identifier")
        let secret = app.secureTextFields["tailnet-api-secret"]
        XCTAssertTrue(secret.exists); secret.tap(); secret.typeText("tskey-client-fixture-secret")
        app.buttons["tailnet-api-connect"].tap()
        XCTAssertTrue(app.staticTexts["tailnet-api-error"].waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "tailscale-api-link-validation"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["取消"].tap()
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["tailnet-unlink"].exists)
    }

    func testDemoChoiceShowsSubmittingWithoutClaimingAdoption() {
        let app = XCUIApplication(); app.launchArguments = ["--demo"]; app.launch()
        XCTAssertTrue(app.navigationBars["决策收件箱"].waitForExistence(timeout: 10))
        let inboxShot = XCTAttachment(screenshot: app.screenshot()); inboxShot.name = "ios-inbox"; inboxShot.lifetime = .keepAlways; add(inboxShot)
        app.buttons["request.demo-choice"].tap()
        XCTAssertTrue(app.buttons["option.test"].waitForExistence(timeout: 5))
        let detailShot = XCTAttachment(screenshot: app.screenshot()); detailShot.name = "ios-detail"; detailShot.lifetime = .keepAlways; add(detailShot)
        app.buttons["option.test"].tap()
        app.buttons["submit-decision"].tap()
        XCTAssertTrue(app.staticTexts["提交中"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["原任务已采用"].exists)
    }
    func testChineseTextReplyAndMultipleSelection() {
        let app = XCUIApplication(); app.launchArguments = ["--demo", "--demo-more"]; app.launch()
        app.buttons["request.demo-text"].tap()
        let field = app.textFields["reply-text"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("请先检查差异")
        app.buttons["submit-decision"].tap()
        XCTAssertTrue(app.staticTexts["提交中"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["原任务已采用"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["request.demo-multi"].tap()
        app.buttons["option.unit"].tap(); app.buttons["option.lint"].tap()
        app.buttons["submit-decision"].tap()
        XCTAssertTrue(app.staticTexts["提交中"].waitForExistence(timeout: 5))
    }
    func testNativeSingleQuestionChoiceThenChineseTextIsExclusive() {
        let app = XCUIApplication(); app.launchArguments = ["--demo", "--demo-more"]; app.launch()
        app.buttons["request.demo-native-choice"].tap()
        let option = app.buttons["option.native-test"]
        XCTAssertTrue(option.waitForExistence(timeout: 5)); option.tap()
        XCTAssertEqual(option.value as? String, "已选择")
        let field = app.textFields["reply-text.native-question"]
        field.tap(); field.typeText("请先检查差异")
        XCTAssertEqual(option.value as? String, "未选择")
        app.buttons["submit-decision"].tap()
        XCTAssertTrue(app.staticTexts["提交中"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["原任务已采用"].exists)
    }
    func testSettingsAndMachineTabs() {
        let app = XCUIApplication(); app.launchArguments = ["--demo"]; app.launch()
        app.tabBars.buttons["设置"].tap()
        XCTAssertTrue(app.textFields["server-url"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["pairing-code"].exists)
        app.buttons["本地开发配置"].tap()
        XCTAssertTrue(app.secureTextFields["device-key"].exists)
        app.tabBars.buttons["机器"].tap()
        XCTAssertTrue(app.navigationBars["执行机器"].waitForExistence(timeout: 5))
    }
    func testMachineImportPreviewCancellationAndInvalidInput() {
        let app = XCUIApplication(); app.launchArguments = ["--demo"]; app.launch()
        app.tabBars.buttons["机器"].tap()
        app.buttons["已有设备快照"].tap()
        let entry = app.buttons["tailnet-import"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5)); entry.tap()
        let editor = app.textViews["tailnet-import-json"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap()
        editor.typeText("{}")
        app.buttons["tailnet-import-preview"].tap()
        XCTAssertTrue(app.staticTexts["tailnet-import-error"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["tailnet-import-confirm"].exists)
        app.buttons["取消"].tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["tailnet-login"].exists)
    }
    func testShortcutSnapshotPreviewCancelConfirmAndClear() {
        let app = XCUIApplication(); app.launchArguments = ["--demo"]; app.launch()
        app.tabBars.buttons["机器"].tap()
        app.buttons["已有设备快照"].tap()
        let clear = app.buttons["清除设备快照"]
        if clear.exists { clear.tap() }
        let entry = app.buttons["tailnet-import"]
        let payload = #"{"schemaVersion":1,"account":"ui-fixture@example.com","connected":true,"devices":[{"id":"ui-node","name":"ui-imported-host","ipv4Address":"100.100.1.2","magicDNSAddress":"ui-imported-host.fixture.ts.net","isOnline":true}]}"#
        entry.tap()
        let editor = app.textViews["tailnet-import-json"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap(); editor.typeText(payload)
        app.buttons["tailnet-import-preview"].tap()
        app.swipeUp()
        let confirm = app.buttons["tailnet-import-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        let preview = XCTAttachment(screenshot: app.screenshot()); preview.name = "ios-tailnet-import-preview"; preview.lifetime = .keepAlways; add(preview)
        app.buttons["取消"].tap()
        XCTAssertFalse(app.staticTexts["ui-imported-host.fixture.ts.net"].exists)
        entry.tap(); XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap(); editor.typeText(payload)
        app.buttons["tailnet-import-preview"].tap(); app.swipeUp()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        for _ in 0..<4 where !app.staticTexts["ui-imported-host.fixture.ts.net"].exists { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["ui-imported-host.fixture.ts.net"].waitForExistence(timeout: 5))
        let imported = XCTAttachment(screenshot: app.screenshot()); imported.name = "ios-tailnet-imported-machines"; imported.lifetime = .keepAlways; add(imported)
        for _ in 0..<4 where !app.buttons["清除设备快照"].exists { app.swipeDown() }
        app.buttons["清除设备快照"].tap()
        XCTAssertFalse(app.staticTexts["ui-imported-host.fixture.ts.net"].exists)
    }

    func testReplyMilestonesRemainUnconfirmedInDemo() {
        let app = XCUIApplication(); app.launchArguments = ["--demo"]; app.launch()
        app.buttons["request.demo-choice"].tap()
        let received = app.descendants(matching: .any)["reply-step.received"]
        let continued = app.descendants(matching: .any)["reply-step.continued"]
        XCTAssertTrue(received.waitForExistence(timeout: 5))
        XCTAssertEqual(received.value as? String, "未确认")
        XCTAssertEqual(continued.value as? String, "未确认")
        app.buttons["option.test"].tap(); app.buttons["submit-decision"].tap()
        XCTAssertTrue(app.staticTexts["提交中"].waitForExistence(timeout: 5))
        XCTAssertEqual(received.value as? String, "未确认")
        XCTAssertEqual(continued.value as? String, "未确认")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "reply-milestones-unconfirmed"; shot.lifetime = .keepAlways; add(shot)
    }

}
