import XCTest

@MainActor
final class HerdrFirstMateComposerUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testAttachmentModelContextAndTapDictation() throws {
        let app = launch(); defer { app.terminate() }
        let row = app.buttons["first-mate-feature-demo1-demo-receipts"]
        for _ in 0..<8 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.isHittable); row.tap()
        let mic = app.buttons["first-mate-microphone"]
        XCTAssertTrue(mic.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(mic.frame.width, 44); XCTAssertGreaterThanOrEqual(mic.frame.height, 44)
        mic.tap()
        XCTAssertTrue(app.staticTexts["Listening…"].waitForExistence(timeout: 3))
        XCTAssertEqual(mic.label, "Stop voice dictation")
        app.buttons["first-mate-cancel-dictation"].tap()

        app.buttons["first-mate-model-controls"].tap()
        XCTAssertTrue(app.staticTexts["Current session"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Requested for next turn"].exists)
        let model = app.buttons["Sample Fast"]
        XCTAssertTrue(model.waitForExistence(timeout: 5)); model.tap()
        let apply = app.buttons["Apply for next coordinator turn"]
        XCTAssertTrue(apply.waitForExistence(timeout: 5)); apply.tap()
        try capture("phase5-model-confirmed", app)
        app.buttons["Done"].tap()
        app.buttons["first-mate-context"].tap()
        XCTAssertTrue(app.navigationBars["Context"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "38,400")).firstMatch.exists)
        try capture("phase5-context-sheet", app)
        app.buttons["Done"].tap()

        app.buttons["first-mate-composer-plus"].tap()
        app.buttons["Add sample attachment"].tap()
        XCTAssertTrue(app.staticTexts["Sample.txt"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Ready"].waitForExistence(timeout: 5))
        try capture("phase5-attachment-ready", app)
        app.buttons["first-mate-send"].tap()
        XCTAssertTrue(mic.waitForExistence(timeout: 5))
        let input = app.descendants(matching: .any)["first-mate-composer"]
        input.tap(); input.typeText("Keep this introduction.")
        XCTAssertTrue(mic.isHittable, "Dictation stays available while editing a draft")
        mic.tap()
        XCTAssertTrue(app.staticTexts["Listening…"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["first-mate-send"].isEnabled)
        try capture("dictation-listening", app)
        mic.tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "Keep this introduction.\nPlease summarize the next step.")
        XCTAssertFalse(app.staticTexts["Sent by voice"].exists, "Stopping must not send the draft")
        XCTAssertEqual(mic.label, "Start voice dictation")
        try capture("dictation-draft-review", app)
        app.buttons["first-mate-send"].tap()
        XCTAssertTrue(app.staticTexts["Sent by voice"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Please summarize the next step.")).firstMatch.exists)
        try capture("phase5-voice-sent", app)
    }

    func testMentionAndFeedbackEditorOnCanonicalResponse() throws {
        let app = launch(); defer { app.terminate() }
        let row = app.buttons["first-mate-feature-demo1-demo-receipts"]
        for _ in 0..<8 where !row.isHittable { app.swipeUp() }
        row.tap()
        let input = app.descendants(matching: .any)["first-mate-composer"]
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap(); input.typeText("@Quiet")
        let tag = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Tag Quiet notifications")).firstMatch
        XCTAssertTrue(tag.waitForExistence(timeout: 5)); tag.tap()
        XCTAssertTrue((input.value as? String ?? "").contains("@Quiet notifications "))
        app.buttons["first-mate-send"].tap()
        // Return to the conversation so the keyboard does not cover the older
        // response. This also verifies feedback remains available after navigation.
        app.buttons["first-mate-chat-back"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        // Collapse accessories so the retained reply and its context menu stay visible.
        let collapse = app.buttons["Collapse composer accessories"]
        if collapse.exists { collapse.tap() }
        let reply = app.descendants(matching: .any)["first-mate-message-demo-receipts-message-3"]
        for _ in 0..<12 where !reply.isHittable { app.swipeDown() }
        XCTAssertTrue(reply.exists && reply.isHittable)
        XCTAssertLessThan(reply.frame.maxY, app.buttons["first-mate-composer-plus"].frame.minY)
        reply.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.95)).press(forDuration: 1.0)
        try capture("phase5-feedback-menu", app)
        XCTAssertTrue(app.buttons["Give feedback"].waitForExistence(timeout: 5), app.debugDescription); app.buttons["Give feedback"].tap()
        XCTAssertTrue(app.navigationBars["Feedback"].waitForExistence(timeout: 5))
        let reason = app.buttons["Longer than it needed to be"]
        XCTAssertTrue(reason.waitForExistence(timeout: 5)); reason.tap()
        let comment = app.textFields["Comment (optional)"]
        if comment.exists { comment.tap(); comment.typeText("Synthetic feedback") }
        let save = app.buttons["Save feedback"]
        for _ in 0..<5 where !save.isHittable { app.swipeUp() }
        XCTAssertTrue(save.isHittable); save.tap()
        XCTAssertTrue(app.buttons["first-mate-reaction-demo-receipts-message-3"].waitForExistence(timeout: 5))
        try capture("phase5-feedback-reaction", app)
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-HerdrFirstMateDemo", "-HerdrFirstMateComposerScenarios", "-HerdrResetFirstMateScope", "-herdr.smartAlerts", "NO"]
        app.launch(); XCTAssertTrue(app.buttons["first-mate-machine-picker"].waitForExistence(timeout: 10)); return app
    }
    private func capture(_ name: String, _ app: XCUIApplication) throws {
        let screenshot = app.screenshot(), attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        let folder = URL(filePath: ProcessInfo.processInfo.environment["HERDR_IOS_RENDER_DIR"]
            ?? ProcessInfo.processInfo.environment["TEST_RUNNER_HERDR_IOS_RENDER_DIR"] ?? NSTemporaryDirectory() + "herdr-composer-ui")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try screenshot.pngRepresentation.write(to: folder.appending(path: name + ".png"))
    }
}
