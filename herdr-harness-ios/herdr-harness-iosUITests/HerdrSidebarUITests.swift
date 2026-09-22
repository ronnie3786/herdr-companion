import XCTest

final class HerdrSidebarUITests: XCTestCase {
    @MainActor
    func testRecentsIsTheDefaultFlatNavigatorAndOpensAChat() throws {
        let app = launchDemo()

        app.buttons["sidebar-toggle"].tap()

        let range = app.descendants(matching: .any)["sidebar-recent-filter"]
        XCTAssertTrue(
            range.waitForExistence(timeout: 5),
            "Missing range menu. XCTest tree:\n\(app.debugDescription)"
        )
        XCTAssertTrue(range.label.contains("Recents"))
        XCTAssertTrue(
            app.descendants(matching: .any)["sidebar-machine-picker"].exists,
            "Missing machine menu. XCTest tree:\n\(app.debugDescription)"
        )
        XCTAssertTrue(app.textFields["Filter chats"].exists)
        XCTAssertTrue(app.buttons["sidebar-close"].exists)
        XCTAssertTrue(app.buttons["sidebar-tab-colors"].exists)
        XCTAssertTrue(
            app.descendants(matching: .any)["sidebar-new-workspace"].exists,
            "Missing new-workspace menu. XCTest tree:\n\(app.debugDescription)"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["sidebar-new-pi-session"].exists,
            "Missing new-session menu. XCTest tree:\n\(app.debugDescription)"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["sidebar-run-agent"].exists,
            "Missing run-agent menu. XCTest tree:\n\(app.debugDescription)"
        )
        XCTAssertTrue(app.descendants(matching: .any)["sidebar-recents-section"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["sidebar-workspace-demo1|w1"].exists)

        let pane = app.buttons["sidebar-pane-demo1|w1:p2"]
        scrollToElement(pane, in: app)
        pane.tap()
        let firstTitle = app.staticTexts["pane-session-title"]
        XCTAssertTrue(firstTitle.waitForExistence(timeout: 3))
        XCTAssertTrue(firstTitle.label.contains("Choose sample garden colors"))
        XCTAssertFalse(app.buttons["sidebar-toggle"].exists)

        returnToAgents(app)
        app.buttons["sidebar-toggle"].tap()
        let otherWorkspacePane = app.buttons["sidebar-pane-demo1|w2:p1"]
        scrollToElement(otherWorkspacePane, in: app)
        otherWorkspacePane.tap()
        let secondTitle = app.staticTexts["pane-session-title"]
        XCTAssertTrue(secondTitle.waitForExistence(timeout: 3))
        XCTAssertTrue(secondTitle.label.contains("Sample reading list export"))
    }

    @MainActor
    func testAllShowsPrioritySectionsAndTheActualHierarchyWithoutDuplicates() throws {
        let app = launchDemo()
        openSidebarAndChooseAll(app)

        XCTAssertTrue(app.descendants(matching: .any)["sidebar-unread-section"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["sidebar-starred-section"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons.matching(identifier: "sidebar-pane-demo1|w1:p2").count, 1)
        XCTAssertEqual(app.buttons.matching(identifier: "sidebar-pane-demo1|w1:p1").count, 1)

        let workspace = app.buttons["sidebar-workspace-demo1|w1"]
        scrollToElement(workspace, in: app)
        XCTAssertTrue(workspace.exists)

        let tab = app.buttons["sidebar-tab-demo1|w1:t2"]
        scrollToElement(tab, in: app)
        XCTAssertTrue(tab.exists)

        let ordinaryPane = app.buttons["sidebar-pane-demo1|w1:p3"]
        scrollToElement(ordinaryPane, in: app)
        XCTAssertTrue(ordinaryPane.exists)
    }

    @MainActor
    func testSidebarWorkspaceRowCollapsesAndExpandsOnlyItsHierarchy() throws {
        let app = launchDemo()
        openSidebarAndChooseAll(app)

        let workspace = app.buttons["sidebar-workspace-demo1|w1"]
        scrollToElement(workspace, in: app)
        XCTAssertTrue(workspace.exists)

        let ordinaryPane = app.buttons["sidebar-pane-demo1|w1:p3"]
        scrollToElement(ordinaryPane, in: app)
        XCTAssertTrue(ordinaryPane.exists)

        workspace.tap()
        XCTAssertFalse(ordinaryPane.waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["sidebar-pane-demo1|w1:p2"].exists, "Unread promotion must remain outside workspace collapse")

        workspace.tap()
        scrollToElement(ordinaryPane, in: app)
        XCTAssertTrue(ordinaryPane.waitForExistence(timeout: 2))
    }

    @MainActor
    func testTabColorSheetExplainsLocalOnlyStorageAndOffersEveryLabel() throws {
        let app = launchDemo()

        app.buttons["sidebar-toggle"].tap()
        let colors = app.buttons["sidebar-tab-colors"]
        XCTAssertTrue(colors.waitForExistence(timeout: 5))
        colors.tap()

        XCTAssertTrue(app.descendants(matching: .any)["chat-color-filter-sheet"].waitForExistence(timeout: 3))
        for color in ["lavender", "iris", "rose", "clay", "sage", "slate"] {
            let edit = app.buttons["chat-color-label-edit-\(color)"]
            scrollToElement(edit, in: app)
            XCTAssertTrue(edit.exists)
        }
        let localOnlyCopy = app.staticTexts["Colors and labels are saved only on this iPhone or iPad. Mac assignments are not imported or synchronized."]
        scrollToElement(localOnlyCopy, in: app)
        XCTAssertTrue(localOnlyCopy.exists)
    }

    @MainActor
    func testSearchAndColorScopeSurviveDrawerReopenButResetOnRelaunch() throws {
        let app = launchDemo()

        app.buttons["sidebar-toggle"].tap()
        let pane = app.buttons["sidebar-pane-demo1|w1:p2"]
        scrollToElement(pane, in: app)
        pane.press(forDuration: 1)

        let tabColorMenu = app.descendants(matching: .any)["Tab color"]
        XCTAssertTrue(
            tabColorMenu.waitForExistence(timeout: 3),
            "Missing Tab color context menu. XCTest tree:\n\(app.debugDescription)"
        )
        tabColorMenu.tap()
        let lavenderAssignment = app.buttons["tab-color-lavender"]
        XCTAssertTrue(lavenderAssignment.waitForExistence(timeout: 3))
        lavenderAssignment.tap()

        let colorFilter = app.buttons["sidebar-tab-colors"]
        XCTAssertTrue(colorFilter.waitForExistence(timeout: 3))
        colorFilter.tap()
        let lavenderFilter = app.buttons["chat-color-filter-lavender"]
        XCTAssertTrue(lavenderFilter.waitForExistence(timeout: 3))
        lavenderFilter.tap()
        app.buttons["Done"].tap()

        let search = app.textFields["Filter chats"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText("garden colors")
        app.keyboards.buttons["Done"].tap()

        let filteredPane = app.buttons["sidebar-pane-demo1|w1:p2"]
        XCTAssertTrue(filteredPane.waitForExistence(timeout: 3))
        filteredPane.tap()
        XCTAssertTrue(app.staticTexts["pane-session-title"].waitForExistence(timeout: 3))

        returnToAgents(app)
        app.buttons["sidebar-toggle"].tap()
        let reopenedSearch = app.textFields["Filter chats"]
        XCTAssertTrue(reopenedSearch.waitForExistence(timeout: 3))
        XCTAssertEqual(reopenedSearch.value as? String, "garden colors")
        XCTAssertEqual(app.buttons["sidebar-tab-colors"].value as? String, "Filtered by Lavender")
        XCTAssertTrue(app.buttons["sidebar-pane-demo1|w1:p2"].exists)

        app.terminate()
        app.launchArguments = ["-HerdrDemoMode"]
        app.launch()
        app.buttons["sidebar-toggle"].tap()

        let relaunchedSearch = app.textFields["Filter chats"]
        XCTAssertTrue(relaunchedSearch.waitForExistence(timeout: 5))
        XCTAssertNotEqual(relaunchedSearch.value as? String, "garden colors")
        XCTAssertEqual(app.buttons["sidebar-tab-colors"].value as? String, "No filter")
    }

    @MainActor
    private func launchDemo() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-HerdrDemoMode", "-HerdrResetSidebarState"]
        app.launch()
        return app
    }

    @MainActor
    private func openSidebarAndChooseAll(_ app: XCUIApplication) {
        app.buttons["sidebar-toggle"].tap()
        let range = app.descendants(matching: .any)["sidebar-recent-filter"]
        XCTAssertTrue(
            range.waitForExistence(timeout: 5),
            "Missing range menu. XCTest tree:\n\(app.debugDescription)"
        )
        range.tap()
        let all = app.buttons["All"]
        XCTAssertTrue(all.waitForExistence(timeout: 3))
        all.tap()
    }

    @MainActor
    private func returnToAgents(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 3))
        back.tap()
        XCTAssertTrue(app.buttons["sidebar-toggle"].waitForExistence(timeout: 3))
    }

    @MainActor
    private func scrollToElement(_ element: XCUIElement, in app: XCUIApplication) {
        var attempts = 0
        while !element.exists, attempts < 8 {
            app.swipeUp()
            attempts += 1
        }
    }
}
