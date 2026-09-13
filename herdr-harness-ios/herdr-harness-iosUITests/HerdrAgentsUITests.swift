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
}
