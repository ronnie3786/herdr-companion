import XCTest

@MainActor
final class HerdrFirstMateChatUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    func testSendInfoFileAndNativeSwipeBack() throws {
        let app = launch(); defer { app.terminate() }
        let receipt = app.buttons["first-mate-feature-demo1-demo-receipts"]
        reach(receipt, app: app, downward: false); receipt.tap()
        XCTAssertTrue(app.buttons["first-mate-chat-title"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.tabBars.buttons["First Mates"].isHittable)
        for id in ["first-mate-chat-back", "first-mate-chat-title", "first-mate-chat-inspector-toggle", "first-mate-feature-options", "first-mate-composer-plus", "first-mate-send"] {
            let control = app.buttons[id]
            XCTAssertGreaterThanOrEqual(control.frame.width, 43.99, id)
            XCTAssertGreaterThanOrEqual(control.frame.height, 43.99, id)
        }
        try capture("phase3-chat-before-send", app)
        let input = app.descendants(matching: .any)["first-mate-composer"]
        input.tap(); input.typeText("Synthetic phone direction\nKeep the second line.")
        try capture("phase3-chat-focused", app)
        app.buttons["first-mate-send"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Synthetic phone direction")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse((input.value as? String ?? "").contains("Synthetic phone direction"))
        app.buttons["first-mate-chat-inspector-toggle"].tap()
        XCTAssertTrue(app.otherElements["first-mate-info-screen"].waitForExistence(timeout: 5))
        app.buttons["first-mate-tab-documents"].tap()
        XCTAssertTrue(app.staticTexts["first-mate-documents"].waitForExistence(timeout: 5))
        try capture("phase3-info-documents", app)
        app.navigationBars.buttons.firstMatch.tap()
        let file = app.buttons["first-mate-file-demo-receipts-document-2"]
        reach(file, app: app, downward: true); file.tap()
        XCTAssertTrue(app.staticTexts["first-mate-documents"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        let origin = app.coordinate(withNormalizedOffset: .init(dx: 0.005, dy: 0.48))
        origin.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: .init(dx: 0.90, dy: 0.48)))
        XCTAssertTrue(app.buttons["first-mate-machine-picker"].waitForExistence(timeout: 5), "Native edge swipe must pop custom chrome")
        XCTAssertTrue(receipt.isHittable)
        try capture("phase3-list-after-send", app)
    }
    func testAdditionalResponseKeepsItsDocumentAndPRCards() throws {
        let app = launch(extra: ["-HerdrFirstMateAdditionalResponse"]); defer { app.terminate() }
        let receipt = app.buttons["first-mate-feature-demo1-demo-receipts"]
        reach(receipt, app: app, downward: false); receipt.tap()
        let disclosure = app.buttons["Additional response from this turn"]
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5)); disclosure.tap()
        let file = app.buttons["first-mate-file-additional-document"]
        reach(file, app: app, downward: false)
        let pr = app.descendants(matching: .any)["first-mate-link-additional-pr"]
        XCTAssertTrue(pr.waitForExistence(timeout: 5))
        try capture("phase3-additional-response-resources", app)
        file.tap()
        XCTAssertTrue(app.staticTexts["first-mate-documents"].waitForExistence(timeout: 5))
        let document = app.buttons["first-mate-document-additional-document"]
        reach(document, app: app, downward: false); document.tap()
        XCTAssertTrue(app.staticTexts["Synthetic supplementary evidence. No agents launched."].waitForExistence(timeout: 5))
    }

    func testPauseResumeAndConfirmedCancellationRetainTheConversation() throws {
        let app = launch(); defer { app.terminate() }
        let receipt = app.buttons["first-mate-feature-demo1-demo-receipts"]
        reach(receipt, app: app, downward: false); receipt.tap()
        let options = app.buttons["first-mate-feature-options"]
        XCTAssertTrue(options.waitForExistence(timeout: 5)); options.tap()
        app.buttons["Pause feature"].tap()
        options.tap()
        let resume = app.buttons["Resume feature"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5)); resume.tap()
        options.tap()
        XCTAssertTrue(app.buttons["Pause feature"].waitForExistence(timeout: 5))
        app.buttons["Cancel feature"].tap()
        let confirm = app.sheets.buttons["Cancel feature"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        XCTAssertTrue(app.staticTexts["first-mate-checkpoint-status"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["first-mate-checkpoint-status"].label.contains("This feature is closed"))
        XCTAssertTrue(app.buttons["first-mate-chat-title"].label.contains("Cancelled"))
        XCTAssertFalse(app.descendants(matching: .any)["first-mate-composer"].exists)
        XCTAssertFalse(app.buttons["first-mate-reply-0"].exists)
        try capture("phase3-cancelled-chat", app)
        app.buttons["first-mate-chat-inspector-toggle"].tap()
        XCTAssertTrue(app.otherElements["first-mate-info-screen"].waitForExistence(timeout: 5))
    }

    func testBriefingReadoutAndCreationDraftSurvivesCancel() throws {
        let app = launch(extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
        defer { app.terminate() }
        app.buttons["first-mate-chat-pinned-lead"].tap()
        let capsule = app.buttons["first-mate-briefing-feature-demo1-demo-receipts"]
        reach(capsule, app: app, downward: false); capsule.tap()
        let open = app.buttons["first-mate-readout-open"]
        XCTAssertTrue(open.waitForExistence(timeout: 5)); try capture("phase3-readout-popover", app)
        open.tap()
        XCTAssertTrue(app.buttons["first-mate-chat-title"].waitForExistence(timeout: 5))
        app.buttons["first-mate-chat-back"].tap()
        XCTAssertTrue(app.staticTexts["first-mate-briefing-disclosure"].waitForExistence(timeout: 5))
        let input = app.descendants(matching: .any)["first-mate-composer"]
        input.tap(); input.typeText("Synthetic briefing goal")
        app.buttons["first-mate-send"].tap()
        let goal = app.descendants(matching: .any)["first-mate-create-goal"]
        XCTAssertTrue(goal.waitForExistence(timeout: 5))
        XCTAssertEqual(goal.value as? String, "Synthetic briefing goal")
        XCTAssertTrue(app.buttons["first-mate-create-machine"].label.contains("Choose a machine"))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "Synthetic briefing goal")
        try capture("phase3-briefing-draft-retained", app)
    }
    func testTwoHundredMessagesAndCompleteLongReplyScroll() throws {
        let app = launch(extra: ["-HerdrFirstMateTranscriptPerformance"]); defer { app.terminate() }
        let feature = app.buttons["first-mate-feature-demo1-demo-chat-performance"]
        reach(feature, app: app, downward: false); feature.tap()
        let initial = metrics(app) // Before any scroll gestures or row queries.
        let initialBodies = try XCTUnwrap(Int(initial.split(separator: ";")[0].split(separator: "=").last ?? ""))
        XCTAssertLessThan(initialBodies, 200, "Opening chat must not evaluate all 200 bodies to register readout popovers")
        let end = app.staticTexts["END OF COMPLETE MESSAGE"]
        XCTAssertTrue(end.waitForExistence(timeout: 5))
        XCTAssertTrue(end.isHittable, "The initial bottom anchor must expose the complete message end")
        try capture("phase3-long-message-end", app)
        let first = app.descendants(matching: .any)["first-mate-message-performance-message-0"]
        let started = Date(); var gestures = 0
        while gestures < 85 && !(first.exists && first.isHittable && first.frame.minY >= 120) {
            drag(app, downward: true); gestures += 1
        }
        XCTAssertTrue(first.exists && first.isHittable, "All 200 messages must remain reachable")
        let elapsed = Date().timeIntervalSince(started), final = metrics(app)
        let observation = "200 synthetic messages including a 24-paragraph final reply; initial=\(initial); final=\(final); gestures=\(gestures); XCTest gesture/settling seconds=\(elapsed). Not an FPS measurement."
        print("HERDR_PHASE3_PERFORMANCE \(observation)")
        let attachment = XCTAttachment(string: observation); attachment.name = "phase3-transcript-performance"; attachment.lifetime = .keepAlways; add(attachment)
        try capture("phase3-first-of-200", app)
    }
    private func launch(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-HerdrFirstMateDemo", "-HerdrResetFirstMateScope", "-herdr.smartAlerts", "NO"] + extra
        app.launch(); XCTAssertTrue(app.buttons["first-mate-machine-picker"].waitForExistence(timeout: 10)); return app
    }
    private func drag(_ app: XCUIApplication, downward: Bool) {
        let low: CGFloat = app.keyboards.firstMatch.exists ? 0.48 : 0.73
        app.coordinate(withNormalizedOffset: .init(dx: 0.94, dy: downward ? 0.25 : low)).press(forDuration: 0.03,
            thenDragTo: app.coordinate(withNormalizedOffset: .init(dx: 0.94, dy: downward ? low : 0.25)))
    }
    private func reach(_ element: XCUIElement, app: XCUIApplication, downward: Bool) {
        for _ in 0..<28 {
            if element.exists && element.isHittable && element.frame.minY >= 100 && element.frame.maxY < app.frame.maxY - 175 { return }
            drag(app, downward: downward)
        }
        XCTAssertTrue(element.exists && element.isHittable, element.debugDescription)
    }
    private func metrics(_ app: XCUIApplication) -> String {
        let button = app.buttons["first-mate-transcript-metrics"]; button.tap(); return button.label
    }
    private func capture(_ name: String, _ app: XCUIApplication) throws {
        let image = app.screenshot(), attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        let folder = URL(filePath: ProcessInfo.processInfo.environment["HERDR_IOS_RENDER_DIR"]
            ?? ProcessInfo.processInfo.environment["TEST_RUNNER_HERDR_IOS_RENDER_DIR"] ?? NSTemporaryDirectory() + "herdr-chat-ui")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try image.pngRepresentation.write(to: folder.appending(path: name + ".png"))
    }
}
