import XCTest

final class HerdrDashboardUITests: HerdrUITestCase {
    @MainActor
    func testDashboardDestinationsAndSharedFocusMode() {
        let app = launchDemoApp(startOnDashboard: true)
        defer { app.terminate() }
        XCTAssertTrue(app.control(identifier: "dashboard").waitForExistence(timeout: 10))
        let focus = app.control(identifier: "dashboard-focus-mode")
        if focus.value as? String == "1" { focus.click() }
        let approvedReview = app.buttons["dashboard-review-prr_demo43"]
        XCTAssertTrue(approvedReview.waitForExistence(timeout: 10))
        focus.click()
        XCTAssertFalse(approvedReview.exists)
        XCTAssertTrue(app.buttons["dashboard-review-prr_demo42"].exists)
        app.buttons["dashboard-open-agent-view"].click()
        XCTAssertTrue(app.control(identifier: "agent-board").waitForExistence(timeout: 5))
        XCTAssertEqual(app.control(identifier: "dashboard-focus-mode").value as? String, "1")
        app.buttons["back-to-dashboard"].click()
        XCTAssertTrue(app.control(identifier: "dashboard").waitForExistence(timeout: 5))
        app.buttons["dashboard-review-prr_demo42"].click()
        XCTAssertTrue(app.buttons["back-to-dashboard"].waitForExistence(timeout: 5))
        app.buttons["back-to-dashboard"].click()
        app.buttons["dashboard-recent-chats"].click()
        XCTAssertTrue(app.buttons["sidebar-dashboard"].waitForExistence(timeout: 5))
        app.buttons["sidebar-dashboard"].click()
        XCTAssertTrue(app.control(identifier: "dashboard").waitForExistence(timeout: 5))
    }
}
