import XCTest

@MainActor
final class HerdrFirstMateLeadUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    func testRealLeadInfoMachineSwitchAndReturnKeepOwnerAndDraft() throws {
        let app = launch(); defer { app.terminate() }
        app.buttons["first-mate-chat-pinned-lead"].tap()
        choose("first-mate-lead-automatic", app)
        owner("desktop", app)
        XCTAssertFalse(app.staticTexts["first-mate-briefing-disclosure"].exists)
        XCTAssertFalse(app.buttons["first-mate-feature-options"].exists)
        let composer = app.descendants(matching: .any)["first-mate-composer"]
        composer.tap(); composer.typeText("Desktop draft stays here")
        choose("first-mate-lead-machine-demo2", app)
        owner("laptop", app)
        XCTAssertFalse((composer.value as? String ?? "").contains("Desktop draft"))
        composer.tap(); composer.typeText("Laptop draft stays here")
        choose("first-mate-lead-machine-demo1", app)
        owner("desktop", app)
        XCTAssertEqual(composer.value as? String, "Desktop draft stays here")
        try capture("phase4-lead-desktop-draft", app)
        app.buttons["first-mate-chat-inspector-toggle"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["first-mate-lead-tab-overview"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Your features at a glance"].exists)
        XCTAssertFalse(app.buttons["first-mate-tab-agents"].exists)
        XCTAssertFalse(app.buttons["first-mate-tab-workflow"].exists)
        try capture("phase4-lead-info", app)
        let receipt = app.buttons["first-mate-briefing-feature-demo1-demo-receipts"]
        XCTAssertTrue(receipt.isHittable); receipt.tap()
        let open = app.buttons["first-mate-readout-open"]
        XCTAssertTrue(open.waitForExistence(timeout: 5)); open.tap()
        XCTAssertTrue(app.buttons["first-mate-chat-title"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["first-mate-chat-title"].label.contains("Receipt export"))
        app.buttons["first-mate-chat-back"].tap()
        XCTAssertTrue(app.staticTexts["Your features at a glance"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        owner("desktop", app)
        XCTAssertEqual(composer.value as? String, "Desktop draft stays here")
        choose("first-mate-lead-automatic", app)
        app.buttons["first-mate-chat-back"].tap()
        XCTAssertTrue(app.buttons["first-mate-chat-pinned-lead"].waitForExistence(timeout: 5))
    }
    func testFailedListPollStandInAndRecoveredPreferredHaveMatchingOwnerHeader() throws {
        let app = launch(); defer { app.terminate() }
        app.buttons["first-mate-chat-pinned-lead"].tap()
        choose("first-mate-lead-machine-demo1", app)
        owner("desktop", app)
        option("Fail preferred LIST poll", app)
        owner("desktop", app)
        XCTAssertFalse(app.staticTexts["first-mate-lead-offline"].exists)
        option("Fail preferred LIST poll", app)
        owner("laptop", app)
        let offline = app.staticTexts["first-mate-lead-offline"]
        XCTAssertTrue(offline.waitForExistence(timeout: 5))
        XCTAssertTrue(offline.label.contains("desktop is offline") && offline.label.contains("laptop is standing in"))
        try capture("phase4-lead-stand-in", app)
        option("Recover preferred machine", app)
        owner("desktop", app)
        XCTAssertFalse(offline.exists)
        choose("first-mate-lead-automatic", app)
        try capture("phase4-lead-recovered", app)
    }
    func testOlderHostBriefingCreationKeepsExplicitDestination() throws {
        let app = launch(extra: ["-HerdrFirstMateOlderHosts", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
        defer { app.terminate() }
        app.buttons["first-mate-chat-pinned-lead"].tap()
        XCTAssertTrue(app.staticTexts["first-mate-briefing-disclosure"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["first-mate-lead-machine-menu"].exists)
        let field = app.descendants(matching: .any)["first-mate-composer"]
        field.tap(); field.typeText("Synthetic older-host goal")
        app.buttons["first-mate-send"].tap()
        XCTAssertTrue(app.buttons["first-mate-create-machine"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["first-mate-create-machine"].label.contains("Choose a machine"))
        XCTAssertEqual(app.descendants(matching: .any)["first-mate-create-goal"].value as? String, "Synthetic older-host goal")
        app.buttons["Cancel"].tap()
        XCTAssertEqual(field.value as? String, "Synthetic older-host goal")
        try capture("phase4-older-host-briefing", app)
    }
    private func launch(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-HerdrFirstMateDemo", "-HerdrFirstMateLeadScenarios", "-HerdrResetFirstMateScope", "-herdr.smartAlerts", "NO"] + extra
        app.launch(); XCTAssertTrue(app.buttons["first-mate-machine-picker"].waitForExistence(timeout: 10)); return app
    }
    private func choose(_ id: String, _ app: XCUIApplication) {
        let menu = app.buttons["first-mate-lead-machine-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5)); menu.tap()
        let button = app.buttons[id]; XCTAssertTrue(button.waitForExistence(timeout: 5)); button.tap()
    }
    private func option(_ text: String, _ app: XCUIApplication) {
        app.buttons["first-mate-lead-options"].tap()
        let button = app.buttons[text]; XCTAssertTrue(button.waitForExistence(timeout: 5)); button.tap()
    }
    private func owner(_ name: String, _ app: XCUIApplication) {
        let value = app.staticTexts["first-mate-lead-owner"]
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label BEGINSWITH %@", name + " ·"), object: value)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
        XCTAssertTrue(app.descendants(matching: .any)["first-mate-composer"].exists)
    }
    private func capture(_ name: String, _ app: XCUIApplication) throws {
        let screenshot = app.screenshot(), attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        let folder = URL(filePath: ProcessInfo.processInfo.environment["HERDR_IOS_RENDER_DIR"]
            ?? ProcessInfo.processInfo.environment["TEST_RUNNER_HERDR_IOS_RENDER_DIR"] ?? NSTemporaryDirectory() + "herdr-lead-ui")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try screenshot.pngRepresentation.write(to: folder.appending(path: name + ".png"))
    }
}
