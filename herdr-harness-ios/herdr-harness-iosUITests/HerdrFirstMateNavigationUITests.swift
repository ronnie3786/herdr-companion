import XCTest

final class HerdrFirstMateNavigationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testEditingTheSameHostClearsItsOldFeatureDestination() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-HerdrFirstMateDemo", "-HerdrResetFirstMateScope", "-herdr.firstMate.appearance", "light", "-herdr.smartAlerts", "NO"]
        app.launch()
        let secondFeature = app.buttons["first-mate-feature-demo1-demo-search"]
        XCTAssertTrue(secondFeature.waitForExistence(timeout: 10))
        for _ in 0..<4 where !secondFeature.isHittable { scrollUp(app) }
        XCTAssertTrue(secondFeature.isHittable)
        secondFeature.tap()
        XCTAssertTrue(app.descendants(matching: .any)["first-mate-composer"].waitForExistence(timeout: 5))

        tapTab("Settings", app: app)
        let host = app.buttons["settings-machine-row-demo1"]
        XCTAssertTrue(host.waitForExistence(timeout: 5))
        host.tap()
        let save = app.buttons["machine-editor-save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        // Demo hosts intentionally have no network address. Enter a valid synthetic
        // address so this exercises a successful edit, rather than URL validation.
        let serverURL = app.textFields["Server URL"]
        XCTAssertTrue(serverURL.waitForExistence(timeout: 5))
        serverURL.tap()
        serverURL.typeText("https://example.invalid")
        // Saving the same host changes the connection generation without changing
        // its ID or demo mode. The previous detail must not control a new selection.
        save.tap()
        XCTAssertTrue(host.waitForExistence(timeout: 5),
            "The host edit must save successfully before checking navigation. "
            + "Run this test with simulator code signing enabled so Keychain remains available. "
            + "Visible alert: \(app.alerts.firstMatch.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " "))")
        tapTab("First Mate", app: app)

        XCTAssertTrue(secondFeature.waitForExistence(timeout: 5))
        for _ in 0..<6 where !secondFeature.isHittable { scrollUp(app) }
        XCTAssertTrue(secondFeature.isHittable)
        XCTAssertFalse(app.descendants(matching: .any)["first-mate-composer"].exists)
        secondFeature.tap()
        let composer = app.descendants(matching: .any)["first-mate-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Make review evidence searchable"].exists)
        composer.tap()
        composer.typeText("Continue the search feature after reconnecting.")
        app.buttons["first-mate-send"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "first-mate-message-", "Continue the search feature after reconnecting."
        )).firstMatch.waitForExistence(timeout: 5))
        app.terminate()
    }

    @MainActor
    private func scrollUp(_ app: XCUIApplication) {
        // On iPad the swipe must land on the sidebar list, not the detail column.
        let list = app.scrollViews["first-mate-feature-list"]
        if list.exists {
            list.swipeUp()
        } else {
            app.swipeUp()
        }
    }

    /// iPadOS renders the tab bar as floating tab-bar cells, not a classic
    /// `TabBar`, so try each query shape and take the first match.
    @MainActor
    private func tapTab(_ name: String, app: XCUIApplication) {
        let classic = app.tabBars.buttons[name]
        if classic.exists, classic.isHittable {
            classic.tap()
            return
        }
        let modern = app.cells[name]
        if modern.exists, modern.isHittable {
            modern.tap()
            return
        }
        // The floating bar nests duplicate buttons with the same label, so
        // take one match instead of requiring a unique element.
        let button = app.buttons[name].firstMatch
        if button.waitForExistence(timeout: 5) {
            button.tap()
            return
        }
        let fallback = app.descendants(matching: .any)[name].firstMatch
        XCTAssertTrue(fallback.waitForExistence(timeout: 5), "Missing tab \(name)")
        fallback.tap()
    }
}
