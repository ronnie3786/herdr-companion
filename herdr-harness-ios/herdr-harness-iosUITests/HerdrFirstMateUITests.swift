import XCTest

final class HerdrFirstMateUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testFeatureConversationAndWorkflowEvidence() throws {
        let app = launchDemo(appearance: "light")
        try capture("iphone-light-features", app: app)
        openFeature(app)
        XCTAssertTrue(app.descendants(matching: .any)["first-mate-composer"].waitForExistence(timeout: 5))
        try capture("iphone-light-conversation", app: app)
        let composer = app.descendants(matching: .any)["first-mate-composer"]
        composer.tap()
        composer.typeText("Check accessibility before implementation.")
        app.buttons["first-mate-send"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "first-mate-message-", "Check accessibility before implementation.")).firstMatch.waitForExistence(timeout: 5))
        app.buttons["first-mate-open-workflow"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["first-mate-workflow"].waitForExistence(timeout: 5))
        try capture("iphone-light-workflow", app: app)
        let documents = app.buttons["first-mate-visit-documents-demo-plan"]
        let foundDocuments = documents.waitForExistence(timeout: 5)
        if !foundDocuments { print(app.debugDescription) }
        XCTAssertTrue(foundDocuments)
        documents.tap()
        app.buttons["Session ownership map.md"].tap()
        XCTAssertTrue(app.staticTexts["Session ownership"].waitForExistence(timeout: 5))
        try capture("iphone-light-document", app: app)
        app.terminate()
    }

    @MainActor
    func testSevenReviewersRemainAvailableBehindGraph() throws {
        let app = launchDemo(appearance: "dark")
        let next = app.buttons["first-mate-demo-next"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        next.tap()
        next.tap()
        openFeature(app)
        try capture("iphone-dark-conversation", app: app)
        app.buttons["first-mate-open-workflow"].tap()
        let graph = app.buttons["Graph"]
        XCTAssertTrue(graph.waitForExistence(timeout: 5))
        graph.tap()
        try capture("iphone-dark-graph", app: app)
        let reviewAgents = app.buttons["first-mate-visit-agents-demo-review"]
        scrollTo(reviewAgents, app: app)
        reviewAgents.tap()
        XCTAssertTrue(app.buttons["Correctness review"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["User experience review"].exists)
        try capture("iphone-dark-seven-reviewers", app: app)
        app.buttons["Concurrency review"].tap()
        let source = app.buttons["first-mate-source-details"]
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        source.tap()
        XCTAssertTrue(app.staticTexts["demo-session-review-2"].waitForExistence(timeout: 5))
        try capture("iphone-dark-agent-session", app: app)
        app.terminate()
    }

    @MainActor
    func testCreateAFeatureAndSendItsFirstDirection() throws {
        let app = launchDemo(appearance: "light")
        app.buttons["first-mate-new-feature"].tap()
        let title = app.descendants(matching: .any)["first-mate-create-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 4))
        title.tap()
        title.typeText("Polish the mobile workflow")
        let goal = app.descendants(matching: .any)["first-mate-create-goal"]
        goal.tap()
        goal.typeText("Make every review easy to inspect on a phone.")
        let folder = app.descendants(matching: .any)["first-mate-create-folder"]
        scrollTo(folder, app: app)
        folder.tap()
        folder.typeText("/workspace/sample-app")
        let submit = app.buttons["first-mate-create-submit"]
        scrollTo(submit, app: app)
        submit.tap()
        let composer = app.descendants(matching: .any)["first-mate-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("Start with a plan and an architecture review.")
        app.buttons["first-mate-send"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "first-mate-message-", "Start with a plan and an architecture review.")).firstMatch.waitForExistence(timeout: 5))
        try capture("iphone-new-feature", app: app)
        app.terminate()
    }

    @MainActor
    func testLargeTextKeepsNavigationAndComposerReachable() throws {
        let app = launchDemo(appearance: "light", extraArguments: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge"
        ])
        openFeature(app)
        let composer = app.descendants(matching: .any)["first-mate-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertTrue(composer.isHittable)
        let workflow = app.buttons["first-mate-open-workflow"]
        XCTAssertTrue(workflow.isHittable)
        try capture("iphone-accessibility-conversation", app: app)
        workflow.tap()
        XCTAssertTrue(app.descendants(matching: .any)["first-mate-workflow"].waitForExistence(timeout: 5))
        try capture("iphone-accessibility-workflow", app: app)
        app.terminate()
    }

    @MainActor
    private func launchDemo(appearance: String, extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-HerdrFirstMateDemo", "-herdr.firstMate.appearance", appearance, "-herdr.smartAlerts", "NO"] + extraArguments
        app.launch()
        XCTAssertTrue(app.buttons["first-mate-feature-demo-session-continuity"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func openFeature(_ app: XCUIApplication) {
        let feature = app.buttons["first-mate-feature-demo-session-continuity"]
        scrollTo(feature, app: app)
        feature.tap()
    }

    @MainActor
    private func scrollTo(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<8 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        if !element.exists || !element.isHittable { print(app.debugDescription) }
        XCTAssertTrue(element.exists && element.isHittable)
    }

    @MainActor
    private func capture(_ name: String, app: XCUIApplication) throws {
        // Accessibility can be ready a few frames before the native sheet finishes drawing.
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let captureName = app.windows.firstMatch.frame.width > 700 ? name.replacingOccurrences(of: "iphone", with: "ipad") : name
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = captureName
        attachment.lifetime = .keepAlways
        add(attachment)
        let folder = URL(fileURLWithPath: "/tmp/herdr-first-mate-ios-screens", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try screenshot.pngRepresentation.write(to: folder.appending(path: "\(captureName).png"))
    }
}
