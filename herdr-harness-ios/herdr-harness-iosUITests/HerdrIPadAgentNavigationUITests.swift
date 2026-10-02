import XCTest

@MainActor
final class HerdrIPadAgentNavigationUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testAgentChatKeepsTabsAvailableAndPreservesSelection() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-HerdrDemoMode", "-HerdrAgentChatFixture", "-herdr.smartAlerts", "NO",
                               "-herdr.ios.appearance.glass", "YES"]
        app.launch()
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        try XCTSkipIf(app.windows.firstMatch.frame.width < 600, "iPad split navigation regression")
        let card = app.buttons["agent-card-demo1|w2:p1"]
        XCTAssertTrue(card.waitForExistence(timeout: 10)); card.tap()
        let title = app.staticTexts["pane-session-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertTrue(title.label.contains("Sample reading list export"))

        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            for name in ["Settings", "First Mates", "Notes", "Attention"] {
                tab(name, app: app).tap()
                let agents = tab("Agents", app: app)
                agents.tap()
                XCTAssertTrue(title.waitForExistence(timeout: 5))
                XCTAssertTrue(title.label.contains("Sample reading list export"), "Switching tabs preserves the selected chat")
            }
            let sidebar = app.otherElements["agents-sidebar-column"]
            let detail = app.otherElements["agents-detail-column"]
            XCTAssertTrue(sidebar.exists); XCTAssertTrue(detail.exists)
            XCTAssertEqual(sidebar.frame.minX, app.windows.firstMatch.frame.minX, accuracy: 1,
                           "The sidebar is attached to the window edge")
            XCTAssertTrue((280...320).contains(sidebar.frame.width))
            XCTAssertEqual(sidebar.frame.maxX, detail.frame.minX, accuracy: 1,
                           "The sidebar and detail share a divider with no floating-card gutter")
            let composer = app.textFields["prompt-composer"]
            XCTAssertTrue(composer.waitForExistence(timeout: 5))
            XCTAssertEqual(app.buttons["pane-mode-toggle"].value as? String, "Chat view")
            XCTAssertTrue(app.staticTexts["Your reading list is ready"].exists)
            XCTAssertLessThanOrEqual(composer.frame.width, 800)
            XCTAssertGreaterThanOrEqual(composer.frame.minX, detail.frame.minX)
            XCTAssertLessThanOrEqual(composer.frame.maxX, detail.frame.maxX)
            XCTAssertTrue(app.buttons["pane-mode-toggle"].isHittable)
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = orientation == .portrait ? "ipad-chat-tabs-portrait" : "ipad-chat-tabs-landscape"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testSidebarToolsAndDraftSurviveModeChangesAtLargeText() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-HerdrDemoMode", "-HerdrAgentChatFixture", "-herdr.smartAlerts", "NO",
                               "-herdr.ios.appearance.glass", "YES",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        try XCTSkipIf(app.windows.firstMatch.frame.width < 600, "iPad workspace regression")
        let card = app.buttons["agent-card-demo1|w2:p1"]
        XCTAssertTrue(card.waitForExistence(timeout: 10)); card.tap()
        let composer = app.textFields["prompt-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap(); composer.typeText("Keep this draft while reviewing the session")
        app.staticTexts["pane-session-title"].tap()
        app.buttons["pane-mode-toggle"].tap()
        app.buttons["pane-action-mode-terminal"].tap()
        app.buttons["pane-mode-toggle"].tap()
        app.buttons["pane-action-mode-chat"].tap()
        XCTAssertEqual(composer.value as? String, "Keep this draft while reviewing the session")
        app.buttons["agents-list-actions"].tap()
        XCTAssertTrue(app.buttons["car-mode-open"].waitForExistence(timeout: 3))
        app.buttons["Refresh"].tap()
        let saved = app.buttons["hud-chats-destination"]
        XCTAssertTrue(saved.isHittable); saved.tap()
        XCTAssertTrue(app.buttons["hud-chats-machine"].waitForExistence(timeout: 5))
        card.tap()
        XCTAssertEqual(composer.value as? String, "Keep this draft while reviewing the session")
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "ipad-agents-large-text"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func tab(_ name: String, app: XCUIApplication) -> XCUIElement {
        let candidates = [app.tabBars.buttons[name], app.cells[name].firstMatch, app.buttons[name].firstMatch]
        let predicate = NSPredicate { _, _ in candidates.contains { $0.exists && $0.isHittable } }
        let ready = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed, "Tab must remain reachable: \(name)")
        return candidates.first { $0.exists && $0.isHittable } ?? candidates[0]
    }
}
