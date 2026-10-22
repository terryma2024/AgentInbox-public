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

    func testDecisionContextOriginalOnPhysicalPhone() throws {
        try requirePhysicalAuthorization()
        let env = ProcessInfo.processInfo.environment
        guard env["AGENTINBOX_CONTEXT_ACCEPTANCE"] == "1",
              let data = env["AGENTINBOX_PHYSICAL_BINDING_JSON"]?.data(using: .utf8),
              let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let request = envelope["request"] as? [String: Any],
              let requestID = request["requestId"] as? String,
              let host = request["hostId"] as? String,
              let project = request["projectPath"] as? String,
              let context = request["decisionContext"] as? [String: Any],
              let original = context["originalContent"] as? String,
              let mode = envelope["contextCase"] as? String,
              ["question", "command"].contains(mode) else {
            throw XCTSkip("需显式提供隔离上下文验收题的精确绑定")
        }
        let marker = mode == "question" ? "CONTEXT_QUESTION_END" : "CONTEXT_COMMAND_END"
        guard original.contains(marker), (request["expiresAt"] as? Double ?? 0) > Date().timeIntervalSince1970,
              let native = request["native"] as? [String: Any], let callback = native["callback"] as? [String: Any],
              let params = callback["params"] as? [String: Any],
              request["sessionId"] as? String == params["threadId"] as? String,
              request["turnId"] as? String == params["turnId"] as? String,
              request["itemId"] as? String == params["itemId"] as? String else {
            XCTFail("上下文验收必须来自同一个有效原调用"); return
        }
        let app = XCUIApplication(); app.launch()
        let row = app.buttons["request.\(requestID)"]
        XCTAssertTrue(row.waitForExistence(timeout: 30)); row.tap()
        func reveal(_ element: XCUIElement, upward: Bool = true) {
            for _ in 0..<18 where !element.isHittable { if upward { app.swipeUp() } else { app.swipeDown() } }
            XCTAssertTrue(element.isHittable)
        }
        let expected = ["machine": host, "project": project,
                        "goal": context["taskGoal"] as? String ?? "未知",
                        "reason": context["blockingReason"] as? String ?? "未知",
                        "scope": context["impactScope"] as? String ?? "未知"]
        for key in ["machine", "project", "goal", "reason", "scope"] {
            let field = app.staticTexts["decision-context.\(key)"]; reveal(field)
            XCTAssertTrue(field.label == expected[key], "手机上下文字段必须与绑定的原请求一致：\(key)")
        }
        let details = XCTAttachment(screenshot: app.screenshot()); details.name = "physical-decision-context"; details.lifetime = .keepAlways; add(details)
        let full = app.buttons["decision-original"]; reveal(full, upward: false); full.tap()
        XCTAssertTrue(app.navigationBars["完整原文"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["完整原始参数"].exists)
        if mode == "question", let questions = params["questions"] as? [[String: Any]],
           let prompt = questions.first?["question"] as? String {
            let firstLine = app.staticTexts["decision-original.question-0.0"]
            XCTAssertTrue(firstLine.waitForExistence(timeout: 5))
            XCTAssertTrue(firstLine.label == prompt.components(separatedBy: "\n")[0], "原文必须直接展示消息内容")
        } else if let command = params["command"] as? String {
            let firstLine = app.staticTexts["decision-original.command.0"]
            XCTAssertTrue(firstLine.waitForExistence(timeout: 5))
            XCTAssertTrue(firstLine.label == command.components(separatedBy: "\n")[0], "命令必须按原始消息展示")
        }
        let tail = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch
        reveal(tail)
        let end = XCTAttachment(screenshot: app.screenshot()); end.name = "physical-original-tail"; end.lifetime = .keepAlways; add(end)
        XCTAssertTrue(app.buttons["copy-decision-original"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let option = app.buttons[mode == "question" ? "option.q0-o1" : "option.deny"]
        reveal(option); option.tap()
        let submit = app.buttons["submit-decision"]; reveal(submit); XCTAssertTrue(submit.isEnabled); submit.tap()
        let submitted = app.descendants(matching: .any)["reply-step.submitted"]; reveal(submitted, upward: false)
        func confirmed(_ element: XCUIElement) -> Bool {
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "已确认"), object: element)], timeout: 35) == .completed
        }
        XCTAssertTrue(confirmed(submitted))
        if mode == "question" {
            let received = app.descendants(matching: .any)["reply-step.received"]
            let continued = app.descendants(matching: .any)["reply-step.continued"]
            XCTAssertTrue(confirmed(received)); XCTAssertEqual(continued.value as? String, "未确认")
            print("AGENTINBOX_PHYSICAL_RECEIVED_CONFIRMED")
            XCTAssertTrue(confirmed(continued))
        }
        print("AGENTINBOX_PHYSICAL_CONTEXT_ACCEPTED")
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
        if ProcessInfo.processInfo.environment["AGENTINBOX_REPLY_WIDGET_ACCEPTANCE"] == "1" {
            try runExactWidgetBeta(requestID: requestID, revision: revision, betaID: betaID)
            return
        }
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
        let versionRow = app.descendants(matching: .any)["request-revision"]
        for _ in 0..<6 where !identityText.isHittable || !versionRow.isHittable { app.swipeUp() }
        XCTAssertTrue(identityText.exists, "Detail must display the exact authorized product request ID")
        XCTAssertTrue(versionRow.exists)
        XCTAssertEqual(versionRow.value as? String, String(revision), "Detail must display the exact authorized revision")
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
        let progressAcceptance = ProcessInfo.processInfo.environment["AGENTINBOX_REPLY_PROGRESS_ACCEPTANCE"] == "1"
        let received = app.descendants(matching: .any)["reply-step.received"]
        let continued = app.descendants(matching: .any)["reply-step.continued"]
        if progressAcceptance {
            for _ in 0..<6 where !received.isHittable { app.swipeDown() }
            XCTAssertEqual(received.value as? String, "未确认")
            XCTAssertEqual(continued.value as? String, "未确认")
            for _ in 0..<6 where !submit.isHittable { app.swipeUp() }
            guard submit.isHittable, submit.isEnabled else { XCTFail("Exact original submit control is unavailable"); return }
        }
        submit.tap() // Exactly one submission; failure below never retries or switches requests.
        if progressAcceptance {
            for _ in 0..<6 where !received.isHittable { app.swipeDown() }
            func confirmed(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
                XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "已确认"), object: element)], timeout: timeout) == .completed
            }
            let submitted = app.descendants(matching: .any)["reply-step.submitted"]
            XCTAssertTrue(confirmed(submitted, timeout: 30), "Durable relay submission must be confirmed")
            XCTAssertTrue(confirmed(received, timeout: 30), "Original source-attributed reception must be confirmed")
            XCTAssertEqual(continued.value as? String, "未确认", "Controlled native continuation must still be held")
            // The private qualification driver releases its controlled model only
            // after this UI assertion. This never becomes part of an agent answer.
            print("AGENTINBOX_PHYSICAL_RECEIVED_CONFIRMED")
            XCTAssertTrue(confirmed(continued, timeout: 40), "Original execution must independently continue")
        } else {
            let adopted = app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND label == %@", "request-state", "原任务已采用")).firstMatch
            for _ in 0..<6 where !adopted.isHittable { app.swipeDown() }
            XCTAssertTrue(adopted.waitForExistence(timeout: 75), "Only the original adopted state counts as success")
        }
        var proof: [String: Any] = identities
        proof["requestId"] = requestID; proof["revision"] = revision; proof["optionId"] = betaID
        proof["submissionTapCount"] = 1; proof["state"] = "adopted"
        proof["independentReplyMilestonesChecked"] = progressAcceptance
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: proof, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "physical-isolated-original-beta-binding-proof"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func runExactWidgetBeta(requestID: String, revision: Int, betaID: String) throws {
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.buttons["request.\(requestID)"].waitForExistence(timeout: 30))
        app.terminate()
        XCTAssertEqual(app.state, .notRunning, "Widget acceptance must start with the App stopped")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        springboard.activate()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        springboard.swipeRight() // Include the Today View before scanning Home Screen pages.
        let beta = springboard.buttons["widget.option.\(requestID).\(revision).\(betaID)"]
        for page in 0..<7 {
            if beta.exists { break }
            let refresh = springboard.buttons["widget.refresh"].firstMatch
            if refresh.exists && refresh.isHittable {
                refresh.tap() // Read-only refresh of the actual Widget; never submits.
                _ = beta.waitForExistence(timeout: 10)
            }
            if beta.exists { break }
            let tree = XCTAttachment(string: springboard.debugDescription)
            tree.name = "private-widget-surface-page-\(page)"; tree.lifetime = .keepAlways; add(tree)
            let screenshot = XCTAttachment(screenshot: springboard.screenshot())
            screenshot.name = "private-widget-screen-page-\(page)"; screenshot.lifetime = .keepAlways; add(screenshot)
            if page < 6 { springboard.swipeLeft() }
        }
        guard beta.waitForExistence(timeout: 10), beta.isHittable else {
            XCTFail("Exact authorized Beta must be visible on a medium or large physical Widget; no alternate request is allowed")
            return
        }
        beta.tap() // One AppIntent invocation; never fall back to the App submission path.
        XCTAssertNotEqual(app.state, .runningForeground)
        let received = springboard.staticTexts["原调用已接收"]
        let refresh = springboard.buttons["widget.refresh"].firstMatch
        let deadline = Date().addingTimeInterval(25)
        while !received.exists && Date() < deadline {
            if refresh.exists && refresh.isHittable { refresh.tap() }
            RunLoop.current.run(until: Date().addingTimeInterval(2))
        }
        let receivedBeforeContinuation = received.exists
        XCTAssertTrue(receivedBeforeContinuation, "Physical Widget must independently refresh the original reception milestone")
        XCTAssertNotEqual(app.state, .runningForeground)
        print("AGENTINBOX_PHYSICAL_RECEIVED_CONFIRMED")
        let empty = springboard.staticTexts["暂无待决问题"]
        let completionDeadline = Date().addingTimeInterval(40)
        while !empty.exists && Date() < completionDeadline {
            if refresh.exists && refresh.isHittable { refresh.tap() }
            RunLoop.current.run(until: Date().addingTimeInterval(2))
        }
        XCTAssertTrue(empty.exists, "Completed original execution must leave the active Widget inbox")
        XCTAssertNotEqual(app.state, .runningForeground)
        let proof: [String: Any] = ["physicalDevice": true, "requestId": requestID, "revision": revision,
                                  "optionId": betaID, "submissionTapCount": 1, "appForegroundOpenedByAnswer": false,
                                  "receivedVisibleBeforeContinuation": receivedBeforeContinuation, "completedRequestLeftActiveInbox": empty.exists]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: proof, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "physical-widget-exact-beta-milestones-proof"; attachment.lifetime = .keepAlways; add(attachment)
    }

}
