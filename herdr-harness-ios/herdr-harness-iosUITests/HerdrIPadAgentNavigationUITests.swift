import XCTest

@MainActor
final class HerdrIPadAgentNavigationUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testAgentChatKeepsTabsAvailableAndPreservesSelection() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-HerdrDemoMode", "-herdr.smartAlerts", "NO"]
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
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = orientation == .portrait ? "ipad-chat-tabs-portrait" : "ipad-chat-tabs-landscape"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func tab(_ name: String, app: XCUIApplication) -> XCUIElement {
        let candidates = [app.tabBars.buttons[name], app.cells[name].firstMatch, app.buttons[name].firstMatch]
        let predicate = NSPredicate { _, _ in candidates.contains { $0.exists && $0.isHittable } }
        let ready = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed, "Tab must remain reachable: \(name)")
        return candidates.first { $0.exists && $0.isHittable } ?? candidates[0]
    }
}
