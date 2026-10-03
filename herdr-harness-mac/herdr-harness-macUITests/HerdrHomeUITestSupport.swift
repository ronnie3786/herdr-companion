import XCTest

/// Home acceptance runs use the same canned, offline fleet as the other suites.
/// The moment argument also requests fresh, isolated Home presentation defaults.
extension HerdrUITestCase {
    @MainActor
    func launchHomeDemoApp(moment: String = "morning") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-HerdrDemoMode", "-HerdrResetSidebarState",
            "-ApplePersistenceIgnoreState", "YES",
            "-HerdrHomeMoment", moment,
        ]
        app.launch()
        app.activate()
        XCTAssertTrue(app.control(identifier: "home.content").waitForExistence(timeout: 10))
        let greeting = [
            "morning": "Good morning.", "afternoon": "Good afternoon.", "clear": "Good evening.",
            "trouble": "Heads up.", "loading": "Welcome home.",
            "disconnected": "Let’s reconnect.", "stale": "Here’s the last update.",
        ][moment] ?? "Good morning."
        XCTAssertTrue(app.text(containing: greeting).waitForExistence(timeout: 10),
                      "The requested synthetic snapshot should be installed before interaction")
        return app
    }

    @MainActor
    @discardableResult
    func waitForHomeValue(_ value: String, in element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", value), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    @discardableResult
    func revealHomeControl(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let control = app.control(identifier: identifier)
        let content = app.control(identifier: "home.content")
        for _ in 0..<8 {
            if control.exists && control.isHittable { return control }
            content.scroll(byDeltaX: 0, deltaY: -220)
        }
        XCTAssertTrue(control.exists, "Home should contain \(identifier)")
        XCTAssertTrue(control.isHittable, "Scrolling should reveal \(identifier)")
        return control
    }
}
