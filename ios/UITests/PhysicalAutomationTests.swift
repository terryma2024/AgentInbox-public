import XCTest
import CoreFoundation

@MainActor
final class PhysicalAutomationTests: XCTestCase {
    private func requirePhysicalAuthorization() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("此场景只验收明确授权的实体 iPhone")
        #endif
        guard ProcessInfo.processInfo.environment["AGENTINBOX_PHYSICAL_AUTOMATION"] == "1" else {
            throw XCTSkip("需显式启用本项目真机自动化")
        }
        continueAfterFailure = false
    }

    private func allowOnlyAgentInboxNotificationAlert() -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.exists else { return false }
        let labels = alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ") + " " + alert.label
        guard labels.contains("Agent 收件箱"), labels.contains("通知") || labels.lowercased().contains("notification") else { return false }
        for title in ["允许", "Allow"] where alert.buttons[title].exists {
            alert.buttons[title].tap()
            return true
        }
        return false
    }

    func testPairingFileAndPushRegistration() throws {
        try requirePhysicalAuthorization()
        let app = XCUIApplication()
        let monitor = addUIInterruptionMonitor(withDescription: "AgentInbox notification permission only") { [weak self] _ in
            self?.allowOnlyAgentInboxNotificationAlert() ?? false
        }
        defer { removeUIInterruptionMonitor(monitor) }
        app.launchArguments = ["--consume-pairing-file", "--write-diagnostics"]
        app.launch()
        _ = allowOnlyAgentInboxNotificationAlert()
        let settings = app.tabBars.buttons["设置"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        if !app.navigationBars["设置"].exists { settings.tap() }
        _ = allowOnlyAgentInboxNotificationAlert()
        let paired = app.staticTexts["设备密钥已存入 Keychain"]
        XCTAssertTrue(paired.waitForExistence(timeout: 40), "必须由正式 App 保存身份，预填不算配对")
        _ = allowOnlyAgentInboxNotificationAlert()
        let enable = app.buttons["启用推送通知"]
        XCTAssertTrue(enable.waitForExistence(timeout: 5))
        enable.tap()
        _ = allowOnlyAgentInboxNotificationAlert()
        let deadline = Date().addingTimeInterval(35)
        let registered = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "已注册，待真实推送验证")).firstMatch
        while Date() < deadline && !registered.exists {
            _ = allowOnlyAgentInboxNotificationAlert()
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTAssertTrue(registered.exists, "必须得到 relay 对 APNs 注册的确认")
        let proof: [String: Any] = ["physicalDevice": true, "entry": "signed native XCUITest plus App one-shot pairing file", "keychainLabelObserved": paired.exists, "apnsRegistrationLabelObserved": registered.exists, "realAPNsDeliveryClaimed": false, "pairingCodeOrTokenLogged": false]
        let data = try JSONSerialization.data(withJSONObject: proof, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "physical-pairing-and-apns-registration-proof"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    // This is an answer to the explicitly authorized, command-free Beta fixture only.
    // No generic approval, text input, alternate request or retry path is available.
    func testAuthorizedIsolatedBetaOnly() throws {
        try requirePhysicalAuthorization()
        guard let raw = ProcessInfo.processInfo.environment["AGENTINBOX_PHYSICAL_BINDING_JSON"],
              raw.utf8.count <= 32768, let data = raw.data(using: .utf8),
              let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Missing complete non-secret isolated fixture binding"); return
        }
        let request = (envelope["request"] as? [String: Any]) ?? envelope
        func string(_ value: [String: Any], _ field: String) throws -> String {
            guard let result = value[field] as? String, !result.isEmpty else {
                throw NSError(domain: "AgentInboxFixtureBinding", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing required binding field: \(field)"])
            }
            return result
        }
        let requestID = try string(request, "requestId")
        guard UUID(uuidString: requestID) != nil,
              let revisionValue = request["revision"] as? NSNumber,
              CFGetTypeID(revisionValue) != CFBooleanGetTypeID(),
              revisionValue.doubleValue == Double(revisionValue.intValue), revisionValue.intValue > 0,
              let expires = request["expiresAt"] as? NSNumber,
              CFGetTypeID(expires) != CFBooleanGetTypeID(), expires.doubleValue.isFinite,
              expires.doubleValue > Date().timeIntervalSince1970,
              request["state"] as? String == "pending", request["engine"] as? String == "codex",
              request["kind"] as? String == "choice", request["body"] as? String == "AGENTINBOX_CHOOSE_ROUTE",
              request["title"] as? String == "Codex 等待回答", request["multiSelect"] as? Bool == false,
              let native = request["native"] as? [String: Any],
              let callback = native["callback"] as? [String: Any], callback["method"] as? String == "item/tool/requestUserInput",
              let callbackID = callback["id"], !(callbackID is NSNull),
              let params = callback["params"] as? [String: Any],
              let questions = request["questions"] as? [[String: Any]], questions.count == 1,
              let nativeQuestions = params["questions"] as? [[String: Any]], nativeQuestions.count == 1 else {
            XCTFail("Only the exact unexpired isolated Codex single-choice fixture is authorized"); return
        }
        let revision = revisionValue.intValue
        let fields = ["hostId", "runtimeId", "sessionId", "turnId", "nativeRequestId", "itemId"]
        var identities: [String: String] = [:]
        for field in fields { identities[field] = try string(request, field) }
        let encodedCallbackID = try JSONSerialization.data(withJSONObject: callbackID, options: [.fragmentsAllowed, .sortedKeys])
        guard identities["sessionId"] == (params["threadId"] as? String),
              identities["turnId"] == (params["turnId"] as? String), identities["itemId"] == (params["itemId"] as? String),
              identities["nativeRequestId"] == String(data: encodedCallbackID, encoding: .utf8) else {
            XCTFail("Original callback identity does not match the product binding"); return
        }
        if let expected = envelope["binding"] as? [String: Any] {
            guard expected["requestId"] as? String == requestID,
                  let expectedRevision = expected["revision"] as? NSNumber,
                  CFGetTypeID(expectedRevision) != CFBooleanGetTypeID(), expectedRevision == revisionValue else {
                XCTFail("Independent product binding mismatch"); return
            }
            for field in fields where expected[field] as? String != identities[field] {
                XCTFail("Independent original binding mismatch: \(field)"); return
            }
        }
        let question = questions[0], nativeQuestion = nativeQuestions[0]
        guard question["id"] as? String == "route", nativeQuestion["id"] as? String == "route",
              question["prompt"] as? String == "AGENTINBOX_CHOOSE_ROUTE",
              nativeQuestion["question"] as? String == "AGENTINBOX_CHOOSE_ROUTE",
              question["multiSelect"] as? Bool == false, nativeQuestion["isSecret"] as? Bool != true,
              let options = request["options"] as? [[String: Any]], options.count == 2,
              let questionOptions = question["options"] as? [[String: Any]], questionOptions.count == 2,
              let nativeOptions = nativeQuestion["options"] as? [[String: Any]], nativeOptions.count == 2 else {
            XCTFail("Only the single route question and its exact Alpha/Beta options are authorized"); return
        }
        var betaID: String?
        for index in 0..<2 {
            let label = index == 0 ? "Alpha" : "Beta"
            let id = "q0-o\(index)"
            guard options[index]["label"] as? String == label, questionOptions[index]["label"] as? String == label,
                  nativeOptions[index]["label"] as? String == label, options[index]["id"] as? String == id,
                  questionOptions[index]["id"] as? String == id else {
                XCTFail("Option labels and IDs must match the original callback mapping"); return
            }
            if label == "Beta" { betaID = id }
        }
        guard let betaID else { XCTFail("No exact Beta option"); return }
        let app = XCUIApplication()
        app.launchArguments = ["--write-diagnostics"]
        app.launch()
        let row = app.buttons.matching(identifier: "request.\(requestID)")
        XCTAssertTrue(row.firstMatch.waitForExistence(timeout: 30), "Exact authorized request must be present")
        guard row.count == 1 else { XCTFail("Request UI identity is not unique"); return }
        row.firstMatch.tap()
        let questionText = app.staticTexts["AGENTINBOX_CHOOSE_ROUTE"]
        XCTAssertTrue(questionText.firstMatch.waitForExistence(timeout: 8))
        let identityText = app.staticTexts[requestID]
        let versionRow = app.cells.containing(.staticText, identifier: "版本").firstMatch
        for _ in 0..<6 where !identityText.isHittable || !versionRow.isHittable { app.swipeUp() }
        XCTAssertTrue(identityText.exists, "Detail must display the exact authorized product request ID")
        XCTAssertTrue(versionRow.exists)
        XCTAssertTrue(versionRow.staticTexts[String(revision)].exists, "Detail must display the exact authorized revision")
        guard Date().timeIntervalSince1970 < expires.doubleValue else { XCTFail("Fixture expired before selection"); return }
        let beta = app.buttons.matching(identifier: "option.\(betaID)")
        for _ in 0..<6 where !beta.firstMatch.isHittable { app.swipeDown() }
        guard beta.count == 1, beta.firstMatch.isHittable, beta.firstMatch.label.contains("Beta") else {
            XCTFail("Exact authorized Beta option is not uniquely actionable"); return
        }
        beta.firstMatch.tap()
        XCTAssertEqual(beta.firstMatch.value as? String, "已选择")
        let submit = app.buttons["submit-decision"]
        for _ in 0..<4 where !submit.isHittable { app.swipeUp() }
        guard submit.exists, submit.isEnabled, submit.isHittable,
              Date().timeIntervalSince1970 < expires.doubleValue else {
            XCTFail("Original request is no longer actionable before its only submission"); return
        }
        submit.tap() // Exactly one submission; failure below never retries or switches requests.
        let adopted = app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND label == %@", "request-state", "原任务已采用")).firstMatch
        for _ in 0..<6 where !adopted.isHittable { app.swipeDown() }
        XCTAssertTrue(adopted.waitForExistence(timeout: 75), "Only the original adopted state counts as success")
        var proof: [String: Any] = identities
        proof["requestId"] = requestID; proof["revision"] = revision; proof["optionId"] = betaID
        proof["submissionTapCount"] = 1; proof["state"] = "adopted"
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: proof, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "physical-isolated-original-beta-binding-proof"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

}
