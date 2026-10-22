import XCTest

@MainActor
final class PhysicalTailnetTests: XCTestCase {
    private func requireAuthorization() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Only the explicitly authorized physical iPhone")
        #endif
        guard ProcessInfo.processInfo.environment["AGENTINBOX_PHYSICAL_AUTOMATION"] == "1" else {
            throw XCTSkip("Requires explicit physical automation authorization")
        }
        continueAfterFailure = false
    }

    func testPhysicalPreviewCancellationPreservesCatalogAndPairing() throws {
        try requireAuthorization()
        let app = XCUIApplication()
        app.launch()
        let settings = app.tabBars.buttons["设置"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15)); settings.tap()
        let pairedBefore = app.staticTexts["设备密钥已存入 Keychain"].exists
        app.tabBars.buttons["机器"].tap()
        app.buttons["已有设备快照"].tap()
        let entry = app.buttons["tailnet-import"]
        XCTAssertTrue(entry.waitForExistence(timeout: 8)); entry.tap()
        let editor = app.textViews["tailnet-import-json"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap(); editor.typeText("{}")
        app.buttons["tailnet-import-preview"].tap()
        XCTAssertTrue(app.staticTexts["tailnet-import-error"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["tailnet-import-confirm"].exists)
        app.buttons["取消"].tap()
        entry.tap(); XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap()
        editor.typeText(#"{"schemaVersion":1,"account":"physical-preview@example.com","connected":true,"devices":[{"id":"physical-preview-only","name":"physical-preview-only"}]}"#)
        app.buttons["tailnet-import-preview"].tap(); app.swipeUp()
        XCTAssertTrue(app.buttons["tailnet-import-confirm"].waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "physical-tailnet-preview"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["取消"].tap()
        XCTAssertFalse(app.staticTexts["physical-preview-only"].exists)
        app.terminate(); app.launch(); app.tabBars.buttons["机器"].tap()
        XCTAssertFalse(app.staticTexts["physical-preview-only"].exists)
        app.tabBars.buttons["设置"].tap()
        XCTAssertEqual(app.staticTexts["设备密钥已存入 Keychain"].exists, pairedBefore)
    }

}
