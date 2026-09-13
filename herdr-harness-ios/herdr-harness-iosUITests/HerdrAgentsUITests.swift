import XCTest

final class HerdrAgentsUITests: XCTestCase {
    @MainActor
    func testCardsSearchAndOpenSession() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-HerdrDemoMode"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Agents"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.tabBars.buttons["Workspaces"].exists)
        let card = app.buttons["agent-card-demo1|w2:p1"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        let workspace = app.staticTexts["agent-workspace-demo1|w2"]
        XCTAssertTrue(workspace.exists)
        XCTAssertEqual(app.staticTexts.matching(identifier: "agent-workspace-demo1|w2").count, 1)
        XCTAssertEqual(workspace.label, "Reading Journal")
        let secondAgent = app.buttons["agent-card-demo1|w2:p2"]
        XCTAssertTrue(secondAgent.waitForExistence(timeout: 3))
        XCTAssertLessThan(workspace.frame.minY, card.frame.minY)
        XCTAssertLessThan(card.frame.minY, secondAgent.frame.minY)
        XCTAssertLessThan(card.frame.height, 100, "A standard single-title card should stay compact")
        XCTAssertTrue(card.label.contains("Done"))
        let screenshot = app.screenshot()
        try screenshot.pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/herdr-agents-cards.png"))
        let search = app.textFields["Search agents"]
        search.tap()
        search.typeText("Reading Journal")
        XCTAssertTrue(card.exists)
        XCTAssertFalse(app.buttons["agent-card-demo1|w1:p1"].exists)
        search.typeText("\n")
        card.tap()
        let title = app.buttons["pane-session-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertTrue(title.label.contains("Sample reading list export"))
    }

    @MainActor
    func testLongPressRenameStarAndCloseConfirmation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-HerdrDemoMode", "-HerdrResetSidebarState"]
        app.launch()
        let card = app.buttons["agent-card-demo1|w2:p1"]
        XCTAssertTrue(card.waitForExistence(timeout: 8))
        card.press(forDuration: 1)
        let rename = app.buttons["agent-action-rename"]
        XCTAssertTrue(rename.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Open workspace"].exists)
        XCTAssertTrue(app.buttons["Mac controls"].exists)
        try app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/herdr-agent-session-menu.png"))
        rename.tap()
        let alert = app.alerts["Rename session"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        let field = alert.textFields["Session name"]
        XCTAssertEqual(field.value as? String, "Sample reading list export")
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Sample reading list export".count))
        XCTAssertFalse(alert.buttons["Save"].isEnabled, "Empty rename field: \(field.value ?? "nil")")
        field.typeText("Example reading notes")
        XCTAssertTrue(alert.buttons["Save"].isEnabled)
        alert.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Pane renamed"].waitForExistence(timeout: 3))

        card.press(forDuration: 1)
        let star = app.buttons["agent-action-star"]
        XCTAssertTrue(star.waitForExistence(timeout: 3))
        XCTAssertEqual(star.label, "Star chat")
        star.tap()
        card.press(forDuration: 1)
        XCTAssertTrue(star.waitForExistence(timeout: 3))
        XCTAssertEqual(star.label, "Unstar chat")
        app.buttons["Close session"].tap()
        let end = app.buttons["End Pi & close pane"]
        XCTAssertTrue(end.waitForExistence(timeout: 3))
        end.tap()
        let close = app.alerts["End Pi and close this pane?"]
        XCTAssertTrue(close.waitForExistence(timeout: 3))
        close.buttons["Cancel"].tap()
        XCTAssertTrue(card.exists)
        card.tap()
        XCTAssertTrue(app.buttons["pane-session-title"].waitForExistence(timeout: 5))
    }

}
