import XCTest

final class HerdrFirstMateMachinesUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAllMachinesIsTheDefaultAndEveryHostRemainsSelectable() throws {
        let app = launchDemo()
        let picker = app.buttons["first-mate-machine-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(picker.label.contains("All Machines"), "Fresh installs must open on All Machines, got \(picker.label)")

        let desktopRow = app.buttons["first-mate-feature-demo1-demo-session-continuity"]
        XCTAssertTrue(reach(desktopRow, app: app))
        XCTAssertTrue(desktopRow.label.contains("desktop"), "The combined row must identify its owning host: \(desktopRow.label)")
        let laptopRow = app.buttons["first-mate-feature-demo2-demo-session-continuity"]
        XCTAssertTrue(reach(laptopRow, app: app))
        XCTAssertTrue(laptopRow.label.contains("laptop"), "The combined row must identify its owning host: \(laptopRow.label)")
        XCTAssertTrue(reach(app.buttons["first-mate-feature-demo2-demo2-release-checklist"], app: app))

        selectMachine("desktop", app: app)
        XCTAssertTrue(reach(desktopRow, app: app))
        assertAbsent(laptopRow, app: app)

        selectMachine("laptop", app: app)
        XCTAssertTrue(reach(laptopRow, app: app))
        assertAbsent(desktopRow, app: app)

        selectMachine("All Machines", app: app)
        XCTAssertTrue(reach(desktopRow, app: app))
        XCTAssertTrue(reach(laptopRow, app: app))
    }

    @MainActor
    func testOpeningAFeatureAndReturningKeepsTheSelectedScope() throws {
        let app = launchDemo()
        selectMachine("desktop", app: app)
        let desktopRow = app.buttons["first-mate-feature-demo1-demo-session-continuity"]
        XCTAssertTrue(reach(desktopRow, app: app))
        desktopRow.tap()
        XCTAssertTrue(app.descendants(matching: .any)["first-mate-composer"].waitForExistence(timeout: 5))

        if app.windows.firstMatch.frame.width < 700, app.navigationBars.buttons.firstMatch.exists {
            app.navigationBars.buttons.firstMatch.tap()
        }
        let picker = app.buttons["first-mate-machine-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(picker.label.contains("desktop"), "Opening a feature must not change the browsing scope")

        tapTab("Agents", app: app)
        tapTab("First Mate", app: app)
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(picker.label.contains("desktop"), "Returning from another tab must not narrow the scope")
        assertAbsent(app.buttons["first-mate-feature-demo2-demo-session-continuity"], app: app)
    }

    @MainActor
    func testCreateFromAllMachinesRequiresAnExplicitDestination() throws {
        let app = launchDemo()
        app.buttons["first-mate-new-feature"].tap()
        // All Machines starts with no destination and accepts no repository
        // until one host is chosen.
        let destination = app.buttons["first-mate-create-machine"]
        XCTAssertTrue(destination.waitForExistence(timeout: 5))
        XCTAssertTrue(destination.label.contains("Choose a machine"), "Got \(destination.label)")
        destination.tap()
        let laptopOption = app.buttons["laptop"].firstMatch
        XCTAssertTrue(laptopOption.waitForExistence(timeout: 5))
        laptopOption.tap()
        XCTAssertTrue(app.staticTexts["Repository on laptop"].waitForExistence(timeout: 5))

        let title = app.descendants(matching: .any)["first-mate-create-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("Route the laptop checklist")
        let goal = app.descendants(matching: .any)["first-mate-create-goal"]
        goal.tap()
        goal.typeText("Keep the release steps attached to the host that runs them.")
        let folder = app.descendants(matching: .any)["first-mate-create-folder"]
        scrollTo(folder, app: app)
        folder.tap()
        folder.typeText("/workspace/release-tools")

        let submit = app.buttons["first-mate-create-submit"]
        scrollTo(submit, app: app)
        XCTAssertTrue(submit.isEnabled)
        submit.tap()

        XCTAssertTrue(app.descendants(matching: .any)["first-mate-composer"].waitForExistence(timeout: 5))
        if app.windows.firstMatch.frame.width < 700, app.navigationBars.buttons.firstMatch.exists {
            app.navigationBars.buttons.firstMatch.tap()
        }
        let created = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "first-mate-feature-demo2-", "Route the laptop checklist"
        )).firstMatch
        XCTAssertTrue(reach(created, app: app), "The created feature must belong to the chosen laptop host")
    }

    @MainActor
    func testMachineControlsStayReachableAtAccessibilityTextSizes() throws {
        let app = launchDemo(extraArguments: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge"
        ])
        let picker = app.buttons["first-mate-machine-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        XCTAssertTrue(picker.isHittable)
        let newFeature = app.buttons["first-mate-new-feature"]
        XCTAssertTrue(newFeature.exists)
        XCTAssertTrue(newFeature.isHittable)
        XCTAssertTrue(reach(app.buttons["first-mate-feature-demo1-demo-session-continuity"], app: app))
        XCTAssertTrue(reach(app.buttons["first-mate-feature-demo2-demo-session-continuity"], app: app))
    }

    // MARK: - Helpers

    @MainActor
    private func launchDemo(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-HerdrFirstMateDemo", "-HerdrResetFirstMateScope",
            "-herdr.firstMate.appearance", "light", "-herdr.smartAlerts", "NO"
        ] + extraArguments
        app.launch()
        XCTAssertTrue(app.buttons["first-mate-feature-demo1-demo-session-continuity"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func selectMachine(_ name: String, app: XCUIApplication) {
        let picker = app.buttons["first-mate-machine-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        let option = app.buttons[name]
        XCTAssertTrue(option.waitForExistence(timeout: 5), "Missing machine option \(name)")
        option.tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
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

    @MainActor
    private func reach(_ element: XCUIElement, app: XCUIApplication, swipes: Int = 8) -> Bool {
        for _ in 0..<swipes {
            if element.exists && element.isHittable { return true }
            scrollUp(app)
        }
        return element.exists && element.isHittable
    }

    /// Scrolls through the whole list before concluding a filtered row is gone,
    /// so lazy rendering cannot make an absent row look merely off-screen.
    @MainActor
    private func assertAbsent(_ element: XCUIElement, app: XCUIApplication, swipes: Int = 8) {
        for _ in 0..<swipes {
            XCTAssertFalse(element.exists, "A filtered-out machine's row must not remain visible")
            scrollUp(app)
        }
        XCTAssertFalse(element.exists)
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

    @MainActor
    private func scrollTo(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<8 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.exists && element.isHittable)
    }
}
